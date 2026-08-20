//
//  RepTapView.swift
//  LiftLogger  (iOS target only)
//
//  design.md §6 — the observer taps once per rep while the lifter works on the
//  watch. This screen's output is training ground truth, so the tap path stays
//  deliberately dumb: one mutation per press, no animation that could swallow a
//  hit, no state derived from a value captured in the body.
//

import SwiftUI
import UIKit

struct RepTapView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    /// Kept warm so the first tap of a set isn't the one that pays for setup.
    @State private var haptics = UIImpactFeedbackGenerator(style: .heavy)

    private var armed: Bool { store.repSetArmed }
    private var disconnected: Bool { !store.watchReachable && !store.repSessionActive }

    var body: some View {
        VStack(spacing: 16) {
            overline
            exerciseName
            counters
            tapButton
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, DS.screenHPadding)
        .padding(.top, 8)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Developer").font(.dsBody)
                    }
                    .foregroundStyle(DS.accent)
                }
            }
        }
        .toolbarBackground(DS.canvas, for: .navigationBar)
        .onChange(of: armed) { _, isArmed in
            if isArmed { haptics.prepare() }
        }
    }

    private var overline: some View {
        Group {
            if disconnected {
                label("Watch disconnected", DS.pending)
            } else if armed {
                label("Set open · tag every rep", DS.accent)
            } else {
                label("Waiting for watch", DS.textTertiary)
            }
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(12 * 0.14)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
    }

    private var exerciseName: some View {
        Text(armed && !store.repExercise.isEmpty
             ? prettyExercise(store.repExercise) : "No set open")
            .font(.dsNumeralStat)
            .tracking(30 * -0.025)
            .foregroundStyle(armed ? DS.textPrimary : DS.textTertiary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
    }

    private var counters: some View {
        HStack(spacing: 34) {
            counter(store.repSetCount, "This set", dimmed: !armed)
            counter(store.repSessionTotal, "Session", dimmed: false)
        }
    }

    private func counter(_ value: Int, _ caption: String, dimmed: Bool) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.dsNumeralTagger)
                .tracking(DSTracking.numeralTagger)
                .monospacedDigit()
                .foregroundStyle(dimmed ? DS.textTertiary : DS.textPrimary)
                .contentTransition(.numericText())
            Text(caption.uppercased())
                .font(.dsLabelChip)
                .tracking(12 * 0.10)
                .foregroundStyle(DS.textTertiary)
        }
    }

    private var tapButton: some View {
        Button {
            // One mutation, no animation wrapper that could coalesce rapid taps.
            store.recordTap()
            haptics.impactOccurred()
            haptics.prepare()
        } label: {
            ZStack {
                Circle().fill(armed ? DS.accent : DS.card)
                VStack(spacing: 6) {
                    Text(armed ? "TAP" : "WAIT")
                        .font(.dsNumeralTap)
                        .tracking(DSTracking.numeralTap)
                        .foregroundStyle(armed ? DS.accentInk : DS.textQuaternary)
                    Text(armed ? "EVERY REP" : "WATCH WILL ARM")
                        .font(.system(size: 17, weight: .bold))
                        .tracking(17 * 0.12)
                        .foregroundStyle(armed ? DS.accentInk : DS.textQuaternary)
                }
            }
            .frame(width: DS.tapButton, height: DS.tapButton)
        }
        .buttonStyle(TapPressStyle())
        .disabled(!armed)
        .accessibilityLabel("Tag rep")
        .accessibilityValue("\(store.repSetCount) this set")
    }

    private var footer: some View {
        Text("The button arms itself when the watch opens a set. Every tap is timestamped into reps.csv.")
            .font(.dsCaptionSmall)
            .foregroundStyle(DS.textTertiary)
            .multilineTextAlignment(.center)
    }
}

/// §6 — the press treatment lives in a ButtonStyle rather than a gesture, so
/// nothing competes with the Button's own tap recognition. Rapid taps each
/// deliver their own action; the scale is cosmetic and never gates the hit.
private struct TapPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
    }
}
