"""Train the period-regression rep counter — no per-rep taps needed.

Unlike train_reps_model.py / train_reps_windows.py (which need reps.csv, i.e. an
observer tapping every rep live on the phone), this trains on nothing but the
final `reps` integer already in sets.csv: every hand-dialed manual set, plus any
auto-detected set corrected via the phone's "Fix reps" sheet (SessionStore.
confirmReps, folded into sets.csv by buildMergedExport). See config.py's PERIOD
section for why predicting the bout's dominant rep PERIOD (not raw count) is what
makes a single scalar per set enough supervision to learn from.

Each bout is edge-padded/cropped to REP_PERIOD_BOUT_LEN frames (same convention as
rep_windows.pad_to_window: edge-pad if short, crop from the start if long) and fed
whole to a global-average-pooled CNN. The label is log(duration_s / true_count) —
the average period implied by the corrected count; at eval/inference the predicted
period is exponentiated and divided into the bout's real duration to get a count.

Scored the same way as evaluate_reps.py and the other two rep models (exact/
within-1/MAE) so all of them compare head-to-head.

Outputs (in artifacts/):
    rep_period_cnn.pt        trained weights
    rep_period_norm.npz      per-channel mean/std (baked into the CoreML export)
    rep_period_metrics.txt   count accuracy, overall + per-exercise

Run from inside the training/ folder:
    python train_reps_period.py
"""
from __future__ import annotations
from dataclasses import dataclass

import numpy as np
import pandas as pd
import torch
from torch.utils.data import DataLoader, TensorDataset

import config
from data import compute_norm, load_raw
from models import RepPeriodCNN
from rep_windows import pad_to_window, uniform_resample
from train_reps_model import grouped_split, score, set_seed


@dataclass
class PeriodBout:
    X: np.ndarray        # (T, N_CHANNELS) float32 — real-time (FS Hz) resampled IMU
    duration_s: float
    count: int            # true rep count, from sets.csv
    exercise: str
    subject: str


def build_period_bouts(min_reps: int = config.REP_PERIOD_MIN_REPS) -> list[PeriodBout]:
    """Every set with a usable reps count — no reps.csv required."""
    readings, sets = load_raw()

    discards = sets[sets["exercise"] == config.DISCARD_LABEL]
    sets = sets[sets["exercise"] != config.DISCARD_LABEL].copy()
    if "reps" not in sets.columns:
        raise RuntimeError(
            "sets.csv has no `reps` column — record rep counts on the watch "
            "(End Set) or correct a detected set on the phone, then re-export.")
    sets["reps"] = pd.to_numeric(sets["reps"], errors="coerce")
    sets = sets.dropna(subset=["reps"])
    sets = sets[sets["reps"] >= min_reps]

    bouts: list[PeriodBout] = []
    for s in sets.itertuples(index=False):
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

        X = uniform_resample(seg, times, config.FS)
        duration_s = (times[-1] - times[0]) / 1000.0
        bouts.append(PeriodBout(X=X, duration_s=duration_s, count=int(round(s.reps)),
                                exercise=s.exercise, subject=s.subject))

    if not bouts:
        raise RuntimeError(
            f"No sets with reps >= {min_reps} and matching readings.csv coverage. "
            "Record sets and confirm a rep count (dial or phone correction), then re-export.")
    return bouts


def make_inputs(bouts: list[PeriodBout], width: int) -> np.ndarray:
    return np.stack([pad_to_window(b.X, width) for b in bouts]).astype(np.float32)


@torch.no_grad()
def predicted_counts(model, X, durations_s, mean, std, device) -> np.ndarray:
    model.eval()
    x = torch.tensor((X - mean) / std).transpose(1, 2).to(device)   # (N, C, L)
    period_s = np.exp(model(x).cpu().numpy())
    return durations_s / period_s


def main():
    set_seed(config.SEED)
    config.ARTIFACTS.mkdir(parents=True, exist_ok=True)

    bouts = build_period_bouts()
    counts = np.array([b.count for b in bouts], dtype=np.int64)
    durations = np.array([b.duration_s for b in bouts], dtype=np.float64)
    log_periods = np.log(durations / counts).astype(np.float32)
    groups = np.array([b.subject for b in bouts])
    exercises = np.array([b.exercise for b in bouts])

    print(f"bouts: {len(bouts)}   subjects: {len(np.unique(groups))}   "
          f"mean reps/bout {counts.mean():.1f}")

    tr, va, te = grouped_split(groups, len(bouts))
    print(f"bouts — train {len(tr)}  val {len(va)}  test {len(te)}")

    width = config.REP_PERIOD_BOUT_LEN
    X_all = make_inputs(bouts, width)
    mean, std = compute_norm(X_all[tr])               # train-only stats — no leakage

    def loader(idx, shuffle):
        x = torch.tensor((X_all[idx] - mean) / std).transpose(1, 2)   # (N, C, L)
        y = torch.tensor(log_periods[idx])
        return DataLoader(TensorDataset(x, y), batch_size=config.REP_BATCH_SIZE,
                          shuffle=shuffle,
                          drop_last=shuffle and len(idx) > config.REP_BATCH_SIZE)

    train_loader = loader(tr, True)
    if len(train_loader) == 0:
        raise SystemExit(
            f"\nTrain loader is empty ({len(tr)} bouts, batch size {config.REP_BATCH_SIZE}) — "
            "lower REP_BATCH_SIZE in config.py.")
    print(f"train batches/epoch: {len(train_loader)}")

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model = RepPeriodCNN().to(device)
    criterion = torch.nn.MSELoss()
    opt = torch.optim.Adam(model.parameters(), lr=config.LR, weight_decay=config.WEIGHT_DECAY)

    best_mae, best_state, patience = float("inf"), None, 0
    for epoch in range(config.REP_EPOCHS):
        model.train()
        for xb, yb in train_loader:
            xb, yb = xb.to(device), yb.to(device)
            opt.zero_grad()
            criterion(model(xb), yb).backward()
            opt.step()
        val_mae = score(predicted_counts(model, X_all[va], durations[va], mean, std, device),
                        counts[va])["mae"]
        if val_mae < best_mae:
            best_mae, patience = val_mae, 0
            best_state = {k: v.cpu().clone() for k, v in model.state_dict().items()}
        else:
            patience += 1
        print(f"epoch {epoch:3d}   val count-MAE {val_mae:.3f}   best {best_mae:.3f}")
        if patience >= config.REP_EARLY_STOP_PATIENCE:
            print(f"early stop (no val improvement for {config.REP_EARLY_STOP_PATIENCE} epochs)")
            break

    model.load_state_dict(best_state)
    pred = predicted_counts(model, X_all[te], durations[te], mean, std, device)
    m = score(pred, counts[te])
    print("\n=== TEST (held-out) ===")
    print(f"exact {m['exact']:.1%}   within-1 {m['within1']:.1%}   MAE {m['mae']:.2f} reps")

    df = pd.DataFrame({"exercise": exercises[te], "true": counts[te],
                       "pred": np.rint(pred).astype(int)})
    df["abs_err"] = (df["pred"] - df["true"]).abs()
    per_ex = df.groupby("exercise").agg(
        n=("true", "size"), mae=("abs_err", "mean"),
        within1=("abs_err", lambda s: (s <= 1).mean())).sort_values("mae", ascending=False)
    print("\nper-exercise (worst first):")
    for ex, row in per_ex.iterrows():
        print(f"  {ex:24s} n={int(row.n):3d}  MAE={row.mae:.2f}  ±1={row.within1:6.1%}")

    torch.save(model.state_dict(), config.ARTIFACTS / "rep_period_cnn.pt")
    np.savez(config.ARTIFACTS / "rep_period_norm.npz", mean=mean, std=std)
    (config.ARTIFACTS / "rep_period_metrics.txt").write_text(
        f"bouts {len(bouts)}  subjects {len(np.unique(groups))}\n"
        f"test exact {m['exact']:.4f}  within1 {m['within1']:.4f}  mae {m['mae']:.4f}\n\n"
        f"{per_ex.to_string()}\n")
    print(f"\nsaved artifacts -> {config.ARTIFACTS}")
    print("compare against: python evaluate_reps.py (unsupervised) and "
          "python train_reps_windows.py (tap-supervised density model)")
    print("export with: python export_reps_coreml.py --period")


if __name__ == "__main__":
    main()
