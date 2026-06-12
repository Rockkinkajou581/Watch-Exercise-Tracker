"""Load the watch CSVs, label every sample, slice into windows, and split by subject.

Input schema (produced by the iPhone app's "merged export"):
    readings.csv: subject,session,time_ms,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z
    sets.csv:     subject,session,exercise,start_ms,end_ms

time_ms in both files is the watch's time-since-boot clock, so a reading belongs
to a set iff start_ms <= time_ms <= end_ms within the same (subject, session).
"""
from __future__ import annotations
from dataclasses import dataclass

import numpy as np
import pandas as pd
from sklearn.model_selection import GroupShuffleSplit

import config


@dataclass
class Dataset:
    X: np.ndarray          # (n_windows, WINDOW, N_CHANNELS) float32
    y: np.ndarray          # (n_windows,) int64 class indices
    groups: np.ndarray     # (n_windows,) subject each window came from
    classes: list[str]     # index -> class name (sorted, includes 'rest' if present)


def load_raw() -> tuple[pd.DataFrame, pd.DataFrame]:
    readings = pd.read_csv(config.READINGS_CSV)
    sets = pd.read_csv(config.SETS_CSV)
    readings = readings.dropna(subset=config.CHANNELS + ["time_ms"])
    readings = readings.sort_values(["subject", "session", "time_ms"]).reset_index(drop=True)
    return readings, sets


def label_samples(readings: pd.DataFrame, sets: pd.DataFrame) -> pd.DataFrame:
    """Tag each reading with the exercise of the set interval it falls in, else REST."""
    readings = readings.copy()
    readings["label"] = config.REST_LABEL
    for (subj, sess), grp in sets.groupby(["subject", "session"]):
        mask = (readings["subject"] == subj) & (readings["session"] == sess)
        if not mask.any():
            continue
        t = readings.loc[mask, "time_ms"].to_numpy()
        labels = np.full(len(t), config.REST_LABEL, dtype=object)
        for _, row in grp.iterrows():
            inside = (t >= row["start_ms"]) & (t <= row["end_ms"])
            labels[inside] = row["exercise"]
        readings.loc[mask, "label"] = labels
    return readings


def make_windows(readings: pd.DataFrame) -> Dataset:
    """Sliding windows within each (subject, session), majority-labeled with a purity gate."""
    W, S = config.WINDOW, config.STRIDE
    Xs, names, groups = [], [], []
    for (subj, _sess), grp in readings.groupby(["subject", "session"]):
        arr = grp[config.CHANNELS].to_numpy(dtype=np.float32)
        lab = grp["label"].to_numpy()
        for start in range(0, len(grp) - W + 1, S):
            wl = lab[start:start + W]
            vals, counts = np.unique(wl, return_counts=True)
            j = counts.argmax()
            if counts[j] / W < config.LABEL_PURITY:
                continue                       # straddles a boundary — too mixed to trust
            top = vals[j]
            if top == config.REST_LABEL and not config.INCLUDE_REST:
                continue
            Xs.append(arr[start:start + W])
            names.append(top)
            groups.append(subj)

    if not Xs:
        raise RuntimeError(
            "No windows produced. Check that sets.csv intervals overlap readings.csv "
            "time_ms, and that you have at least WINDOW samples per session.")

    X = np.stack(Xs).astype(np.float32)
    names = np.array(names)
    classes = sorted(set(names.tolist()))
    idx = {c: i for i, c in enumerate(classes)}
    y = np.array([idx[c] for c in names], dtype=np.int64)
    return Dataset(X=X, y=y, groups=np.array(groups), classes=classes)


def make_splits(ds: Dataset):
    """Group-aware train/val/test split.

    Groups by subject when there are >=3 subjects, so no subject leaks across splits
    (this is the honest estimate of how the model generalizes to a NEW user). With
    fewer subjects there's no way to hold a subject out, so we split by window and
    warn — those accuracies will be optimistic.
    """
    n_subj = len(np.unique(ds.groups))
    if n_subj >= 3:
        groups = ds.groups
    else:
        print(f"[warn] only {n_subj} subject(s): splitting by window, so train and test "
              "share subjects. Accuracy will be optimistic vs. a brand-new user.")
        groups = np.arange(len(ds.y))

    idx = np.arange(len(ds.y))
    gss = GroupShuffleSplit(n_splits=1, test_size=config.TEST_FRACTION, random_state=config.SEED)
    trainval, test = next(gss.split(idx, ds.y, groups))

    val_rel = config.VAL_FRACTION / (1.0 - config.TEST_FRACTION)
    gss2 = GroupShuffleSplit(n_splits=1, test_size=val_rel, random_state=config.SEED)
    tr_rel, va_rel = next(gss2.split(trainval, ds.y[trainval], groups[trainval]))
    return trainval[tr_rel], trainval[va_rel], test


def compute_norm(X: np.ndarray):
    """Per-channel mean/std over (windows x time). X: (N, WINDOW, C) -> (C,), (C,)."""
    flat = X.reshape(-1, X.shape[-1])
    mean = flat.mean(axis=0).astype(np.float32)
    std = (flat.std(axis=0) + 1e-6).astype(np.float32)
    return mean, std
