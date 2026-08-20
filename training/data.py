"""Load the watch CSVs, label every sample, slice into windows, and split by subject.

Input schema (produced by the iPhone app's "merged export"):
    readings.csv: subject,session,time_ms,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z
    sets.csv:     subject,session,exercise,start_ms,end_ms

time_ms in both files is the watch's time-since-boot clock, so a reading belongs
to a set iff start_ms <= time_ms <= end_ms within the same (subject, session).
The labeled interval is shrunk by config.TRIM_SEC on each end (see label_samples)
so button-press setup/wind-down motion is treated as REST, not the exercise.
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


def apply_exercise_roster(sets: pd.DataFrame) -> pd.DataFrame:
    """Rewrite sets recorded for exercises the watch no longer offers.

    Retiring an exercise on the watch only changes what you can record NEXT — every
    old session still carries it, so without this the classifier keeps a head slot
    for a class the watch can never produce, and that dead class still competes for
    probability against the ones you kept (it also drags the live confidence
    threshold around in auto-detect).

    Retired sets are rewritten to DISCARD_LABEL or REST_LABEL per
    config.RETIRED_POLICY; both are already understood by every downstream consumer,
    so nothing else needs to know a roster exists. The raw CSVs are untouched —
    put a name back in KEEP_EXERCISES and its data comes back.
    """
    if not config.KEEP_EXERCISES:
        return sets
    keep = set(config.KEEP_EXERCISES) | {config.REST_LABEL, config.DISCARD_LABEL}
    retired = ~sets["exercise"].isin(keep)
    if not retired.any():
        return sets

    names = sorted(sets.loc[retired, "exercise"].unique())
    replacement = (config.DISCARD_LABEL if config.RETIRED_POLICY == "drop"
                   else config.REST_LABEL)
    sets = sets.copy()
    sets.loc[retired, "exercise"] = replacement
    print(f"[roster] {int(retired.sum())} set(s) of {len(names)} retired exercise(s) "
          f"-> '{replacement}': {', '.join(names)}")
    return sets


def load_raw() -> tuple[pd.DataFrame, pd.DataFrame]:
    readings = pd.read_csv(config.READINGS_CSV)
    sets = pd.read_csv(config.SETS_CSV)
    readings = readings.dropna(subset=config.CHANNELS + ["time_ms"])
    readings = readings.sort_values(["subject", "session", "time_ms"]).reset_index(drop=True)
    # One chokepoint: the classifier, both rep paths and evaluate_reps all load
    # through here, so they can't disagree about which exercises exist.
    return readings, apply_exercise_roster(sets)


def label_samples(readings: pd.DataFrame, sets: pd.DataFrame) -> pd.DataFrame:
    """Tag each reading with the exercise of the set interval it falls in, else REST.

    Sets whose exercise == DISCARD_LABEL (marked bad on the watch) are applied last
    and override any other label, so make_windows can drop windows that touch them.
    """
    readings = readings.copy()
    readings["label"] = config.REST_LABEL
    start_ms = config.TRIM_START_SEC * 1000.0
    end_ms = config.TRIM_END_SEC * 1000.0
    for (subj, sess), grp in sets.groupby(["subject", "session"]):
        mask = (readings["subject"] == subj) & (readings["session"] == sess)
        if not mask.any():
            continue
        t = readings.loc[mask, "time_ms"].to_numpy()
        labels = np.full(len(t), config.REST_LABEL, dtype=object)
        # Real exercises first; discarded sets second so they win on any overlap.
        ordered = sorted(
            grp.itertuples(index=False),
            key=lambda r: r.exercise == config.DISCARD_LABEL,
        )
        for row in ordered:
            start, end = row.start_ms, row.end_ms
            if row.exercise == config.DISCARD_LABEL:
                # Discard the exact interval — no trim (we want all of the bad motion).
                inside = (t >= start) & (t <= end)
            else:
                # Trim setup (front) / wind-down (end) so transition motion stays REST.
                # Skip trimming if the set is too short to survive it (keep the full set).
                if end - start > start_ms + end_ms:
                    start, end = start + start_ms, end - end_ms
                inside = (t >= start) & (t <= end)
            labels[inside] = row.exercise
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
            if (wl == config.DISCARD_LABEL).any():
                continue                       # touches a set the user marked bad
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
