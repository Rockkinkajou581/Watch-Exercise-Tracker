"""Convert the trained CNN to a Core ML model for on-watch inference.

Produces artifacts/LiftLoggerClassifier.mlpackage. Drag it into the Xcode project
(Watch App target). Xcode generates a `LiftLoggerClassifier` Swift class.

On-watch usage sketch (collect WINDOW=100 frames of 6 channels, then):
    let input = try MLMultiArray(shape: [1, 100, 6], dataType: .float32)
    // fill input[[0, t, c]] with raw acc_xyz / gyro_xyz, same channel order as CHANNELS
    let out = try model.prediction(imu_window: input)
    let label = out.classLabel              // e.g. "bicep_curl"  (top-1)
    let probs = out.classLabel_probs        // [String: Double]   (per-class confidence)

Run from inside the training/ folder (after train.py):  python export_coreml.py
"""
import json

import numpy as np
import torch

import config
from models import CNN1D, ExportWrapper


def main():
    import coremltools as ct

    classes = json.loads((config.ARTIFACTS / "classes.json").read_text())
    norm = np.load(config.ARTIFACTS / "norm.npz")

    model = CNN1D(n_classes=len(classes))
    model.load_state_dict(torch.load(config.ARTIFACTS / "cnn.pt", map_location="cpu"))
    model.eval()

    wrapper = ExportWrapper(model, norm["mean"], norm["std"]).eval()
    example = torch.randn(1, config.WINDOW, config.N_CHANNELS)     # (B, WINDOW, C)
    traced = torch.jit.trace(wrapper, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="imu_window",
                              shape=(1, config.WINDOW, config.N_CHANNELS))],
        classifier_config=ct.ClassifierConfig(class_labels=classes),
        minimum_deployment_target=ct.target.watchOS9,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel.short_description = (
        "LiftLogger exercise classifier — 6-channel IMU @50Hz, 2s window")
    mlmodel.input_description["imu_window"] = (
        f"{config.WINDOW}x{config.N_CHANNELS}: rows=time @50Hz, "
        f"cols={config.CHANNELS}")

    out = config.ARTIFACTS / "LiftLoggerClassifier.mlpackage"
    mlmodel.save(str(out))
    print(f"saved -> {out}")
    print(f"classes (output order): {classes}")


if __name__ == "__main__":
    main()
