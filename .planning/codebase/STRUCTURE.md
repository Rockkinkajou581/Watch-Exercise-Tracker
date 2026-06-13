# Codebase Structure

**Analysis Date:** 2026-06-13

## Directory Layout

```
LiftLogger/                                  # repo root
├── LiftLogger/                              # iOS app target sources
│   ├── LiftLoggerApp.swift                  # App entry point + PhoneRootView UI
│   ├── SessionStore.swift                   # ObservableObject: WCSession receiver + CSV merger
│   ├── LiftLogger-Bridging-Header.h         # ObjC bridging header (empty/template)
│   └── Assets.xcassets/                     # App icon, accent color
│
├── LiftLogger Watch App/                    # watchOS app target sources
│   ├── LiftLoggerWatchApp.swift             # App entry point + WatchRootView UI
│   ├── RecorderModel.swift                  # ObservableObject: IMU capture, CSV write, transfer
│   ├── LiftLogger Watch App.entitlements    # HealthKit entitlement
│   ├── LiftLogger Watch App-Bridging-Header.h
│   └── Assets.xcassets/
│
├── LiftLogger Watch AppTests/               # watchOS unit test target (empty stubs)
├── LiftLogger Watch AppUITests/             # watchOS UI test target (empty stubs)
│   └── LiftLogger_Watch_AppUITests.swift
│   └── LiftLogger_Watch_AppUITestsLaunchTests.swift
│
├── LiftLoggerTests/                         # iOS unit test target (empty stub)
│   └── LiftLoggerTests.swift
│
├── LiftLoggerUITests/                       # iOS UI test target (empty stubs)
│   └── LiftLoggerUITests.swift
│   └── LiftLoggerUITestsLaunchTests.swift
│
├── LiftLogger.xcodeproj/                    # Xcode project file
│
├── training/                                # Offline Python ML pipeline
│   ├── config.py                            # All tunable constants (FS, WINDOW, paths, etc.)
│   ├── data.py                              # CSV loading, windowing, label assignment
│   ├── features.py                          # Feature engineering utilities
│   ├── models.py                            # CNN1D + ExportWrapper definitions
│   ├── train.py                             # Training loop entry point
│   ├── export_coreml.py                     # PyTorch → CoreML .mlpackage export
│   ├── baseline_rf.py                       # Random forest baseline
│   ├── make_synthetic.py                    # Synthetic data generation for testing
│   ├── requirements.txt                     # Python dependencies
│   ├── data/
│   │   ├── readings.csv                     # Raw IMU recordings (from iPhone export)
│   │   └── sets.csv                         # Set boundaries with exercise labels
│   ├── artifacts/                           # Generated outputs — do not edit manually
│   │   ├── LiftLoggerClassifier.mlpackage/  # Trained CoreML model ready for embedding
│   │   ├── cnn.pt                           # Raw PyTorch weights
│   │   ├── norm.npz                         # Per-channel mean/std normalization stats
│   │   ├── classes.json                     # Ordered class name list
│   │   └── metrics.txt                      # Test accuracy + confusion matrix
│   └── .venv/                               # Python virtual environment (not committed)
│
├── .planning/                               # GSD planning documents
│   └── codebase/
├── .claude/                                 # Claude/GSD tooling config
├── AI Pipeline.html                         # Architecture documentation (HTML)
├── LiftLogger_DataCollection_App_Explained.html
├── LiftLogger-Watch-App-Info.plist
├── README.md
└── .gitignore
```

## Directory Purposes

**`LiftLogger/` (iOS target):**
- Purpose: iPhone companion app — receives sensor CSVs from watch, organizes sessions, merges for export
- Contains: 2 Swift source files, assets
- Key files: `LiftLogger/SessionStore.swift`, `LiftLogger/LiftLoggerApp.swift`

**`LiftLogger Watch App/` (watchOS target):**
- Purpose: Primary data collection app running on the wrist
- Contains: 2 Swift source files, assets, entitlements
- Key files: `LiftLogger Watch App/RecorderModel.swift`, `LiftLogger Watch App/LiftLoggerWatchApp.swift`

**`training/`:**
- Purpose: Offline ML development — process collected CSVs, train classifier, export to CoreML
- Contains: Python scripts, raw data, trained artifacts
- Key files: `training/config.py` (constants), `training/train.py` (entry), `training/models.py` (architecture)

**`training/data/`:**
- Purpose: Input CSVs for training — populated by exporting from the iPhone app
- Generated: No (placed here manually after export)
- Committed: Yes (current dataset)

**`training/artifacts/`:**
- Purpose: All outputs of the training pipeline
- Generated: Yes (`python training/train.py` + `python training/export_coreml.py`)
- Committed: Yes (model checkpoint and CoreML package are tracked)

## Key File Locations

**Entry Points:**
- `LiftLogger/LiftLoggerApp.swift`: iOS `@main` struct, creates `SessionStore`
- `LiftLogger Watch App/LiftLoggerWatchApp.swift`: watchOS `@main` struct, creates `RecorderModel`
- `training/train.py`: Training pipeline entry point
- `training/export_coreml.py`: CoreML export entry point

**Configuration:**
- `training/config.py`: ALL tunable ML constants (sample rate, window size, training hyperparameters, file paths)
- `LiftLogger-Watch-App-Info.plist`: Watch app plist overrides
- `LiftLogger Watch App/LiftLogger Watch App.entitlements`: HealthKit entitlement

**Core Logic:**
- `LiftLogger Watch App/RecorderModel.swift`: IMU recording, state machine, file I/O, WatchConnectivity transfer
- `LiftLogger/SessionStore.swift`: File receive delegate, session management, CSV merge
- `training/models.py`: CNN1D and ExportWrapper class definitions
- `training/data.py`: Windowing and label-assignment logic

**Testing:**
- `LiftLoggerTests/LiftLoggerTests.swift`: iOS unit test stub (empty)
- `LiftLoggerUITests/LiftLoggerUITests.swift`: iOS UI test stub (empty)
- `LiftLogger Watch AppUITests/LiftLogger_Watch_AppUITests.swift`: Watch UI test stub (empty)

## Naming Conventions

**Swift Files:**
- `PascalCase` for types and files matching their primary type: `RecorderModel.swift`, `SessionStore.swift`
- App entry files named `<TargetName>App.swift`: `LiftLoggerApp.swift`, `LiftLoggerWatchApp.swift`

**Swift Types:**
- Structs/classes: `PascalCase` — `SessionFolder`, `RecorderModel`, `PhoneRootView`
- Enums/cases: `PascalCase` type, `camelCase` cases — `Phase.idle`, `Phase.inSet`
- Properties/methods: `camelCase` — `startSession()`, `buildMergedExport()`, `pendingFiles`
- Private members marked `private`; internal helpers marked `// MARK: -`

**Python Files:**
- `snake_case` module names: `config.py`, `data.py`, `export_coreml.py`, `make_synthetic.py`

**Python Classes/Functions:**
- Classes: `PascalCase` — `CNN1D`, `ExportWrapper`
- Functions/variables: `snake_case` — `make_windows()`, `compute_norm()`, `label_samples()`

**Session IDs:**
- Format: `yyyyMMdd-HHmmss` — e.g. `20260610-141503`
- Generated by `RecorderModel.sessionIDNow()`

**CSV Files on Watch:**
- Pattern: `<sessionID>_readings.csv`, `<sessionID>_sets.csv`
- After transfer to iPhone: stored as `Documents/sessions/<sessionID>/readings.csv` and `sets.csv`

## Where to Add New Code

**New Watch UI screen:**
- Add a new `case` to `RecorderModel.Phase` in `LiftLogger Watch App/RecorderModel.swift`
- Add the corresponding view branch in `WatchRootView.body` in `LiftLogger Watch App/LiftLoggerWatchApp.swift`

**New exercise type:**
- Edit the `exercises` array in `LiftLogger Watch App/RecorderModel.swift:42`
- No other changes needed — label flows automatically into CSV

**New iPhone UI section:**
- Add a `Section` in `PhoneRootView.body` in `LiftLogger/LiftLoggerApp.swift`
- Add corresponding action methods to `LiftLogger/SessionStore.swift`

**New ML model architecture:**
- Add class to `training/models.py`
- Update `training/train.py` to instantiate new model
- Keep `ExportWrapper` interface unchanged to avoid breaking `export_coreml.py`

**New training hyperparameters:**
- Add constants to `training/config.py` only — all other scripts import from there

**New training data:**
- Export merged CSVs from iPhone app
- Append to or replace `training/data/readings.csv` and `training/data/sets.csv`
- Re-run `python training/train.py` then `python training/export_coreml.py`

**Utilities / shared helpers:**
- Python: add to `training/features.py` (feature engineering) or create a new module in `training/`
- Swift: add methods directly to `RecorderModel` or `SessionStore` as appropriate (project is too small for a separate utilities file)

## Special Directories

**`training/artifacts/`:**
- Purpose: All ML pipeline outputs — weights, normalization stats, class list, CoreML package, metrics
- Generated: Yes (by `train.py` and `export_coreml.py`)
- Committed: Yes

**`training/.venv/`:**
- Purpose: Python virtual environment
- Generated: Yes
- Committed: No (in `training/.gitignore`)

**`.planning/`:**
- Purpose: GSD planning and codebase map documents
- Generated: By GSD tooling
- Committed: Yes

**`LiftLogger.xcodeproj/`:**
- Purpose: Xcode project definition and user data
- Generated: Partially (user data in `xcuserdata/` is local)
- Committed: Project file yes; user data typically gitignored

---

*Structure analysis: 2026-06-13*
