# LiftLogger — iPhone UI Design Spec

Implementation target: SwiftUI, iOS 17+, dark appearance only (`.preferredColorScheme(.dark)`).
Reference build: `LiftLogger.dc.html` (live prototype — all values below are taken from it).

Scope: the iPhone companion app (Sessions list, Session Detail, Developer, Rep Tagger) plus the app icons for both targets. The watch app UI is out of scope here.

---

## 1. Design language

### 1.1 Color palette

| Role | Hex | Usage |
|---|---|---|
| `bg.canvas` | `#000000` | Screen background |
| `bg.card` | `#1C1C1E` | All cards, rows, stat tiles, waiting-state tap button |
| `bg.cardHover` | `#26262A` | Pressed state of a tappable card/row |
| `bg.control` | `#2C2C2E` | Secondary buttons, unselected chips |
| `bg.controlHover` | `#36363A` | Pressed state of secondary buttons |
| `bg.inset` | `#000000` | Inset field inside a card (e.g. Subject ID field) |
| `accent.primary` | `#A6F000` | THE accent: set counts, trend line, armed tap button, links/actions |
| `accent.ink` | `#0B0B0C` | Text/graphics drawn *on* `accent.primary` |
| `text.primary` | `#FFFFFF` | Titles, numerals |
| `text.secondary` | `#EBEBF5` | Chip labels, secondary card text |
| `text.tertiary` | `#8E8E93` | Captions, axis labels, metadata, uncertain-state text |
| `text.quaternary` | `#5A5A5E` | Footer hints, field affordance labels |
| `separator` | `#2C2C2E` | 1px hairlines inside cards |
| `stroke.uncertain` | `#3A3A3C` | 1px inset ring on an uncertain-label card |
| `bar.dim` | `#48484A` | Dashed bar segments for uncertain sets |
| `state.pending` | `#FFD426` | Still-transferring session, retry rows |
| `state.negative` | `#FF6B5A` | Negative trend delta |
| `exercise.tint.1` | `#A6F000` | Exercise accent, cycle position 1 |
| `exercise.tint.2` | `#0AE0C8` | Exercise accent, cycle position 2 |
| `exercise.tint.3` | `#FFD426` | Exercise accent, cycle position 3 |
| `exercise.tint.uncertain` | `#8E8E93` | Exercise accent when the label is uncertain |

Rules:
- **One accent per screen.** `#A6F000` marks the single most important number (sets) and the primary action. Never accent two competing numbers on the same screen — reps are deliberately neutral white.
- Exercise tints cycle in order of appearance within a session, `tint.1 → tint.2 → tint.3 → tint.1 …`.
- Derived bar tints: `accent.withAlphaComponent(0.30 + 0.70 * reps / maxRepsInExercise)`.

### 1.2 Typography

System font (SF Pro), `.rounded` design **only** for large numerals; `.default` elsewhere. All numerals `.monospacedDigit()`.

| Token | Size / weight | Tracking | Used for |
|---|---|---|---|
| `display` | 64 / `.heavy` | −0.04em | Session Detail hero set count |
| `title.screen` | 34 / `.heavy` | −0.03em | "Sessions" nav title |
| `numeral.set` | 44 / `.heavy` | −0.035em | Per-set rep numerals (Rep Rail) |
| `numeral.tap` | 56 / `.black` | −0.03em | "TAP" / "WAIT" |
| `numeral.tagger` | 48 / `.heavy` | −0.035em | Tagger counters |
| `numeral.row` | 34 / `.heavy` | −0.035em | Session-row set count |
| `numeral.stat` | 30 / `.heavy` | −0.03em | Graph headline reps; screen titles on secondary screens |
| `numeral.tile` | 24 / `.heavy` | −0.03em | Summary strip tiles |
| `heading.card` | 19 / `.bold` | −0.01em | Exercise name in a detail card |
| `heading.row` | 18 / `.bold` | −0.01em | Session row title |
| `body` | 17 / `.semibold` | 0 | Dev row titles, nav bar items, inset field value (20/`.bold`) |
| `body.button` | 16 / `.semibold` | 0 | Secondary button labels |
| `caption` | 14 / `.regular` | 0 | Subtitles, dev descriptions |
| `caption.small` | 13 / `.regular` | 0 | Row metadata, file sizes, hints |
| `label.chip` | 12 / `.semibold` | 0 | Exercise chips, set labels, deltas |
| `label.overline` | 11 / `.semibold` | +0.10em, uppercase | Card section titles, tile captions |
| `label.axis` | 11 / `.regular` | 0 | Graph x-axis labels |

Set truncation policy: exercise names use `.lineLimit(1)` + `.minimumScaleFactor(0.85)`; session titles never truncate.

### 1.3 Spacing, sizing, radii

Base unit **4pt**. Allowed steps: 2, 4, 5, 6, 8, 9, 10, 11, 12, 14, 16, 18, 20, 26, 34.

| Token | Value |
|---|---|
| `screen.hPadding` | 20 |
| `card.padding` | 15–17 h / 15–18 v (see per-screen) |
| `card.gap` | 9 (list rows) / 10 (detail cards) / 14 (dev cards) |
| `radius.card` | 20 |
| `radius.tile` | 16 |
| `radius.control` | 12 |
| `radius.chip` | 8 |
| `radius.pill` | 14 |
| `bar.height` | 5, `radius` 3 |
| `dot.status` | 7×7 (8×8 in Dev) circle |
| `hit.min` | 44×44 for every tappable element |
| `tap.button` | 280×280 circle |

---

## 2. Screen: Sessions (root)

`NavigationStack` root. Background `bg.canvas`. Vertical layout, top to bottom:

**2.1 Header** — padding `6, 20, 14, 20`
- `Text("Sessions")` — `title.screen`.
- Trailing `HStack(spacing: 8)`:
  - Subject pill: `bg.card`, `radius.pill`, padding `6×11`; 7pt `accent.primary` dot + subject ID in `label.chip` / `text.secondary`.
  - Developer button: 30×30 circle, `bg.card`, SF Symbol `gearshape.fill` 15pt `text.tertiary`; pressed → `bg.cardHover` + `text.secondary`. Expand the tappable area to 44×44 with `.contentShape`.
- Subtitle: "Received from Apple Watch" — `caption` / `text.tertiary`, 2pt below title.

**2.2 Summary strip** — `HStack(spacing: 8)`, bottom padding 12
Three equal tiles: `bg.card`, `radius.tile`, padding `11×13`.
- Value `numeral.tile`; caption `label.overline` / `text.tertiary`.
- Order: **Sessions** (white), **Sets** (`accent.primary`), **Reps** (white).
- Only the SETS value is accented. Do not accent reps.

**2.3 Progress module** (see §4) — bottom padding 14.

**2.4 Session list** — `ScrollView`, `screen.hPadding`, `card.gap` 9, bottom padding 16
Each row is a `Button` wrapping a card: `bg.card`, `radius.card`, padding `14×16`, `VStack(spacing: 9)`:
1. Title line: session title `heading.row` + metadata (`"6:12 PM · 41 min"`) `caption.small`/`text.tertiary`, trailing `chevron.right` 15pt `#48484A`.
2. Metric line, baseline-aligned: **set count** `numeral.row` in the session's tint, then `"sets"` `caption.small`/`text.tertiary`, then 8pt gap and `"48 reps · 3 exercises"` `caption.small`/`text.tertiary`.
3. Exercise chips: wrapping `HStack(spacing: 5)`, each `bg.control`, `radius.chip`, padding `4×8`, `label.chip`/`text.secondary`. Cap at 4 chips + `"+N"` chip.
4. *Pending only:* 1px `separator` top rule, 9pt padding, 7pt `state.pending` dot + `"Transferring · 2 of 3 files"` `label.chip`/`state.pending`.

Row press state: `bg.cardHover`.
Footer under the last row: `"Pull to refresh · files arrive automatically"` — `label.chip`/`text.quaternary`, centered. Wire `.refreshable`.

**2.5 States**
- **Empty:** replace list + progress module with a centered card: `dumbbell` symbol 34pt `text.tertiary`, `"No sessions yet"` `heading.card`, `"Record one on the watch — files arrive here automatically, usually within a minute of End Session."` `caption.small`/`text.tertiary`, and a `"Open Developer"` text button in `accent.primary`.
- **Loading (first sync):** keep header + strip with `—` values; three redacted list rows (`bg.card`, `radius.card`, height 118) with `.redacted(reason: .placeholder)`.
- **Partial/pending:** row renders normally with the pending strip; do not block opening it.
- **Delete:** `.swipeActions` → destructive `trash`, confirm via alert.

---

## 3. Screen: Session Detail (Rep Rail)

Push from a session row. Background `bg.canvas`. `.navigationBarTitleDisplayMode(.inline)` with a custom bar:
- Leading: `"‹ Sessions"` in `accent.primary`, `body`.
- Trailing: `ShareLink` with `square.and.arrow.up`, `accent.primary`.

Content `ScrollView`, `screen.hPadding`, section gap 18, bottom padding 20.

**3.1 Hero**
- Overline: `"TODAY · 6:12 PM · 41 MIN · S01"` — `label.axis` at 13pt `.semibold`, +0.12em, uppercase, `text.tertiary`.
- Metric line (baseline-aligned, 4pt below): **set count** `display` in `accent.primary`, `"sets"` 20/`.semibold` white, then spacer and `"48 reps · 3 exercises"` 15pt `text.tertiary`.

**3.2 Exercise cards** — `VStack(spacing: 10)`, one card per exercise
Card: `bg.card`, `radius.card`, padding `16, 18, 18, 18`.
1. Header `HStack(spacing: 8)`: exercise SF Symbol 15pt in the exercise tint, name `heading.card` white, trailing total `"21 reps"` `caption.small`/`text.tertiary`.
2. Set rail, 14pt below: `HStack(spacing: 10)`, one column per set, each column `VStack(spacing: 6)`:
   - Rep numeral — `numeral.set`, white, `lineSpacing` tight (`line-height ≈ .95`).
   - Bar — height 5, radius 3, fill `tint.withAlpha(0.30 + 0.70 * reps/maxInExercise)`.
   - `"SET n"` — `label.chip` `.regular`, `text.tertiary`.
   - **Column widths are equal and fixed to 3 slots.** If an exercise has fewer than 3 sets, append an empty spacer with `flex = 3 − count` so numerals stay left-aligned on a consistent grid. Exercises with >3 sets wrap to a second row of columns using the same 10pt spacing.

**Hierarchy contract:** the rep numeral is the largest element in the card (44pt) and the set count is the largest on the screen (64pt). Never let a label out-weigh either.

**3.3 Uncertain label state**
When the classifier's label is not confirmed:
- Card gains `inset 1px stroke.uncertain` ring (`.overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "3A3A3C"), lineWidth: 1))`).
- Symbol `questionmark.circle` and name (`"Unrecognized set"` or the low-confidence label) in `text.tertiary`.
- Rep numerals in `text.tertiary`; bars become a dashed pattern: repeating 6pt `bar.dim` segment / 5pt gap.
- Footer inside the card: `separator` top rule (margin-top 14, padding-top 12), `"Label uncertain — confirm to use for training"` `label.chip`/`text.tertiary`, trailing `"Label"` 14/`.semibold` `accent.primary` → opens an exercise picker sheet.
- No confidence percentage anywhere in this screen.

**3.4 Other states**
- **Zero-rep set** (bout detected, rep count 0): numeral `0` in `text.tertiary`, bar at the minimum alpha (0.30), `"SET n"` unchanged.
- **Session with no parsed sets:** single card, `"No sets in this file"` `heading.card`/`text.tertiary` + `"sets.csv has 0 rows"` `caption.small` + `ShareLink` to the raw file.

### 3.5 SF Symbols per exercise

Map on the exercise label; fall back to `dumbbell.fill`.

| Exercise family | Symbol |
|---|---|
| chest press (incline/flat), bench press | `figure.strengthtraining.traditional` |
| shoulder press, overhead press, cable front/side delt | `figure.arms.open` |
| triceps (dips, overhead, push down) | `figure.strengthtraining.functional` |
| row (wide/machine), lat pulldown | `figure.rower` |
| curls (cable, hammer, machine arm) | `dumbbell.fill` |
| forearm / wrist (extensions, curl, raises) | `hand.raised.fill` |
| squat | `figure.cross.training` |
| rest / unrecognized | `questionmark.circle` |
| generic fallback | `dumbbell.fill` |

---

## 4. Component: Progress module (trend line)

Card: `bg.card`, `radius.card`, padding `15, 17, 14, 17`, `VStack(spacing: 11)`.

1. **Header row:** `"PROGRESS · REPS PER SESSION"` `label.overline`/`text.tertiary`; trailing delta `label.chip` — `"+2 vs last"` in `accent.primary`, negative in `state.negative`, zero in `text.tertiary`.
2. **Exercise chips:** `HStack(spacing: 6)`, horizontally scrollable. Selected chip `accent.primary` bg / `accent.ink` text; unselected `bg.control` / `text.secondary`. Radius 8, padding `5×9`, `label.chip`. Default selection = most-performed exercise across received sessions.
3. **Headline:** `"24"` `numeral.stat` white + `"reps · avg 21"` `caption.small`/`text.tertiary`, baseline-aligned.
4. **Chart** — height 96, full card width, `Chart` (Swift Charts) or a `Path`:
   - Series: total reps per session for the selected exercise, last 6 sessions, chronological.
   - `AreaMark` fill `accent.primary` @ 14% opacity; `LineMark` stroke `accent.primary` 3pt, round join/cap; `PointMark` r=3 `#5C7A00` for all points, r=5 `accent.primary` for the newest.
   - **Y domain is padded to the data range, not zero-anchored:** `floor = min − max(1, round((max − min) * 0.35))`, `domain: floor...max`, plot inset 8pt bottom / 14pt top. This is what makes a 17→24 rep climb readable; a zero-anchored axis flattens it.
   - No gridlines, no y-axis labels, no legend.
5. **X labels:** `HStack` with `.frame(maxWidth: .infinity)` per label, `label.axis`/`text.tertiary`, short dates (`"8/20"`).

**States**
- `< 2` sessions for the selected exercise: hide the chart, show `"Two sessions needed to plot a trend"` `caption.small`/`text.tertiary` at 96pt height, centered.
- No sessions at all: module hidden entirely.
- Flat series (all equal): line renders mid-plot; delta shows `"0 vs last"` in `text.tertiary`.

---

## 5. Screen: Developer (hidden)

Reached only from the ⚙ in the Sessions header. Same nav-bar pattern (`"‹ Sessions"`).

- Title `"Developer"` `numeral.stat`; subtitle `"Data-collection tools for training the model. Not needed for normal use."` `caption`/`text.tertiary`.
- `VStack(spacing: 14)` of cards, each `bg.card`, `radius.card`, padding `15×17`:
  1. **Subject** — `label.overline` title; inset field `bg.inset`, `radius.control`, padding `12×14`, value 20/`.bold` + trailing `"Subject ID"` `caption.small`/`text.quaternary`; then full-width button `bg.control`, `radius.control`, padding `12` vertical, `body.button` in `accent.primary`: `"Sync subject to watch"`. Success → the label swaps to `"Synced ✓"` for 2s. Failure → `"Watch unreachable"` in `state.pending`.
  2. **Rep tagger** navigation row — 38×38 `radius.control` tile, `accent.primary` @16% bg, `hand.tap.fill` 17pt `accent.primary`; title `body` + subtitle `"Tap once per rep as ground truth"` `caption.small`/`text.tertiary`; trailing chevron `#48484A`.
  3. **Export for training** — `label.overline` title; button `"Build merged readings + sets CSV"` (`bg.control`, white `body.button`); then one row per artifact: `"readings.csv · 4.2 MB"` `caption.small`/`text.tertiary` with trailing `"Share ↑"` (`square.and.arrow.up`) `accent.primary`, wired to `ShareLink`. Before a build has run, show `"No merged export yet"` in `text.quaternary` instead of the rows.
  4. **Transfer status** — 8pt `state.pending` dot + `"1 session still transferring"` `caption` / `text.secondary`, trailing `"Retry"` `accent.primary`. Hide the whole card when nothing is pending.

---

## 6. Screen: Rep Tagger

Full screen, used at arm's length by an observer. Nav bar: leading `"‹ Developer"` in `accent.primary`. (The `"Simulate watch"` trailing control in the prototype is a design affordance only — ship it behind `#if DEBUG`.)

Layout `VStack(spacing: 16)`, centered, `screen.hPadding`, bottom padding 26:
1. **State overline** — 12pt `.bold`, +0.14em, uppercase. Armed: `"SET OPEN · TAG EVERY REP"` in `accent.primary`. Waiting: `"WAITING FOR WATCH"` in `text.tertiary`.
2. **Exercise** — `numeral.stat` (30/`.heavy`, −0.025em). Armed: exercise name, white. Waiting: `"No set open"`, `text.tertiary`.
3. **Counters** — `HStack(spacing: 34)`: `numeral.tagger` value over `"THIS SET"` / `"SESSION"` (`label.chip`, +0.10em, `text.tertiary`, 4pt gap). THIS SET dims to `text.tertiary` when not armed; SESSION stays white.
4. **Tap button** — 280×280 circle.
   - Armed: fill `accent.primary`, `"TAP"` `numeral.tap` in `accent.ink` over `"EVERY REP"` 17/`.bold` +0.12em, 6pt gap.
   - Waiting: fill `bg.card`, `"WAIT"` + `"WATCH WILL ARM"` in `text.quaternary`, `.disabled(true)`.
   - Press: scale 0.97, `.easeOut(0.06)`; `UIImpactFeedbackGenerator(style: .heavy)` per tap, generator `prepare()`d on arm.
5. **Footer** — `"The button arms itself when the watch opens a set. Every tap is timestamped into reps.csv."` `caption.small`/`text.tertiary`, centered, pushed to the bottom.

**Correctness requirement:** increment with the functional form — `count += 1` inside a single actor-isolated mutation (`withAnimation(nil) { taps += 1 }`), never from a value captured in the view body. Rapid taps must never coalesce; this screen's output is training ground truth. Keep `.allowsHitTesting` on during animations and set `.buttonStyle(.plain)`.

**Edge states**
- Set closes on the watch while tagging → overline flips to waiting, THIS SET freezes then resets to 0 after the row is written.
- Watch disconnects → overline `"WATCH DISCONNECTED"` in `state.pending`, button `bg.card` disabled.
- Tap while disarmed: no-op, no haptic.

---

## 7. App icons

Concept **B — barbell**: a white bar with lime plates, dead-centered, no text, no gradient. Reads as strength training at 40px and stays legible on both light and dark home screens because the tile itself is near-black.

### 7.1 iPhone — 1024×1024 PNG (no alpha)

Canvas 1024×1024, background solid `#0B0B0C` (Apple applies the corner mask; do not pre-round).
All geometry is centered on (512, 512). Coordinates are top-left origin, radii are corner radii.

| Element | x | y | w | h | radius | fill |
|---|---|---|---|---|---|---|
| Shaft | 256 | 464 | 512 | 112 | 56 | `#FFFFFF` |
| Inner plate, left | 144 | 320 | 128 | 400 | 48 | `#A6F000` |
| Inner plate, right | 752 | 320 | 128 | 400 | 48 | `#A6F000` |
| Collar plate, left | 48 | 416 | 80 | 208 | 32 | `#A6F000` @ 60% |
| Collar plate, right | 896 | 416 | 80 | 208 | 32 | `#A6F000` @ 60% |

Notes: plates sit *on top of* the shaft (draw shaft first). No shadow, no stroke, no bevel. Export via a 1024pt SwiftUI/vector source so the same geometry can be scaled.

### 7.2 Watch variant

Same mark, simplified: **drop both collar plates** and thicken the remaining elements so the silhouette survives the circular crop.

Canvas 1024×1024 on `#0B0B0C` (watchOS applies the circular mask):

| Element | x | y | w | h | radius | fill |
|---|---|---|---|---|---|---|
| Shaft | 320 | 456 | 384 | 112 | 56 | `#FFFFFF` |
| Plate, left | 192 | 320 | 128 | 384 | 48 | `#A6F000` |
| Plate, right | 704 | 320 | 128 | 384 | 48 | `#A6F000` |

Keep all artwork inside a 760pt-diameter safe circle centered on the canvas.

### 7.3 Small sizes / favicon

At 44pt (spotlight/settings) and for the web favicon, use the watch geometry — two plates + shaft only. Favicon SVG (32/64px) uses the same ratios on a 14px-radius `#0B0B0C` tile.

### 7.4 Accent color asset

`AccentColor` in both targets: `#A6F000` for dark, `#7FBA00` for light contexts (so lime-on-white controls remain legible if any light surface appears).

---

## 8. Implementation notes

- **Grouping:** parse `sets.csv` rows (`subject, session, exercise, start_ms, end_ms, reps`), group by `exercise` **preserving first-appearance order** (not alphabetical — the order reflects the workout), and number sets within each group by `start_ms` ascending.
- **Never assume a label is certain.** Model every set with `label: String?` + `isConfirmed: Bool`; the uncertain treatment in §3.3 is the default rendering path for unconfirmed rows, not an error state.
- **Numerals:** always `.monospacedDigit()` so counts don't reflow during live updates.
- **Accessibility:** rep numerals get `.accessibilityLabel("Set 1, 8 reps")`; the tap button `.accessibilityLabel("Tag rep")` + `.accessibilityValue("\(setTaps) this set")`. Support Dynamic Type up to XL by scaling `caption`/`body` tokens only — the fixed numerals stay fixed, since their legibility comes from size.
- **Motion:** value changes on numerals use `.contentTransition(.numericText())`; card appearance uses no animation. No parallax, no springs above 0.3s.
- **Do not** add a confidence percentage, a rings/ring-chart treatment, or a second accent color. The visual system is one accent + one card fill.
