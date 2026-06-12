"""Hand-crafted per-window features for the Random Forest baseline.

These are the classic Human-Activity-Recognition (HAR) features: time-domain
statistics, a little frequency-domain info, and cross-axis correlations. They give
a strong, fast, overfitting-resistant baseline that the CNN has to beat.
"""
import numpy as np

import config


def _axis_feats(x: np.ndarray) -> list[float]:
    """Features for a single channel over one window. x: (WINDOW,)."""
    feats = [
        x.mean(), x.std(), x.min(), x.max(), np.median(x),
        np.sqrt((x ** 2).mean()),                       # RMS
        np.percentile(x, 75) - np.percentile(x, 25),    # IQR
        np.mean(np.abs(np.diff(x))),                    # mean abs successive diff
        float(((x[:-1] * x[1:]) < 0).mean()),           # zero-crossing rate
    ]
    spec = np.abs(np.fft.rfft(x - x.mean()))
    if len(spec) > 1:
        k = 1 + int(spec[1:].argmax())                  # dominant bin (skip DC)
        feats += [k * config.FS / len(x), float(spec[1:].max()), float(spec.sum())]
    else:
        feats += [0.0, 0.0, 0.0]
    return feats


def window_features(win: np.ndarray) -> np.ndarray:
    """win: (WINDOW, C) -> 1-D feature vector."""
    feats: list[float] = []
    for c in range(win.shape[1]):
        feats += _axis_feats(win[:, c])
    # correlations within the accel triplet and within the gyro triplet
    for a, b in [(0, 1), (0, 2), (1, 2), (3, 4), (3, 5), (4, 5)]:
        xa, xb = win[:, a], win[:, b]
        if xa.std() > 1e-8 and xb.std() > 1e-8:
            feats.append(float(np.corrcoef(xa, xb)[0, 1]))
        else:
            feats.append(0.0)
    # signal-magnitude area for accel and gyro
    feats.append(float(np.abs(win[:, 0:3]).sum() / len(win)))
    feats.append(float(np.abs(win[:, 3:6]).sum() / len(win)))
    return np.array(feats, dtype=np.float32)


def feature_matrix(X: np.ndarray) -> np.ndarray:
    """X: (N, WINDOW, C) -> (N, n_features)."""
    return np.stack([window_features(w) for w in X])
