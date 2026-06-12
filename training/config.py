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

# ----- signal -----
FS = 50                             # Hz — MUST match motion.deviceMotionUpdateInterval on the watch
CHANNELS = ["acc_x", "acc_y", "acc_z", "gyro_x", "gyro_y", "gyro_z"]
N_CHANNELS = len(CHANNELS)

# ----- windowing -----
WINDOW_SEC = 2.0
WINDOW = int(round(WINDOW_SEC * FS))    # 100 samples @ 50 Hz
STRIDE = WINDOW // 2                     # 50% overlap between consecutive windows
LABEL_PURITY = 0.80   # a window keeps a label only if >= this fraction of its samples agree
REST_LABEL = "rest"   # everything outside a labeled set (reserved word — see the Swift recorder)
INCLUDE_REST = True   # keep 'rest' as a predictable class so the watch knows when idle

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
