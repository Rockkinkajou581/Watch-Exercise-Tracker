//
//  LiftLoggerApp.swift
//  LiftLogger  (add to the iOS target only)
//
//  Replaces the Xcode template's App file AND ContentView.swift — delete the
//  template ContentView.swift in the iOS target.
//

import SwiftUI

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
