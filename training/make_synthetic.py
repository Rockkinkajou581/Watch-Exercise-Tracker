"""Generate synthetic readings.csv + sets.csv in the exact watch schema.

This lets you exercise the ENTIRE pipeline (windowing, training, CoreML export)
today, before any real data exists. The signals are fake — each exercise is a
distinct sine pattern — so a model trivially learns them. Do NOT mistake the high
accuracy here for real performance; it only proves the plumbing works.

Run from inside the training/ folder:  python make_synthetic.py
"""
import numpy as np
import pandas as pd

import config

EXERCISES = ["bicep_curl", "hammer_curl", "shoulder_press", "lateral_raise",
             "tricep_pushdown", "bent_over_row", "chest_press"]
PERIOD = {"bicep_curl": 1.2, "hammer_curl": 1.3, "shoulder_press": 1.6,
          "lateral_raise": 1.5, "tricep_pushdown": 1.0, "bent_over_row": 1.4,
          "chest_press": 1.7}


def synth_set(exercise: str, t0: float, n_reps: int = 10):
    """Return (signal (n,6), times_ms (n,), duration_s) for one fake set."""
    fs = config.FS
    period = PERIOD[exercise]
    n = int(period * n_reps * fs)
    t = np.arange(n) / fs
    f = 1.0 / period
    rng = np.random.default_rng(abs(hash(exercise)) % 2**32)
    phase = rng.uniform(0, 2 * np.pi, size=6)
    amp = rng.uniform(0.5, 1.5, size=6)
    bias = rng.normal(0, 0.3, size=6)
    sig = bias + amp * np.sin(2 * np.pi * f * t[:, None] + phase) \
        + 0.05 * rng.standard_normal((n, 6))
    sig[:, 2] += 1.0                                 # gravity offset on acc_z
    return sig.astype(np.float32), (t0 + t) * 1000.0, n / fs


def main():
    config.DATA_DIR.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(config.SEED)
    rcols = ["subject", "session", "time_ms", *config.CHANNELS]
    readings, sets = [], []

    for subj in ["S01", "S02", "S03", "S04"]:        # 4 subjects -> grouped split works
        for s in range(2):
            session = f"2026010{s + 1}-1200{s:02d}"
            t = 5.0
            for ex in EXERCISES:
                # rest gap before the set
                nrest = int(3.0 * config.FS)
                trest = t + np.arange(nrest) / config.FS
                rsig = 0.05 * rng.standard_normal((nrest, 6)); rsig[:, 2] += 1.0
                for i in range(nrest):
                    readings.append([subj, session, trest[i] * 1000, *rsig[i]])
                t += 3.0

                n_reps = int(rng.integers(8, 13))     # vary 8–12 so rep eval is real
                sig, times, dur = synth_set(ex, t, n_reps=n_reps)
                for i in range(len(sig)):
                    readings.append([subj, session, times[i], *sig[i]])
                sets.append([subj, session, ex, times[0], times[-1], n_reps])
                t += dur

    pd.DataFrame(readings, columns=rcols).to_csv(config.READINGS_CSV, index=False)
    pd.DataFrame(sets,
                 columns=["subject", "session", "exercise", "start_ms", "end_ms", "reps"]
                 ).to_csv(config.SETS_CSV, index=False)
    print(f"wrote {config.READINGS_CSV}  ({len(readings)} rows)")
    print(f"wrote {config.SETS_CSV}  ({len(sets)} rows)")


if __name__ == "__main__":
    main()
