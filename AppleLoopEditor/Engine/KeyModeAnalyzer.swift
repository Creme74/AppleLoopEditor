// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

/// The result of a suggestive key/mode analysis. Never applied
/// automatically — the user applies a suggestion by clicking it (or by
/// picking from the Key/Scale menus), and it only reaches the file once
/// they click Save.
public struct KeyModeSuggestion {
    /// All 24 keys, best first (probabilities sum to 1).
    public let candidates: [KeyCandidate]
    /// The model's 24 log-probabilities (index t = t Major, 12 + t = t Minor).
    public let logProbabilities: [Double]
    /// True when the loop's embedded MIDI performance was combined with its
    /// audio (software-instrument loops); false for audio only.
    public let usesMidi: Bool

    public var best: KeyCandidate { candidates[0] }
    /// One of `AppleLoopKeyEncoding.noteNames`.
    public var key: String { best.key }
    /// "Major" or "Minor". The analyzer never suggests "Good for Both" (on
    /// Apple's loops, guessing it lowers agreement with their tags).
    public var mode: String { best.mode }
    public var confidence: Double { best.probability }
    /// Below this, the suggestion is right less than half the time on
    /// Apple's loops (and drums land here) — shown as "low confidence".
    public var isUncertain: Bool { confidence < 0.3 }

    init(logProbabilities: [Double], usesMidi: Bool = false) {
        self.logProbabilities = logProbabilities
        self.usesMidi = usesMidi
        candidates = LearnedKeyDetector.rankedCandidates(logProbabilities)
    }
}

/// Suggests a Key + Mode for a loop from its audio (`LearnedKeyDetector`)
/// and, when the loop carries one, its embedded MIDI performance
/// (`MidiKeyDetector`) — both learned from Apple's own tagged loops. Purely
/// suggestive — this never touches the file itself.
public enum KeyModeAnalyzer {
    public static func analyze(url: URL) throws -> KeyModeSuggestion {
        let midi = MidiKeyDetector.logProbabilities(forFileAt: url)
        let audio: [Double]
        do {
            audio = try LearnedKeyDetector.logProbabilities(forFileAt: url)
        } catch {
            // Silent or unreadable audio: the MIDI performance alone still says something.
            guard let midi else { throw error }
            return KeyModeSuggestion(logProbabilities: midi, usesMidi: true)
        }
        guard let midi else { return KeyModeSuggestion(logProbabilities: audio) }
        // Average of the two log-distributions (a geometric mean, renormalized):
        // on Apple's loops this keeps the shown percentage in line with how
        // often the top pick is right (mean confidence 57 % vs 60 % right),
        // where simply adding them would overstate it (78 %).
        let averaged = zip(audio, midi).map { ($0 + $1) / 2 }
        let m = averaged.max()!
        let logTotal = log(averaged.map { exp($0 - m) }.reduce(0, +)) + m
        return KeyModeSuggestion(logProbabilities: averaged.map { $0 - logTotal }, usesMidi: true)
    }
}
