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
import CoreML
import CoreMotion
// HealthKit removed for free-account testing (HealthKit is a restricted
// entitlement requiring a paid Apple Developer Program membership).
// import HealthKit
import WatchConnectivity
import WatchKit

final class RecorderModel: NSObject, ObservableObject {

    enum Phase { case idle, resting, countdown, inSet, enteringReps, autoDetecting }

    /// Reserved label for sets the user marks as bad. Training drops any window
    /// touching a discard interval. MUST match config.DISCARD_LABEL in the Python.
    static let discardLabel = "discard"

    /// The model's idle class. MUST match config.REST_LABEL in the Python.
    static let restLabel = "rest"

    // MARK: - live auto-detect tuning (must stay consistent with the trainer)
    /// Samples per inference window. MUST match config.WINDOW (2 s @ 50 Hz).
    static let windowSize = 100
    /// Channels per sample. MUST match config.N_CHANNELS / CHANNELS order.
    static let nChannels = 6
    /// Sample rate. MUST match config.FS and motion.deviceMotionUpdateInterval.
    static let fs = 50
    /// Frames a bout is resampled to by the legacy whole-bout rep model.
    /// MUST match config.REP_BOUT_LEN.
    static let repBoutLen = 256
    /// Hop between rep-density windows when the bundled model is the windowed one.
    /// MUST match config.REP_WIN_STRIDE (1 s at 50 Hz). The window LENGTH isn't a
    /// constant here — it's read off the compiled model, so retraining with a
    /// different REP_WINDOW needs no Swift change.
    static let repWinStride = 50
    /// Default rep count pre-filled on the End Set screen (manual sessions).
    static let defaultReps = 8
    /// Run a prediction every this many new samples (~2x/sec at 50 Hz).
    private let inferenceStride = 25
    /// Below this top-class probability, a window is treated as rest (don't log guesses).
    private let liveConfidenceThreshold = 0.6
    /// Consecutive agreeing predictions before we OPEN a set (debounce).
    private let startWindows = 3
    /// Consecutive agreeing predictions before we act on a change while a set is
    /// already open. Higher than `startWindows`: it should be harder to leave an
    /// exercise than to enter one, so a couple of ambiguous windows can't end a set.
    private let stopWindows = 5
    /// Mid-set pauses (a hold at the top, a breath at the bottom, resetting grip)
    /// look like rest to a 2 s window. After rest goes stable we keep the set open
    /// this long; if the same exercise comes back before the grace expires the set
    /// simply continues instead of being split into fragments. Raise this if long
    /// pauses still split a set; lower it if back-to-back sets get merged into one.
    private let restGraceMS = 5000.0
    /// Detected sets shorter than this are treated as noise and not logged.
    private let minDetectedMS = 1500.0
    /// Samples of lead-in kept before a bout commits, so its first reps aren't missed.
    private let repLeadSamples = 150
    /// Hard cap on a single bout's buffered samples (~120 s at 50 Hz).
    private let maxBoutSamples = 6000

    /// Seconds counted down (3-2-1) after tapping an exercise, before the set
    /// window actually starts — gives you time to get into position so the
    /// front of every set is clean. start_ms is stamped raw here; the training
    /// pipeline shaves a little more off each end when it draws labels (see
    /// TRIM_START_SEC / TRIM_END_SEC in training/config.py).
    static let countdownSeconds = 3

    // MARK: - UI state (mutate on main thread only)
    @Published var phase: Phase = .idle
    @Published var subject: String = "S01"
    @Published var sessionID: String = ""
    @Published var currentExercise: String = ""
    @Published var setStartDate: Date = Date()
    @Published var countdownRemaining: Int = 0   // shown during .countdown
    @Published var sampleCount: Int = 0
    @Published var setCount: Int = 0
    @Published var canDiscardLast: Bool = false   // true after a set, until discarded/new set
    @Published var repsEntry: Int = RecorderModel.defaultReps   // editable on the End Set screen
    @Published var repsFromPhone = false        // true when repsEntry came from the phone tagger
    @Published var status: String = "ready"
    @Published var pendingFiles: [URL] = []   // recorded but not yet transferred

    // Live auto-detect UI state (mutate on main thread only)
    @Published var liveExercise: String = "—"   // model's current top class
    @Published var liveConfidence: Double = 0    // its probability, 0…1
    @Published var detectedCount: Int = 0        // sets the model has logged this session
    @Published var lastDetectedReps: Int = 0     // reps counted for the most recent logged set

    /// Edit to change the exercises offered on the watch.
    /// Do NOT name one "rest" or "discard" — the transform script reserves those
    /// labels (rest = outside any set; discard = a set marked bad).
    let exercises = [
        "incline_chest_press", "machine_shoulder_press", "machine_row_wide",
        "cable_push_down", "overhead_triceps", "dumbbell_hammer_curl",
        "forearm_raises",
    ]

    // MARK: - private
    private let motion = CMMotionManager()
    private let workQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1   // serial: all file IO happens here
        q.name = "liftlogger.recorder"
        return q
    }()

    // HealthKit keep-alive disabled for free-account testing.

    private var readingsHandle: FileHandle?
    private var setsHandle: FileHandle?
    private var readingsURL: URL?
    private var setsURL: URL?

    private var lineBuffer: [String] = []   // touched only on workQueue
    private let flushEvery = 50             // ~1 s of samples at 50 Hz
    private var csvPrefix = ""              // "subject,session", frozen at session start
    private var setStartMS: Double = 0
    private var countdownTimer: Timer?
    private var lastSetStartMS: Double?     // boundaries of the most recent completed set,
    private var lastSetEndMS: Double?       // so it can be discarded after the fact
    private var pendingSetEndMS: Double = 0 // end of the set awaiting rep entry
    private var repsEntryEdited = false     // user turned the dial; don't overwrite their number

    // MARK: - live auto-detect state (touched on workQueue, except @Published mirrors)
    private let classifier = ExerciseClassifier()
    private let repCounter = RepCounter()                 // unsupervised fallback
    private let repModel = RepDensityCounter()            // supervised, if bundled
    private var leadRing: [[Float]] = []    // recent samples kept for bout lead-in
    private var boutBuffer: [[Float]]?      // samples of the active bout (nil = none open)
    private var isAutoSession = false
    private var ring: [[Float]] = []        // rolling last `windowSize` samples (nChannels each)
    private var samplesSinceInference = 0
    private var candidateLabel = RecorderModel.restLabel   // debounced label being voted on
    private var candidateStreak = 0
    private var pendingEndMS: Double?       // rest went stable here; set closes if it holds
    private var pendingEndSamples: Int?     // bout length at that moment, for trimming the tail
    private var activeLabel: String?        // exercise of the set currently being logged, if any
    private var activeStartMS: Double = 0
    private var activeConfSum: Double = 0   // running confidence sum over the active set
    private var activeConfN = 0
    private var detectedHandle: FileHandle?
    private var detectedURL: URL?

    private static let readingsHeader =
        "subject,session,time_ms,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z\n"
    private static let setsHeader =
        "subject,session,exercise,start_ms,end_ms,reps\n"
    private static let detectedHeader =
        "subject,session,exercise,start_ms,end_ms,reps,confidence\n"

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
        canDiscardLast = false
        lastSetStartMS = nil
        lastSetEndMS = nil

        do {
            try openFiles(sessionID: sid)
        } catch {
            status = "file error: \(error.localizedDescription)"
            return
        }

        isAutoSession = false
        // Tell the phone "rep tagger" a manual (training) session began, and hand
        // it a clock anchor (watch uptime ↔ wall clock captured together) so the
        // observer's phone taps can be mapped back onto this session's IMU timeline.
        sendPhone([
            "type": "session_start", "session": sid, "subject": subj,
            "anchorUptimeMs": ProcessInfo.processInfo.systemUptime * 1000.0,
            "anchorUnixMs": Date().timeIntervalSince1970 * 1000.0,
        ])
        startWorkoutKeepAlive()   // keeps app + sensors alive with screen off
        startMotion()
        status = "recording"
        phase = .resting
    }

    // MARK: - auto-detect session (uses the trained model; writes only detected.csv)

    /// Start a session that runs the trained model live: no exercise buttons —
    /// it watches the IMU stream and logs any exercise it recognizes. Produces
    /// <session>_detected.csv only, so these (unlabeled-by-hand) sessions can
    /// never be mistaken for training data.
    func startAutoSession() {
        guard classifier.isReady else {
            status = "AI model not on watch yet — add LiftLoggerClassifier.mlpackage "
                + "to the Watch App target in Xcode and rebuild."
            return
        }
        let subj = Self.sanitize(subject)
        let sid = Self.sessionIDNow()
        subject = subj
        sessionID = sid
        csvPrefix = "\(subj),\(sid)"
        sampleCount = 0
        detectedCount = 0
        lastDetectedReps = 0
        liveExercise = Self.restLabel
        liveConfidence = 0
        resetLiveState()

        do {
            try openDetectedFile(sessionID: sid)
        } catch {
            status = "file error: \(error.localizedDescription)"
            return
        }

        isAutoSession = true
        startWorkoutKeepAlive()
        startMotion()
        status = "auto-detecting"
        phase = .autoDetecting
    }

    private func resetLiveState() {
        ring.removeAll(keepingCapacity: true)
        leadRing.removeAll(keepingCapacity: true)
        boutBuffer = nil
        samplesSinceInference = 0
        candidateLabel = Self.restLabel
        candidateStreak = 0
        pendingEndMS = nil
        pendingEndSamples = nil
        activeLabel = nil
        activeStartMS = 0
        activeConfSum = 0
        activeConfN = 0
    }

    /// workQueue only. Buffer one sample, and every `inferenceStride` samples run
    /// the model on the latest full window.
    private func feedLive(_ sample: [Float], atMS tms: Double) {
        ring.append(sample)
        if ring.count > Self.windowSize {
            ring.removeFirst(ring.count - Self.windowSize)
        }
        // Keep a short rolling lead-in, and accumulate the active bout for rep counting.
        leadRing.append(sample)
        if leadRing.count > repLeadSamples {
            leadRing.removeFirst(leadRing.count - repLeadSamples)
        }
        if boutBuffer != nil {
            boutBuffer!.append(sample)
            if boutBuffer!.count > maxBoutSamples {
                let dropped = boutBuffer!.count - maxBoutSamples
                boutBuffer!.removeFirst(dropped)
                // pendingEndSamples indexes into this buffer — slide it too.
                if let n = pendingEndSamples { pendingEndSamples = max(0, n - dropped) }
            }
        }
        DispatchQueue.main.async { self.sampleCount += 1 }

        samplesSinceInference += 1
        guard ring.count == Self.windowSize, samplesSinceInference >= inferenceStride else { return }
        samplesSinceInference = 0
        guard let (label, conf) = classifier.predict(window: ring) else { return }
        handlePrediction(rawLabel: label, confidence: conf, atMS: tms)
    }

    /// workQueue only. Debounced segmentation: a stable non-rest class opens a
    /// "set"; sustained rest (or switching exercise) closes and logs it.
    ///
    /// Rest doesn't end a set the moment it commits. It only arms `pendingEndMS`;
    /// the set is written when rest has held for `restGraceMS`. If the same
    /// exercise returns first the set continues uninterrupted — that's what keeps
    /// a pause at the top or bottom of a rep from splitting one set into five.
    private func handlePrediction(rawLabel: String, confidence: Double, atMS tms: Double) {
        DispatchQueue.main.async {
            self.liveExercise = rawLabel
            self.liveConfidence = confidence
        }

        // Low-confidence predictions count as rest so we never log a shaky guess.
        let label = confidence >= liveConfidenceThreshold ? rawLabel : Self.restLabel
        if label == candidateLabel {
            candidateStreak += 1
        } else {
            candidateLabel = label
            candidateStreak = 1
        }

        // A set whose grace period has run out closes now, at the moment rest began.
        if let armed = pendingEndMS, tms - armed >= restGraceMS {
            closeActiveSet(endMS: armed)
        }

        // Leaving an open set takes more agreement than opening or resuming one:
        // coming back from a pause should be easy, ending a set should be hard.
        let needed: Int
        if activeLabel == nil {
            needed = startWindows                    // opening a new set
        } else if candidateLabel == activeLabel {
            needed = startWindows                    // the set is still going
        } else {
            needed = stopWindows                     // ending it, or switching exercise
        }
        guard candidateStreak >= needed else { return }   // not stable yet

        let current = activeLabel ?? Self.restLabel
        if candidateLabel == current {
            if activeLabel != nil {
                pendingEndMS = nil      // exercise is back — this set was never over
                pendingEndSamples = nil
                activeConfSum += confidence
                activeConfN += 1
            }
            return
        }

        // Stable rest during a set: arm the grace timer and keep buffering samples,
        // so if this is just a pause the reps on either side stay in one bout.
        if activeLabel != nil && candidateLabel == Self.restLabel {
            if pendingEndMS == nil {
                pendingEndMS = tms
                pendingEndSamples = boutBuffer?.count   // don't count reps in the pause tail
            }
            return
        }

        // A different exercise, or rest that already timed out: real transition.
        closeActiveSet(endMS: pendingEndMS ?? tms)
        if candidateLabel != Self.restLabel {
            activeLabel = candidateLabel
            activeStartMS = tms
            activeConfSum = confidence
            activeConfN = 1
            boutBuffer = leadRing      // seed with lead-in so the first reps aren't lost
            WKInterfaceDevice.current().play(.start)
        }
    }

    /// workQueue only. Write the active detected set (if long enough) and clear it.
    private func closeActiveSet(endMS: Double) {
        let trimTo = pendingEndSamples
        pendingEndMS = nil
        pendingEndSamples = nil
        guard let label = activeLabel else { return }
        activeLabel = nil
        var samples = boutBuffer ?? []
        boutBuffer = nil
        // Drop the trailing rest we buffered while waiting out the grace period —
        // endMS stops at the pause, so the rep model shouldn't see past it either.
        if let n = trimTo, n < samples.count { samples.removeLast(samples.count - n) }
        guard endMS - activeStartMS >= minDetectedMS else { return }   // blip — ignore
        // Prefer the trained density model; fall back to unsupervised if it isn't bundled.
        let reps = repModel.count(samples, fs: Self.fs) ?? repCounter.count(samples, fs: Self.fs)
        let avgConf = activeConfN > 0 ? activeConfSum / Double(activeConfN) : 0
        let line = "\(csvPrefix),\(label),"
            + String(format: "%.1f,%.1f,%d,%.3f\n", activeStartMS, endMS, reps, avgConf)
        if let h = detectedHandle, let d = line.data(using: .utf8) {
            try? h.write(contentsOf: d)
        }
        DispatchQueue.main.async {
            self.detectedCount += 1
            self.lastDetectedReps = reps
        }
        WKInterfaceDevice.current().play(.stop)
    }

    private func openDetectedFile(sessionID: String) throws {
        let url = docsDir.appendingPathComponent("\(sessionID)_detected.csv")
        try Self.detectedHeader.data(using: .utf8)!.write(to: url)
        detectedURL = url
        detectedHandle = try FileHandle(forWritingTo: url)
        try detectedHandle?.seekToEnd()
    }

    private func endAutoSession() {
        motion.stopDeviceMotionUpdates()
        stopWorkoutKeepAlive()
        status = "finishing…"
        let subj = Self.sanitize(subject)
        let sid = sessionID
        workQueue.addOperation { [weak self] in
            guard let self else { return }
            // Close any set still open at the moment End Session was tapped.
            self.closeActiveSet(
                endMS: self.pendingEndMS ?? ProcessInfo.processInfo.systemUptime * 1000.0)
            try? self.detectedHandle?.close()
            self.detectedHandle = nil
            if let d = self.detectedURL {
                WCSession.default.transferFile(
                    d, metadata: ["kind": "detected", "session": sid, "subject": subj])
            }
            DispatchQueue.main.async {
                self.isAutoSession = false
                self.status = "sending to iPhone… (can take a minute)"
                self.phase = .idle
                self.liveExercise = "—"
                self.scanPending()
            }
        }
    }

    /// Tapping an exercise starts a 3-2-1 countdown (time to get into position)
    /// before the set window actually opens, so its front edge is clean.
    func startSet(_ exercise: String) {
        guard phase == .resting else { return }
        currentExercise = exercise
        canDiscardLast = false        // starting a new set retires the previous discard option
        countdownRemaining = Self.countdownSeconds
        phase = .countdown
        WKInterfaceDevice.current().play(.click)
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.countdownRemaining -= 1
            if self.countdownRemaining <= 0 {
                timer.invalidate()
                self.beginSetRecording()
            } else {
                WKInterfaceDevice.current().play(.click)
            }
        }
    }

    /// Bail out during the countdown without recording a set.
    func cancelCountdown() {
        guard phase == .countdown else { return }
        countdownTimer?.invalidate()
        countdownTimer = nil
        currentExercise = ""
        phase = .resting
        WKInterfaceDevice.current().play(.failure)
    }

    /// Called when the countdown reaches zero: stamp the real set start.
    private func beginSetRecording() {
        countdownTimer = nil
        setStartMS = ProcessInfo.processInfo.systemUptime * 1000.0
        setStartDate = Date()
        phase = .inSet
        WKInterfaceDevice.current().play(.start)
        // Arm the phone tagger: taps from here until set_end belong to this set.
        sendPhone(["type": "set_start", "exercise": currentExercise, "startMs": setStartMS])
    }

    /// End the set's recording window, then ask for the rep count before logging it.
    ///
    /// If someone is tagging reps on the phone they already counted this set, so
    /// `set_end` asks for that tally and pre-fills the entry with it — one tap on
    /// Save Set and you're done. The phone's answer arrives asynchronously; until
    /// it does (or if nobody is tagging) the screen shows `defaultReps` as before.
    func endSet() {
        guard phase == .inSet else { return }
        pendingSetEndMS = ProcessInfo.processInfo.systemUptime * 1000.0
        repsEntry = Self.defaultReps
        repsFromPhone = false
        repsEntryEdited = false
        phase = .enteringReps
        WKInterfaceDevice.current().play(.stop)
        // Disarms the phone tagger and replies with its tap count for this set.
        sendPhone(["type": "set_end", "endMs": pendingSetEndMS]) { [weak self] reply in
            guard let self else { return }
            let taps = (reply["repTaps"] as? Int) ?? 0
            let tagging = (reply["tagging"] as? Bool) ?? false
            guard tagging, taps > 0 else { return }   // nobody counted — keep the default
            DispatchQueue.main.async {
                // A late reply must not clobber a number the user already dialed,
                // or land on the next set after this one was saved.
                guard self.phase == .enteringReps, !self.repsEntryEdited else { return }
                self.repsEntry = min(taps, 99)
                self.repsFromPhone = true
            }
        }
    }

    func incrementReps() {
        repsEntry = min(repsEntry + 1, 99)
        repsEntryEdited = true
        repsFromPhone = false
    }

    func decrementReps() {
        repsEntry = max(repsEntry - 1, 0)
        repsEntryEdited = true
        repsFromPhone = false
    }

    /// Confirm the rep count from the End Set screen and write the set.
    func confirmReps() {
        guard phase == .enteringReps else { return }
        finalizeSet()
        WKInterfaceDevice.current().play(.success)
    }

    /// Write the pending set (with `repsEntry`) and return to resting. Shared by the
    /// rep-entry screen and by End Session auto-closing an open set.
    private func finalizeSet() {
        writeSetRow(exercise: currentExercise, startMS: setStartMS,
                    endMS: pendingSetEndMS, reps: repsEntry)
        lastSetStartMS = setStartMS       // remember it so it can be discarded after the fact
        lastSetEndMS = pendingSetEndMS
        canDiscardLast = true
        setCount += 1
        currentExercise = ""
        phase = .resting
    }

    /// Mark the most recently completed set as bad. Its readings stay in
    /// readings.csv, but a "discard" interval is logged so training drops every
    /// window touching it (instead of mislabeling that motion as rest).
    func discardLastSet() {
        guard let start = lastSetStartMS, let end = lastSetEndMS else { return }
        writeSetRow(exercise: Self.discardLabel, startMS: start, endMS: end, reps: 0)
        lastSetStartMS = nil              // prevent discarding the same set twice
        lastSetEndMS = nil
        canDiscardLast = false
        setCount = max(0, setCount - 1)
        WKInterfaceDevice.current().play(.failure)
        setStatus("last set discarded")
    }

    private func writeSetRow(exercise: String, startMS: Double, endMS: Double, reps: Int) {
        let line = "\(csvPrefix),\(exercise),"
            + String(format: "%.1f,%.1f,%d\n", startMS, endMS, reps)
        workQueue.addOperation { [weak self] in
            guard let self, let h = self.setsHandle,
                  let d = line.data(using: .utf8) else { return }
            try? h.write(contentsOf: d)
        }
    }

    func endSession() {
        countdownTimer?.invalidate()      // in case a countdown was mid-flight
        countdownTimer = nil
        if isAutoSession { endAutoSession(); return }
        // Auto-close a set still open or awaiting reps, using the default count.
        if phase == .inSet {
            pendingSetEndMS = ProcessInfo.processInfo.systemUptime * 1000.0
            sendPhone(["type": "set_end", "endMs": pendingSetEndMS])
            repsEntry = Self.defaultReps
            finalizeSet()
        } else if phase == .enteringReps {
            finalizeSet()
        }
        sendPhone(["type": "session_end"])   // phone closes & files this session's reps.csv
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

            // Auto-detect session: feed the live classifier, don't write readings.
            if self.isAutoSession {
                self.feedLive(
                    [Float(ax), Float(ay), Float(az), Float(r.x), Float(r.y), Float(r.z)],
                    atMS: tms)
                return
            }

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

    // No-ops while HealthKit is stripped for free-account testing.
    // Without the workout-session keep-alive, watchOS may suspend the app when
    // the screen sleeps, so keep the watch screen awake during sets.
    private func requestHealthAuthorization() {}

    private func startWorkoutKeepAlive() {}

    private func stopWorkoutKeepAlive() {}

    // MARK: - helpers

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    /// Fire-and-forget live message to the iPhone (rep-tagger coordination).
    /// Best-effort: if the phone app isn't open/reachable, recording continues
    /// unaffected — that session just won't have per-rep tap labels.
    private func sendPhone(_ msg: [String: Any],
                           reply: (([String: Any]) -> Void)? = nil) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(msg, replyHandler: reply, errorHandler: nil)
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

// MARK: - On-watch CoreML inference

/// Loads the exported Core ML classifier and turns one IMU window into a label.
///
/// Loads the compiled model generically (by bundle resource + feature names from
/// the model description) instead of the Xcode-generated `LiftLoggerClassifier`
/// Swift class, so this file compiles and the manual recorder keeps working even
/// before the .mlpackage has been dragged into the Watch target. `isReady` is
/// false until the model is actually bundled.
final class ExerciseClassifier {

    private let model: MLModel?
    private let labelName: String      // model description's predicted-class feature
    private let probsName: String?     // …and its probability-dictionary feature
    let isReady: Bool

    init() {
        if let url = Bundle.main.url(forResource: "LiftLoggerClassifier", withExtension: "mlmodelc"),
           let m = try? MLModel(contentsOf: url) {
            model = m
            labelName = m.modelDescription.predictedFeatureName ?? "classLabel"
            probsName = m.modelDescription.predictedProbabilitiesName
            isReady = true
        } else {
            model = nil
            labelName = "classLabel"
            probsName = nil
            isReady = false
        }
    }

    /// window: `RecorderModel.windowSize` rows × `nChannels` cols of RAW IMU,
    /// channel order matching the trainer's CHANNELS. Returns (top label, its prob).
    func predict(window: [[Float]]) -> (label: String, confidence: Double)? {
        let W = RecorderModel.windowSize
        let C = RecorderModel.nChannels
        guard let model, window.count == W, window.first?.count == C,
              let arr = try? MLMultiArray(shape: [1, NSNumber(value: W), NSNumber(value: C)],
                                          dataType: .float32) else { return nil }

        // Contiguous [1, W, C] layout → linear index t*C + c (batch 0).
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: W * C)
        var i = 0
        for t in 0..<W {
            let row = window[t]
            for c in 0..<C { ptr[i] = row[c]; i += 1 }
        }

        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: ["imu_window": MLFeatureValue(multiArray: arr)]),
              let out = try? model.prediction(from: provider) else { return nil }

        let label = out.featureValue(for: labelName)?.stringValue ?? RecorderModel.restLabel
        var confidence = 0.0
        if let probsName, let probs = out.featureValue(for: probsName)?.dictionaryValue {
            for (k, v) in probs where "\(k)" == label { confidence = v.doubleValue; break }
        }
        return (label, confidence)
    }
}

// MARK: - On-watch rep counting

/// Counts reps in one exercise bout by the same unsupervised periodicity method as
/// training/reps.py: pick the most periodic channel, read its dominant repetition
/// period, and estimate reps ≈ bout_length / period (cross-checked vs. peak counts).
/// Keep the constants and logic in sync with reps.py.
final class RepCounter {

    private let periodMinS = 0.5
    private let periodMaxS = 4.0
    private let periodicityMin = 0.25
    private let prominenceFrac = 0.30

    /// samples: bout rows × `RecorderModel.nChannels` of raw IMU. Returns reps (>= 0).
    func count(_ samples: [[Float]], fs: Int) -> Int {
        let n = samples.count
        guard n >= fs, let c = samples.first?.count, c > 0 else { return 0 }
        let minLag = Int(periodMinS * Double(fs))
        let maxLag = min(Int(periodMaxS * Double(fs)), n / 2)
        guard maxLag > minLag else { return 0 }

        // Column-major, mean-removed copy for fast per-channel autocorrelation.
        var cols = [[Double]](repeating: [Double](repeating: 0, count: n), count: c)
        for t in 0..<n {
            let row = samples[t]
            for ch in 0..<c { cols[ch][t] = Double(row[ch]) }
        }

        var bestScore = -1.0, bestLag = 0, bestCh = 0
        for ch in 0..<c {
            let mean = cols[ch].reduce(0, +) / Double(n)
            for t in 0..<n { cols[ch][t] -= mean }
            var energy = 0.0
            for v in cols[ch] { energy += v * v }
            if energy < 1e-8 { continue }
            let (score, lag) = bestAutocorr(cols[ch], energy: energy, minLag: minLag, maxLag: maxLag)
            if score > bestScore { bestScore = score; bestLag = lag; bestCh = ch }
        }
        guard bestLag > 0 else { return 0 }

        let period = bestLag
        let autocorrReps = Int((Double(n) / Double(period)).rounded())

        let x = cols[bestCh]                          // already mean-removed
        var variance = 0.0
        for v in x { variance += v * v }
        let std = (variance / Double(n)).squareRoot()
        let peakReps = countPeaks(x, minDistance: Int((0.6 * Double(period)).rounded()),
                                  prominence: prominenceFrac * std)

        if bestScore < periodicityMin { return max(peakReps, 0) }
        if peakReps > 0 && abs(peakReps - autocorrReps) <= 1 { return peakReps }
        return max(autocorrReps, 0)
    }

    private func bestAutocorr(_ x: [Double], energy: Double, minLag: Int, maxLag: Int) -> (Double, Int) {
        var bestScore = -1.0, bestLag = 0
        let n = x.count
        for lag in minLag...maxLag {
            var dot = 0.0
            var t = 0
            while t < n - lag { dot += x[t] * x[t + lag]; t += 1 }
            let ac = dot / energy
            if ac > bestScore { bestScore = ac; bestLag = lag }
        }
        return (bestScore, bestLag)
    }

    private func countPeaks(_ x: [Double], minDistance: Int, prominence: Double) -> Int {
        let md = max(minDistance, 1)
        var count = 0
        var last = -md
        var i = 1
        while i < x.count - 1 {
            if x[i] > x[i - 1] && x[i] >= x[i + 1] && x[i] >= prominence && i - last >= md {
                count += 1
                last = i
            }
            i += 1
        }
        return count
    }
}

// MARK: - On-watch supervised rep counting (Core ML density model)

/// Loads the exported rep-density model (LiftLoggerRepCounter.mlpackage) and counts
/// reps in one bout by resampling it to `RecorderModel.repBoutLen` frames, running
/// the model, and summing the predicted per-frame density — the deployment of
/// train_reps_model.py. `count` returns nil when the model isn't bundled yet, so the
/// caller transparently falls back to the unsupervised `RepCounter`.
final class RepDensityCounter {

    private let model: MLModel?
    private let inName: String         // model description's IMU input feature
    private let outName: String        // model description's density output feature
    private let frames: Int            // time steps the model expects per call
    private let windowed: Bool         // slide fixed-second windows vs. resample the bout
    let isReady: Bool

    /// Both rep models are the same network with the same output; they differ in
    /// what one call covers. The compiled model says which is bundled — a
    /// "imu_window" input means fixed-SECOND windows to slide over the bout
    /// (train_reps_windows.py), anything else means the whole set resampled to a
    /// fixed frame count (train_reps_model.py). Reading the length from the model
    /// too means retraining at a different window size needs no change here.
    init() {
        guard let url = Bundle.main.url(forResource: "LiftLoggerRepCounter",
                                        withExtension: "mlmodelc"),
              let m = try? MLModel(contentsOf: url) else {
            model = nil
            inName = ""; outName = ""
            frames = 0; windowed = false
            isReady = false
            return
        }
        let desc = m.modelDescription
        let input = desc.inputDescriptionsByName.first { $0.value.multiArrayConstraint != nil }
        let shape = input?.value.multiArrayConstraint?.shape ?? []
        model = m
        inName = input?.key ?? "imu_bout"
        outName = desc.outputDescriptionsByName.keys.first ?? "var_0"
        // Shape is [1, L, C]; fall back to the legacy length if it's unreadable.
        frames = shape.count >= 2 ? shape[shape.count - 2].intValue : RecorderModel.repBoutLen
        windowed = (input?.key == "imu_window")
        isReady = frames > 1
    }

    /// samples: bout rows × `RecorderModel.nChannels` of raw IMU. Returns a rep
    /// count, or nil if the model isn't available (caller should fall back).
    func count(_ samples: [[Float]], fs: Int) -> Int? {
        guard isReady, let model else { return nil }
        guard samples.count >= 2, samples.first?.count == RecorderModel.nChannels else {
            return nil
        }
        let density = windowed ? slidingDensity(samples, model: model)
                               : resampledDensity(samples, model: model)
        guard let density else { return nil }
        return max(Int(density.reduce(0, +).rounded()), 0)   // reps = integral
    }

    /// Windowed model: run every `repWinStride` samples and overlap-add the
    /// predictions back onto the bout's own timeline. Overlapping windows are
    /// AVERAGED (divided by how many covered each frame), not summed — otherwise
    /// a rep in an overlap region would be counted once per window over it.
    /// Mirrors rep_windows.bout_density, so the watch and the metrics agree.
    private func slidingDensity(_ samples: [[Float]], model: MLModel) -> [Double]? {
        let n = samples.count
        let w = frames
        var starts: [Int] = []
        if n <= w {
            starts = [0]
        } else {
            var st = 0
            while st + w <= n { starts.append(st); st += RecorderModel.repWinStride }
            if starts.last != n - w { starts.append(n - w) }   // don't drop the tail
        }

        var acc = [Double](repeating: 0, count: n)
        var cov = [Double](repeating: 0, count: n)
        for st in starts {
            guard let dens = predict(model: model, frameCount: w, fill: { i in
                // Edge-pad past the end: acc_* includes gravity, so repeating the
                // last sample reads as "held still" where a zero row is impossible.
                samples[min(st + i, n - 1)]
            }) else { return nil }
            let end = min(st + w, n)
            for i in 0..<(end - st) {
                acc[st + i] += dens[i]
                cov[st + i] += 1
            }
        }
        return (0..<n).map { acc[$0] / max(cov[$0], 1) }
    }

    /// Legacy whole-bout model: linear-resample the set onto `frames` steps and
    /// run once. Matches rep_events._resample.
    private func resampledDensity(_ samples: [[Float]], model: MLModel) -> [Double]? {
        let n = samples.count
        let l = frames
        return predict(model: model, frameCount: l) { i in
            let pos = Double(i) * Double(n - 1) / Double(l - 1)
            let lo = Int(pos)
            let hi = min(lo + 1, n - 1)
            let f = Float(pos - Double(lo))
            let a = samples[lo], b = samples[hi]
            return (0..<RecorderModel.nChannels).map { a[$0] * (1 - f) + b[$0] * f }
        }
    }

    /// One forward pass. `fill(i)` supplies row i of the model's input buffer.
    private func predict(model: MLModel, frameCount: Int,
                         fill: (Int) -> [Float]) -> [Double]? {
        let c = RecorderModel.nChannels
        guard let arr = try? MLMultiArray(
                shape: [1, NSNumber(value: frameCount), NSNumber(value: c)],
                dataType: .float32) else { return nil }
        // Contiguous [1, L, C] layout -> index i*C + channel.
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: frameCount * c)
        for i in 0..<frameCount {
            let row = fill(i)
            let base = i * c
            for ch in 0..<c { ptr[base + ch] = row[ch] }
        }
        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: [inName: MLFeatureValue(multiArray: arr)]),
              let out = try? model.prediction(from: provider),
              let dens = out.featureValue(for: outName)?.multiArrayValue else { return nil }
        return (0..<dens.count).map { dens[$0].doubleValue }
    }
}
