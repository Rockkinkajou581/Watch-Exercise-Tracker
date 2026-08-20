//
//  DeveloperView.swift
//  LiftLogger  (iOS target only)
//
//  design.md §5 — the data-collection tools, moved off the main flow. Everything
//  the old root Form did (subject sync, rep tagger, merged export) lives here.
//

import SwiftUI

struct DeveloperView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    /// Drives the transient "Synced ✓" / "Watch unreachable" label swap.
    @State private var syncFeedback: String?
    @State private var syncFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Developer")
                            .font(.dsNumeralStat)
                            .tracking(DSTracking.numeralStat)
                            .foregroundStyle(DS.textPrimary)
                        Text("Data-collection tools for training the model. Not needed for normal use.")
                            .font(.dsCaption)
                            .foregroundStyle(DS.textTertiary)
                    }
                    .padding(.bottom, 2)

                    subjectCard
                    repTaggerRow
                    exportCard
                    if !store.pendingSessions.isEmpty { transferCard }
                }
                .padding(.horizontal, DS.screenHPadding)
                .padding(.bottom, 26)
            }
            .background(DS.canvas)
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Sessions").font(.dsBody)
                        }
                        .foregroundStyle(DS.accent)
                    }
                }
            }
            .toolbarBackground(DS.canvas, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .tint(DS.accent)
    }

    // §5.1
    private var subjectCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                DSOverline(text: "Subject")

                HStack {
                    TextField("S01", text: $store.subject)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(DS.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    Text("Subject ID")
                        .font(.dsCaptionSmall)
                        .foregroundStyle(DS.textQuaternary)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(DS.inset,
                            in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))

                Button {
                    syncSubject()
                } label: {
                    Text(syncFeedback ?? "Sync subject to watch")
                }
                .buttonStyle(DSControlButtonStyle(tint: syncFailed ? DS.pending : DS.accent))
            }
        }
    }

    private func syncSubject() {
        store.sendSubjectToWatch()
        syncFailed = store.status.contains("failed")
        syncFeedback = syncFailed ? "Watch unreachable" : "Synced ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            syncFeedback = nil
            syncFailed = false
        }
    }

    // §5.2
    private var repTaggerRow: some View {
        NavigationLink {
            RepTapView().environmentObject(store)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(DS.accent)
                    .frame(width: 38, height: 38)
                    .background(DS.accent.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: DS.radiusControl,
                                                     style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rep tagger")
                        .font(.dsBody)
                        .foregroundStyle(DS.textPrimary)
                    Text("Tap once per rep as ground truth")
                        .font(.dsCaptionSmall)
                        .foregroundStyle(DS.textTertiary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.chevron)
            }
            .padding(EdgeInsets(top: 15, leading: 17, bottom: 15, trailing: 17))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(DSCardButtonStyle())
    }

    // §5.3
    private var exportCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                DSOverline(text: "Export for training")

                Button("Build merged readings + sets CSV") {
                    store.buildMergedExport()
                }
                .buttonStyle(DSControlButtonStyle(tint: DS.textPrimary))

                if store.mergedURLs.isEmpty {
                    Text("No merged export yet")
                        .font(.dsCaptionSmall)
                        .foregroundStyle(DS.textQuaternary)
                } else {
                    ForEach(store.mergedURLs, id: \.self) { url in
                        HStack {
                            Text("\(url.lastPathComponent) · \(Self.sizeString(url))")
                                .font(.dsCaptionSmall)
                                .foregroundStyle(DS.textTertiary)
                            Spacer(minLength: 8)
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(DS.accent)
                            }
                        }
                    }
                    if !store.status.isEmpty {
                        Text(store.status)
                            .font(.dsCaptionSmall)
                            .foregroundStyle(DS.textQuaternary)
                    }
                }
            }
        }
    }

    // §5.4
    private var transferCard: some View {
        DSCard {
            HStack(spacing: 8) {
                Circle().fill(DS.pending).frame(width: 8, height: 8)
                Text("\(store.pendingSessions.count) session\(store.pendingSessions.count == 1 ? "" : "s") still transferring")
                    .font(.dsCaption)
                    .foregroundStyle(DS.textSecondary)
                Spacer(minLength: 8)
                Button("Retry") { store.refresh() }
                    .font(.dsBodyButton)
                    .foregroundStyle(DS.accent)
            }
        }
    }

    static func sizeString(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
