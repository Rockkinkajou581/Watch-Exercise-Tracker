"""Turn per-rep tap timestamps (reps.csv) into density-labeled training bouts.

The phone "rep tagger" writes one row per rep — a timestamp already mapped onto
the watch IMU clock (see SessionStore.recordTap). Here we:
    1. attach each rep to the set interval (in sets.csv) that contains it,
    2. slice that set's raw IMU and resample it to a fixed length REP_BOUT_LEN,
    3. build a 1-D target signal that is a sum of unit-area Gaussians, one centered
       on each rep — so the model learns to emit a bump per rep and the integral
       of the predicted density is the rep count.

This is the supervised counterpart to reps.py (the unsupervised counter). It
needs reps.csv; without it the set carries only the single manual `reps` integer,
which is enough for evaluate_reps.py but not for training a density model.

Schemas:
    reps.csv: subject,session,rep_time_ms,set_start_ms,tap_unix_ms
    sets.csv: subject,session,exercise,start_ms,end_ms,reps
"""
from __future__ import annotations
from dataclasses import dataclass

import numpy as np
import pandas as pd

import config
from data import load_raw


@dataclass
class RepDataset:
    X: np.ndarray          # (n_bouts, REP_BOUT_LEN, N_CHANNELS) float32 — resampled IMU
    Y: np.ndarray          # (n_bouts, REP_BOUT_LEN) float32 — rep-density target (sum ≈ count)
    counts: np.ndarray     # (n_bouts,) int — tagged reps per bout (the ground-truth count)
    groups: np.ndarray     # (n_bouts,) subject each bout came from (for grouped splits)
    exercises: np.ndarray  # (n_bouts,) exercise name per bout


def load_rep_events() -> pd.DataFrame:
    reps = pd.read_csv(config.REPS_CSV)
    reps = reps.dropna(subset=["subject", "session", "rep_time_ms"])
    return reps.sort_values(["subject", "session", "rep_time_ms"]).reset_index(drop=True)


def _resample(seg: np.ndarray, times: np.ndarray, length: int) -> np.ndarray:
    """Linear-resample (T, C) sampled at `times` onto `length` evenly spaced points."""
    span = times[-1] - times[0]
    norm = (times - times[0]) / span            # 0..1, faithful to real timing/gaps
    grid = np.linspace(0.0, 1.0, length)
    out = np.empty((length, seg.shape[1]), dtype=np.float32)
    for c in range(seg.shape[1]):
        out[:, c] = np.interp(grid, norm, seg[:, c])
    return out


def _density(rep_idx: np.ndarray, length: int, sigma: float) -> np.ndarray:
    """Sum of unit-area Gaussians centered at `rep_idx` (fractional frames)."""
    grid = np.arange(length, dtype=np.float32)
    y = np.zeros(length, dtype=np.float32)
    for r in rep_idx:
        g = np.exp(-0.5 * ((grid - r) / sigma) ** 2)
        s = g.sum()
        if s > 0:
            y += g / s                           # unit area -> total area == rep count
    return y


def build_rep_dataset() -> RepDataset:
    readings, sets = load_raw()
    reps = load_rep_events()

    # Sets the user marked bad on the watch. Keep them aside so we can drop any
    # real set (and its taps) that overlaps one — mirrors how make_windows drops
    # discarded windows for the classifier.
    discards = sets[sets["exercise"] == config.DISCARD_LABEL]
    sets = sets[sets["exercise"] != config.DISCARD_LABEL].copy()
    L, sigma = config.REP_BOUT_LEN, config.REP_DENSITY_SIGMA

    Xs, Ys, counts, groups, exes = [], [], [], [], []
    for s in sets.itertuples(index=False):
        # Drop this set entirely if it was discarded (its interval overlaps a
        # discard row in the same session) — its reps were tagged but are bad.
        dmask = ((discards["subject"] == s.subject) &
                 (discards["session"] == s.session) &
                 (discards["start_ms"] <= s.end_ms) &
                 (discards["end_ms"] >= s.start_ms))
        if dmask.any():
            continue

        rmask = ((readings["subject"] == s.subject) &
                 (readings["session"] == s.session) &
                 (readings["time_ms"] >= s.start_ms) &
                 (readings["time_ms"] <= s.end_ms))
        seg_rows = readings.loc[rmask].sort_values("time_ms")
        if len(seg_rows) < config.FS:            # under ~1 s of IMU — unusable
            continue
        times = seg_rows["time_ms"].to_numpy(dtype=np.float64)
        if times[-1] <= times[0]:
            continue
        seg = seg_rows[config.CHANNELS].to_numpy(dtype=np.float32)

        # Reps tagged inside this set's interval (same subject+session).
        ev = reps[(reps["subject"] == s.subject) &
                  (reps["session"] == s.session) &
                  (reps["rep_time_ms"] >= s.start_ms) &
                  (reps["rep_time_ms"] <= s.end_ms)]
        rep_times = ev["rep_time_ms"].to_numpy(dtype=np.float64)
        if len(rep_times) < config.REP_MIN_TAGGED:
            continue

        rep_idx = (rep_times - times[0]) / (times[-1] - times[0]) * (L - 1)
        rep_idx = np.clip(rep_idx, 0, L - 1)

        Xs.append(_resample(seg, times, L))
        Ys.append(_density(rep_idx, L, sigma))
        counts.append(len(rep_times))
        groups.append(s.subject)
        exes.append(s.exercise)

    if not Xs:
        raise RuntimeError(
            "No tagged bouts. Need reps.csv with rep_time_ms inside set intervals — "
            "record a session with the phone rep tagger open, then re-export.")

    return RepDataset(
        X=np.stack(Xs).astype(np.float32),
        Y=np.stack(Ys).astype(np.float32),
        counts=np.array(counts, dtype=np.int64),
        groups=np.array(groups),
        exercises=np.array(exes),
    )


if __name__ == "__main__":
    ds = build_rep_dataset()
    print(f"bouts: {len(ds.counts)}   subjects: {len(np.unique(ds.groups))}")
    print(f"reps per bout: min {ds.counts.min()}  max {ds.counts.max()}  "
          f"mean {ds.counts.mean():.1f}")
    # Sanity: each target's area should match its tagged rep count closely.
    area = ds.Y.sum(axis=1)
    print(f"density area vs. count — max abs err {np.abs(area - ds.counts).max():.3f}")
