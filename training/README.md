# LiftLogger — training pipeline

Trains an exercise classifier from watch IMU data and exports it to Core ML for
on-watch inference.

```
watch (RecorderModel.swift)  ->  readings.csv + sets.csv  ->  this pipeline  ->  LiftLoggerClassifier.mlpackage  ->  watch app
```

## Layout

| file | what it does |
|------|--------------|
| `config.py` | all knobs: sample rate, window size, hyperparameters, paths |
| `data.py` | load CSVs, label each sample, slice into windows, split **by subject** |
| `features.py` | hand-crafted window features for the RF baseline |
| `models.py` | the 1-D CNN + an export wrapper that bakes in normalization |
| `train.py` | train the CNN, evaluate, save weights/metrics |
| `baseline_rf.py` | Random Forest baseline — the number to beat |
| `export_coreml.py` | convert the trained CNN to `.mlpackage` |
| `make_synthetic.py` | generate fake data so you can run all of the above **today** |

## With real data

1. In the iPhone app, tap **merged export** and AirDrop / save `readings.csv` and
   `sets.csv`.
2. Drop both into `training/data/`.
3. `python train.py && python export_coreml.py`.
4. Drag `artifacts/LiftLoggerClassifier.mlpackage` into the Xcode project, Watch
   App target. Use the generated `LiftLoggerClassifier` class (see the header of
   `export_coreml.py` for the call).

The model input is a `[1, 100, 6]` array: 100 frames (2 s @ 50 Hz) × 6 channels in
the order `acc_x, acc_y, acc_z, gyro_x, gyro_y, gyro_z` — **raw** values; the model
normalizes internally. Slide it every ~0.5 s during a workout.

---

## Model choice — best to worst for this problem

The constraints that decide this: 6-channel IMU @ 50 Hz, short windows of a
**periodic** motion, a **small hand-collected** dataset, eventually **20–30
classes**, and inference on an **Apple Watch** (tiny compute, Core ML / Neural
Engine).

### Recommended

- **1-D CNN (temporal ConvNet)** — *what this repo ships.* Translation-invariant,
  so it doesn't care where in the rep the window starts; small (~150k params);
  fast on the Neural Engine; converts cleanly to Core ML. The workhorse of
  activity recognition. Best accuracy-per-effort here.
- **Random Forest / gradient boosting on hand-crafted features** — *the baseline.*
  Remarkably hard to beat on small data, robust, interpretable (feature importance
  tells you which axes matter), trains in seconds. Downside: you'd have to
  re-implement the feature extraction in Swift to deploy it, and it plateaus below
  a good CNN as classes/data grow.

### Worth trying once you have lots of data

- **CNN + small GRU/LSTM (DeepConvLSTM)** — CNN for local motion motifs, a
  recurrent layer for longer structure. Often +1–3% accuracy. Costs: bigger,
  slower, recurrent layers are fiddlier to convert and less Neural-Engine-friendly.
- **TCN (dilated temporal convolutions)** — like the CNN but a larger receptive
  field for cheap; good if some exercises have long, slow reps.

### Avoid (for on-watch deployment)

- **k-NN + DTW** — decent for time series, but inference compares against the whole
  training set: O(N) per prediction, no clean Core ML path. Can't live on a watch.
- **Vanilla RNN (no gating)** — vanishing gradients, unstable, slow; strictly
  dominated by GRU/LSTM.
- **Large pretrained / LLM-style models** — absurd for 6-channel IMU on a watch.

## Scaling to 20–30 exercises

The architecture doesn't need to change much, just widen the conv channels a little and
collect more data. What actually moves accuracy:

1. **Data variety beats model fanciness.** Multiple subjects, both wrists, watch
   rotated differently on the wrist, varied tempo and weight. The biggest real-world
   error source is a new *user*, which is why `data.py` splits **by subject** — that
   number is the one that predicts how it does on a stranger.
2. **More samples per class.** Aim for tens of sets per exercise per person; rare
   classes will dominate the confusion matrix until they have enough data.
3. **Watch the confusion matrix, not just accuracy.** Mechanically similar moves
   (bicep vs. hammer curl) blur together — that tells you where to collect more or
   merge classes.
4. **Class imbalance.** `rest` will dominate; training already applies class
   weights, and `metrics.txt` reports per-class F1 so a high overall accuracy can't
   hide a class the model never gets right.

## Rep counting: two training paths

Both learn from the same labels — the per-rep taps the phone Rep Tagger writes to
`reps.csv` — and both produce `artifacts/LiftLoggerRepCounter.mlpackage`. They
differ in what one training example *is*.

| | `train_reps_model.py` (bout) | `train_reps_windows.py` (window) |
|---|---|---|
| one example | a whole set, resampled to `REP_BOUT_LEN` frames | an 8 s window at real 50 Hz |
| examples from 50 sets | ~50 | ~1,100 |
| time axis | normalized away — a 10 s and a 50 s set share one grid | real seconds |
| built by | `rep_events.py` | `rep_windows.py` |

The window path is the default (`auto_retrain.py` runs it, `export_reps_coreml.py`
exports it). Two reasons:

1. **Density of supervision.** The taps are per-rep, so a set can be sliced. One
   example per set left the trainer with ~5 gradient steps per epoch, BatchNorm
   estimating statistics from 8 examples, and a val metric computed over ~7 bouts
   — quantized to ~0.14 and mostly noise, so checkpoint selection was near random.
2. **Duration/tempo entanglement.** Squeezing every set onto a fixed frame grid
   makes the same movement at the same tempo look 5× faster in a 10 s set than in
   a 50 s set. Fixed-*second* windows keep tempo in real Hz.

Two things the real-time framing forces, both handled in `config.py`:

- **Receptive field.** `RF = 7 + 2*sum(dilations)`. The bout default `(1,2,4,8)`
  is 37 frames — fine when a frame is 1/256th of a set, but only **0.74 s** in
  real time, less than one rep of a slow exercise. `REP_WIN_DILATIONS` reaches
  5.2 s.
- **Head bias.** A real density averages `reps/frames` ≈ 0.01 per frame, while an
  untuned Softplus head starts at 0.69 — 70× too high. The trainer initializes the
  bias to `inverse_softplus(mean target)`. Without it the model spends its whole
  epoch budget deflating, which *looks* like convergence.

Splits are by **subject** when there are ≥ 3, else by **set** — never by window.
Two overlapping windows from one set are nearly the same signal, so a window-level
split would put a near-duplicate of every val example into train and report a
beautiful, meaningless number. Val and test metrics are always computed at set
level, by sliding the window over the whole bout and overlap-adding
(`rep_windows.bout_count`) — the same thing `RepDensityCounter` does on the watch.

Keep both paths around and compare on the same data:

```
python train_reps_model.py      # bout baseline
python train_reps_windows.py    # windowed
python evaluate_reps.py         # unsupervised autocorrelation baseline
```

If the windowed model doesn't clearly beat the other two, the bottleneck is data
quantity, not architecture — keep tagging.
