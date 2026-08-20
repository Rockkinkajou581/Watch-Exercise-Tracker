"""Train the rep-density model on WINDOWS instead of whole bouts.

Same labels as train_reps_model.py (phone rep-tagger taps), same network, same
scoring — but each set contributes ~23 overlapping 8 s windows instead of one
duration-normalized bout, and time stays in real seconds. See rep_windows.py for
why that matters.

Two things this buys beyond raw example count:
  * the val metric becomes usable. The bout script early-stops on the count-MAE of
    ~7 held-out bouts, which is quantized to ~0.14 and mostly noise, so checkpoint
    selection is close to a coin flip. Here training runs over hundreds of windows
    while the val metric is still computed at SET level (the number you care about).
  * BatchNorm sees real batches instead of 8 examples.

Splits are by SUBJECT when there are >= 3, else by SET — never by window. Two
overlapping windows from one set are nearly the same signal, so a window-level
split would put a near-duplicate of every val example in train and report a
beautiful, meaningless number.

Outputs (in artifacts/):
    rep_win_cnn.pt        trained weights
    rep_win_norm.npz      per-channel mean/std (baked into the CoreML export)
    rep_win_metrics.txt   set-level count accuracy, overall + per-exercise

Run from inside the training/ folder (after collecting reps.csv):
    python train_reps_windows.py
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
from rep_windows import Bout, bout_count, build_bouts, build_rep_windows
from train_reps_model import score, set_seed


def split_bouts(bouts: list[Bout]):
    """Train/val/test indices over BOUTS, holding subjects out when there are >= 3."""
    n = len(bouts)
    subjects = np.array([b.subject for b in bouts])
    n_subj = len(np.unique(subjects))
    idx = np.arange(n)

    if n_subj >= 3:
        gss = GroupShuffleSplit(n_splits=1, test_size=config.TEST_FRACTION,
                                random_state=config.SEED)
        trainval, test = next(gss.split(idx, groups=subjects))
        val_rel = config.VAL_FRACTION / (1.0 - config.TEST_FRACTION)
        gss2 = GroupShuffleSplit(n_splits=1, test_size=val_rel, random_state=config.SEED)
        tr_rel, va_rel = next(gss2.split(trainval, groups=subjects[trainval]))
        return trainval[tr_rel], trainval[va_rel], test

    print(f"[warn] only {n_subj} subject(s): splitting by set, so train and test "
          "share subjects. Rep accuracy will be optimistic vs. a brand-new user.")
    if n < 3:
        raise SystemExit(
            f"\nOnly {n} tagged set(s) found — too few to train (need >= 3 just to form "
            "train/val/test, and realistically dozens across several people for a useful "
            "model). The ingestion works; keep collecting sets with the rep tagger.")
    perm = np.random.RandomState(config.SEED).permutation(n)
    n_test = max(1, round(n * config.TEST_FRACTION))
    n_val = max(1, round(n * config.VAL_FRACTION))
    if n - n_test - n_val < 1:
        n_test, n_val = 1, 1
    return perm[n_test + n_val:], perm[n_test:n_test + n_val], perm[:n_test]


def make_predict(model, mean, std, device):
    """(n, W, C) raw IMU -> (n, W) density, for rep_windows.bout_count."""
    @torch.no_grad()
    def predict(batch: np.ndarray) -> np.ndarray:
        model.eval()
        x = torch.tensor((batch - mean) / std, dtype=torch.float32)
        return model(x.transpose(1, 2).to(device)).cpu().numpy()
    return predict


def set_level_counts(model, bouts: list[Bout], idx, mean, std, device):
    """Predicted vs. true rep count for each held-out SET (the metric that matters)."""
    predict = make_predict(model, mean, std, device)
    pred = np.array([bout_count(predict, bouts[i].X) for i in idx])
    true = np.array([bouts[i].count for i in idx])
    return pred, true


def main():
    set_seed(config.SEED)
    config.ARTIFACTS.mkdir(parents=True, exist_ok=True)

    bouts = build_bouts()
    ds = build_rep_windows(bouts)
    print(f"sets: {len(bouts)}   windows: {len(ds.counts)} "
          f"({len(ds.counts) / len(bouts):.1f} per set)   "
          f"subjects: {len(np.unique(ds.groups))}")
    print(f"window: {config.REP_WINDOW_SEC:.0f} s @ {config.REP_WIN_STRIDE_SEC:.0f} s stride   "
          f"mean reps/window {ds.counts.mean():.2f}")

    tr_b, va_b, te_b = split_bouts(bouts)
    print(f"sets — train {len(tr_b)}  val {len(va_b)}  test {len(te_b)}")

    # Windows follow their set into whichever split the set landed in.
    win_of = lambda b_idx: np.flatnonzero(np.isin(ds.bout_ids, b_idx))
    tr, va = win_of(tr_b), win_of(va_b)
    mean, std = compute_norm(ds.X[tr])                # train-only stats — no leakage

    def loader(idx, shuffle):
        x = torch.tensor((ds.X[idx] - mean) / std).transpose(1, 2)   # (N, C, W)
        y = torch.tensor(ds.Y[idx])                                  # (N, W)
        return DataLoader(TensorDataset(x, y), batch_size=config.REP_WIN_BATCH_SIZE,
                          shuffle=shuffle,
                          drop_last=shuffle and len(idx) > config.REP_WIN_BATCH_SIZE)

    train_loader = loader(tr, True)
    if len(train_loader) == 0:
        raise SystemExit(
            f"\nTrain loader is empty ({len(tr)} windows, batch size "
            f"{config.REP_WIN_BATCH_SIZE}) — lower REP_WIN_BATCH_SIZE in config.py.")
    print(f"train windows: {len(tr)}   batches/epoch: {len(train_loader)}")

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    # Start the head at the data's mean density rather than softplus(0)=0.69/frame,
    # which is ~70x too high and otherwise eats the entire epoch budget.
    bias0 = RepDensityCNN.inverse_softplus(float(ds.Y[tr].mean()))
    model = RepDensityCNN(dilations=config.REP_WIN_DILATIONS,
                          head_bias_init=bias0).to(device)
    print(f"head bias init {bias0:.2f} (mean density {ds.Y[tr].mean():.5f}/frame)")
    print(f"receptive field: {model.receptive_field} frames "
          f"({model.receptive_field / config.FS:.1f} s) — must span at least one rep")
    criterion = torch.nn.MSELoss()
    opt = torch.optim.Adam(model.parameters(), lr=config.LR,
                           weight_decay=config.WEIGHT_DECAY)

    best_mae, best_state, patience = float("inf"), None, 0
    for epoch in range(config.REP_WIN_EPOCHS):
        model.train()
        for xb, yb in train_loader:
            xb, yb = xb.to(device), yb.to(device)
            opt.zero_grad()
            criterion(model(xb), yb).backward()
            opt.step()
        # Early-stop on SET-level count MAE, not window loss — the windows are a
        # training convenience, the set count is the product.
        val_mae = score(*set_level_counts(model, bouts, va_b, mean, std, device))["mae"]
        if val_mae < best_mae:
            best_mae, patience = val_mae, 0
            best_state = {k: v.cpu().clone() for k, v in model.state_dict().items()}
        else:
            patience += 1
        print(f"epoch {epoch:3d}   val set count-MAE {val_mae:.3f}   best {best_mae:.3f}")
        if patience >= config.REP_WIN_EARLY_STOP_PATIENCE:
            print(f"early stop (no val improvement for "
                  f"{config.REP_WIN_EARLY_STOP_PATIENCE} epochs)")
            break

    model.load_state_dict(best_state)
    pred, true = set_level_counts(model, bouts, te_b, mean, std, device)
    m = score(pred, true)
    print("\n=== TEST (held-out sets) ===")
    print(f"exact {m['exact']:.1%}   within-1 {m['within1']:.1%}   MAE {m['mae']:.2f} reps")

    df = pd.DataFrame({"exercise": [bouts[i].exercise for i in te_b],
                       "true": true, "pred": np.rint(pred).astype(int)})
    df["abs_err"] = (df["pred"] - df["true"]).abs()
    per_ex = df.groupby("exercise").agg(
        n=("true", "size"), mae=("abs_err", "mean"),
        within1=("abs_err", lambda s: (s <= 1).mean())).sort_values("mae", ascending=False)
    print("\nper-exercise (worst first):")
    for ex, row in per_ex.iterrows():
        print(f"  {ex:24s} n={int(row.n):3d}  MAE={row.mae:.2f}  ±1={row.within1:6.1%}")

    torch.save(model.state_dict(), config.ARTIFACTS / "rep_win_cnn.pt")
    np.savez(config.ARTIFACTS / "rep_win_norm.npz", mean=mean, std=std)
    (config.ARTIFACTS / "rep_win_metrics.txt").write_text(
        f"sets {len(bouts)}  windows {len(ds.counts)}  "
        f"subjects {len(np.unique(ds.groups))}\n"
        f"window {config.REP_WINDOW_SEC}s stride {config.REP_WIN_STRIDE_SEC}s\n"
        f"test exact {m['exact']:.4f}  within1 {m['within1']:.4f}  mae {m['mae']:.4f}\n\n"
        f"{per_ex.to_string()}\n")
    print(f"\nsaved artifacts -> {config.ARTIFACTS}")
    print("compare against the bout model: python train_reps_model.py")


if __name__ == "__main__":
    main()
