"""Convert the trained rep-density model to Core ML for on-watch rep counting.

Produces artifacts/LiftLoggerRepCounter.mlpackage. Drag it into the Xcode project
(Watch App target) alongside LiftLoggerClassifier.mlpackage. The watch loads it in
RepDensityCounter (RecorderModel.swift): it feeds one resampled bout and sums the
returned density to get a rep count. Until this model is bundled the watch falls
back to the unsupervised RepCounter, so this is a drop-in upgrade.

On-watch I/O:
    input  "imu_bout":  (1, REP_BOUT_LEN, N_CHANNELS) raw IMU, CHANNELS order
    output  density:    (1, REP_BOUT_LEN) non-negative; rep count = sum over time

Run from inside the training/ folder (after train_reps_model.py):
    python export_reps_coreml.py
"""
import numpy as np
import torch

import config
from models import RepDensityCNN, RepExportWrapper


def main():
    import coremltools as ct

    norm = np.load(config.ARTIFACTS / "rep_norm.npz")
    model = RepDensityCNN()
    model.load_state_dict(torch.load(config.ARTIFACTS / "rep_cnn.pt", map_location="cpu"))
    model.eval()

    wrapper = RepExportWrapper(model, norm["mean"], norm["std"]).eval()
    example = torch.randn(1, config.REP_BOUT_LEN, config.N_CHANNELS)   # (B, L, C)
    traced = torch.jit.trace(wrapper, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="imu_bout",
                              shape=(1, config.REP_BOUT_LEN, config.N_CHANNELS))],
        minimum_deployment_target=ct.target.watchOS9,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel.short_description = (
        "LiftLogger rep-density counter — 6-channel IMU bout, sum density for count")
    mlmodel.input_description["imu_bout"] = (
        f"{config.REP_BOUT_LEN}x{config.N_CHANNELS}: rows=time (set resampled to "
        f"{config.REP_BOUT_LEN} frames), cols={config.CHANNELS}")

    out = config.ARTIFACTS / "LiftLoggerRepCounter.mlpackage"
    mlmodel.save(str(out))
    print(f"saved -> {out}")


if __name__ == "__main__":
    main()
