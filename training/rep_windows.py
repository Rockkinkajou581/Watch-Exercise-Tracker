"""Windowed rep-density training data — the same per-rep taps, ~50x the examples.

rep_events.py turns each set into ONE example: the whole bout resampled to
REP_BOUT_LEN frames. That wastes the supervision you actually collected (the taps
are per-rep, not per-set) and it entangles set duration with rep frequency, since
a 10 s set and a 50 s set are squeezed onto the same 256-frame grid.

Here a set is instead:
    1. resampled onto a uniform FS-Hz grid, so time stays in real seconds,
    2. given a per-sample rep-density curve (unit-area Gaussian per tap, sigma in
       seconds), and
    3. sliced into overlapping REP_WINDOW-sample windows at REP_WIN_STRIDE.

Each window's target is its slice of that curve; its rep count is the slice's
integral — a FRACTION when a rep straddles the window edge, which is fine and is
what makes the labels dense. A 30 s set yields ~23 windows instead of 1.

Set-level counts come back via `bout_count`, which slides the same windows over a
whole bout and overlap-adds the predictions — this MUST stay in sync with
RepDensityCounter in RecorderModel.swift, which does exactly the same thing live.

Schemas are the same as rep_events.py:
    reps.csv: subject,session,rep_time_ms,set_start_ms,tap_unix_ms
    sets.csv: subject,session,exercise,start_ms,end_ms,reps
"""
from __future__ import annotations
from dataclasses import dataclass

import numpy as np

import config
from data import load_raw
from rep_events import load_rep_events


@dataclass
class Bout:
    """One set on a uniform FS-Hz grid, with its rep-density curve."""
    X: np.ndarray          # (T, N_CHANNELS) float32 — IMU at real FS
    Y: np.ndarray          # (T,) float32 — rep density, integrates to `count`
    count: int             # tagged reps in this set
    subject: str
    session: str
    exercise: str


@dataclass
class RepWindowDataset:
    X: np.ndarray          # (n_win, REP_WINDOW, N_CHANNELS) float32
    Y: np.ndarray          # (n_win, REP_WINDOW) float32 — density slice
    counts: np.ndarray     # (n_win,) float32 — fractional reps inside the window
    groups: np.ndarray     # (n_win,) subject, for subject-held-out splits
    bout_ids: np.ndarray   # (n_win,) index into `bouts`; NEVER split on the window axis
    bouts: list[Bout]      # the sets these windows came from, for set-level scoring


def _uniform_resample(seg: np.ndarray, times_ms: np.ndarray, fs: int) -> np.ndarray:
    """Resample (T, C) sampled at `times_ms` onto an even fs-Hz grid, keeping real time.

    Unlike rep_events._resample this does NOT normalize duration away: the output
    length is proportional to how long the set actually lasted.
    """
    dur_s = (times_ms[-1] - times_ms[0]) / 1000.0
    n = max(2, int(round(dur_s * fs)) + 1)
    grid = np.linspace(times_ms[0], times_ms[-1], n)
    out = np.empty((n, seg.shape[1]), dtype=np.float32)
    for c in range(seg.shape[1]):
        out[:, c] = np.interp(grid, times_ms, seg[:, c])
    return out


def _density(rep_idx: np.ndarray, length: int, sigma: float) -> np.ndarray:
    """Sum of unit-area Gaussians at `rep_idx` (fractional frames), same as rep_events.

    Each bump is normalized over the grid it lands on, so a rep near the start or
    end of a bout still contributes exactly 1.0 to the total instead of leaking
    mass off the edge.
    """
    grid = np.arange(length, dtype=np.float32)
    y = np.zeros(length, dtype=np.float32)
    for r in rep_idx:
        g = np.exp(-0.5 * ((grid - r) / sigma) ** 2)
        s = g.sum()
        if s > 0:
            y += g / s
    return y


def window_starts(n_frames: int, width: int, stride: int) -> list[int]:
    """Window offsets covering [0, n_frames), always including a flush-right window.

    Bouts shorter than one window get a single window at 0 (the caller pads it).
    """
    if n_frames <= width:
        return [0]
    starts = list(range(0, n_frames - width + 1, stride))
    if starts[-1] != n_frames - width:
        starts.append(n_frames - width)      # don't drop the tail of the set
    return starts


def pad_to_window(x: np.ndarray, width: int) -> np.ndarray:
    """Edge-pad (T, C) up to `width` rows.

    Edge padding, not zeros: acc_* includes gravity, so a zero row is physically
    impossible (a still watch reads ~1 g) while a repeated last row reads exactly
    like the arm being held motionless — which is honestly "no reps here".
    """
    if len(x) >= width:
        return x[:width]
    pad = np.repeat(x[-1:], width - len(x), axis=0)
    return np.concatenate([x, pad], axis=0)


def build_bouts() -> list[Bout]:
    """Every tagged, non-discarded set as a real-time bout with a density curve."""
    readings, sets = load_raw()
    reps = load_rep_events()

    discards = sets[sets["exercise"] == config.DISCARD_LABEL]
    sets = sets[sets["exercise"] != config.DISCARD_LABEL].copy()
    sigma = config.REP_DENSITY_SIGMA_SEC * config.FS

    bouts: list[Bout] = []
    for s in sets.itertuples(index=False):
        # Drop sets the user marked bad on the watch (mirrors rep_events).
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

        ev = reps[(reps["subject"] == s.subject) &
                  (reps["session"] == s.session) &
                  (reps["rep_time_ms"] >= s.start_ms) &
                  (reps["rep_time_ms"] <= s.end_ms)]
        rep_times = ev["rep_time_ms"].to_numpy(dtype=np.float64)
        if len(rep_times) < config.REP_MIN_TAGGED:
            continue

        X = _uniform_resample(seg, times, config.FS)
        # Taps land on the uniform grid by elapsed seconds, not by fraction of the
        # set — that difference is the whole point of the real-time framing.
        rep_idx = (rep_times - times[0]) / 1000.0 * config.FS
        rep_idx = np.clip(rep_idx, 0, len(X) - 1)
        bouts.append(Bout(X=X, Y=_density(rep_idx, len(X), sigma),
                          count=len(rep_times), subject=s.subject,
                          session=s.session, exercise=s.exercise))

    if not bouts:
        raise RuntimeError(
            "No tagged bouts. Need reps.csv with rep_time_ms inside set intervals — "
            "record a session with the phone rep tagger open, then re-export.")
    return bouts


def build_rep_windows(bouts: list[Bout] | None = None) -> RepWindowDataset:
    """Slice every bout into overlapping fixed-SECOND windows with density targets."""
    bouts = bouts if bouts is not None else build_bouts()
    W, S = config.REP_WINDOW, config.REP_WIN_STRIDE

    Xs, Ys, counts, groups, bids = [], [], [], [], []
    for bi, b in enumerate(bouts):
        for st in window_starts(len(b.X), W, S):
            xw = pad_to_window(b.X[st:st + W], W)
            yw = b.Y[st:st + W]
            if len(yw) < W:                       # pad the density with zeros:
                yw = np.concatenate([yw, np.zeros(W - len(yw), dtype=np.float32)])
            Xs.append(xw)
            Ys.append(yw.astype(np.float32))
            counts.append(float(yw.sum()))        # fractional at window edges
            groups.append(b.subject)
            bids.append(bi)

    return RepWindowDataset(
        X=np.stack(Xs).astype(np.float32),
        Y=np.stack(Ys).astype(np.float32),
        counts=np.array(counts, dtype=np.float32),
        groups=np.array(groups),
        bout_ids=np.array(bids, dtype=np.int64),
        bouts=bouts,
    )


def bout_density(predict, X: np.ndarray) -> np.ndarray:
    """Overlap-add a windowed model's output back into one per-frame curve.

    `predict` maps a batch (n, W, C) of raw IMU to (n, W) densities. Overlapping
    windows are averaged (accumulate / coverage), not summed, or every rep in an
    overlap region would be counted once per window covering it.
    """
    W, S = config.REP_WINDOW, config.REP_WIN_STRIDE
    n = len(X)
    starts = window_starts(n, W, S)
    batch = np.stack([pad_to_window(X[st:st + W], W) for st in starts])
    dens = np.asarray(predict(batch), dtype=np.float64)     # (n_win, W)

    acc = np.zeros(n, dtype=np.float64)
    cov = np.zeros(n, dtype=np.float64)
    for k, st in enumerate(starts):
        end = min(st + W, n)                                # ignore the padded tail
        acc[st:end] += dens[k, :end - st]
        cov[st:end] += 1.0
    return acc / np.maximum(cov, 1.0)


def bout_count(predict, X: np.ndarray) -> float:
    """Rep count for a whole set: integral of the overlap-added density."""
    return float(bout_density(predict, X).sum())


if __name__ == "__main__":
    bouts = build_bouts()
    ds = build_rep_windows(bouts)
    secs = np.array([len(b.X) for b in bouts]) / config.FS
    print(f"bouts: {len(bouts)}   windows: {len(ds.counts)}   "
          f"({len(ds.counts) / len(bouts):.1f} windows per set)")
    print(f"subjects: {len(np.unique(ds.groups))}   "
          f"set length: {secs.min():.0f}-{secs.max():.0f} s (mean {secs.mean():.0f} s)")
    print(f"reps per set: min {min(b.count for b in bouts)}  "
          f"max {max(b.count for b in bouts)}  "
          f"mean {np.mean([b.count for b in bouts]):.1f}")
    print(f"reps per window: mean {ds.counts.mean():.2f}  max {ds.counts.max():.2f}")
    # Sanity: each bout's density must still integrate to its tagged rep count.
    err = max(abs(float(b.Y.sum()) - b.count) for b in bouts)
    print(f"density area vs. count — max abs err {err:.3f}")
