"""Central configuration for the LiftLogger training pipeline.

Everything tunable lives here so the data, model, and export scripts stay in sync
with each other and with the watch recorder (RecorderModel.swift).
"""
from pathlib import Path

# ----- paths -----
ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"            # put readings.csv + sets.csv here (from the iPhone export)
ARTIFACTS = ROOT / "artifacts"      # checkpoints, metrics, exported CoreML model
READINGS_CSV = DATA_DIR / "readings.csv"
SETS_CSV = DATA_DIR / "sets.csv"
REPS_CSV = DATA_DIR / "reps.csv"    # per-rep tap timestamps from the phone rep tagger

# Extra exported data to merge in at load time, on top of DATA_DIR — e.g. an old
# merged export you still have sitting around from before an app reinstall wiped
# the session folders it came from, so "Build merged export" can't regenerate it
# anymore. Each entry is a directory that has its own readings.csv / sets.csv /
# reps.csv (any subset — missing files are just skipped). See data.load_raw() and
# rep_events.load_rep_events(), the two chokepoints every training/eval script
# loads through, for how these get merged in safely.
EXTRA_DATA_DIRS: list[Path] = [
    # ROOT / "data_old",
]

# ----- signal -----
FS = 50                             # Hz — MUST match motion.deviceMotionUpdateInterval on the watch
CHANNELS = ["acc_x", "acc_y", "acc_z", "gyro_x", "gyro_y", "gyro_z"]
N_CHANNELS = len(CHANNELS)

# ----- windowing -----
WINDOW_SEC = 2.0
WINDOW = int(round(WINDOW_SEC * FS))    # 100 samples @ 50 Hz
STRIDE = WINDOW // 2                     # 50% overlap between consecutive windows
LABEL_PURITY = 0.80     # a window keeps a label only if >= this fraction of its samples agree
REST_LABEL = "rest"     # everything outside a labeled set (reserved word — see the Swift recorder)
INCLUDE_REST = True     # keep 'rest' as a predictable class so the watch knows when idle
DISCARD_LABEL = "discard"  # a set the user marked bad on the watch; windows touching it are dropped

# ----- exercise roster -----
# The exercises the watch still offers (RecorderModel.exercises). Older sessions
# in sets.csv may contain exercises you have since retired; anything not listed
# here is handled by RETIRED_POLICY below. Leave the list EMPTY to train on
# whatever happens to be in the data.
# Keep in sync with `exercises` in RecorderModel.swift.
KEEP_EXERCISES = [
    "incline_chest_press", "machine_shoulder_press", "machine_row_wide",
    "cable_push_down", "overhead_triceps", "dumbbell_hammer_curl",
    "forearm_raises", "lat_pulldown", "machine_chest_press", "cable_curl",
    "squat", "dumbbell_rdl", "machine_calf_raise",
    "dumbbell_bulgarian_split_squat", "dumbbell_curl",
]

# What to do with a set whose exercise isn't in KEEP_EXERCISES:
#   "drop" — treat it like a discarded set: every window touching it is thrown
#       away. The default, because retired exercises are usually MECHANICALLY
#       SIMILAR to ones you kept (flat vs. incline chest press, cable/machine curl
#       vs. hammer curl, forearm curl vs. forearm raises). Calling those windows
#       "rest" would label near-identical signal both ways and actively damage the
#       class you kept.
#   "rest" — fold them into the idle class, teaching the model "arm moving, but
#       not one of my exercises → don't log a set". Only worth it for retired
#       exercises that look nothing like a kept one.
RETIRED_POLICY = "drop"

# ----- set-boundary trim -----
# Shrink each labeled set interval before labeling, so button-press slop isn't
# learned as the exercise:
#   * front  > 0 absorbs the last moment of getting set after the watch's 3-2-1
#     countdown stamps start_ms, so settling motion isn't learned as the exercise.
#   * end    > 0 trims the wind-down between finishing the movement and tapping
#     "End Set".
# Set either to 0.0 to disable that side.
TRIM_START_SEC = 0.5
TRIM_END_SEC = 1.0

# ----- rep counting -----
# Reps are counted by finding the dominant repetition PERIOD in the most periodic
# IMU channel of an exercise bout, then dividing the bout length by it (cross-checked
# against peak counts). Unsupervised — the `reps` column in sets.csv (entered on the
# watch) is only used by evaluate_reps.py to measure accuracy. Keep these in sync
# with RepCounter in RecorderModel.swift.
REP_PERIOD_RANGE_S = (0.5, 4.0)    # plausible seconds-per-rep (≈0.25–2 reps/sec)
REP_PERIODICITY_MIN = 0.25         # min normalized autocorrelation to trust a period
REP_MIN_PROMINENCE_FRAC = 0.30     # a peak must rise this × signal-std to be a rep

# ----- supervised rep counting (per-rep tap labels) -----
# Ground-truth per-rep timestamps come from the phone "rep tagger" (an observer
# taps once per rep, aligned to the watch IMU clock) and land in reps.csv. They
# train a density-regression model (train_reps_model.py) that learns to emit one
# bump per rep — more accurate than the unsupervised counter, especially on
# wrist-quiet exercises. Each set's IMU is resampled to a fixed length so bouts
# of any duration batch together; the per-rep Gaussians have unit area, so the
# predicted density integrates back to a rep count.
REP_BOUT_LEN = 256                 # frames each set's IMU is resampled to for the model
REP_DENSITY_SIGMA = 4.0            # Gaussian label half-width, in resampled frames, per rep
REP_MIN_TAGGED = 1                 # ignore sets with fewer tagged reps than this

# A training example here is a whole SET, not a 2 s sliding window, so this dataset
# is ~50 bouts where the classifier has ~2500 windows. The shared BATCH_SIZE/EPOCHS
# below are sized for windows: reused here they give ~1 gradient step per epoch and
# the model never leaves its initialization. These are the bout-scale equivalents.
REP_BATCH_SIZE = 8
REP_EPOCHS = 400
REP_EARLY_STOP_PATIENCE = 40

# ----- supervised rep counting, WINDOWED (preferred: rep_windows.py) -----
# The bout framing above has two problems that windows fix:
#   1. one training example per SET, so ~50 examples where the classifier has
#      thousands. Per-rep taps are dense labels — slicing a set into overlapping
#      windows turns each set into dozens of examples with no new data collected.
#   2. resampling every set to REP_BOUT_LEN frames entangles set DURATION with
#      rep frequency: the same movement at the same tempo looks 5x faster in a
#      10 s set than in a 50 s set. Windows are a fixed number of SECONDS, so
#      tempo stays in real Hz and that nuisance variable disappears.
# The window must span at least two rep periods or the task isn't learnable —
# REP_PERIOD_RANGE_S tops out at 4 s/rep, hence 8 s.
REP_WINDOW_SEC = 8.0
REP_WINDOW = int(round(REP_WINDOW_SEC * FS))          # 400 samples @ 50 Hz
REP_WIN_STRIDE_SEC = 1.0
REP_WIN_STRIDE = int(round(REP_WIN_STRIDE_SEC * FS))  # 50 -> ~23 windows per 30 s set
# Gaussian label half-width in SECONDS (the bout path's REP_DENSITY_SIGMA is in
# resampled frames, which is exactly the units problem windows exist to avoid).
REP_DENSITY_SIGMA_SEC = 0.20                          # 10 frames @ 50 Hz

# Window-scale training hyperparameters. There are ~50x more examples here than
# in the bout path, so these look like the classifier's, not REP_* above.
# A frame is now a real 1/FS second, so the density net needs a receptive field
# that spans a rep. RF = 7 + 2*sum(dilations): the bout path's (1,2,4,8) gives 37
# frames = 0.74 s, less than one rep of a slow exercise; this reaches 261 frames
# = 5.2 s, enough context to see periodicity without exceeding the 8 s window.
REP_WIN_DILATIONS = (1, 2, 4, 8, 16, 32, 64)

REP_WIN_BATCH_SIZE = 64
REP_WIN_EPOCHS = 120
REP_WIN_EARLY_STOP_PATIENCE = 15

# ----- supervised rep counting, PERIOD (no taps: train_reps_period.py) -----
# Both models above need reps.csv (per-rep taps from the phone tagger) — dense
# supervision that requires someone tapping live during the set. This one trains
# on nothing but the final `reps` integer already in sets.csv: every hand-dialed
# manual set, plus any auto-detected set corrected via the phone's "Fix reps"
# sheet (SessionStore.confirmReps, folded in by buildMergedExport). The trick that
# makes a single scalar per set enough supervision: predict the bout's dominant
# rep PERIOD instead of its count. Period is duration-independent and lives in a
# narrow physical range (REP_PERIOD_RANGE_S above), so it's a far more
# sample-efficient regression target than raw count, which entangles tempo with
# however long the set happened to run. Trained in log-seconds (periods are
# ratio-scale); count at inference/eval is duration_s / exp(prediction).
REP_PERIOD_BOUT_SEC = 12.0            # seconds of IMU fed to the model per bout
REP_PERIOD_BOUT_LEN = int(round(REP_PERIOD_BOUT_SEC * FS))
REP_PERIOD_MIN_REPS = 2               # ignore sets with fewer true reps than this

# ----- rep-count calibration (evaluate_reps.py) -----
# A cheap alternative/complement to training a new model: fit a per-exercise
# linear correction (true ~= a*pred + b) on top of whichever counter you're
# already running, using the same (true, pred) pairs evaluate_reps.py collects.
# Fixes a systematic bias (e.g. "always +1 on squats") with a handful of examples
# and no training run.
REP_CALIBRATION_MIN_N = 5             # need at least this many sets to fit a line

# ----- training -----
SEED = 1337
BATCH_SIZE = 64
EPOCHS = 80
LR = 1e-3
WEIGHT_DECAY = 1e-4
VAL_FRACTION = 0.15
TEST_FRACTION = 0.15
EARLY_STOP_PATIENCE = 12
DROPOUT = 0.3
