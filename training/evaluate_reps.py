"""Measure rep-counting accuracy against the rep counts you logged on the watch.

For every labeled set in sets.csv that has a ground-truth `reps` value, replay
count_reps() over the readings inside that set's interval and compare predicted
vs. true. Prints overall accuracy (exact, within ±1, MAE) and a per-exercise
breakdown so you can see where counting is reliable and where it needs tuning —
the rep-counting equivalent of train.py's metrics.txt.

Run from inside the training/ folder (after collecting sets with reps):
    python evaluate_reps.py
"""
from __future__ import annotations

import numpy as np
import pandas as pd

import config
from data import load_raw
from reps import count_reps


def main():
    readings, sets = load_raw()

    if "reps" not in sets.columns:
        print("No `reps` column in sets.csv yet — record rep counts on the watch "
              "(End Set → set the count) and re-export.")
        return

    sets = sets[sets["exercise"] != config.DISCARD_LABEL].copy()
    sets["reps"] = pd.to_numeric(sets["reps"], errors="coerce")
    sets = sets.dropna(subset=["reps"])
    sets = sets[sets["reps"] > 0]
    if sets.empty:
        print("No sets with a ground-truth rep count yet.")
        return

    rows = []
    for r in sets.itertuples(index=False):
        mask = ((readings["subject"] == r.subject) &
                (readings["session"] == r.session) &
                (readings["time_ms"] >= r.start_ms) &
                (readings["time_ms"] <= r.end_ms))
        seg = readings.loc[mask, config.CHANNELS].to_numpy(dtype=np.float32)
        if len(seg) < config.FS:                 # under a second of data — skip
            continue
        pred = count_reps(seg, fs=config.FS)
        rows.append((r.exercise, int(round(r.reps)), pred, abs(pred - int(round(r.reps)))))

    if not rows:
        print("No evaluable sets (each needs ≥1 s of readings inside its interval).")
        return

    df = pd.DataFrame(rows, columns=["exercise", "true", "pred", "abs_err"])
    print(f"sets evaluated: {len(df)}")
    print(f"exact:    {(df.abs_err == 0).mean():6.1%}")
    print(f"within 1: {(df.abs_err <= 1).mean():6.1%}")
    print(f"MAE:      {df.abs_err.mean():.2f} reps\n")

    print("per-exercise (worst first):")
    g = df.groupby("exercise").agg(
        n=("true", "size"),
        mae=("abs_err", "mean"),
        within1=("abs_err", lambda s: (s <= 1).mean()),
    ).sort_values("mae", ascending=False)
    for ex, row in g.iterrows():
        print(f"  {ex:24s} n={int(row.n):3d}  MAE={row.mae:.2f}  ±1={row.within1:6.1%}")

    print("\nworst misses:")
    for r in df.sort_values("abs_err", ascending=False).head(8).itertuples(index=False):
        print(f"  {r.exercise:24s} true={r.true:3d}  pred={r.pred:3d}  |err|={r.abs_err}")


if __name__ == "__main__":
    main()
