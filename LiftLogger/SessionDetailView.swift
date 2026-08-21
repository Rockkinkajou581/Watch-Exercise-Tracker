//
//  SessionDetailView.swift
//  LiftLogger  (iOS target only)
//
//  design.md §3 — the Rep Rail. One card per exercise, one 44pt numeral per set.
//  Hierarchy contract: the rep numeral is the largest thing in a card (44pt) and
//  the session set count is the largest thing on the screen (64pt).
//

import SwiftUI

struct SessionDetailView: View {
    let summary: SessionSummary
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    /// The uncertain set awaiting a label from the picker sheet.
    @State private var labeling: SetEntry?
    /// The detected set whose rep count is being corrected.
    @State private var correctingReps: SetEntry?

    /// Re-read from the store so a confirmed label refreshes this screen.
    private var live: SessionSummary {
        store.summaries.first(where: { $0.id == summary.id }) ?? summary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if live.groups.isEmpty {
                    emptyCard
                } else {
                    VStack(spacing: 10) {
                        ForEach(live.groups) { group in
                            ExerciseCard(group: group, onLabel: { entry in
                                labeling = entry
                            }, onFixReps: { entry in
                                correctingReps = entry
                            })
                        }
                    }
                }
            }
            .padding(.horizontal, DS.screenHPadding)
            .padding(.bottom, 20)
        }
        .background(DS.canvas)
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                        Text("Sessions").font(.dsBody)
                    }
                    .foregroundStyle(DS.accent)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(items: live.files) {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(DS.accent)
                }
            }
        }
        .toolbarBackground(DS.canvas, for: .navigationBar)
        .sheet(item: $labeling) { entry in
            ExercisePickerSheet { choice in
                store.confirmLabel(sessionID: live.id, startMs: entry.startMs, exercise: choice)
                labeling = nil
            }
        }
        .sheet(item: $correctingReps) { entry in
            RepsCorrectionSheet(initialReps: entry.reps) { corrected in
                store.confirmReps(sessionID: live.id, startMs: entry.startMs, reps: corrected)
                correctingReps = nil
            }
        }
    }

    // MARK: - §3.1 Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            DSOverline(
                text: [live.title, live.metaLine, live.subject]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                size: 13,
                tracking: 13 * 0.12
            )

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(live.totalSets)")
                    .font(.dsDisplay)
                    .tracking(DSTracking.display)
                    .monospacedDigit()
                    .foregroundStyle(DS.accent)
                Text(" sets")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: 8)
                Text(live.repsLine)
                    .font(.system(size: 15))
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .padding(.top, 4)
    }

    // §3.4 — a file arrived but parsed to zero rows.
    private var emptyCard: some View {
        DSCard(padding: EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(live.hasSourceFile ? "No sets in this file" : "No set data received")
                    .font(.dsHeadingCard)
                    .foregroundStyle(DS.textTertiary)
                Text(live.hasSourceFile
                     ? "The session file has 0 rows."
                     : "This session has no sets.csv or detected.csv yet.")
                    .font(.dsCaptionSmall)
                    .foregroundStyle(DS.textTertiary)
                if !live.files.isEmpty {
                    ShareLink(items: live.files) {
                        Label("Share raw files", systemImage: "square.and.arrow.up")
                            .font(.dsCaptionSmall)
                            .foregroundStyle(DS.accent)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - §3.2 Exercise card

struct ExerciseCard: View {
    let group: ExerciseGroup
    var onLabel: (SetEntry) -> Void
    var onFixReps: (SetEntry) -> Void

    private var tint: Color {
        group.isConfirmed ? DS.exerciseTint(group.tintIndex) : DS.textTertiary
    }

    /// §3.2 — columns are fixed to a 3-slot grid so numerals stay aligned;
    /// more than three sets wraps to another row of the same grid.
    private var rows: [[SetEntry]] {
        stride(from: 0, to: group.sets.count, by: 3).map {
            Array(group.sets[$0..<min($0 + 3, group.sets.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Header
            HStack(spacing: 8) {
                Image(systemName: ExerciseSymbol.name(for: group.name ?? "",
                                                      uncertain: !group.isConfirmed))
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                Text(group.displayName)
                    .font(.dsHeadingCard)
                    .tracking(DSTracking.headingCard)
                    .foregroundStyle(group.isConfirmed ? DS.textPrimary : DS.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                Text("\(group.totalReps) reps")
                    .font(.dsCaptionSmall)
                    .foregroundStyle(DS.textTertiary)
            }

            // 2. Set rail
            VStack(spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row) { entry in
                            setColumn(entry)
                        }
                        // Pad the last row so numerals keep the 3-slot grid.
                        ForEach(Array(0..<(3 - row.count)), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }
            .padding(.top, 14)

            // 3. §3.3 uncertain footer
            if !group.isConfirmed {
                Rectangle().fill(DS.separator).frame(height: 1).padding(.top, 14)
                HStack {
                    Text("Label uncertain — confirm to use for training")
                        .font(.dsLabelChip)
                        .foregroundStyle(DS.textTertiary)
                    Spacer(minLength: 8)
                    Button("Label") { onLabel(group.sets[0]) }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.accent)
                }
                .padding(.top, 12)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 18, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay {
            if !group.isConfirmed {
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .stroke(DS.strokeUncertain, lineWidth: 1)
            }
        }
    }

    private func setColumn(_ entry: SetEntry) -> some View {
        // Only detected.csv rows (confidence != nil) came from a model guess —
        // sets.csv reps were already dialed in by hand, nothing to correct.
        let fixable = entry.confidence != nil
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                onFixReps(entry)
            } label: {
                Text("\(entry.reps)")
                    .font(.dsNumeralSet)
                    .tracking(DSTracking.numeralSet)
                    .monospacedDigit()
                    .foregroundStyle(group.isConfirmed && entry.reps > 0
                                     ? DS.textPrimary : DS.textTertiary)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
            .disabled(!fixable)

            bar(for: entry)

            Text("SET \(entry.setNumber)")
                .font(.system(size: 12))
                .foregroundStyle(DS.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Set \(entry.setNumber), \(entry.reps) reps"
                            + (fixable ? ", tap to correct" : ""))
    }

    @ViewBuilder
    private func bar(for entry: SetEntry) -> some View {
        if group.isConfirmed {
            // Alpha scales with reps so the rail reads as a mini bar chart.
            let alpha = 0.30 + 0.70 * (Double(entry.reps) / Double(group.maxReps))
            RoundedRectangle(cornerRadius: DS.barRadius, style: .continuous)
                .fill(tint.opacity(min(alpha, 1)))
                .frame(height: DS.barHeight)
        } else {
            GeometryReader { geo in
                Path { p in
                    p.move(to: CGPoint(x: 0, y: DS.barHeight / 2))
                    p.addLine(to: CGPoint(x: geo.size.width, y: DS.barHeight / 2))
                }
                .stroke(DS.barDim,
                        style: StrokeStyle(lineWidth: DS.barHeight, dash: [6, 5]))
            }
            .frame(height: DS.barHeight)
        }
    }
}

// MARK: - reps correction sheet

/// Fixes a detected set's rep count by hand — the low-friction alternative to
/// running the phone tapper live during the set. Confirming here marks the row
/// reps_confirmed=1 so it feeds evaluate_reps.py on the next merged export.
struct RepsCorrectionSheet: View {
    let initialReps: Int
    var onConfirm: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reps: Int

    init(initialReps: Int, onConfirm: @escaping (Int) -> Void) {
        self.initialReps = initialReps
        self.onConfirm = onConfirm
        _reps = State(initialValue: initialReps)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("How many reps were actually in this set?")
                    .font(.dsBody)
                    .foregroundStyle(DS.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)

                HStack(spacing: 20) {
                    Button { reps = max(0, reps - 1) } label: {
                        Image(systemName: "minus.circle.fill").font(.title)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.accent)

                    Text("\(reps)")
                        .font(.dsNumeralTagger)
                        .monospacedDigit()
                        .frame(minWidth: 70)
                        .contentTransition(.numericText())

                    Button { reps += 1 } label: {
                        Image(systemName: "plus.circle.fill").font(.title)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.accent)
                }

                Button {
                    onConfirm(reps)
                    dismiss()
                } label: {
                    Text("Save Correction").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.accent)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.screenHPadding)
            .background(DS.canvas)
            .navigationTitle("Fix Reps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(DS.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - §3.3 label picker

struct ExercisePickerSheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(SessionStore.knownExercises, id: \.self) { ex in
                Button {
                    onPick(ex)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: ExerciseSymbol.name(for: ex))
                            .foregroundStyle(DS.accent)
                            .frame(width: 22)
                        Text(prettyExercise(ex))
                            .font(.dsBody)
                            .foregroundStyle(DS.textPrimary)
                    }
                }
                .listRowBackground(DS.card)
            }
            .scrollContentBackground(.hidden)
            .background(DS.canvas)
            .navigationTitle("Label this set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(DS.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
