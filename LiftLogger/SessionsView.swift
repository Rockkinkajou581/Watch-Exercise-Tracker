//
//  SessionsView.swift
//  LiftLogger  (iOS target only)
//
//  design.md §2 — the root screen. Header, summary strip, progress module, and
//  the list of sessions received from the watch.
//

import SwiftUI

struct SessionsView: View {
    @EnvironmentObject var store: SessionStore
    @State private var showDeveloper = false
    @State private var pendingDelete: SessionSummary?
    /// Rows navigate programmatically: a NavigationLink inside a List draws its
    /// own disclosure chevron, which would sit alongside the row's own (§2.4).
    @State private var path = NavigationPath()

    private var totalSets: Int { store.summaries.reduce(0) { $0 + $1.totalSets } }
    private var totalReps: Int { store.summaries.reduce(0) { $0 + $1.totalReps } }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                content
            }
            .background(DS.canvas)
            .navigationBarHidden(true)
            .navigationDestination(for: String.self) { id in
                if let s = store.summaries.first(where: { $0.id == id }) {
                    SessionDetailView(summary: s).environmentObject(store)
                }
            }
            .sheet(isPresented: $showDeveloper) {
                DeveloperView().environmentObject(store)
            }
            .alert("Delete session?", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete", role: .destructive) {
                    if let s = pendingDelete { store.deleteSession(s.id) }
                    pendingDelete = nil
                }
            } message: {
                Text("\(pendingDelete?.title ?? "") and its CSV files will be removed from this phone.")
            }
        }
        .preferredColorScheme(.dark)
        .tint(DS.accent)
    }

    // MARK: - §2.1 Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                Text("Sessions")
                    .font(.dsTitleScreen)
                    .tracking(DSTracking.titleScreen)
                    .foregroundStyle(DS.textPrimary)

                Spacer()

                // Subject pill
                HStack(spacing: 6) {
                    Circle().fill(DS.accent).frame(width: 7, height: 7)
                    Text(store.subject)
                        .font(.dsLabelChip)
                        .foregroundStyle(DS.textSecondary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 11)
                .background(DS.card, in: Capsule())

                Button { showDeveloper = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(DS.textTertiary)
                        .frame(width: 30, height: 30)
                        .background(DS.card, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Developer tools")
            }

            Text("Received from Apple Watch")
                .font(.dsCaption)
                .foregroundStyle(DS.textTertiary)
        }
        .padding(.top, 6)
        .padding(.horizontal, DS.screenHPadding)
        .padding(.bottom, 14)
    }

    // MARK: - Body states (§2.5)

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded {
            loadingList
        } else if store.summaries.isEmpty {
            emptyState
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        List {
            summaryStrip
                .listRowInsets(EdgeInsets(top: 0, leading: DS.screenHPadding,
                                          bottom: 12, trailing: DS.screenHPadding))
                .plainRow()

            if store.summaries.count > 0 {
                ProgressModule(summaries: store.summaries)
                    .listRowInsets(EdgeInsets(top: 0, leading: DS.screenHPadding,
                                              bottom: 14, trailing: DS.screenHPadding))
                    .plainRow()
            }

            ForEach(store.summaries) { s in
                Button { path.append(s.id) } label: {
                    SessionRow(summary: s)
                }
                .buttonStyle(DSCardButtonStyle())
                .listRowInsets(EdgeInsets(top: 0, leading: DS.screenHPadding,
                                          bottom: 9, trailing: DS.screenHPadding))
                .plainRow()
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { pendingDelete = s } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            Text("Pull to refresh · files arrive automatically")
                .font(.dsLabelChip)
                .foregroundStyle(DS.textQuaternary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 7)
                .padding(.bottom, 16)
                .plainRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DS.canvas)
        .refreshable { store.refresh() }
    }

    // §2.2 Summary strip — only SETS is accented.
    private var summaryStrip: some View {
        HStack(spacing: 8) {
            tile("\(store.summaries.count)", "Sessions", DS.textPrimary)
            tile("\(totalSets)", "Sets", DS.accent)
            tile("\(totalReps)", "Reps", DS.textPrimary)
        }
    }

    private func tile(_ value: String, _ caption: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.dsNumeralTile)
                .tracking(DSTracking.numeralTile)
                .monospacedDigit()
                .foregroundStyle(color)
            DSOverline(text: caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radiusTile, style: .continuous))
    }

    // §2.5 Empty
    private var emptyState: some View {
        VStack {
            DSCard(padding: EdgeInsets(top: 26, leading: 20, bottom: 26, trailing: 20)) {
                VStack(spacing: 10) {
                    Image(systemName: "dumbbell")
                        .font(.system(size: 34))
                        .foregroundStyle(DS.textTertiary)
                    Text("No sessions yet")
                        .font(.dsHeadingCard)
                        .foregroundStyle(DS.textPrimary)
                    Text("Record one on the watch — files arrive here automatically, usually within a minute of End Session.")
                        .font(.dsCaptionSmall)
                        .foregroundStyle(DS.textTertiary)
                        .multilineTextAlignment(.center)
                    Button("Open Developer") { showDeveloper = true }
                        .font(.dsBodyButton)
                        .foregroundStyle(DS.accent)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, DS.screenHPadding)
            Spacer()
        }
    }

    // §2.5 Loading — strip shows em dashes, three redacted rows.
    private var loadingList: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                tile("—", "Sessions", DS.textPrimary)
                tile("—", "Sets", DS.accent)
                tile("—", "Reps", DS.textPrimary)
            }
            .padding(.bottom, 3)

            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .fill(DS.card)
                    .frame(height: 118)
            }
            Spacer()
        }
        .redacted(reason: .placeholder)
        .padding(.horizontal, DS.screenHPadding)
    }
}

// MARK: - §2.4 Session row

struct SessionRow: View {
    let summary: SessionSummary

    private var tint: Color {
        summary.groups.first(where: { $0.isConfirmed }).map { DS.exerciseTint($0.tintIndex) }
            ?? DS.textTertiary
    }

    /// One chip per group so the count in the metric line reconciles with what
    /// is shown. An unconfirmed group has no name to print, so it chips as "?".
    private var chips: [String] {
        summary.groups.map { $0.isConfirmed ? $0.displayName : "?" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // 1. Title line
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.title)
                    .font(.dsHeadingRow)
                    .tracking(DSTracking.headingRow)
                    .foregroundStyle(DS.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)
                Text(summary.metaLine)
                    .font(.dsCaptionSmall)
                    .foregroundStyle(DS.textTertiary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.chevron)
            }

            // 2. Metric line — set count leads, reps/exercises demoted.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(summary.totalSets)")
                    .font(.dsNumeralRow)
                    .tracking(DSTracking.numeralRow)
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(" sets")
                    .font(.dsCaptionSmall)
                    .foregroundStyle(DS.textTertiary)
                Text(summary.repsLine)
                    .font(.dsCaptionSmall)
                    .foregroundStyle(DS.textTertiary)
                    .padding(.leading, 8)
            }

            // 3. Exercise chips — cap at 4 + "+N"
            if !chips.isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(Array(chips.prefix(4)), id: \.self) { DSChip(text: $0) }
                    if chips.count > 4 {
                        DSChip(text: "+\(chips.count - 4)")
                    }
                }
            }

            // 4. Pending strip
            if SessionStore.isPending(summary.files) {
                Rectangle().fill(DS.separator).frame(height: 1)
                    .padding(.top, 0)
                HStack(spacing: 6) {
                    Circle().fill(DS.pending).frame(width: 7, height: 7)
                    Text("Transferring · \(summary.files.count) of 2 files")
                        .font(.dsLabelChip)
                        .foregroundStyle(DS.pending)
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.title), \(summary.totalSets) sets, \(summary.totalReps) reps")
    }
}

// MARK: - helpers

extension View {
    /// Strips List's chrome so a row renders as a bare card on the canvas.
    func plainRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// Wrapping horizontal stack for the exercise chips (§2.4).
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}
