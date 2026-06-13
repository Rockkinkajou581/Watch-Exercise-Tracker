<!-- refreshed: 2026-06-13 -->
# Architecture

**Analysis Date:** 2026-06-13

## System Overview

```text
┌─────────────────────────────────────────────────────────────────┐
│                   Apple Watch App (watchOS)                      │
│   `LiftLogger Watch App/LiftLoggerWatchApp.swift`                │
│   `LiftLogger Watch App/RecorderModel.swift`                     │
│   Phases: idle → resting → inSet                                 │
└────────────────────────┬────────────────────────────────────────┘
                         │ WCSession.transferFile()
                         │ (readings.csv + sets.csv)
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    iPhone App (iOS)                               │
│   `LiftLogger/LiftLoggerApp.swift` (PhoneRootView)               │
│   `LiftLogger/SessionStore.swift` (WCSessionDelegate)            │
│   Stores files in Documents/sessions/<sessionID>/                │
└────────────────────────┬────────────────────────────────────────┘
                         │ manual export (ShareLink)
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│             Python Training Pipeline (offline)                   │
│   `training/data.py`  →  `training/train.py`                    │
│   `training/export_coreml.py`                                    │
│   Output: `training/artifacts/LiftLoggerClassifier.mlpackage`    │
└─────────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| LiftLoggerWatchApp | Watch app entry point, injects RecorderModel | `LiftLogger Watch App/LiftLoggerWatchApp.swift` |
| WatchRootView | Phase-driven UI (idle / resting / inSet) | `LiftLogger Watch App/LiftLoggerWatchApp.swift` |
| RecorderModel | IMU capture at 50 Hz, CSV write, WCSession file transfer | `LiftLogger Watch App/RecorderModel.swift` |
| LiftLoggerApp | iOS app entry point, injects SessionStore | `LiftLogger/LiftLoggerApp.swift` |
| PhoneRootView | Session list, export UI | `LiftLogger/LiftLoggerApp.swift` |
| SessionStore | Receives CSV files from watch, merges for export | `LiftLogger/SessionStore.swift` |
| config.py | Central constants shared by all training scripts | `training/config.py` |
| data.py | CSV loading, windowing (100 samples, 50% overlap), label assignment | `training/data.py` |
| models.py | CNN1D architecture and ExportWrapper for CoreML | `training/models.py` |
| train.py | Training loop, early stopping, artifact saving | `training/train.py` |
| export_coreml.py | Converts trained PyTorch model to .mlpackage | `training/export_coreml.py` |
| baseline_rf.py | Random forest baseline for comparison | `training/baseline_rf.py` |

## Pattern Overview

**Overall:** Three-tier data collection pipeline — Watch sensor layer → iOS aggregation layer → Offline ML training layer

**Key Characteristics:**
- Watch is the sole sensor source; iOS is a passive relay with local storage
- No network calls; all transfer is local peer-to-peer via WatchConnectivity
- Training is fully offline (Python/PyTorch); the resulting `.mlpackage` is intended to be bundled back into the watch app
- State machine pattern on the watch: `Phase` enum (`.idle`, `.resting`, `.inSet`) drives all UI and recording logic
- Observable object pattern: both `RecorderModel` and `SessionStore` are `@StateObject`/`ObservableObject` injected via `environmentObject`

## Layers

**Watch Sensor Layer:**
- Purpose: Capture IMU data at 50 Hz and write to local CSV files
- Location: `LiftLogger Watch App/`
- Contains: `RecorderModel.swift` (all logic), `LiftLoggerWatchApp.swift` (UI + entry)
- Depends on: CoreMotion, HealthKit (keep-alive), WatchConnectivity, WatchKit
- Used by: Nothing — this is the origin of all data

**iOS Aggregation Layer:**
- Purpose: Receive CSV files from watch, organize by session, enable export
- Location: `LiftLogger/`
- Contains: `SessionStore.swift`, `LiftLoggerApp.swift`
- Depends on: WatchConnectivity, SwiftUI
- Used by: Training pipeline (receives exported CSVs)

**Python Training Layer:**
- Purpose: Process CSV data, train CNN, export CoreML model
- Location: `training/`
- Contains: `config.py`, `data.py`, `features.py`, `models.py`, `train.py`, `export_coreml.py`, `baseline_rf.py`, `make_synthetic.py`
- Depends on: PyTorch, scikit-learn, coremltools, numpy
- Used by: Developer workflow only — not runtime

## Data Flow

### Primary Recording Path

1. User taps "Start Session" on watch → `RecorderModel.startSession()` (`LiftLogger Watch App/RecorderModel.swift:93`)
2. `openFiles()` creates `<sessionID>_readings.csv` and `<sessionID>_sets.csv` in Watch Documents dir
3. `CMMotionManager` delivers 50 Hz updates on `workQueue` (serial `OperationQueue`)
4. Each update appends a CSV row to `lineBuffer`; every 50 samples (~1 s) `flushReadings()` writes to disk
5. User taps exercise → `startSet()` records `setStartMS` from `ProcessInfo.systemUptime`
6. User taps "End Set" → `endSet()` writes a row to `setsHandle`
7. User taps "End Session" → `endSession()` drains queue, closes handles, calls `WCSession.default.transferFile()` for both CSVs with metadata `{kind, session, subject}`

### Watch-to-Phone Transfer Path

1. `WCSession.transferFile()` queues file transfer (background, survives app termination)
2. iOS `SessionStore.session(_:didReceive:)` fires (`LiftLogger/SessionStore.swift:140`)
3. File is synchronously moved to `Documents/sessions/<sessionID>/<kind>.csv`
4. `refresh()` rebuilds the `sessions` published array

### Training Pipeline Path

1. Developer exports merged CSVs from iPhone via "Build merged readings.csv + sets.csv" → `SessionStore.buildMergedExport()` (`LiftLogger/SessionStore.swift:84`)
2. CSVs are placed in `training/data/`
3. `python training/train.py`: loads CSVs → labels samples → slides 100-sample windows (50% overlap) → trains CNN1D → saves `artifacts/cnn.pt`, `norm.npz`, `classes.json`, `metrics.txt`
4. `python training/export_coreml.py`: wraps model in `ExportWrapper` (bakes normalization) → exports `artifacts/LiftLoggerClassifier.mlpackage`

**State Management:**
- Watch: `RecorderModel.phase: Phase` enum controls all UI branching; all @Published properties mutated on main thread; file I/O on dedicated serial `workQueue`
- iOS: `SessionStore.sessions: [SessionFolder]` is the source of truth, rebuilt from disk on every `refresh()`

## Key Abstractions

**RecorderModel.Phase:**
- Purpose: Explicit state machine preventing invalid transitions (e.g. starting a set while idle)
- Location: `LiftLogger Watch App/RecorderModel.swift:26`
- Pattern: Swift enum, switch-driven view in `WatchRootView`

**SessionFolder:**
- Purpose: Groups related CSV files under a timestamp-based session ID
- Location: `LiftLogger/SessionStore.swift:17`
- Pattern: Lightweight value type (`struct`) conforming to `Identifiable`

**ExportWrapper:**
- Purpose: Bundles trained CNN1D with per-channel normalization stats for zero-overhead on-device inference
- Location: `training/models.py:47`
- Pattern: PyTorch `nn.Module` wrapping another module; bakes `mean`/`std` as registered buffers

## Entry Points

**Watch App:**
- Location: `LiftLogger Watch App/LiftLoggerWatchApp.swift`
- Triggers: watchOS app launch
- Responsibilities: Instantiates `RecorderModel`, renders phase-driven UI

**iOS App:**
- Location: `LiftLogger/LiftLoggerApp.swift`
- Triggers: iOS app launch
- Responsibilities: Instantiates `SessionStore`, activates WCSession, renders session list

**Training:**
- Location: `training/train.py` (primary), `training/export_coreml.py` (export)
- Triggers: Manual developer invocation (`python train.py`)
- Responsibilities: End-to-end model training from raw CSVs to `.mlpackage`

## Architectural Constraints

- **Threading:** Watch file I/O runs exclusively on a serial `OperationQueue` named `liftlogger.recorder`; all `@Published` mutations dispatched to main thread via `DispatchQueue.main.async`
- **Clock alignment:** All timestamps use `CMDeviceMotion.timestamp` (= `ProcessInfo.systemUptime`) on the watch — both IMU samples and set boundaries share the same clock, which is critical for correct label assignment in `data.py`
- **File transfer atomicity:** `WCSession.didReceive(file:)` must move `file.fileURL` synchronously before the delegate returns; the system deletes the inbox file immediately after the method exits
- **Global state:** `WCSession.default` is a singleton; both `RecorderModel` and `SessionStore` register as its delegate on their respective platforms
- **No CoreML inference yet:** The `.mlpackage` artifact exists in `training/artifacts/` but is not yet embedded in the watch app for real-time classification

## Anti-Patterns

### No CoreML on-device inference

**What happens:** The trained `LiftLoggerClassifier.mlpackage` is saved to `training/artifacts/` but never imported into the Xcode project or used at runtime.
**Why it's wrong:** The end goal of the pipeline is live exercise classification on the watch; without embedding the model, all recording is for data collection only.
**Do this instead:** Add `LiftLoggerClassifier.mlpackage` to the Watch App target in Xcode, import `CoreML`, and run inference in `RecorderModel` using a sliding window buffer.

## Error Handling

**Strategy:** Status string pattern — errors are surfaced to users via `@Published var status: String` displayed in the UI; no structured error propagation.

**Patterns:**
- File I/O errors use `try?` (silent ignore) for non-critical operations; throws for session-open (surfaced via `status`)
- WatchConnectivity errors logged to `status`
- HealthKit auth failure degrades gracefully (recording continues, screen-sleep protection lost)

## Cross-Cutting Concerns

**Logging:** No logging framework; `status` string is the sole observability surface
**Validation:** `RecorderModel.sanitize(_:)` cleans subject IDs before use in filenames; `Phase` enum prevents illegal state transitions
**Authentication:** HealthKit permission requested at init; WatchConnectivity peer pairing handled by the OS

---

*Architecture analysis: 2026-06-13*
