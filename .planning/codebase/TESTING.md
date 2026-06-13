# Testing Patterns

**Analysis Date:** 2026-06-13

## Test Framework

**Swift Unit Tests:**
- Framework: Swift Testing (new Apple framework, not XCTest)
- Config: Xcode project — `LiftLoggerTests/LiftLoggerTests.swift`
- Import: `import Testing`

**Swift UI Tests:**
- Framework: XCTest with XCUIAutomation
- Config: Xcode project — `LiftLoggerUITests/LiftLoggerUITests.swift`, `LiftLoggerUITests/LiftLoggerUITestsLaunchTests.swift`
- Import: `import XCTest`

**Watch App UI Tests:**
- Framework: XCTest
- Location: `LiftLogger Watch AppUITests/LiftLogger_Watch_AppUITests.swift`, `LiftLogger Watch AppUITests/LiftLogger_Watch_AppUITestsLaunchTests.swift`

**Python Training Pipeline:**
- No test framework detected — no `pytest`, `unittest`, or test files found in `training/`

**Run Commands:**
```bash
# Run all tests via Xcode (command line)
xcodebuild test -scheme LiftLogger -destination 'platform=iOS Simulator,name=iPhone 16'

# Run UI tests
xcodebuild test -scheme LiftLoggerUITests -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Test File Organization

**Location:** Separate test targets (standard Xcode convention)
- Unit tests: `LiftLoggerTests/` — iOS target unit tests
- UI tests: `LiftLoggerUITests/` — iOS UI automation
- Watch UI tests: `LiftLogger Watch AppUITests/` — Watch UI automation

**Naming:**
- Unit test files: `LiftLoggerTests.swift`
- UI test files: `LiftLoggerUITests.swift`, `LiftLoggerUITestsLaunchTests.swift`
- Watch UI test files: `LiftLogger_Watch_AppUITests.swift`, `LiftLogger_Watch_AppUITestsLaunchTests.swift`

## Test Structure

**Swift Testing (unit tests) pattern:**
```swift
import Testing
@testable import LiftLogger

struct LiftLoggerTests {
    @Test func example() async throws {
        // #expect(...) assertions
    }
}
```

**XCTest (UI tests) pattern:**
```swift
import XCTest

final class LiftLoggerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws { }

    @MainActor
    func testExample() throws {
        let app = XCUIApplication()
        app.launch()
        // XCTAssert assertions
    }
}
```

**Patterns:**
- Setup: `setUpWithError()` on XCTest classes; `continueAfterFailure = false` set in UI test setup
- Teardown: `tearDownWithError()` (currently empty stubs)
- Async tests: `async throws` supported via Swift Testing `@Test` macro

## Mocking

**Framework:** None detected — no mocking libraries (OCMock, etc.) present

**Current state:** Test files contain only Xcode template stubs with no actual mocks or test logic implemented.

**What to Mock (when tests are added):**
- `WCSession` — watch connectivity cannot be tested on simulator without mock
- `CMMotionManager` — hardware sensor; needs mock for unit tests of `RecorderModel`
- `HKHealthStore` / `HKWorkoutSession` — HealthKit not available in unit test context
- `FileManager` — file IO in `SessionStore` and `RecorderModel` should be mockable via injection

## Fixtures and Factories

**Test Data:**
- No fixtures or factories exist yet
- Sample CSV data format for `readings.csv`:
  `subject,session,time_ms,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z`
- Sample CSV data format for `sets.csv`:
  `subject,session,exercise,start_ms,end_ms`
- Synthetic data generator exists at `training/make_synthetic.py` — can be used to generate CSV fixtures for testing the Python pipeline

**Location:**
- Real training data: `training/data/readings.csv`, `training/data/sets.csv`
- Synthetic data script: `training/make_synthetic.py`

## Coverage

**Requirements:** None enforced — no coverage configuration detected

**View Coverage:**
```bash
xcodebuild test -scheme LiftLogger -enableCodeCoverage YES -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Test Types

**Unit Tests (`LiftLoggerTests/`):**
- Scope: iOS app logic — currently only an empty stub exists
- Target: `LiftLogger` module via `@testable import LiftLogger`
- Key untested logic: `SessionStore.buildMergedExport()`, `SessionStore.refresh()`, `RecorderModel.sanitize()`, `RecorderModel.sessionIDNow()`

**Integration Tests:**
- Not implemented

**E2E / UI Tests (`LiftLoggerUITests/`, `LiftLogger Watch AppUITests/`):**
- Framework: XCUIAutomation
- Current state: Template stubs only — `testExample()` launches app but makes no assertions; `testLaunchPerformance()` measures launch time with `XCTApplicationLaunchMetric`
- Launch screenshot capture is implemented in `LiftLoggerUITestsLaunchTests.swift`:
  ```swift
  let attachment = XCTAttachment(screenshot: app.screenshot())
  attachment.name = "Launch Screen"
  attachment.lifetime = .keepAlways
  add(attachment)
  ```

## Common Patterns

**Async Testing (Swift Testing):**
```swift
@Test func example() async throws {
    // use await for async calls
    // use #expect(...) for assertions
}
```

**Performance Testing (XCTest):**
```swift
func testLaunchPerformance() throws {
    measure(metrics: [XCTApplicationLaunchMetric()]) {
        XCUIApplication().launch()
    }
}
```

**Error Testing:**
- No error testing patterns implemented yet
- Recommended approach when adding: use `#expect(throws:)` in Swift Testing or `XCTAssertThrowsError` in XCTest

## Current Test Coverage State

All test targets exist but contain only Xcode-generated stubs. No actual test logic is implemented. The following are the highest-priority areas to add tests:

- `RecorderModel.sanitize(_:)` — pure static function, easily unit testable (`LiftLogger Watch App/RecorderModel.swift`)
- `SessionStore.buildMergedExport()` — CSV merging logic testable with temp files (`LiftLogger/SessionStore.swift`)
- Python training pipeline — `training/features.py` `window_features()` and `feature_matrix()` are pure functions suitable for pytest unit tests

---

*Testing analysis: 2026-06-13*
