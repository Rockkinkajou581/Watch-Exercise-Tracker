//
//  SessionSummary.swift
//  LiftLogger  (iOS target only)
//
//  Turns a received session folder into the exercise → set → reps structure the
//  Session Detail screen renders (design.md §3, §8).
//
//  Two file shapes arrive from the watch:
//    sets.csv      subject,session,exercise,start_ms,end_ms,reps
//    detected.csv  subject,session,exercise,start_ms,end_ms,reps,confidence
//
//  sets.csv rows were labeled by hand on the watch, so they are confirmed.
//  detected.csv rows come from the classifier and are only treated as confirmed
//  above `confidenceThreshold` — per §8, an unconfirmed label is the default
//  rendering path, not an error state.
//

import Foundation

/// Below this the classifier's label gets the §3.3 uncertain treatment.
let confidenceThreshold = 0.75

struct SetEntry: Identifiable {
    let id = UUID()
    /// nil when the row carries no usable label (a "rest"/unknown bout).
    let exercise: String?
    let startMs: Double
    let endMs: Double
    let reps: Int
    /// nil for hand-labeled rows from sets.csv.
    let confidence: Double?
    let isConfirmed: Bool
    /// 1-based position within its exercise group, assigned after grouping.
    var setNumber: Int = 0
}

struct ExerciseGroup: Identifiable {
    let id: String
    /// nil renders as "Unrecognized set" (§3.3).
    let name: String?
    let isConfirmed: Bool
    let tintIndex: Int
    var sets: [SetEntry]

    var totalReps: Int { sets.reduce(0) { $0 + $1.reps } }
    var maxReps: Int { max(sets.map(\.reps).max() ?? 0, 1) }
    var displayName: String { name.map(prettyExercise) ?? "Unrecognized set" }
}

struct SessionSummary: Identifiable {
    /// Folder name, e.g. "Aug-20" — also the SessionStore key.
    let id: String
    let sessionID: String
    let subject: String
    let date: Date?
    let duration: TimeInterval
    let groups: [ExerciseGroup]
    let files: [URL]
    /// A sets/detected file existed but yielded no rows (§3.4).
    let hasSourceFile: Bool

    var totalSets: Int { groups.reduce(0) { $0 + $1.sets.count } }
    var totalReps: Int { groups.reduce(0) { $0 + $1.totalReps } }
    var exerciseCount: Int { groups.count }

    /// "Today" / "Yesterday" / "Aug 18" (§2.4).
    var title: String {
        guard let d = date else { return id }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    /// "6:12 PM · 41 min" (§2.4). Duration is omitted when the file had no rows.
    var metaLine: String {
        var parts: [String] = []
        if let d = date {
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = .none
            parts.append(f.string(from: d))
        }
        if duration > 0 {
            parts.append("\(Int((duration / 60).rounded())) min")
        }
        return parts.joined(separator: " · ")
    }

    /// "53 reps · 3 exercises" (§2.4 / §3.1).
    var repsLine: String {
        "\(totalReps) reps · \(exerciseCount) exercise\(exerciseCount == 1 ? "" : "s")"
    }

    var shortDateLabel: String {
        guard let d = date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: d)
    }
}

// MARK: - Parsing

enum SessionParser {

    /// Builds the summary for one session folder. Prefers detected.csv (the
    /// auto-detect path this screen was designed around) and falls back to
    /// sets.csv for hand-labeled sessions.
    static func summary(id: String, sessionID: String, files: [URL],
                        fallbackSubject: String) -> SessionSummary {
        let detected = files.first { $0.lastPathComponent == "detected.csv" }
        let sets = files.first { $0.lastPathComponent == "sets.csv" }
        let source = detected ?? sets
        let confirmedByDefault = (detected == nil)

        var rows: [SetEntry] = []
        var subject = fallbackSubject

        if let source, let text = try? String(contentsOf: source, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines.dropFirst() {
                let f = line.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard f.count >= 6 else { continue }
                if !f[0].isEmpty { subject = f[0] }

                let rawLabel = f[2]
                let start = Double(f[3]) ?? 0
                let end = Double(f[4]) ?? 0
                let reps = Int(Double(f[5]) ?? 0)
                let conf = f.count >= 7 ? Double(f[6]) : nil

                // "rest" is a classifier state, not an exercise — it carries no
                // label to show, so it falls into the uncertain path.
                let isRest = rawLabel.lowercased() == "rest" || rawLabel.isEmpty
                let label: String? = isRest ? nil : rawLabel
                let confirmed = !isRest
                    && (confirmedByDefault || (conf ?? 0) >= confidenceThreshold)

                rows.append(SetEntry(exercise: label, startMs: start, endMs: end,
                                     reps: reps, confidence: conf,
                                     isConfirmed: confirmed))
            }
        }

        // §8: number sets within a group by start_ms ascending, but group in
        // order of first appearance — the order reflects the workout.
        rows.sort { $0.startMs < $1.startMs }

        var order: [String] = []
        var buckets: [String: [SetEntry]] = [:]
        var confirmedFor: [String: Bool] = [:]
        var labelFor: [String: String?] = [:]

        for row in rows {
            // Unconfirmed rows never merge into a confirmed group, so an
            // uncertain set always renders its own card.
            let key = row.isConfirmed ? "ok:\(row.exercise ?? "")" : "unsure:\(row.exercise ?? "-")"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
                confirmedFor[key] = row.isConfirmed
                labelFor[key] = row.exercise
            }
            buckets[key]?.append(row)
        }

        var tint = 0
        let groups: [ExerciseGroup] = order.map { key in
            var entries = buckets[key] ?? []
            for i in entries.indices { entries[i].setNumber = i + 1 }
            let confirmed = confirmedFor[key] ?? false
            // Uncertain cards use the grey tint and don't consume a tint slot.
            let tintIndex: Int
            if confirmed {
                tintIndex = tint
                tint += 1
            } else {
                tintIndex = -1
            }
            return ExerciseGroup(id: key, name: labelFor[key] ?? nil,
                                 isConfirmed: confirmed, tintIndex: tintIndex,
                                 sets: entries)
        }

        let start = rows.map(\.startMs).min() ?? 0
        let end = rows.map(\.endMs).max() ?? 0
        let duration = end > start ? (end - start) / 1000 : 0

        return SessionSummary(
            id: id,
            sessionID: sessionID,
            subject: subject,
            date: parseDate(sessionID),
            duration: duration,
            groups: groups,
            files: files,
            hasSourceFile: source != nil
        )
    }

    /// "20260610-141503" → Date. The watch's session id is the only timestamp
    /// that survives into the folder, so everything date-shaped derives from it.
    static func parseDate(_ sid: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: sid)
    }
}
