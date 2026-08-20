//
//  DesignSystem.swift
//  LiftLogger  (iOS target only)
//
//  The tokens from design.md §1. Everything visual in the phone app pulls from
//  here — no literal colors or font sizes in the view files.
//

import SwiftUI

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - §1.1 Colors

enum DS {
    static let canvas = Color(hex: "000000")
    static let card = Color(hex: "1C1C1E")
    static let cardHover = Color(hex: "26262A")
    static let control = Color(hex: "2C2C2E")
    static let controlHover = Color(hex: "36363A")
    static let inset = Color(hex: "000000")

    static let accent = Color(hex: "A6F000")
    static let accentInk = Color(hex: "0B0B0C")

    static let textPrimary = Color(hex: "FFFFFF")
    static let textSecondary = Color(hex: "EBEBF5")
    static let textTertiary = Color(hex: "8E8E93")
    static let textQuaternary = Color(hex: "5A5A5E")

    static let separator = Color(hex: "2C2C2E")
    static let strokeUncertain = Color(hex: "3A3A3C")
    static let barDim = Color(hex: "48484A")
    static let chevron = Color(hex: "48484A")

    static let pending = Color(hex: "FFD426")
    static let negative = Color(hex: "FF6B5A")

    /// Exercise tints cycle in order of first appearance within a session.
    static let exerciseTints = [
        Color(hex: "A6F000"),
        Color(hex: "0AE0C8"),
        Color(hex: "FFD426"),
    ]

    /// Uncertain groups carry index -1 and take the grey tint rather than a
    /// slot in the cycle.
    static func exerciseTint(_ index: Int) -> Color {
        guard index >= 0 else { return textTertiary }
        return exerciseTints[index % exerciseTints.count]
    }

    // MARK: - §1.3 Spacing, sizing, radii

    static let screenHPadding: CGFloat = 20
    static let radiusCard: CGFloat = 20
    static let radiusTile: CGFloat = 16
    static let radiusControl: CGFloat = 12
    static let radiusChip: CGFloat = 8
    static let radiusPill: CGFloat = 14
    static let barHeight: CGFloat = 5
    static let barRadius: CGFloat = 3
    static let tapButton: CGFloat = 280
}

// MARK: - §1.2 Typography
//
// Tracking in the spec is given in em; SwiftUI wants points, so each token
// converts once here (points = size * em).

extension Font {
    static let dsDisplay = Font.system(size: 64, weight: .heavy, design: .rounded)
    static let dsTitleScreen = Font.system(size: 34, weight: .heavy)
    static let dsNumeralSet = Font.system(size: 44, weight: .heavy, design: .rounded)
    static let dsNumeralTap = Font.system(size: 56, weight: .black, design: .rounded)
    static let dsNumeralTagger = Font.system(size: 48, weight: .heavy, design: .rounded)
    static let dsNumeralRow = Font.system(size: 34, weight: .heavy, design: .rounded)
    static let dsNumeralStat = Font.system(size: 30, weight: .heavy, design: .rounded)
    static let dsNumeralTile = Font.system(size: 24, weight: .heavy, design: .rounded)
    static let dsHeadingCard = Font.system(size: 19, weight: .bold)
    static let dsHeadingRow = Font.system(size: 18, weight: .bold)
    static let dsBody = Font.system(size: 17, weight: .semibold)
    static let dsBodyButton = Font.system(size: 16, weight: .semibold)
    static let dsCaption = Font.system(size: 14)
    static let dsCaptionSmall = Font.system(size: 13)
    static let dsLabelChip = Font.system(size: 12, weight: .semibold)
    static let dsLabelOverline = Font.system(size: 11, weight: .semibold)
    static let dsLabelAxis = Font.system(size: 11)
}

enum DSTracking {
    static let display: CGFloat = 64 * -0.04
    static let titleScreen: CGFloat = 34 * -0.03
    static let numeralSet: CGFloat = 44 * -0.035
    static let numeralTap: CGFloat = 56 * -0.03
    static let numeralTagger: CGFloat = 48 * -0.035
    static let numeralRow: CGFloat = 34 * -0.035
    static let numeralStat: CGFloat = 30 * -0.03
    static let numeralTile: CGFloat = 24 * -0.03
    static let headingCard: CGFloat = 19 * -0.01
    static let headingRow: CGFloat = 18 * -0.01
    static let overline: CGFloat = 11 * 0.10
}

// MARK: - Shared primitives

/// §2.4 / §5 — the standard card fill, with the pressed treatment when tappable.
struct DSCard<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 15, leading: 17, bottom: 15, trailing: 17)
    var radius: CGFloat = DS.radiusCard
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Cards that are buttons swap to `bg.cardHover` while pressed (§2.4).
struct DSCardButtonStyle: ButtonStyle {
    var radius: CGFloat = DS.radiusCard

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? DS.cardHover : DS.card,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
    }
}

/// §5 — secondary buttons on `bg.control`.
struct DSControlButtonStyle: ButtonStyle {
    var tint: Color = DS.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dsBodyButton)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                configuration.isPressed ? DS.controlHover : DS.control,
                in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
            )
    }
}

/// §2.4 exercise chips and §4 selectable chips.
struct DSChip: View {
    let text: String
    var selected = false

    var body: some View {
        Text(text)
            .font(.dsLabelChip)
            .foregroundStyle(selected ? DS.accentInk : DS.textSecondary)
            .padding(.vertical, selected ? 5 : 4)
            .padding(.horizontal, selected ? 9 : 8)
            .background(
                selected ? DS.accent : DS.control,
                in: RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
            )
    }
}

/// §2.1 / §3.1 — uppercase overline with wide tracking.
struct DSOverline: View {
    let text: String
    var size: CGFloat = 11
    var tracking: CGFloat = 11 * 0.10
    var color: Color = DS.textTertiary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}

/// §3.5 — exercise label → SF Symbol. Matched on substrings so the underscored
/// CSV labels ("cable_push_down") and display names both resolve.
enum ExerciseSymbol {
    static func name(for exercise: String, uncertain: Bool = false) -> String {
        if uncertain { return "questionmark.circle" }
        let e = exercise.lowercased().replacingOccurrences(of: "_", with: " ")

        if e.contains("rest") { return "questionmark.circle" }
        if e.contains("squat") { return "figure.cross.training" }
        if e.contains("row") || e.contains("pulldown") { return "figure.rower" }
        if e.contains("tricep") || e.contains("dip") || e.contains("push down")
            || e.contains("pushdown") {
            return "figure.strengthtraining.functional"
        }
        if e.contains("shoulder press") || e.contains("overhead press")
            || e.contains("delt") {
            return "figure.arms.open"
        }
        if e.contains("bench") || e.contains("chest press") || e.contains("press") {
            return "figure.strengthtraining.traditional"
        }
        if e.contains("forearm") || e.contains("wrist") { return "hand.raised.fill" }
        if e.contains("curl") { return "dumbbell.fill" }
        return "dumbbell.fill"
    }
}

/// "bench_press" → "Bench Press". The CSV labels are underscored snake case.
func prettyExercise(_ raw: String) -> String {
    raw.replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}
