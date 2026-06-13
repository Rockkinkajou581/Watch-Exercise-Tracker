# Technology Stack

**Analysis Date:** 2026-06-13

## Languages

**Primary:**
- Swift — iOS app (`LiftLogger/`) and watchOS app (`LiftLogger Watch App/`)
- Python 3.9.6 — ML training pipeline (`training/`)

**Secondary:**
- C/Objective-C — Bridging headers (`LiftLogger/LiftLogger-Bridging-Header.h`, `LiftLogger Watch App/LiftLogger Watch App-Bridging-Header.h`)

## Runtime

**Environment:**
- watchOS (minimum watchOS 9, per CoreML export target `ct.target.watchOS9`)
- iOS (companion iPhone app)
- Python 3.9.6 (training pipeline, via venv at `training/.venv/`)

**Package Manager:**
- pip (Python) — `training/requirements.txt`
- Swift Package Manager / Xcode project — `LiftLogger.xcodeproj/project.pbxproj`
- Lockfile: Not present (no `requirements.lock` or `Package.resolved`)

## Frameworks

**Core (Swift / Apple):**
- SwiftUI — UI for both iOS and watchOS targets
- Combine — Reactive state (`@Published`, `ObservableObject`) in `SessionStore.swift` and `RecorderModel.swift`
- CoreMotion — IMU sensor sampling at 50 Hz (`CMMotionManager`) in `LiftLogger Watch App/RecorderModel.swift`
- WatchConnectivity — File transfer between watch and iPhone (`WCSession`) in both `SessionStore.swift` and `RecorderModel.swift`
- HealthKit — Workout session keep-alive to prevent watchOS from suspending the recording app (`HKWorkoutSession`) in `LiftLogger Watch App/RecorderModel.swift`
- WatchKit — Haptic feedback (`WKInterfaceDevice.current().play(.start/.stop)`) in `LiftLogger Watch App/RecorderModel.swift`

**ML (Python):**
- PyTorch — CNN model definition and training (`training/models.py`, `training/train.py`)
- scikit-learn — Baseline random forest classifier (`training/baseline_rf.py`)
- coremltools — Export trained PyTorch model to `.mlpackage` for on-device inference (`training/export_coreml.py`)
- Core ML (Apple, runtime) — On-watch inference via `LiftLoggerClassifier.mlpackage` (`training/artifacts/LiftLoggerClassifier.mlpackage`)

**Data / Utils (Python):**
- numpy — Normalization statistics, array ops (`training/features.py`, `training/export_coreml.py`)
- pandas — CSV data loading and manipulation (`training/data.py`)

**Build/Dev:**
- Xcode — iOS/watchOS build, project file at `LiftLogger.xcodeproj/`
- Python venv — Isolated training environment at `training/.venv/`

## Key Dependencies

**Critical:**
- `torch` — Defines and trains the 1-D CNN classifier (`training/models.py`); ~150k parameter model
- `coremltools` — Converts trained PyTorch model to Core ML for deployment on Apple Watch (`training/export_coreml.py`)
- `WatchConnectivity` (Apple SDK) — The sole data transport between watch and iPhone; no network connectivity used
- `CoreMotion` (Apple SDK) — IMU data source; app is non-functional without it

**Infrastructure:**
- `scikit-learn` — Baseline random forest for benchmarking (`training/baseline_rf.py`)
- `numpy` — Normalization parameters persisted in `training/artifacts/norm.npz`
- `pandas` — Reads `training/data/readings.csv` and `training/data/sets.csv`

## Configuration

**Training Pipeline:**
- Central config file: `training/config.py`
- Key parameters: `FS=50` (Hz), `WINDOW=100` (samples), `CHANNELS=["acc_x","acc_y","acc_z","gyro_x","gyro_y","gyro_z"]`, `BATCH_SIZE=64`, `EPOCHS=80`, `LR=1e-3`
- Artifacts output to `training/artifacts/` — `cnn.pt`, `norm.npz`, `classes.json`, `LiftLoggerClassifier.mlpackage`

**Swift / Xcode:**
- Watch app info plist: `LiftLogger-Watch-App-Info.plist`
- Watch app entitlements: `LiftLogger Watch App/LiftLogger Watch App.entitlements`
- No `.env` files — no secrets or API keys required

**Sensor/Model Sync Constraint:**
- `config.py` `FS=50` and `WINDOW=100` MUST match `motion.deviceMotionUpdateInterval = 1.0/50.0` in `RecorderModel.swift` — these are tightly coupled

## Platform Requirements

**Development:**
- macOS with Xcode (for Swift/watchOS/iOS builds)
- Python 3.9.6 (training pipeline)
- Apple Watch paired to iPhone (for data collection)

**Production:**
- Apple Watch (watchOS 9+) — sensor recording and ML inference
- iPhone (iOS) — receives session CSV files, merges and exports for training

---

*Stack analysis: 2026-06-13*
