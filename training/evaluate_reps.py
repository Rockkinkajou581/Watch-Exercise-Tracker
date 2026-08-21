"""Measure rep-counting accuracy against the rep counts you logged on the watch.

For every labeled set in sets.csv that has a ground-truth `reps` value, replay
count_reps() over the readings inside that set's interval and compare predicted
vs. true. Prints overall accuracy (exact, within ±1, MAE) and a per-exercise
breakdown so you can see where counting is reliable and where it needs tuning —
the rep-counting equivalent of train.py's metrics.txt.

Also fits a per-exercise linear calibration (true ~= a*pred + b) on top of the raw
counter — a cheap bias/scale fix that needs no retraining, just the same (true,
pred) pairs this script already collects. Saved to artifacts/rep_calibration.json;
exercises with fewer than config.REP_CALIBRATION_MIN_N sets are left uncalibrated
(a=1, b=0) since a line fit through a handful of points is noise, not signal.

Run from inside the training/ folder (after collecting sets with reps):
    python evaluate_reps.py
"""
from __future__ import annotations

import json

import numpy as np
import pandas as pd

import config
from data import load_raw
from reps import count_reps


def fit_calibration(df: pd.DataFrame) -> dict[str, dict]:
    """Per-exercise least-squares (a, b) so true ~= a*pred + b. Skips exercises with
    too few sets (config.REP_CALIBRATION_MIN_N) or with no spread in `pred` (a
    least-squares line through a single x-value is undefined)."""
    calib: dict[str, dict] = {}
    for ex, g in df.groupby("exercise"):
        n = len(g)
        if n < config.REP_CALIBRATION_MIN_N or g["pred"].nunique() < 2:
            calib[ex] = {"a": 1.0, "b": 0.0, "n": n, "fit": False}
            continue
        a, b = np.polyfit(g["pred"].to_numpy(dtype=float), g["true"].to_numpy(dtype=float), 1)
        calib[ex] = {"a": float(a), "b": float(b), "n": n, "fit": True}
    return calib


def apply_calibration(df: pd.DataFrame, calib: dict[str, dict]) -> np.ndarray:
    a = df["exercise"].map(lambda ex: calib.get(ex, {"a": 1.0})["a"]).to_numpy(dtype=float)
    b = df["exercise"].map(lambda ex: calib.get(ex, {"b": 0.0})["b"]).to_numpy(dtype=float)
    return np.maximum(0, np.rint(a * df["pred"].to_numpy(dtype=float) + b)).astype(int)


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

    calib = fit_calibration(df)
    df["calibrated"] = apply_calibration(df, calib)
    df["cal_err"] = (df["calibrated"] - df["true"]).abs()
    n_fit = sum(c["fit"] for c in calib.values())
    print(f"\ncalibration: fit for {n_fit}/{len(calib)} exercise(s) "
          f"(need >= {config.REP_CALIBRATION_MIN_N} sets each)")
    print(f"  raw        exact {(df.abs_err == 0).mean():6.1%}  within1 "
          f"{(df.abs_err <= 1).mean():6.1%}  MAE {df.abs_err.mean():.2f}")
    print(f"  calibrated exact {(df.cal_err == 0).mean():6.1%}  within1 "
          f"{(df.cal_err <= 1).mean():6.1%}  MAE {df.cal_err.mean():.2f}")
    for ex, c in sorted(calib.items()):
        tag = f"a={c['a']:.2f} b={c['b']:+.2f}" if c["fit"] else "not enough data"
        print(f"  {ex:24s} n={c['n']:3d}  {tag}")

    out = config.ARTIFACTS / "rep_calibration.json"
    config.ARTIFACTS.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(calib, indent=2, sort_keys=True))
    print(f"\nsaved -> {out}")


if __name__ == "__main__":
    main()
