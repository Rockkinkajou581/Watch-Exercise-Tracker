//
//  SessionStore.swift
//  LiftLogger  (add to the iOS target only)
//
//  Receives <session>_readings.csv / <session>_sets.csv from the watch,
//  files them under Documents/sessions/<sessionID>/, and can merge everything
//  into one readings.csv + one sets.csv — the exact inputs for
//  build_workouts_csv.py.
//

import Foundation
import Combine
import WatchConnectivity

final class SessionStore: NSObject, ObservableObject {

    struct SessionFolder: Identifiable {
        let id: String        // session ID, e.g. "20260610-141503"
        let files: [URL]
    }

    @Published var subject: String = "S01"
    @Published var sessions: [SessionFolder] = []
    @Published var mergedURLs: [URL] = []
    @Published var status: String = ""

    private let fm = FileManager.default

    private static let readingsHeader =
        "subject,session,time_ms,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z"
    private static let setsHeader =
        "subject,session,exercise,start_ms,end_ms"

    var sessionsDir: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("sessions", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        refresh()
    }

    // MARK: - actions

    func refresh() {
        let folders = (try? fm.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        let list = folders
            .filter(\.hasDirectoryPath)
            .sorted { $0.lastPathComponent > $1.lastPathComponent }  // newest first
            .map { dir -> SessionFolder in
                let files = ((try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                return SessionFolder(id: dir.lastPathComponent, files: files)
            }
        DispatchQueue.main.async { self.sessions = list }
    }

    func sendSubjectToWatch() {
        let clean = subject.trimmingCharacters(in: .whitespaces)
        do {
            try WCSession.default.updateApplicationContext(["subject": clean])
            status = "subject \"\(clean)\" synced to watch"
        } catch {
            status = "sync failed: \(error.localizedDescription)"
        }
    }

    func deleteSession(_ id: String) {
        try? fm.removeItem(at: sessionsDir.appendingPathComponent(id, isDirectory: true))
        refresh()
    }

    /// Concatenates every session's CSVs into one readings.csv + one sets.csv
    /// (headers written once). Output goes to the temp dir for sharing.
    func buildMergedExport() {
        var readings = Self.readingsHeader + "\n"
        var sets = Self.setsHeader + "\n"
        var nReadings = 0
        var nSets = 0

        for folder in sessions {
            for f in folder.files {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let rows = text.split(separator: "\n").dropFirst().filter { !$0.isEmpty }
                guard !rows.isEmpty else { continue }
                let body = rows.joined(separator: "\n") + "\n"
                switch f.lastPathComponent {
                case "readings.csv":
                    readings += body
                    nReadings += rows.count
                case "sets.csv":
                    sets += body
                    nSets += rows.count
                default:
                    break
                }
            }
        }

        let tmp = fm.temporaryDirectory
        let rOut = tmp.appendingPathComponent("readings.csv")
        let sOut = tmp.appendingPathComponent("sets.csv")
        do {
            try readings.write(to: rOut, atomically: true, encoding: .utf8)
            try sets.write(to: sOut, atomically: true, encoding: .utf8)
            mergedURLs = [rOut, sOut]
            status = "merged \(nReadings) readings + \(nSets) sets from \(sessions.count) session(s)"
        } catch {
            mergedURLs = []
            status = "export failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - WCSessionDelegate (iOS side)

extension SessionStore: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Files arrive here from the watch. The system deletes file.fileURL as
    /// soon as this method returns, so the move must happen synchronously.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let kind = (file.metadata?["kind"] as? String) ?? "data"
        let sid = (file.metadata?["session"] as? String) ?? "unknown"

        let dir = sessionsDir.appendingPathComponent(sid, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(kind).csv")
        try? fm.removeItem(at: dest)   // overwrite on re-send

        do {
            try fm.moveItem(at: file.fileURL, to: dest)
        } catch {
            DispatchQueue.main.async {
                self.status = "receive failed: \(error.localizedDescription)"
            }
        }
        refresh()
    }
}
