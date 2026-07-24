"""Rep counting from IMU during one exercise bout — unsupervised periodicity.

The exercise classifier tells us WHICH exercise; this counts HOW MANY reps. A rep
is one cycle of a quasi-periodic movement, so we:
    1. pick the IMU channel with the strongest periodicity (autocorrelation),
    2. read its dominant repetition period T,
    3. estimate reps ≈ bout_length / T, cross-checked against a peak count.

No labeled rep data is needed to RUN this. The `reps` column in sets.csv (the
ground truth you enter on the watch) is only consumed by evaluate_reps.py to
measure and tune accuracy.

IMPORTANT: keep this logic in sync with `RepCounter` in RecorderModel.swift — the
watch runs the same algorithm live, per bout.
"""
from __future__ import annotations

import numpy as np

import config


def count_reps(window, fs: int = config.FS) -> int:
    """window: (N, C) raw IMU for one bout. Returns an estimated rep count (>= 0)."""
    w = np.asarray(window, dtype=np.float64)
    if w.ndim != 2 or w.shape[0] < fs:        # need at least ~1 s of signal
        return 0
    N, C = w.shape

    min_lag = int(config.REP_PERIOD_RANGE_S[0] * fs)
    max_lag = min(int(config.REP_PERIOD_RANGE_S[1] * fs), N // 2)
    if max_lag <= min_lag:
        return 0

    # Choose the most periodic channel and its dominant period.
    best_score, best_lag, best_ch = -1.0, 0, 0
    for c in range(C):
        x = w[:, c] - w[:, c].mean()
        energy = float(np.dot(x, x))
        if energy < 1e-8:
            continue
        score, lag = _best_autocorr(x, energy, min_lag, max_lag)
        if score > best_score:
            best_score, best_lag, best_ch = score, lag, c

    if best_lag <= 0:
        return 0

    period = best_lag
    autocorr_reps = int(round(N / period))

    x = w[:, best_ch] - w[:, best_ch].mean()
    peak_reps = _count_peaks(
        x,
        min_distance=int(round(0.6 * period)),
        prominence=config.REP_MIN_PROMINENCE_FRAC * float(x.std()),
    )

    if best_score < config.REP_PERIODICITY_MIN:
        return max(peak_reps, 0)            # weak periodicity — fall back to peaks

    # When peaks agree closely with the period estimate, prefer them (they handle
    # partial first/last reps a little better); otherwise trust the period.
    if peak_reps > 0 and abs(peak_reps - autocorr_reps) <= 1:
        return peak_reps
    return max(autocorr_reps, 0)


def _best_autocorr(x, energy: float, min_lag: int, max_lag: int):
    """Return (max normalized autocorrelation, its lag) over [min_lag, max_lag]."""
    best_score, best_lag = -1.0, 0
    for lag in range(min_lag, max_lag + 1):
        ac = float(np.dot(x[:-lag], x[lag:])) / energy
        if ac > best_score:
            best_score, best_lag = ac, lag
    return best_score, best_lag


def _count_peaks(x, min_distance: int, prominence: float) -> int:
    """Local maxima above `prominence`, spaced at least `min_distance` apart."""
    min_distance = max(min_distance, 1)
    count = 0
    last = -min_distance
    for i in range(1, len(x) - 1):
        if x[i] > x[i - 1] and x[i] >= x[i + 1] and x[i] >= prominence:
            if i - last >= min_distance:
                count += 1
                last = i
    return count
