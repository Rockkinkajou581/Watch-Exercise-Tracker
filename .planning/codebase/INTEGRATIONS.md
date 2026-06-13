# External Integrations

**Analysis Date:** 2026-06-13

## APIs & External Services

**None.** LiftLogger has no network calls, no third-party cloud APIs, and no remote backends. All data stays on-device and transfers locally between Apple Watch and iPhone via WatchConnectivity.

## Data Storage

**Databases:**
- None (no SQLite, CoreData, or cloud database)

**File Storage (local only):**
- Watch: CSV files written to app's Documents directory (`FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]`) — `<sessionID>_readings.csv` and `<sessionID>_sets.csv` — `LiftLogger Watch App/RecorderModel.swift`
- iPhone: Received session CSVs stored under `Documents/sessions/<sessionID>/` — `LiftLogger/SessionStore.swift`
- Training: `training/data/readings.csv` and `training/data/sets.csv` (merged export from iPhone); model artifacts in `training/artifacts/`

**Caching:**
- None

## Authentication & Identity

**Auth Provider:**
- None — no user accounts, no login

**Subject Identity:**
- Subject ID is a plain string (e.g. "S01") entered in the iPhone app and synced to the watch via `WCSession.default.updateApplicationContext(["subject": id])` — `LiftLogger/SessionStore.swift:68`

## Device-to-Device Communication

**WatchConnectivity (Apple framework — local, no internet):**
- Channel: `WCSession` (Bluetooth/Wi-Fi peer-to-peer between watch and paired iPhone)
- Watch → iPhone: `WCSession.default.transferFile(url, metadata:)` sends CSV files after each session ends — `LiftLogger Watch App/RecorderModel.swift:160–166`
- iPhone → Watch: `WCSession.default.updateApplicationContext(["subject":])` pushes subject ID — `LiftLogger/SessionStore.swift:70`
- iPhone receives files via `WCSessionDelegate.session(_:didReceive file:)` — `LiftLogger/SessionStore.swift:140`
- Watch receives subject updates via `WCSessionDelegate.session(_:didReceiveApplicationContext:)` — `LiftLogger Watch App/RecorderModel.swift:342`

## Apple System Frameworks Used as Integrations

**CoreMotion (sensor hardware):**
- `CMMotionManager` — samples accelerometer + gyroscope at 50 Hz
- Channels: `acc_x, acc_y, acc_z, gyro_x, gyro_y, gyro_z` (total gravity-inclusive acceleration + rotation rate)
- Used in: `LiftLogger Watch App/RecorderModel.swift:192–214`

**HealthKit (keep-alive only):**
- Purpose: Starts an `HKWorkoutSession` (type: `.traditionalStrengthTraining`) solely to prevent watchOS from suspending the app when the screen sleeps. Workout data is discarded via `discardWorkout()` — not written to Health app.
- Authorization requested for: `HKObjectType.workoutType()` (share only, no read)
- Used in: `LiftLogger Watch App/RecorderModel.swift:254–298`

**Core ML (on-device inference, Apple framework):**
- Model: `training/artifacts/LiftLoggerClassifier.mlpackage` — drag into Xcode Watch App target
- Input: `MLMultiArray` shape `[1, 100, 6]` (1 batch × 100 time steps × 6 IMU channels)
- Output: `classLabel` (String, top-1 prediction), `classLabel_probs` ([String: Double])
- Inference runs entirely on-device; no network call
- Xcode auto-generates `LiftLoggerClassifier` Swift class from the `.mlpackage`

## Monitoring & Observability

**Error Tracking:**
- None — errors surface via `@Published var status: String` displayed in the UI

**Logs:**
- None — no remote logging or analytics

## CI/CD & Deployment

**Hosting:**
- None — distributed as a direct Xcode build to physical devices (no App Store, no TestFlight evident)

**CI Pipeline:**
- None detected

## Webhooks & Callbacks

**Incoming:** None

**Outgoing:** None

## Environment Configuration

**Required env vars:** None — the app has no secrets or external credentials

**Secrets location:** Not applicable

---

*Integration audit: 2026-06-13*
