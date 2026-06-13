# Coding Conventions

**Analysis Date:** 2026-06-13

## Naming Patterns

**Files:**
- Swift: PascalCase matching the primary type they contain (`RecorderModel.swift`, `SessionStore.swift`, `LiftLoggerApp.swift`, `LiftLoggerWatchApp.swift`)
- Python: snake_case module names (`config.py`, `models.py`, `features.py`, `train.py`, `data.py`, `baseline_rf.py`, `export_coreml.py`, `make_synthetic.py`)

**Types/Classes:**
- Swift: PascalCase (`RecorderModel`, `SessionStore`, `PhoneRootView`, `WatchRootView`, `CNN1D`, `ExportWrapper`)
- Python: PascalCase for classes (`CNN1D`, `ExportWrapper`); snake_case for functions/variables

**Functions/Methods:**
- Swift: camelCase verbs describing the action (`startSession()`, `endSet()`, `buildMergedExport()`, `sendSubjectToWatch()`, `scanPending()`, `flushReadings()`)
- Python: snake_case (`set_seed`, `evaluate`, `compute_norm`, `label_samples`, `make_windows`, `window_features`, `feature_matrix`)

**Variables:**
- Swift: camelCase (`sampleCount`, `setCount`, `sessionID`, `csvPrefix`, `lineBuffer`, `workQueue`)
- Python: snake_case (`best_f1`, `best_state`, `train_loader`, `val_loader`)

**Constants/Config:**
- Swift: `static let` in PascalCase for headers (`readingsHeader`, `setsHeader`)
- Python: UPPER_SNAKE_CASE module-level constants (`FS`, `WINDOW`, `BATCH_SIZE`, `SEED`, `ARTIFACTS`)

**Enums:**
- Swift: PascalCase enum name with camelCase cases: `enum Phase { case idle, resting, inSet }`

## Code Style

**Formatting:**
- No auto-formatter config detected (no `.swiftformat`, `.prettier`, `biome.json`)
- Swift follows standard Xcode indentation (4 spaces)
- Python follows standard PEP 8 conventions (4 spaces)

**Linting:**
- No ESLint, SwiftLint, or flake8 config detected

## Import Organization

**Swift pattern:**
1. Foundation
2. Combine
3. Framework-specific (CoreMotion, HealthKit, WatchConnectivity, WatchKit)
4. SwiftUI

Example from `RecorderModel.swift`:
```swift
import Foundation
import Combine
import CoreMotion
import HealthKit
import WatchConnectivity
import WatchKit
```

**Python pattern:**
1. Standard library (`json`, `random`)
2. Third-party (`numpy`, `torch`, `sklearn`)
3. Local modules (`config`, `data`, `models`)

Example from `train.py`:
```python
import json
import random
import numpy as np
import torch
from sklearn.metrics import classification_report, confusion_matrix, f1_score
import config
from data import compute_norm, label_samples, load_raw, make_splits, make_windows
from models import CNN1D
```

## Error Handling

**Swift patterns:**
- `try?` used for non-fatal file/IO operations that can silently fail: `try? fm.removeItem(...)`, `try? h.write(...)`
- `do/catch` with `status` string update used for user-visible errors:
  ```swift
  do {
      try WCSession.default.updateApplicationContext(["subject": clean])
      status = "subject \"\(clean)\" synced to watch"
  } catch {
      status = "sync failed: \(error.localizedDescription)"
  }
  ```
- Status messages surface errors to the UI via `@Published var status: String`
- `guard ... else { return }` used for early exits on invalid state:
  ```swift
  guard phase == .resting else { return }
  ```
- `[weak self]` used consistently in closures to avoid retain cycles

**Python patterns:**
- No explicit try/except in training scripts — errors propagate naturally
- Guard conditions with early returns (implicit via control flow)

## Logging

**Framework:** No dedicated logging framework

**Patterns:**
- Swift: user-visible status stored in `@Published var status: String` on model classes, dispatched to main thread: `DispatchQueue.main.async { self.status = s }`
- Python: `print()` used for training progress output (`print(f"epoch {epoch:3d} ...")`), no structured logging

## Comments

**When to Comment:**
- File-level header comments in Swift explain the target, purpose, and output schema
- Inline comments explain non-obvious decisions (clock alignment rationale, flush frequency, thread safety)
- Python docstrings on classes and functions with brief purpose + key parameter/shape information

**Swift doc comment style:**
```swift
/// Concatenates every session's CSVs into one readings.csv + one sets.csv
/// (headers written once). Output goes to the temp dir for sharing.
func buildMergedExport() {
```

**Python docstring style:**
```python
def window_features(win: np.ndarray) -> np.ndarray:
    """win: (WINDOW, C) -> 1-D feature vector."""
```

**MARK sections used in Swift:**
- `// MARK: - UI state (mutate on main thread only)`
- `// MARK: - private`
- `// MARK: - session control (call from UI / main thread)`
- `// MARK: - motion`
- `// MARK: - files`
- `// MARK: - HealthKit workout keep-alive`
- `// MARK: - helpers`
- `// MARK: - WCSessionDelegate (watch side)`

## Function Design

**Size:** Methods are small-to-medium; each does one thing (open files, flush buffer, transfer files)

**Parameters:** Minimal — prefer reading state from `self` over passing parameters

**Return Values:**
- Swift: void for state-mutating methods; computed properties for derived values
- Python: typed return annotations used (`-> np.ndarray`, `-> list[float]`)

## Module Design

**Swift exports:** `final class` used for both model types — not subclassable (`final class RecorderModel`, `final class SessionStore`)

**Protocol conformance via extensions:** Delegate conformances are in separate `extension` blocks at bottom of file:
```swift
// MARK: - WCSessionDelegate (watch side)
extension RecorderModel: WCSessionDelegate { ... }
extension RecorderModel: HKWorkoutSessionDelegate { ... }
```

**ObservableObject pattern:** Both model classes are `ObservableObject` with `@Published` properties for SwiftUI binding. Views access models via `@EnvironmentObject`.

**Thread safety:** IO-bound work dispatched to a serial `OperationQueue` named `liftlogger.recorder`; UI updates dispatched back to `DispatchQueue.main.async`. This pattern is used consistently throughout `RecorderModel.swift`.

**Python modules:** Scripts import from `config` as a shared constants module — all tunable values live in `config.py` and are imported by all other pipeline scripts.

---

*Convention analysis: 2026-06-13*
