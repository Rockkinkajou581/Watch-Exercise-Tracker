//
//  RepPeriodCounter.swift
//  LiftLogger Watch App  (add to the WATCH target only)
//
//  On-watch counterpart to training/train_reps_period.py: loads
//  LiftLoggerRepPeriodCounter.mlpackage (if bundled) and counts reps in one bout
//  by predicting its dominant rep PERIOD — not a per-frame density curve — and
//  dividing the bout's real duration by it. Unlike RepDensityCounter's model, this
//  one is trained on nothing but the final reps count already in sets.csv (dial-
//  confirmed manual sets, or auto-detected sets corrected via the phone's "Fix
//  reps" sheet), so it needs no per-rep taps to improve. `count` returns nil when
//  the model isn't bundled, so callers fall back to another counter.
//

import CoreML
import Foundation

final class RepPeriodCounter {

    private let model: MLModel?
    private let inName: String
    private let outName: String
    private let frames: Int
    let isReady: Bool

    init() {
        guard let url = Bundle.main.url(forResource: "LiftLoggerRepPeriodCounter",
                                        withExtension: "mlmodelc"),
              let m = try? MLModel(contentsOf: url) else {
            model = nil
            inName = ""; outName = ""
            frames = 0
            isReady = false
            return
        }
        let desc = m.modelDescription
        let input = desc.inputDescriptionsByName.first { $0.value.multiArrayConstraint != nil }
        let shape = input?.value.multiArrayConstraint?.shape ?? []
        model = m
        inName = input?.key ?? "imu_bout"
        outName = desc.outputDescriptionsByName.keys.first ?? "var_0"
        // Shape is [1, L, C]; fall back to the training-time default if unreadable.
        frames = shape.count >= 2 ? shape[shape.count - 2].intValue : RecorderModel.repPeriodBoutLen
        isReady = frames > 1
    }

    /// samples: bout rows × `RecorderModel.nChannels` of raw IMU, in chronological
    /// order. Returns a rep count, or nil if the model isn't available.
    func count(_ samples: [[Float]], fs: Int) -> Int? {
        guard isReady, let model else { return nil }
        let n = samples.count
        guard n >= fs, samples.first?.count == RecorderModel.nChannels else { return nil }
        let durationS = Double(n) / Double(fs)

        let c = RecorderModel.nChannels
        guard let arr = try? MLMultiArray(
                shape: [1, NSNumber(value: frames), NSNumber(value: c)],
                dataType: .float32) else { return nil }
        // Same convention as rep_windows.pad_to_window on the Python side: crop
        // from the start if the bout is longer than the model's input, edge-pad
        // (repeat the last row, not zeros — acc includes gravity) if shorter.
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: frames * c)
        for i in 0..<frames {
            let row = samples[min(i, n - 1)]
            let base = i * c
            for ch in 0..<c { ptr[base + ch] = row[ch] }
        }

        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: [inName: MLFeatureValue(multiArray: arr)]),
              let out = try? model.prediction(from: provider),
              let periodArr = out.featureValue(for: outName)?.multiArrayValue,
              periodArr.count > 0
        else { return nil }

        let periodS = periodArr[0].doubleValue
        guard periodS > 0 else { return nil }
        return max(Int((durationS / periodS).rounded()), 0)
    }
}
