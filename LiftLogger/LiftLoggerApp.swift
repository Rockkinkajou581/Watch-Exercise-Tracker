//
//  LiftLoggerApp.swift
//  LiftLogger  (add to the iOS target only)
//
//  Replaces the Xcode template's App file AND ContentView.swift — delete the
//  template ContentView.swift in the iOS target.
//

import SwiftUI
import UIKit

@main
struct LiftLoggerApp: App {
    @StateObject private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            PhoneRootView().environmentObject(store)
        }
    }
}

struct PhoneRootView: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Subject") {
                    TextField("Subject ID (e.g. S01)", text: $store.subject)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    Button("Sync subject to watch") {
                        store.sendSubjectToWatch()
                    }
                }

                Section("Rep tagging") {
                    NavigationLink {
                        RepTapView().environmentObject(store)
                    } label: {
                        Label(store.repSessionActive ? "Tagging in progress…" : "Open rep tagger",
                              systemImage: "hand.tap")
                            .foregroundStyle(store.repSessionActive ? Color.green : Color.primary)
                    }
                    Text("Open this and hold the phone while someone lifts on the watch. "
                         + "Tap once per rep — used as ground truth for rep counting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Received sessions") {
                    if store.sessions.isEmpty {
                        Text("No sessions yet. Record one on the watch — files arrive here automatically (can take a minute after End Session).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.sessions) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.id).font(.headline)
                            ForEach(s.files, id: \.self) { f in
                                Text("\(f.lastPathComponent) — \(Self.sizeString(f))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ShareLink(items: s.files) {
                                Label("Share this session", systemImage: "square.and.arrow.up")
                            }
                            .font(.callout)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { idx in
                        idx.map { store.sessions[$0].id }.forEach(store.deleteSession)
                    }
                }

                Section("Export for training") {
                    Button("Build merged readings.csv + sets.csv") {
                        store.buildMergedExport()
                    }
                    if !store.mergedURLs.isEmpty {
                        ShareLink(items: store.mergedURLs) {
                            Label("Share merged CSVs", systemImage: "square.and.arrow.up")
                        }
                    }
                    if !store.status.isEmpty {
                        Text(store.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("LiftLogger")
            .refreshable { store.refresh() }
            .onAppear { store.refresh() }
        }
    }

    static func sizeString(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Full-screen rep tagger: the observer taps the big button once per rep while
/// the lifter performs the set on the watch. The button is only active while a
/// set is open (the watch drives that via live messages); each tap is timestamped
/// and written as ground-truth rep timing for the supervised rep counter.
struct RepTapView: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text(store.repExercise.isEmpty
                     ? (store.repSessionActive ? "—" : "Not recording")
                     : store.repExercise.replacingOccurrences(of: "_", with: " "))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(store.repStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 28) {
                stat("This set", store.repSetCount)
                stat("Session", store.repSessionTotal)
            }

            Button {
                store.recordTap()
                let gen = UIImpactFeedbackGenerator(style: .heavy)
                gen.impactOccurred()
            } label: {
                ZStack {
                    Circle()
                        .fill(store.repSetArmed ? Color.green : Color.gray.opacity(0.3))
                    Text(store.repSetArmed ? "TAP\nREP" : "WAIT")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
                .frame(width: 240, height: 240)
            }
            .buttonStyle(.plain)
            .disabled(!store.repSetArmed)

            Text("Button activates automatically when a set starts on the watch.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("Rep Tagger")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack {
            Text("\(value)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
