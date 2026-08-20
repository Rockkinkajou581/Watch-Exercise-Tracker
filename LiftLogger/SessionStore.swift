//
//  SessionStore.swift
//  LiftLogger  (add to the iOS target only)
//
//  Receives <session>_readings.csv / <session>_sets.csv from the watch,
//  files them under Documents/exercises/<abbreviated-date>/ (e.g. "Jun-10",
//  "Jun-10-2" for a second session that day), and can merge everything into one
//  readings.csv + one sets.csv — the exact inputs for build_workouts_csv.py.
//
//  The folder name is purely cosmetic. The unique session id (a timestamp) still
//  lives in the CSV's `session` column — that's what training groups on — and a
//  hidden ".sid" marker in each folder maps it back so the readings/sets/detected
//  files from one session always land together.
//

import Foundation
import Combine
import WatchConnectivity

final class SessionStore: NSObject, ObservableObject {

    struct SessionFolder: Identifiable {
        let id: String        // folder name, e.g. "Jun-10"
        let files: [URL]
        /// The watch's original session id ("20260610-141503") from the ".sid"
        /// marker — the sortable timestamp everything date-shaped derives from.
        var sid: String = ""
    }

    @Published var subject: String = "S01"
    @Published var sessions: [SessionFolder] = []
    @Published var mergedURLs: [URL] = []
    @Published var status: String = ""

    /// Parsed exercise → set → reps view of every received session, newest
    /// first. This is what the Sessions and Session Detail screens render.
    @Published var summaries: [SessionSummary] = []
    /// False until the first refresh lands, so the list can show its loading
    /// placeholder instead of flashing the empty state.
    @Published var hasLoaded = false

    /// The exercises the watch can log — the picker used to confirm an
    /// uncertain classifier label. Kept in sync with RecorderModel.exercises.
    static let knownExercises = [
        "incline_chest_press", "flat_chest_press", "machine_shoulder_press",
        "cable_side_delt", "cable_front_delt", "seated_tricep_dips",
        "overhead_triceps", "cable_push_down", "machine_row_wide",
        "machine_pull_down", "cable_curl", "dumbbell_hammer_curl",
        "machine_arm_curl", "wrist_extensions", "forearm_curl", "forearm_raises",
    ]

    /// Sessions whose file set looks half-delivered (§2.4 pending strip).
    var pendingSessions: [SessionSummary] {
        summaries.filter { Self.isPending($0.files) }
    }

    /// A manual session ships readings.csv *and* sets.csv; having exactly one of
    /// them means the other transfer hasn't landed yet. An auto-detect session
    /// ships detected.csv alone and is never pending.
    static func isPending(_ files: [URL]) -> Bool {
        let names = Set(files.map(\.lastPathComponent))
        if names.contains("detected.csv") { return false }
        let hasReadings = names.contains("readings.csv")
        let hasSets = names.contains("sets.csv")
        return hasReadings != hasSets
    }

    // MARK: - live rep tagging (observer taps once per rep during a watch set)
    @Published var repSessionActive = false      // a manual watch session is recording
    @Published var repExercise = ""              // exercise of the set currently open
    @Published var repSetArmed = false           // a set is open → taps are counted
    @Published var repSetCount = 0               // taps in the current/most-recent set
    @Published var repSessionTotal = 0           // taps across the whole session
    @Published var repStatus = "Open this before starting a session on the watch."
    /// Drives the §6 "WATCH DISCONNECTED" state on the tagger.
    @Published var watchReachable = false

    // Clock anchor from the watch: watch-uptime and wall-clock captured together,
    // used to map a phone tap (wall clock) onto the watch IMU timeline.
    private var anchorUptimeMs = 0.0
    private var anchorUnixMs = 0.0
    private var repSID = ""
    private var repSubject = "S01"
    private var repSetStartMs = 0.0
    private var repsHandle: FileHandle?

    private let fm = FileManager.default

    private static let readingsHeader =
        "subject,session,time_ms,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z"
    private static let setsHeader =
        "subject,session,exercise,start_ms,end_ms,reps"
    private static let repsHeader =
        "subject,session,rep_time_ms,set_start_ms,tap_unix_ms"

    var exercisesDir: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("exercises", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The folder a session's files belong in. Reuses the existing folder if any
    /// file from this session id already arrived (matched via the ".sid" marker);
    /// otherwise makes a new date-named folder, suffixing -2, -3, … on collisions.
    private func folderFor(sessionID sid: String) -> URL {
        let base = exercisesDir
        let existing = (try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil)) ?? []
        for dir in existing where dir.hasDirectoryPath {
            let marker = dir.appendingPathComponent(".sid")
            if let s = try? String(contentsOf: marker, encoding: .utf8), s == sid {
                return dir
            }
        }
        let label = Self.dateLabel(from: sid)
        var name = label
        var n = 2
        while fm.fileExists(atPath: base.appendingPathComponent(name).path) {
            name = "\(label)-\(n)"
            n += 1
        }
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? sid.data(using: .utf8)?.write(to: dir.appendingPathComponent(".sid"))
        return dir
    }

    /// "20260610-141503" -> "Jun-10".  Falls back to the raw id if it can't parse.
    static func dateLabel(from sid: String) -> String {
        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyyMMdd-HHmmss"
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        let outFmt = DateFormatter()
        outFmt.dateFormat = "MMM-d"
        outFmt.locale = Locale(identifier: "en_US_POSIX")
        if let d = inFmt.date(from: sid) { return outFmt.string(from: d) }
        return sid
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
            at: exercisesDir, includingPropertiesForKeys: nil)) ?? []
        let list = folders
            .filter(\.hasDirectoryPath)
            .map { dir -> (folder: SessionFolder, sortKey: String) in
                // The ".sid" marker is the original timestamp — sortable and hidden.
                let sid = (try? String(
                    contentsOf: dir.appendingPathComponent(".sid"), encoding: .utf8))
                    ?? dir.lastPathComponent
                let files = ((try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { !$0.lastPathComponent.hasPrefix(".") }   // hide .sid / .DS_Store
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                return (SessionFolder(id: dir.lastPathComponent, files: files, sid: sid), sid)
            }
            .sorted { $0.sortKey > $1.sortKey }    // newest first by real timestamp
            .map(\.folder)

        let fallback = subject
        let parsed = list.map {
            SessionParser.summary(id: $0.id, sessionID: $0.sid, files: $0.files,
                                  fallbackSubject: fallback)
        }
        DispatchQueue.main.async {
            self.sessions = list
            self.summaries = parsed
            self.hasLoaded = true
        }
    }

    /// §3.3 "Label" action — the observer names an uncertain set. Rewrites that
    /// row in detected.csv with the chosen exercise at confidence 1.0, so the
    /// correction persists into the merged training export rather than living
    /// only in the UI.
    func confirmLabel(sessionID folderID: String, startMs: Double, exercise: String) {
        guard let folder = sessions.first(where: { $0.id == folderID }),
              let url = folder.files.first(where: { $0.lastPathComponent == "detected.csv" }),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            let f = lines[i].split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 7, let start = Double(f[3]),
                  abs(start - startMs) < 0.5 else { continue }
            lines[i] = "\(f[0]),\(f[1]),\(exercise),\(f[3]),\(f[4]),\(f[5]),1.000"
            break
        }

        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            refresh()
        } catch {
            status = "label failed: \(error.localizedDescription)"
        }
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
        try? fm.removeItem(at: exercisesDir.appendingPathComponent(id, isDirectory: true))
        refresh()
    }

    /// Concatenates every session's CSVs into one readings.csv + one sets.csv
    /// (+ reps.csv if any rep tags exist), headers written once. Output goes to
    /// the temp dir for sharing — the exact inputs for the training pipeline.
    func buildMergedExport() {
        var readings = Self.readingsHeader + "\n"
        var sets = Self.setsHeader + "\n"
        var reps = Self.repsHeader + "\n"
        var nReadings = 0
        var nSets = 0
        var nReps = 0

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
                case "reps.csv":
                    reps += body
                    nReps += rows.count
                default:
                    break
                }
            }
        }

        let tmp = fm.temporaryDirectory
        let rOut = tmp.appendingPathComponent("readings.csv")
        let sOut = tmp.appendingPathComponent("sets.csv")
        let repOut = tmp.appendingPathComponent("reps.csv")
        do {
            try readings.write(to: rOut, atomically: true, encoding: .utf8)
            try sets.write(to: sOut, atomically: true, encoding: .utf8)
            var urls = [rOut, sOut]
            if nReps > 0 {
                try reps.write(to: repOut, atomically: true, encoding: .utf8)
                urls.append(repOut)
            }
            mergedURLs = urls
            status = "merged \(nReadings) readings + \(nSets) sets + \(nReps) rep tags "
                + "from \(sessions.count) session(s)"
        } catch {
            mergedURLs = []
            status = "export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - live rep tagging

    /// Observer pressed the rep button. Convert this instant (phone wall clock)
    /// onto the watch IMU timeline via the session anchor, and append it as one
    /// rep event. Only counts while a set is open (`repSetArmed`).
    func recordTap() {
        guard repSetArmed, let h = repsHandle else { return }
        let tapUnixMs = Date().timeIntervalSince1970 * 1000.0
        // Map wall clock -> watch uptime (same clock as readings.csv time_ms).
        let repTimeMs = anchorUptimeMs + (tapUnixMs - anchorUnixMs)
        let line = String(format: "%@,%@,%.1f,%.1f,%.1f\n",
                          repSubject, repSID, repTimeMs, repSetStartMs, tapUnixMs)
        if let d = line.data(using: .utf8) { try? h.write(contentsOf: d) }
        repSetCount += 1
        repSessionTotal += 1
    }

    /// Route a live message from the watch. Called on the WCSession delegate
    /// queue, so all state/file mutation is hopped to main.
    private func handleWatchMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        DispatchQueue.main.async {
            switch type {
            case "session_start":
                self.beginRepSession(msg)
            case "set_start":
                self.repExercise = (msg["exercise"] as? String) ?? ""
                self.repSetStartMs = (msg["startMs"] as? Double) ?? 0
                self.repSetCount = 0
                self.repSetArmed = true
                self.repStatus = "Tap once per rep"
            case "set_end":
                self.repSetArmed = false
                self.repStatus = "Set logged: \(self.repSetCount) reps. Rest…"
            case "session_end":
                self.endRepSession()
            default:
                break
            }
        }
    }

    /// main only. Open this session's reps.csv in its folder and store the anchor.
    private func beginRepSession(_ msg: [String: Any]) {
        repSID = (msg["session"] as? String) ?? "unknown"
        repSubject = (msg["subject"] as? String) ?? subject
        anchorUptimeMs = (msg["anchorUptimeMs"] as? Double) ?? 0
        anchorUnixMs = (msg["anchorUnixMs"] as? Double) ?? 0
        repSessionActive = true
        repSetArmed = false
        repSetCount = 0
        repSessionTotal = 0
        repExercise = ""

        let dir = folderFor(sessionID: repSID)
        let url = dir.appendingPathComponent("reps.csv")
        try? (Self.repsHeader + "\n").data(using: .utf8)?.write(to: url)
        repsHandle = try? FileHandle(forWritingTo: url)
        _ = try? repsHandle?.seekToEnd()
        repStatus = "Session \(Self.dateLabel(from: repSID)) — waiting for a set"
    }

    /// main only. Close the reps file and surface it in the session list.
    private func endRepSession() {
        try? repsHandle?.close()
        repsHandle = nil
        repSessionActive = false
        repSetArmed = false
        repStatus = "Session ended — \(repSessionTotal) reps tagged. Tap Build merged to export."
        refresh()
    }
}

// MARK: - WCSessionDelegate (iOS side)

extension SessionStore: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        let reachable = session.isReachable
        DispatchQueue.main.async { self.watchReachable = reachable }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        DispatchQueue.main.async { self.watchReachable = reachable }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Live rep-tagging coordination messages from the watch.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleWatchMessage(message)
    }

    /// Files arrive here from the watch. The system deletes file.fileURL as
    /// soon as this method returns, so the move must happen synchronously.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let kind = (file.metadata?["kind"] as? String) ?? "data"
        let sid = (file.metadata?["session"] as? String) ?? "unknown"

        let dir = folderFor(sessionID: sid)
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
