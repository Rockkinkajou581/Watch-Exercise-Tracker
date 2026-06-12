"""Random Forest baseline on hand-crafted features — the number the CNN must beat.

If the CNN can't clearly out-perform this, the problem is almost always DATA
(too little, too clean, or leaking between train/test), not the model.

Run from inside the training/ folder:  python baseline_rf.py
"""
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import classification_report, f1_score

import config
from data import label_samples, load_raw, make_splits, make_windows
from features import feature_matrix


def main():
    readings, sets = load_raw()
    ds = make_windows(label_samples(readings, sets))
    tr, va, te = make_splits(ds)
    train_idx = np.concatenate([tr, va])         # RF needs no val split

    Xtr, ytr = feature_matrix(ds.X[train_idx]), ds.y[train_idx]
    Xte, yte = feature_matrix(ds.X[te]), ds.y[te]

    clf = RandomForestClassifier(
        n_estimators=300, n_jobs=-1, class_weight="balanced", random_state=config.SEED)
    clf.fit(Xtr, ytr)
    p = clf.predict(Xte)

    print(f"accuracy {(p == yte).mean():.3f}   "
          f"macro-F1 {f1_score(yte, p, average='macro', zero_division=0):.3f}\n")
    print(classification_report(yte, p, target_names=ds.classes, digits=3, zero_division=0))


if __name__ == "__main__":
    main()
