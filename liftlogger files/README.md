# LiftLogger — Apple Watch IMU Data Collection App

Records wrist motion (accelerometer + gyroscope) at 50 Hz on the Apple Watch,
captures set boundaries with one-tap labeling, and exports the two CSVs that
feed your training pipeline:

```
Watch records  →  iPhone receives  →  export readings.csv + sets.csv
                                          ↓
                              python build_workouts_csv.py   →  workouts.csv
                                          ↓
                              python train_workout_classifier.py  →  workout_cnn.pt
```

---

## 1. Requirements

- A Mac with **Xcode 15 or newer**
- An **iPhone** (iOS 16+) paired with an **Apple Watch** (watchOS 9+, Series 4 or newer)
- An Apple ID. A **free** account works for your own devices (apps expire after
  7 days — just re-run from Xcode to refresh). The **$99/yr** developer account
  is only needed later for TestFlight distribution to other subjects.

## 2. Create the Xcode project

1. Xcode → **File → New → Project → watchOS → App**
2. Product Name: `LiftLogger`
3. **Check "Watch App with New Companion iOS App"** (wording varies slightly by
   Xcode version — you want both an iOS app and a watch app)
4. Interface: SwiftUI, Language: Swift. Create.

You now have two targets: **LiftLogger** (iOS) and **LiftLogger Watch App**.

## 3. Add the source files

| File | Target |
|---|---|
| `WatchApp/RecorderModel.swift` | LiftLogger **Watch App** only |
| `WatchApp/LiftLoggerWatchApp.swift` | LiftLogger **Watch App** only |
| `PhoneApp/SessionStore.swift` | LiftLogger (**iOS**) only |
| `PhoneApp/LiftLoggerApp.swift` | LiftLogger (**iOS**) only |

- Drag each file into Xcode and **check the correct target** in the dialog.
- **Delete the template files** in both targets: the template `ContentView.swift`
  in each, and the template `*App.swift` in each (the provided files contain
  `@main` — having two `@main`s in one target is a build error).
- Target membership is the #1 source of build errors here. If you get
  "cannot find type RecorderModel", a file is in the wrong target.

## 4. Capabilities & Info.plist (Watch App target only)

Select the **LiftLogger Watch App** target:

**Signing & Capabilities tab → + Capability:**
- **HealthKit**
- **Background Modes** → check **Workout processing**

**Info tab → add these keys** (Custom Target Properties):
- `NSMotionUsageDescription` → "Records wrist motion to build the exercise dataset."
- `NSHealthUpdateUsageDescription` → "Runs a workout session so recording continues with the screen off."
- `NSHealthShareUsageDescription` → "Runs a workout session so recording continues with the screen off."

The iOS target needs nothing special.

Why this matters: without the HealthKit workout session, watchOS suspends the
app the moment the screen sleeps and your recordings will have silent gaps.
This is the single most common failure mode.

## 5. Signing & deploy

1. Both targets → Signing & Capabilities → Team: your personal team.
   Let Xcode manage signing.
2. Connect the iPhone by cable. Enable Developer Mode if prompted
   (Settings → Privacy & Security → Developer Mode, on both iPhone and Watch).
3. Select the **LiftLogger Watch App** scheme, destination
   **"<Your Watch> via <Your iPhone>"** → Run. First deploy to a watch is slow
   (several minutes); subsequent runs are fast.
4. Select the **LiftLogger** (iOS) scheme → Run once to install the phone app.
5. If the app won't launch: iPhone Settings → General → VPN & Device
   Management → trust your developer certificate.

## 6. First smoke test (do this before a real gym session)

1. Phone app: set Subject ID (e.g. `S01`) → **Sync subject to watch**.
2. Watch: **Start Session** → grant Motion and Health permissions when prompted.
3. Tap any exercise → wave your arm for ~20 s → **End Set**.
4. **End Session**. Wait ~1 minute.
5. Phone app: the session should appear with `readings.csv` and `sets.csv`.
   Sample count should be ≈ 50 × recording-seconds. If samples flatline when
   the screen sleeps, the HealthKit capability/permission is wrong (step 4).

## 7. Using it for real collection

- **Start Session once at the beginning** of the workout, End Session at the
  very end. It records continuously, including rest — that's intentional
  (rest becomes a labeled class via the transform script).
- **Tap the exercise with the weight already in hand, and begin rep 1
  immediately.** Tap **End Set** right at the last rep. Sloppy taps = noisy
  labels at the set boundaries (the transform's purity filter drops some of
  this, but discipline beats filtering).
- The watch confirms set start/stop with haptics so you don't need to look.
- Keep the iPhone within Bluetooth range (gym bag is fine).
- If files don't arrive (phone left in a locker, app quit early), they're kept
  on the watch — the home screen shows **Resend N file(s)**.
- Battery: a 60-min session costs roughly 10–20%. Start charged.
- Editing the exercise list: change the `exercises` array at the top of
  `RecorderModel.swift`. Use `snake_case`, and never name one `rest`.

## 8. Export → train

1. Phone app → **Build merged readings.csv + sets.csv** → **Share merged CSVs**
   → AirDrop to your Mac (or Save to Files).
2. Put both files next to `build_workouts_csv.py` and run:
   ```
   python build_workouts_csv.py        # → workouts.csv (+ label counts report)
   python train_workout_classifier.py  # → workout_cnn.pt
   ```
3. Keep `FS = 50` in the trainer — it matches the watch's sampling rate.

### Two training reminders

- **`rest` will dominate the label counts** (rest time usually exceeds set time).
  Either keep it (the model learns to say "nothing happening" — useful later)
  but consider class weights in `CrossEntropyLoss`, or downsample rest windows.
- **Honest accuracy = split by subject, not by session.** With multiple
  subjects, make sure the same person never appears in both train and val.
  Easiest path: one continuous recording per subject per session, and group
  the split by the `subject` column (the transform script preserves it).

## 9. Data formats (for reference)

`readings.csv` — one row per sample, continuous through the whole session:
```
subject,session,time_ms,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z
S01,20260610-141503,123456.0,0.012345,-0.987654,0.054321,0.001234,...
```
- Accel = userAcceleration + gravity, in **g** (gravity kept on purpose — it
  encodes arm orientation). Gyro in **rad/s**.
- `time_ms` is the watch's time-since-boot clock. Set events use the same
  clock, so they align exactly. Timestamps are only meaningful *within* a
  session — the transform script handles everything per-session.

`sets.csv` — one row per labeled set:
```
subject,session,exercise,start_ms,end_ms
S01,20260610-141503,bicep_curl,180000.0,210500.0
```

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Samples stop when screen sleeps | HealthKit capability missing, Background Mode unchecked, or Health permission denied. Watch status line will say "keep-alive failed". |
| No motion data at all | Motion permission denied → Watch Settings → Privacy → Motion & Fitness. |
| Files never arrive on phone | Transfers queue and retry automatically — give it a few minutes with both apps installed. Otherwise use **Resend** on the watch home screen. |
| "cannot find type …" build error | File added to the wrong target (see §3). |
| Two `@main` errors | Template App file wasn't deleted (see §3). |
| App stops launching after a week | Free-account signing expired — plug in and Run again from Xcode. |
