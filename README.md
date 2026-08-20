# LiftLogger — Watch Exercise Tracker

An Apple Watch app that automatically detects which gym exercise you're doing and counts your reps in real time — no manual entry required. A companion iPhone app receives and stores the logged sessions. Built with Claude Code.

## How it works

The watch samples wrist motion (accelerometer + gyroscope, fused via CoreMotion) at 50 Hz and runs two small convolutional neural networks **on-device** via CoreML / the Neural Engine:

1. **Exercise classifier** (`CNN1D`) — looks at a rolling 2-second window (100 samples × 6 channels: `acc_x/y/z`, `gyro_x/y/z`) and predicts which of 16 trained exercises (or "rest") is currently happening. Runs ~2x/second; a prediction only commits once it's been confident and stable for a couple of consecutive windows, so brief glitches don't log a phantom set.
2. **Rep counter** (`RepDensityCNN`) — once a set is detected, its full IMU bout is resampled to a fixed length and fed through a dilated 1-D convnet that outputs a rep-density curve (one bump per rep) rather than a single number; the rep count is the curve's integral. This is more accurate than naive peak-counting, especially for wrist-quiet exercises.

Both models are compact 1-D temporal CNNs (~150k params each) — small and fast enough for the Watch's Neural Engine, translation-invariant to *where* in a rep the window starts, and they convert cleanly to CoreML.

```
CMMotionManager (50 Hz IMU)
        │
        ▼
rolling 100-sample window ──► CNN1D ──► exercise label + confidence
        │                                        │
        ▼                                        ▼ (stable, non-rest)
per-set IMU bout ──► RepDensityCNN ──► rep count
        │
        ▼
 detected.csv  ──WatchConnectivity──►  iPhone app (session history)
```

## What it detects

16 exercises trained so far (see `exercises` in `RecorderModel.swift`): incline/flat chest press, machine shoulder press, cable side/front delt, seated tricep dips, overhead triceps, cable push down, wide-grip row, lat pulldown, cable curl, dumbbell hammer curl, machine arm curl, wrist extensions, forearm curl, forearm raises — plus an implicit "rest" class for everything else.

## Repo layout

| path | what it is |
|---|---|
| `LiftLogger Watch App/` | the watch app — `RecorderModel.swift` (sensor loop, live inference, session logging), bundled `LiftLoggerClassifier.mlpackage` |
| `LiftLogger/` | the companion iPhone app — `SessionStore.swift` receives synced sessions from the watch |
| `training/` | the Python/PyTorch pipeline that turns recorded CSVs into the CoreML models (see `training/README.md` for full detail, including the model-choice writeup) |
| `LiftLogger.xcodeproj` | Xcode project for both targets |

## Training pipeline (high level)

The watch can log two kinds of sessions:
- **Manual/training sessions** — you tap the exercise button yourself; every raw sample plus the labeled set boundaries are written to `readings.csv` / `sets.csv` and synced to the phone.
- **Auto-detect sessions** — the live on-watch model runs continuously and logs whatever it recognizes to `detected.csv`, kept separate so it's never mistaken for ground-truth training data.

From collected `readings.csv` + `sets.csv` (and optional per-rep tap timestamps in `reps.csv`), `training/` slices the IMU stream into labeled 2-second windows, trains `CNN1D` (classification) and `RepDensityCNN` (rep density regression) in PyTorch, evaluates on a held-out set of *subjects* (not just windows, so accuracy reflects generalizing to a new person), and exports both to `.mlpackage` for the watch to consume directly. Full details, quick-start commands, and the reasoning behind picking a 1-D CNN over alternatives (RF baseline, LSTM/GRU, TCN, transformers, k-NN+DTW) are in [`training/README.md`](training/README.md).

## Usage

1. Open the watch app and tap **Start** at the beginning of your workout.
2. Move through your workout as normal — switch exercises freely; the app detects each one automatically and counts reps as you go.
3. Tap **Stop** when you're done.
4. The session (every exercise performed, with rep counts and timing) syncs to the iPhone app automatically.

No manual exercise selection, no manual rep counting.
