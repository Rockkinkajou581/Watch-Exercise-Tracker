"""The 1-D CNN classifier and an export wrapper that bakes in normalization.

CNN1D is what we train (it consumes already-normalized (B, C, WINDOW) tensors).
ExportWrapper is what we ship to CoreML: it accepts the natural on-watch layout
(B, WINDOW, C) of RAW sensor values, normalizes internally with the fixed train
statistics, and emits class probabilities — so the Swift side just hands over the
sensor buffer and reads a label.
"""
import torch
import torch.nn as nn

import config


class CNN1D(nn.Module):
    """Compact temporal ConvNet. Input (B, C, WINDOW) -> logits (B, n_classes).

    Translation-invariant over the window (it doesn't matter where in the rep the
    window starts) and ends in global average pooling, which keeps the parameter
    count low (~150k) and the model robust on small datasets — exactly what you
    want for an on-watch model.
    """
    def __init__(self, n_classes: int, n_channels: int = config.N_CHANNELS,
                 dropout: float = config.DROPOUT):
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv1d(n_channels, 64, kernel_size=7, padding=3),
            nn.BatchNorm1d(64), nn.ReLU(),
            nn.MaxPool1d(2),
            nn.Conv1d(64, 128, kernel_size=5, padding=2),
            nn.BatchNorm1d(128), nn.ReLU(),
            nn.MaxPool1d(2),
            nn.Conv1d(128, 128, kernel_size=3, padding=1),
            nn.BatchNorm1d(128), nn.ReLU(),
            nn.AdaptiveAvgPool1d(1),
        )
        self.head = nn.Sequential(
            nn.Flatten(),
            nn.Dropout(dropout),
            nn.Linear(128, n_classes),
        )

    def forward(self, x):
        return self.head(self.features(x))


class ExportWrapper(nn.Module):
    """Wraps a trained CNN1D for deployment.

    Accepts (B, WINDOW, C) raw IMU, applies fixed per-channel normalization, runs
    the CNN, and returns softmax probabilities.
    """
    def __init__(self, model: CNN1D, mean, std):
        super().__init__()
        self.model = model
        self.register_buffer("mean", torch.as_tensor(mean, dtype=torch.float32).view(1, -1, 1))
        self.register_buffer("std", torch.as_tensor(std, dtype=torch.float32).view(1, -1, 1))

    def forward(self, x):
        x = x.transpose(1, 2)            # (B, WINDOW, C) -> (B, C, WINDOW)
        x = (x - self.mean) / self.std
        return torch.softmax(self.model(x), dim=1)
