// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Testing
import Foundation
@testable import AppleLoopEditor

private final class TestBundleToken {}

/// Checks the Swift key detector against KeyDetectLab's Python reference
/// (`keydetect.py`): both analyse the same deterministic synthetic loop
/// (C – Am – F – G with bass and 2nd harmonics, 4.5 s at 22,050 Hz) and
/// `KeyDetectorReference.json` holds what the reference computed for it.
struct KeyDetectorTests {
    struct Reference: Decodable {
        let frames: Int
        let spectrogram_frame0_first20: [Double]
        let spectrogram_sum: Double
        let features: [[Double]]
        let log_probabilities: [Double]
        let best: Int
    }

    static func reference() throws -> Reference {
        let url = try #require(Bundle(for: TestBundleToken.self).url(forResource: "KeyDetectorReference", withExtension: "json"))
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    /// Same signal as KeyDetectLab `export_for_swift.py` (same operation order).
    static func syntheticLoop() -> [Float] {
        let sr = 22050.0
        let n = Int(4.5 * sr)
        let chords: [(Int, [Int])] = [(36, [60, 64, 67]), (33, [57, 60, 64]), (41, [53, 57, 60]), (43, [55, 59, 62])]
        let toneAmps = [0.20, 0.15, 0.12]
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let (bass, tones) = chords[min(i / 24806, 3)]
            let notes = [(bass, 0.30)] + zip(tones, toneAmps).map { ($0, $1) }
            var v = 0.0
            for (midi, amp) in notes {
                let f0 = 440.0 * pow(2, Double(midi - 69) / 12.0)
                v += amp * sin(2 * Double.pi * f0 * Double(i) / sr) + 0.3 * amp * sin(2 * Double.pi * 2 * f0 * Double(i) / sr)
            }
            x[i] = Float(v)
        }
        return x
    }

    @Test func spectrogramMatchesReference() throws {
        let ref = try Self.reference()
        let spec = LearnedKeyDetector.spectrogram(Self.syntheticLoop())
        #expect(spec.frames == ref.frames)
        for (k, expected) in ref.spectrogram_frame0_first20.enumerated() {
            let got = Double(spec[0, k])
            #expect(abs(got - expected) <= 1e-3 * max(abs(expected), 1e-3), "band \(k): \(got) vs \(expected)")
        }
        let total = spec.values.reduce(0.0) { $0 + Double($1) }
        #expect(abs(total - ref.spectrogram_sum) <= 1e-4 * ref.spectrogram_sum, "sum \(total) vs \(ref.spectrogram_sum)")
    }

    @Test func featuresMatchReference() throws {
        let ref = try Self.reference()
        let features = LearnedKeyDetector.features(LearnedKeyDetector.spectrogram(Self.syntheticLoop()))
        #expect(features.count == ref.features.count)
        var worst = 0.0
        var worstName = ""
        for (f, values) in ref.features.enumerated() {
            for (j, expected) in values.enumerated() {
                let d = abs(Double(features[f][j]) - expected)
                if d > worst { worst = d; worstName = "\(LearnedKeyDetector.featureNames[f])[\(j)]" }
            }
        }
        #expect(worst < 2e-3, "largest descriptor difference \(worst) at \(worstName)")
    }

    @Test func predictionMatchesReference() throws {
        let ref = try Self.reference()
        let lp = try LearnedKeyDetector.logProbabilities(samples: Self.syntheticLoop())
        let worst = zip(lp, ref.log_probabilities).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 2e-2, "largest log-probability difference \(worst)")
        let suggestion = KeyModeSuggestion(logProbabilities: lp)
        #expect(suggestion.key == "C")
        #expect(suggestion.mode == "Major")
        #expect(lp.firstIndex(of: lp.max()!) == ref.best)
        let total = suggestion.candidates.reduce(0) { $0 + $1.probability }
        #expect(abs(total - 1) < 1e-9)
    }

    @Test func silenceIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try LearnedKeyDetector.logProbabilities(samples: [Float](repeating: 0, count: 44100))
        }
    }
}
