"""Train the supervised rep-density model and report rep-count accuracy.

Learns to emit one bump per rep from a set's IMU (labels from the phone rep
tagger, built by rep_events.py). The rep count is the integral of the predicted
density. Evaluated subject-grouped where possible — the honest estimate for a
brand-new user — and scored the same way as evaluate_reps.py (exact / within-1 /
MAE) so you can compare it head-to-head against the unsupervised counter.

Outputs (in artifacts/):
    rep_cnn.pt        trained weights
    rep_norm.npz      per-channel mean/std (baked into the CoreML model at export)
    rep_metrics.txt   count accuracy, overall + per-exercise

Run from inside the training/ folder (after collecting reps.csv):
    python train_reps_model.py
"""
from __future__ import annotations
import random

import numpy as np
import pandas as pd
import torch
from sklearn.model_selection import GroupShuffleSplit
from torch.utils.data import DataLoader, TensorDataset

import config
from data import compute_norm
from models import RepDensityCNN
from rep_events import build_rep_dataset


def set_seed(s: int):
    random.seed(s); np.random.seed(s); torch.manual_seed(s)


def grouped_split(groups: np.ndarray, n: int):
    """Train/val/test indices, holding subjects out when there are >= 3 of them.

    With fewer subjects we split by bout instead (accuracy is then optimistic), and
    for tiny datasets we size the splits by hand so each part has >= 1 bout — sklearn
    won't do that for you and raises an opaque error otherwise.
    """
    n_subj = len(np.unique(groups))
    if n_subj >= 3:
        idx = np.arange(n)
        gss = GroupShuffleSplit(n_splits=1, test_size=config.TEST_FRACTION, random_state=config.SEED)
        trainval, test = next(gss.split(idx, groups=groups))
        val_rel = config.VAL_FRACTION / (1.0 - config.TEST_FRACTION)
        gss2 = GroupShuffleSplit(n_splits=1, test_size=val_rel, random_state=config.SEED)
        tr_rel, va_rel = next(gss2.split(trainval, groups=groups[trainval]))
        return trainval[tr_rel], trainval[va_rel], test

    print(f"[warn] only {n_subj} subject(s): splitting by bout, so train and test "
          "share subjects. Rep accuracy will be optimistic vs. a brand-new user.")
    if n < 3:
        raise SystemExit(
            f"\nOnly {n} tagged bout(s) found — too few to train (need >= 3 just to form "
            "train/val/test, and realistically dozens across several people for a useful "
            "model). The ingestion works; keep collecting sets with the rep tagger.")
    perm = np.random.RandomState(config.SEED).permutation(n)
    n_test = max(1, round(n * config.TEST_FRACTION))
    n_val = max(1, round(n * config.VAL_FRACTION))
    if n - n_test - n_val < 1:                       # guarantee a non-empty train set
        n_test, n_val = 1, 1
    test, val, train = perm[:n_test], perm[n_test:n_test + n_val], perm[n_test + n_val:]
    return train, val, test


@torch.no_grad()
def predicted_counts(model, X, mean, std, device) -> np.ndarray:
    model.eval()
    x = torch.tensor((X - mean) / std).transpose(1, 2).to(device)   # (N, C, L)
    dens = model(x)                                                 # (N, L)
    return dens.sum(dim=1).cpu().numpy()


def score(pred: np.ndarray, true: np.ndarray) -> dict:
    p = np.rint(pred).astype(int)
    err = np.abs(p - true)
    return {"exact": float((err == 0).mean()),
            "within1": float((err <= 1).mean()),
            "mae": float(err.mean())}


def main():
    set_seed(config.SEED)
    config.ARTIFACTS.mkdir(parents=True, exist_ok=True)

    ds = build_rep_dataset()
    print(f"bouts: {len(ds.counts)}   subjects: {len(np.unique(ds.groups))}   "
          f"mean reps/bout {ds.counts.mean():.1f}")

    tr, va, te = grouped_split(ds.groups, len(ds.counts))
    mean, std = compute_norm(ds.X[tr])               # train-only stats — no leakage

    def loader(idx, shuffle):
        x = torch.tensor((ds.X[idx] - mean) / std).transpose(1, 2)   # (N, C, L)
        y = torch.tensor(ds.Y[idx])                                  # (N, L)
        return DataLoader(TensorDataset(x, y), batch_size=config.BATCH_SIZE,
                          shuffle=shuffle, drop_last=shuffle)

    train_loader, val_loader = loader(tr, True), loader(va, False)

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model = RepDensityCNN().to(device)
    criterion = torch.nn.MSELoss()
    opt = torch.optim.Adam(model.parameters(), lr=config.LR, weight_decay=config.WEIGHT_DECAY)

    best_mae, best_state, patience = float("inf"), None, 0
    for epoch in range(config.EPOCHS):
        model.train()
        for xb, yb in train_loader:
            xb, yb = xb.to(device), yb.to(device)
            opt.zero_grad()
            criterion(model(xb), yb).backward()
            opt.step()
        val_mae = score(predicted_counts(model, ds.X[va], mean, std, device),
                        ds.counts[va])["mae"]
        if val_mae < best_mae:
            best_mae = val_mae
            best_state = {k: v.cpu().clone() for k, v in model.state_dict().items()}
            patience = 0
        else:
            patience += 1
        print(f"epoch {epoch:3d}   val count-MAE {val_mae:.3f}   best {best_mae:.3f}")
        if patience >= config.EARLY_STOP_PATIENCE:
            print(f"early stop (no val improvement for {config.EARLY_STOP_PATIENCE} epochs)")
            break

    model.load_state_dict(best_state)
    pred = predicted_counts(model, ds.X[te], mean, std, device)
    m = score(pred, ds.counts[te])
    print("\n=== TEST (held-out) ===")
    print(f"exact {m['exact']:.1%}   within-1 {m['within1']:.1%}   MAE {m['mae']:.2f} reps")

    df = pd.DataFrame({"exercise": ds.exercises[te], "true": ds.counts[te],
                       "pred": np.rint(pred).astype(int)})
    df["abs_err"] = (df["pred"] - df["true"]).abs()
    per_ex = df.groupby("exercise").agg(
        n=("true", "size"), mae=("abs_err", "mean"),
        within1=("abs_err", lambda s: (s <= 1).mean())).sort_values("mae", ascending=False)
    print("\nper-exercise (worst first):")
    for ex, row in per_ex.iterrows():
        print(f"  {ex:24s} n={int(row.n):3d}  MAE={row.mae:.2f}  ±1={row.within1:6.1%}")

    torch.save(model.state_dict(), config.ARTIFACTS / "rep_cnn.pt")
    np.savez(config.ARTIFACTS / "rep_norm.npz", mean=mean, std=std)
    (config.ARTIFACTS / "rep_metrics.txt").write_text(
        f"bouts {len(ds.counts)}  subjects {len(np.unique(ds.groups))}\n"
        f"test exact {m['exact']:.4f}  within1 {m['within1']:.4f}  mae {m['mae']:.4f}\n\n"
        f"{per_ex.to_string()}\n")
    print(f"\nsaved artifacts -> {config.ARTIFACTS}")


if __name__ == "__main__":
    main()
