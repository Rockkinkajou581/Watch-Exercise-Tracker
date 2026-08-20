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
        case .countdown: countdownView
        case .inSet: inSetView
        case .enteringReps: repsEntryView
        case .autoDetecting: autoDetectingView
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

                Button {
                    model.startAutoSession()
                } label: {
                    Text("Auto-Detect (AI)").bold()
                }
                .tint(.blue)

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
            if model.canDiscardLast {
                Section {
                    Button(role: .destructive) {
                        model.discardLastSet()
                    } label: {
                        Label("Discard last set", systemImage: "trash")
                    }
                } footer: {
                    Text("Mark the set you just finished as bad — it won't be used for training.")
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

    // MARK: - countdown (get into position before the set window opens)

    private var countdownView: some View {
        VStack(spacing: 8) {
            Text(model.currentExercise.replacingOccurrences(of: "_", with: " "))
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("\(model.countdownRemaining)")
                .font(.system(size: 60, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            Text("Get into position")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(role: .cancel) {
                model.cancelCountdown()
            } label: {
                Text("Cancel")
            }
        }
        .padding()
    }

    // MARK: - rep entry (after End Set, before logging the set)

    private var repsEntryView: some View {
        VStack(spacing: 6) {
            Text(model.currentExercise.replacingOccurrences(of: "_", with: " "))
                .font(.headline)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .lineLimit(2)
            Text(model.repsFromPhone ? "Reps — from phone taps" : "Reps")
                .font(.footnote)
                .foregroundStyle(model.repsFromPhone ? Color.green : Color.secondary)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
            HStack(spacing: 14) {
                Button { model.decrementReps() } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.plain)
                .font(.title2)

                Text("\(model.repsEntry)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 56)
                    .contentTransition(.numericText())

                Button { model.incrementReps() } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .font(.title2)
            }
            Button {
                model.confirmReps()
            } label: {
                Text("Save Set").bold()
            }
            .tint(.green)
        }
        .padding()
    }

    // MARK: - auto-detect (AI labels the set live; no exercise buttons)

    private var autoDetectingView: some View {
        let resting = model.liveExercise == RecorderModel.restLabel || model.liveExercise == "—"
        return VStack(spacing: 8) {
            Text("Auto-Detect")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text(model.liveExercise.replacingOccurrences(of: "_", with: " "))
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(resting ? Color.secondary : Color.green)
                .minimumScaleFactor(0.7)
                .lineLimit(2)

            Text(String(format: "%.0f%%", model.liveConfidence * 100))
                .font(.system(.title3, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(resting ? .secondary : .primary)

            LabeledContent("Logged", value: "\(model.detectedCount)")
                .font(.footnote)
            LabeledContent("Last reps", value: "\(model.lastDetectedReps)")
                .font(.footnote)

            Button(role: .destructive) {
                model.endSession()
            } label: {
                Text("End Session")
            }
            .tint(.red)
        }
        .padding()
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
