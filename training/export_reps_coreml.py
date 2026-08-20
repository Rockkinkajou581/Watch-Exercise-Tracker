"""Convert a trained rep-density model to Core ML for on-watch rep counting.

Produces artifacts/LiftLoggerRepCounter.mlpackage. Drag it into the Xcode project
(Watch App target) alongside LiftLoggerClassifier.mlpackage. Until this model is
bundled the watch falls back to the unsupervised RepCounter, so it's a drop-in
upgrade.

Two models can be exported; the watch handles either, switching on the input
feature's NAME and LENGTH that it reads out of the compiled model:

    --mode window  (default)  from train_reps_windows.py
        input  "imu_window": (1, REP_WINDOW, N_CHANNELS) raw IMU at FS Hz
        The watch slides this window over the bout at REP_WIN_STRIDE, overlap-adds
        the densities, and integrates. Time is in real seconds, so one model
        handles a set of any length.

    --mode bout               from train_reps_model.py
        input  "imu_bout":   (1, REP_BOUT_LEN, N_CHANNELS) whole set, resampled
        The watch squeezes the entire set onto REP_BOUT_LEN frames and runs once.

Output in both cases is a non-negative per-frame density; reps = its integral.

Run from inside the training/ folder:
    python export_reps_coreml.py            # window model
    python export_reps_coreml.py --bout     # legacy bout model
"""
import argparse

import numpy as np
import torch

import config
from models import RepDensityCNN, RepExportWrapper


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bout", action="store_true",
                    help="export the whole-bout model (train_reps_model.py) instead")
    args = ap.parse_args()

    import coremltools as ct

    if args.bout:
        weights, norm_file = "rep_cnn.pt", "rep_norm.npz"
        in_name, length = "imu_bout", config.REP_BOUT_LEN
        dilations = (1, 2, 4, 8)                      # RepDensityCNN's default
        desc = (f"rows=time (set resampled to {length} frames)")
    else:
        weights, norm_file = "rep_win_cnn.pt", "rep_win_norm.npz"
        in_name, length = "imu_window", config.REP_WINDOW
        dilations = config.REP_WIN_DILATIONS           # wider RF for real-time frames
        desc = (f"rows=time ({config.REP_WINDOW_SEC:.0f} s at {config.FS} Hz, slid "
                f"over the bout at {config.REP_WIN_STRIDE_SEC:.0f} s)")

    ckpt = config.ARTIFACTS / weights
    if not ckpt.exists():
        raise SystemExit(
            f"\n{ckpt} not found — train it first:\n"
            f"    python {'train_reps_model.py' if args.bout else 'train_reps_windows.py'}")

    norm = np.load(config.ARTIFACTS / norm_file)
    model = RepDensityCNN(dilations=dilations)
    model.load_state_dict(torch.load(ckpt, map_location="cpu"))
    model.eval()

    wrapper = RepExportWrapper(model, norm["mean"], norm["std"]).eval()
    example = torch.randn(1, length, config.N_CHANNELS)   # (B, L, C)
    traced = torch.jit.trace(wrapper, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name=in_name, shape=(1, length, config.N_CHANNELS))],
        minimum_deployment_target=ct.target.watchOS9,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel.short_description = (
        "LiftLogger rep-density counter — 6-channel IMU, sum density for count")
    mlmodel.input_description[in_name] = (
        f"{length}x{config.N_CHANNELS}: {desc}, cols={config.CHANNELS}")

    out = config.ARTIFACTS / "LiftLoggerRepCounter.mlpackage"
    mlmodel.save(str(out))
    print(f"saved -> {out}   (input {in_name}, {length} frames)")


if __name__ == "__main__":
    main()
