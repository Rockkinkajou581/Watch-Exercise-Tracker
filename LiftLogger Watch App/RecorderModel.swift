//
//  RecorderModel.swift
//  LiftLogger Watch App  (add to the WATCH target only)
//
//  Records wrist IMU at 50 Hz into <session>_readings.csv and set events into
//  <session>_sets.csv, then transfers both files to the iPhone app.
//
//  Output schema (must match build_workouts_csv.py):
//    readings: subject,session,time_ms,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z
//    sets:     subject,session,exercise,start_ms,end_ms
//
//  Clock: every timestamp (samples AND set taps) uses the watch's
//  time-since-boot clock (CMDeviceMotion.timestamp / ProcessInfo.systemUptime),
//  so readings and set boundaries are guaranteed to align.
//

import Foundation
import Combine
import CoreMotion
import HealthKit
import WatchConnectivity
import WatchKit

final class RecorderModel: NSObject, ObservableObject {

    enum Phase { case idle, resting, inSet }

    // MARK: - UI state (mutate on main thread only)
    @Published var phase: Phase = .idle
    @Published var subject: String = "S01"
    @Published var sessionID: String = ""
    @Published var currentExercise: String = ""
    @Published var setStartDate: Date = Date()
    @Published var sampleCount: Int = 0
    @Published var setCount: Int = 0
    @Published var status: String = "ready"
    @Published var pendingFiles: [URL] = []   // recorded but not yet transferred

    /// Edit to change the exercises offered on the watch.
    /// Do NOT name one "rest" — the transform script reserves that label
    /// for everything outside a set.
    let exercises = [
        "bicep_curl", "hammer_curl", "shoulder_press", "lateral_raise",
        "tricep_pushdown", "bent_over_row", "chest_press",
    ]

    // MARK: - private
    private let motion = CMMotionManager()
    private let workQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1   // serial: all file IO happens here
        q.name = "liftlogger.recorder"
        return q
    }()

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?

    private var readingsHandle: FileHandle?
    private var setsHandle: FileHandle?
    private var readingsURL: URL?
    private var setsURL: URL?

    private var lineBuffer: [String] = []   // touched only on workQueue
    private let flushEvery = 50             // ~1 s of samples at 50 Hz
    private var csvPrefix = ""              // "subject,session", frozen at session start
    private var setStartMS: Double = 0

    private static let readingsHeader =
        "subject,session,time_ms,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z\n"
    private static let setsHeader =
        "subject,session,exercise,start_ms,end_ms\n"

    private var docsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - lifecycle

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        requestHealthAuthorization()
        scanPending()
    }

    // MARK: - session control (call from UI / main thread)

    func startSession() {
        let subj = Self.sanitize(subject)
        let sid = Self.sessionIDNow()
        subject = subj
        sessionID = sid
        csvPrefix = "\(subj),\(sid)"
        sampleCount = 0
        setCount = 0

        do {
            try openFiles(sessionID: sid)
        } catch {
            status = "file error: \(error.localizedDescription)"
            return
        }

        startWorkoutKeepAlive()   // keeps app + sensors alive with screen off
        startMotion()
        status = "recording"
        phase = .resting
    }

    func startSet(_ exercise: String) {
        guard phase == .resting else { return }
        currentExercise = exercise
        setStartMS = ProcessInfo.processInfo.systemUptime * 1000.0
        setStartDate = Date()
        phase = .inSet
        WKInterfaceDevice.current().play(.start)
    }

    func endSet() {
        guard phase == .inSet else { return }
        let endMS = ProcessInfo.processInfo.systemUptime * 1000.0
        let startStr = String(format: "%.1f", setStartMS)
        let endStr = String(format: "%.1f", endMS)
        let line = "\(csvPrefix),\(currentExercise),\(startStr),\(endStr)\n"
        workQueue.addOperation { [weak self] in
            guard let self, let h = self.setsHandle,
                  let d = line.data(using: .utf8) else { return }
            try? h.write(contentsOf: d)
        }
        setCount += 1
        currentExercise = ""
        phase = .resting
        WKInterfaceDevice.current().play(.stop)
    }

    func endSession() {
        if phase == .inSet { endSet() }   // auto-close an open set
        stopWorkoutKeepAlive()
        motion.stopDeviceMotionUpdates()
        status = "finishing…"

        let subj = Self.sanitize(subject)
        let sid = sessionID
        // Queued AFTER any pending sample/set writes (serial FIFO queue),
        // so this runs once all data is on disk.
        workQueue.addOperation { [weak self] in
            guard let self else { return }
            self.flushReadings()
            try? self.readingsHandle?.close()
            try? self.setsHandle?.close()
            self.readingsHandle = nil
            self.setsHandle = nil

            if let r = self.readingsURL {
                WCSession.default.transferFile(
                    r, metadata: ["kind": "readings", "session": sid, "subject": subj])
            }
            if let s = self.setsURL {
                WCSession.default.transferFile(
                    s, metadata: ["kind": "sets", "session": sid, "subject": subj])
            }
            DispatchQueue.main.async {
                self.status = "sending to iPhone… (can take a minute)"
                self.phase = .idle
                self.scanPending()
            }
        }
    }

    /// Re-queue any CSVs that were recorded but never made it to the phone
    /// (e.g. phone out of range, app force-quit before transfer finished).
    func resendPending() {
        let files = pendingFiles
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent  // "<sid>_readings"
            let parts = name.split(separator: "_")
            let sid = parts.first.map(String.init) ?? "unknown"
            let kind = parts.count > 1 ? String(parts.last!) : "data"
            WCSession.default.transferFile(
                url, metadata: ["kind": kind, "session": sid, "subject": Self.sanitize(subject)])
        }
        setStatus("re-queued \(files.count) file(s)")
    }

    // MARK: - motion

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            status = "device motion unavailable"
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 50.0   // FS=50 in the trainer
        let prefix = csvPrefix
        motion.startDeviceMotionUpdates(to: workQueue) { [weak self] dm, _ in
            guard let self, let dm else { return }
            let tms = dm.timestamp * 1000.0
            // Total acceleration INCLUDING gravity (g). Gravity encodes arm
            // orientation, which helps separate exercises. Keep this definition
            // consistent across every recording you ever make.
            let ax = dm.userAcceleration.x + dm.gravity.x
            let ay = dm.userAcceleration.y + dm.gravity.y
            let az = dm.userAcceleration.z + dm.gravity.z
            let r = dm.rotationRate   // rad/s
            let line = String(
                format: "%@,%.1f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f",
                prefix, tms, ax, ay, az, r.x, r.y, r.z)
            self.lineBuffer.append(line)
            if self.lineBuffer.count >= self.flushEvery { self.flushReadings() }
        }
    }

    /// workQueue only. Writes buffered lines to disk so a crash loses ≤1 s of data.
    private func flushReadings() {
        guard !lineBuffer.isEmpty, let h = readingsHandle else { return }
        let n = lineBuffer.count
        let chunk = lineBuffer.joined(separator: "\n") + "\n"
        lineBuffer.removeAll(keepingCapacity: true)
        if let data = chunk.data(using: .utf8) {
            try? h.write(contentsOf: data)
        }
        DispatchQueue.main.async { self.sampleCount += n }
    }

    // MARK: - files

    private func openFiles(sessionID: String) throws {
        let rURL = docsDir.appendingPathComponent("\(sessionID)_readings.csv")
        let sURL = docsDir.appendingPathComponent("\(sessionID)_sets.csv")
        try Self.readingsHeader.data(using: .utf8)!.write(to: rURL)
        try Self.setsHeader.data(using: .utf8)!.write(to: sURL)
        readingsURL = rURL
        setsURL = sURL
        readingsHandle = try FileHandle(forWritingTo: rURL)
        setsHandle = try FileHandle(forWritingTo: sURL)
        try readingsHandle?.seekToEnd()
        try setsHandle?.seekToEnd()
    }

    private func scanPending() {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: docsDir, includingPropertiesForKeys: nil)) ?? []
        let csvs = all.filter { $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        DispatchQueue.main.async { self.pendingFiles = csvs }
    }

    // MARK: - HealthKit workout keep-alive

    private func requestHealthAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            setStatus("HealthKit unavailable")
            return
        }
        healthStore.requestAuthorization(
            toShare: [HKObjectType.workoutType()], read: nil
        ) { [weak self] ok, _ in
            if !ok { self?.setStatus("Health auth denied — screen sleep may pause recording") }
        }
    }

    private func startWorkoutKeepAlive() {
        let cfg = HKWorkoutConfiguration()
        cfg.activityType = .traditionalStrengthTraining
        cfg.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: cfg)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore, workoutConfiguration: cfg)
            session.delegate = self
            session.startActivity(with: Date())
            builder.beginCollection(withStart: Date()) { [weak self] _, error in
                if let error { self?.setStatus("builder: \(error.localizedDescription)") }
            }
            workoutSession = session
            workoutBuilder = builder
        } catch {
            // Recording still works, but watchOS may suspend the app when the
            // screen sleeps. Fix the HealthKit capability / permissions.
            setStatus("keep-alive failed: \(error.localizedDescription)")
        }
    }

    private func stopWorkoutKeepAlive() {
        workoutSession?.end()
        workoutBuilder?.endCollection(withEnd: Date()) { [weak self] _, _ in
            // Discard so data-collection sessions don't clutter the Health app.
            // Use finishWorkout(completion:) instead if you want ring credit.
            self?.workoutBuilder?.discardWorkout()
            self?.workoutSession = nil
            self?.workoutBuilder = nil
        }
    }

    // MARK: - helpers

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    static func sanitize(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return cleaned.isEmpty ? "S01" : cleaned
    }

    private static func sessionIDNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - HKWorkoutSessionDelegate

extension RecorderModel: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {}

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        setStatus("workout error: \(error.localizedDescription)")
    }
}

// MARK: - WCSessionDelegate (watch side)

extension RecorderModel: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let s = session.receivedApplicationContext["subject"] as? String {
            DispatchQueue.main.async { self.subject = Self.sanitize(s) }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        if let s = ctx["subject"] as? String {
            DispatchQueue.main.async { self.subject = Self.sanitize(s) }
        }
    }

    func session(_ session: WCSession,
                 didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error == nil {
            // Delivered — remove the local copy so it can't be re-sent twice.
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
            setStatus("delivered to iPhone")
        } else {
            setStatus("transfer failed — use Resend on home screen")
        }
        scanPending()
    }
}
