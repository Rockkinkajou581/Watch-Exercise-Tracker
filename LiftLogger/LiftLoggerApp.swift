//
//  LiftLoggerApp.swift
//  LiftLogger  (add to the iOS target only)
//
//  The screens live in SessionsView / SessionDetailView / DeveloperView /
//  RepTapView; this file is only the entry point. The app is dark-only
//  (design.md §1) — the palette assumes a black canvas throughout.
//

import SwiftUI

@main
struct LiftLoggerApp: App {
    @StateObject private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            SessionsView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
