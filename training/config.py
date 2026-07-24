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

# ----- set-boundary trim -----
# Shrink each labeled set interval before labeling, so button-press slop isn't
# learned as the exercise:
#   * front  = 0.0 because the watch now runs a 3-2-1 countdown before opening the
#     set window, so you're already in position when start_ms is stamped.
#   * end    > 0 trims the wind-down between finishing the movement and tapping
#     "End Set".
# Set either to 0.0 to disable that side.
TRIM_START_SEC = 0.0
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
