//
//  LiftLoggerWatchApp.swift
//  LiftLogger Watch App  (add to the WATCH target only)
//
//  Replaces the Xcode template's App file AND ContentView.swift — delete the
//  template ContentView.swift in the watch target.
//
//  Flow:  Start Session → tap an exercise (set starts) → End Set → … → End Session
//

import SwiftUI

@main
struct LiftLoggerWatchApp: App {
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView().environmentObject(model)
        }
    }
}

struct WatchRootView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        switch model.phase {
        case .idle: idleView
        case .resting: restingView
        case .inSet: inSetView
        }
    }

    // MARK: - idle

    private var idleView: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Subject: \(model.subject)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    model.startSession()
                } label: {
                    Text("Start Session").bold()
                }
                .tint(.green)

                if !model.pendingFiles.isEmpty {
                    Button {
                        model.resendPending()
                    } label: {
                        Text("Resend \(model.pendingFiles.count) file(s)")
                    }
                    .tint(.orange)
                }

                Text(model.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal)
        }
    }

    // MARK: - resting (session active, between sets)

    private var restingView: some View {
        List {
            Section("Tap to start set") {
                ForEach(model.exercises, id: \.self) { ex in
                    Button(ex.replacingOccurrences(of: "_", with: " ")) {
                        model.startSet(ex)
                    }
                }
            }
            Section {
                LabeledContent("Sets", value: "\(model.setCount)")
                LabeledContent("Samples", value: "\(model.sampleCount)")
                Button(role: .destructive) {
                    model.endSession()
                } label: {
                    Text("End Session")
                }
            }
        }
    }

    // MARK: - in set

    private var inSetView: some View {
        VStack(spacing: 10) {
            Text(model.currentExercise.replacingOccurrences(of: "_", with: " "))
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(model.setStartDate, style: .timer)
                .font(.system(.title2, design: .rounded))
                .monospacedDigit()

            Button {
                model.endSet()
            } label: {
                Text("End Set").bold()
            }
            .tint(.red)
        }
        .padding()
    }
}
