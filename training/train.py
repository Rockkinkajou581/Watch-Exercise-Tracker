"""Train the 1-D CNN, evaluate on a held-out split, and save artifacts.

Outputs (in artifacts/):
    cnn.pt          trained weights
    norm.npz        per-channel mean/std (baked into the CoreML model at export)
    classes.json    ordered class names — index i is what the model outputs as i
    metrics.txt     test accuracy, per-class report, confusion matrix

Run from inside the training/ folder:  python train.py
"""
import json
import random

import numpy as np
import torch
from sklearn.metrics import classification_report, confusion_matrix, f1_score
from torch.utils.data import DataLoader, TensorDataset

import config
from data import compute_norm, label_samples, load_raw, make_splits, make_windows
from models import CNN1D


def set_seed(s: int):
    random.seed(s); np.random.seed(s); torch.manual_seed(s)


@torch.no_grad()
def evaluate(model, loader, device, classes=None, full=False):
    model.eval()
    ys, ps = [], []
    for xb, yb in loader:
        ps.append(model(xb.to(device)).argmax(1).cpu().numpy())
        ys.append(yb.numpy())
    y, p = np.concatenate(ys), np.concatenate(ps)
    out = {"accuracy": float((y == p).mean()),
           "macro_f1": float(f1_score(y, p, average="macro", zero_division=0))}
    if full:
        labels = list(range(len(classes)))   # pin labels so a class absent from the
        out["report"] = classification_report(   # test split doesn't break the report
            y, p, labels=labels, target_names=classes, digits=3, zero_division=0)
        out["confusion"] = np.array2string(confusion_matrix(y, p, labels=labels))
    return out


def main():
    set_seed(config.SEED)
    config.ARTIFACTS.mkdir(parents=True, exist_ok=True)

    readings, sets = load_raw()
    ds = make_windows(label_samples(readings, sets))
    dist = {c: int((ds.y == i).sum()) for i, c in enumerate(ds.classes)}
    print(f"windows: {len(ds.y)}   classes: {ds.classes}")
    print(f"class distribution: {dist}")

    tr, va, te = make_splits(ds)
    mean, std = compute_norm(ds.X[tr])           # stats from TRAIN only — no leakage

    def loader(idx, shuffle):
        x = torch.tensor((ds.X[idx] - mean) / std).transpose(1, 2)   # (N, C, WINDOW)
        y = torch.tensor(ds.y[idx])
        # drop_last on the training loader so a trailing batch of 1 can't break BatchNorm
        return DataLoader(TensorDataset(x, y), batch_size=config.BATCH_SIZE,
                          shuffle=shuffle, drop_last=shuffle)

    train_loader, val_loader, test_loader = loader(tr, True), loader(va, False), loader(te, False)

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model = CNN1D(n_classes=len(ds.classes)).to(device)

    counts = np.bincount(ds.y[tr], minlength=len(ds.classes)).astype(np.float32)
    w = torch.tensor(counts.sum() / (counts + 1e-6)).to(device)   # counter class imbalance
    criterion = torch.nn.CrossEntropyLoss(weight=w / w.mean())
    opt = torch.optim.Adam(model.parameters(), lr=config.LR, weight_decay=config.WEIGHT_DECAY)

    best_f1, best_state, patience = -1.0, None, 0
    for epoch in range(config.EPOCHS):
        model.train()
        for xb, yb in train_loader:
            xb, yb = xb.to(device), yb.to(device)
            opt.zero_grad()
            criterion(model(xb), yb).backward()
            opt.step()
        val_f1 = evaluate(model, val_loader, device)["macro_f1"]
        if val_f1 > best_f1:
            best_f1 = val_f1
            best_state = {k: v.cpu().clone() for k, v in model.state_dict().items()}
            patience = 0
        else:
            patience += 1
        print(f"epoch {epoch:3d}   val macro-F1 {val_f1:.3f}   best {best_f1:.3f}")
        if patience >= config.EARLY_STOP_PATIENCE:
            print(f"early stop (no val improvement for {config.EARLY_STOP_PATIENCE} epochs)")
            break

    model.load_state_dict(best_state)
    m = evaluate(model, test_loader, device, classes=ds.classes, full=True)
    print("\n=== TEST ===")
    print(f"accuracy {m['accuracy']:.3f}   macro-F1 {m['macro_f1']:.3f}\n")
    print(m["report"])

    torch.save(model.state_dict(), config.ARTIFACTS / "cnn.pt")
    np.savez(config.ARTIFACTS / "norm.npz", mean=mean, std=std)
    (config.ARTIFACTS / "classes.json").write_text(json.dumps(ds.classes, indent=2))
    (config.ARTIFACTS / "metrics.txt").write_text(
        f"accuracy {m['accuracy']:.4f}\nmacro_f1 {m['macro_f1']:.4f}\n\n"
        f"{m['report']}\n\nconfusion matrix (rows=true, cols=pred):\n{m['confusion']}\n")
    print(f"\nsaved artifacts -> {config.ARTIFACTS}")


if __name__ == "__main__":
    main()
