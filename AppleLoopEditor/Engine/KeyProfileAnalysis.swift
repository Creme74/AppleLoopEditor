// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

/// Krumhansl–Schmuckler key-profile correlation: a well-established way
/// (Krumhansl & Kessler, 1982) to guess a piece's key from nothing but how
/// much total weight — note duration, or spectral energy — each of the 12
/// pitch classes carries. Used identically by both analysis paths:
/// `StandardMidiFile` builds its histogram from note durations,
/// `AudioChromaAnalyzer` builds one from FFT bin energy — so the actual key
/// guess only needs implementing once.
enum KeyProfileAnalysis {
    /// One of the 24 candidate keys and how well it matched.
    struct Candidate {
        let tonic: Int    // 0 = C, 1 = C#, … 11 = B (matches AppleLoopKeyEncoding.noteNames)
        let isMajor: Bool
        let score: Double // Pearson correlation, -1...1 (higher is a better match)
    }

    // Krumhansl & Kessler's published major/minor key profiles: the average
    // perceived "fit" of each of the 12 pitch classes against a tonic of C,
    // gathered from listener judgments — standard reference values, not
    // specific to any one implementation.
    private static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Ranks all 24 (tonic, major/minor) combinations against `histogram` (a
    /// 12-bin pitch-class weight vector — need not be normalized), best
    /// match first.
    static func rankedCandidates(for histogram: [Double]) -> [Candidate] {
        precondition(histogram.count == 12, "pitch-class histogram must have exactly 12 bins")
        var candidates: [Candidate] = []
        candidates.reserveCapacity(24)
        for tonic in 0..<12 {
            candidates.append(Candidate(tonic: tonic, isMajor: true, score: correlate(histogram, rotate(majorProfile, by: tonic))))
            candidates.append(Candidate(tonic: tonic, isMajor: false, score: correlate(histogram, rotate(minorProfile, by: tonic))))
        }
        return candidates.sorted { $0.score > $1.score }
    }

    /// Rotates a profile (defined starting at C) so index 0 lines up with
    /// `tonic` instead.
    private static func rotate(_ profile: [Double], by tonic: Int) -> [Double] {
        (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
    }

    /// Pearson correlation between two equal-length vectors. Returns 0 for a
    /// degenerate (all-zero, e.g. silent or completely atonal) input rather
    /// than dividing by zero.
    private static func correlate(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var numerator = 0.0
        var denomA = 0.0
        var denomB = 0.0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            numerator += da * db
            denomA += da * da
            denomB += db * db
        }
        let denominator = (denomA * denomB).squareRoot()
        return denominator > 0 ? numerator / denominator : 0
    }
}
