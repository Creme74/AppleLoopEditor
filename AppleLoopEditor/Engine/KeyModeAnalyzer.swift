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

    init(logProbabilities: [Double]) {
        self.logProbabilities = logProbabilities
        candidates = LearnedKeyDetector.rankedCandidates(logProbabilities)
    }
}

/// Suggests a Key + Mode for a loop from its audio, with the detector
/// learned from Apple's own tagged loops (see `LearnedKeyDetector`). Purely
/// suggestive — this never touches the file itself.
public enum KeyModeAnalyzer {
    public static func analyze(url: URL) throws -> KeyModeSuggestion {
        KeyModeSuggestion(logProbabilities: try LearnedKeyDetector.logProbabilities(forFileAt: url))
    }
}
