//
//  ProgressModule.swift
//  LiftLogger  (iOS target only)
//
//  design.md §4 — reps per session for one exercise, last six sessions.
//

import Charts
import SwiftUI

struct ProgressModule: View {
    /// Newest first, as the store publishes them.
    let summaries: [SessionSummary]
    @State private var selection: String?

    private struct Point: Identifiable {
        let id = UUID()
        let index: Int
        let label: String
        let reps: Int
    }

    /// Every confirmed exercise that appears in any session, most-performed
    /// first — the default selection is the head of this list (§4.2).
    private var exercises: [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for s in summaries {
            for g in s.groups where g.isConfirmed {
                guard let name = g.name else { continue }
                if counts[name] == nil { order.append(name) }
                counts[name, default: 0] += g.sets.count
            }
        }
        return order.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
    }

    private var selected: String? { selection ?? exercises.first }

    /// Total reps of the selected exercise per session, chronological, last 6.
    private var series: [Point] {
        guard let selected else { return [] }
        let chronological = summaries.reversed().filter { s in
            s.groups.contains { $0.isConfirmed && $0.name == selected }
        }
        return chronological.suffix(6).enumerated().map { i, s in
            let reps = s.groups
                .filter { $0.isConfirmed && $0.name == selected }
                .reduce(0) { $0 + $1.totalReps }
            return Point(index: i, label: s.shortDateLabel, reps: reps)
        }
    }

    private var latest: Int { series.last?.reps ?? 0 }
    private var average: Int {
        guard !series.isEmpty else { return 0 }
        return Int((Double(series.reduce(0) { $0 + $1.reps }) / Double(series.count)).rounded())
    }
    private var delta: Int? {
        guard series.count >= 2 else { return nil }
        return series[series.count - 1].reps - series[series.count - 2].reps
    }

    var body: some View {
        if exercises.isEmpty {
            EmptyView()
        } else {
            DSCard(padding: EdgeInsets(top: 15, leading: 17, bottom: 14, trailing: 17)) {
                VStack(alignment: .leading, spacing: 11) {
                    header
                    chips
                    headline
                    chart
                }
            }
        }
    }

    private var header: some View {
        HStack {
            DSOverline(text: "Progress · Reps per session")
            Spacer(minLength: 8)
            if let delta {
                Text(delta > 0 ? "+\(delta) vs last" : "\(delta) vs last")
                    .font(.dsLabelChip)
                    .monospacedDigit()
                    .foregroundStyle(delta > 0 ? DS.accent
                                     : (delta < 0 ? DS.negative : DS.textTertiary))
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(exercises, id: \.self) { ex in
                    Button { selection = ex } label: {
                        DSChip(text: prettyExercise(ex), selected: ex == selected)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(latest)")
                .font(.dsNumeralStat)
                .tracking(DSTracking.numeralStat)
                .monospacedDigit()
                .foregroundStyle(DS.textPrimary)
                .contentTransition(.numericText())
            Text("reps · avg \(average)")
                .font(.dsCaptionSmall)
                .foregroundStyle(DS.textTertiary)
        }
    }

    @ViewBuilder
    private var chart: some View {
        if series.count < 2 {
            // §4 — one session can't make a trend.
            Text("Two sessions needed to plot a trend")
                .font(.dsCaptionSmall)
                .foregroundStyle(DS.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 96)
        } else {
            VStack(spacing: 6) {
                Chart(series) { p in
                    AreaMark(x: .value("Session", p.index),
                             y: .value("Reps", Double(p.reps)))
                        .foregroundStyle(DS.accent.opacity(0.14))
                        .interpolationMethod(.linear)
                    LineMark(x: .value("Session", p.index),
                             y: .value("Reps", Double(p.reps)))
                        .foregroundStyle(DS.accent)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                    PointMark(x: .value("Session", p.index),
                              y: .value("Reps", Double(p.reps)))
                        .symbolSize(p.index == series.count - 1 ? 100 : 36)
                        .foregroundStyle(p.index == series.count - 1
                                         ? DS.accent : Color(hex: "5C7A00"))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                // §4 — padded to the data range, never zero-anchored: a 17→24
                // climb has to be visible, and a zero floor flattens it.
                .chartYScale(domain: yDomain)
                .frame(height: 96)
                // The area fill draws to the domain floor, which sits below the
                // plot frame — without this it bleeds past the card's corners.
                .clipped()

                HStack(spacing: 0) {
                    ForEach(series) { p in
                        Text(p.label)
                            .font(.dsLabelAxis)
                            .foregroundStyle(DS.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    /// §4 — padded to the data range, never zero-anchored: a 17→24 climb has to
    /// be visible, and a zero floor flattens it. A little headroom above the max
    /// keeps the newest point's marker from clipping at the top edge.
    private var yDomain: ClosedRange<Double> {
        let values = series.map { Double($0.reps) }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let pad = max(1, ((hi - lo) * 0.35).rounded())
        return (lo - pad)...(hi + max(1, pad * 0.4))
    }
}
