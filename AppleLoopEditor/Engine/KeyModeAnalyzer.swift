// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

/// The result of a suggestive key/mode analysis. Never applied
/// automatically — the UI writes it into `AudioFile.pendingKey`/`pendingMode`
/// exactly like picking a value from the Key/Scale menus by hand, so it only
/// reaches the file once the user reviews it and clicks Save.
public struct KeyModeSuggestion {
    /// One of `AppleLoopKeyEncoding.noteNames`, or "" if the analysis
    /// couldn't settle on anything (e.g. silent or completely atonal audio).
    public let key: String
    /// "Major" / "Minor" / "Both", or "" alongside an empty `key`.
    public let mode: String
    public let source: Source
    /// The winning candidate's correlation score (-1...1) — not surfaced in
    /// the UI today, kept in case a confidence display is wanted later.
    public let confidence: Double

    public enum Source {
        /// Read from the loop's own embedded MIDI performance (`.mid`
        /// chunk) — only present on software-instrument loops.
        case midiChunk
        /// Estimated from the audio itself (FFT chroma) — used whenever
        /// there's no MIDI performance to read instead.
        case audio
    }
}

/// Suggests a Key + Mode for a loop: reads the loop's own embedded MIDI
/// performance if it has one (exact notes, normally the more reliable
/// signal), otherwise estimates it from the audio. Purely suggestive — this
/// never touches the file itself; callers write the result into
/// `AudioFile.pendingKey`/`pendingMode` themselves, same as any other form
/// edit, so nothing reaches disk before the user hits Save.
public enum KeyModeAnalyzer {
    public struct AnalysisError: Error, LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }

    /// How close the runner-up candidate at the SAME tonic (the parallel
    /// major/minor of the best match — e.g. "C minor" next to a winning "C
    /// major" — not the relative key) has to be before both are offered as
    /// "Both" instead of picking one. Calibrated against real Apple-authored
    /// loops: one Apple tagged "C#, Both" came back C# Minor 0.715 / C#
    /// Major 0.656 (gap 0.06); one tagged "G, Minor" came back G Minor 0.713
    /// / G Major 0.609 (gap 0.10) — just outside this margin, correctly
    /// favoring a single mode.
    private static let ambiguityGapThreshold = 0.1

    public static func analyze(url: URL) throws -> KeyModeSuggestion {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AnalysisError(message: "couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let format = ChunkParser.detectFormat(data) else {
            throw AnalysisError(message: "not a recognized CAF or AIFF file")
        }

        let start: Int
        switch format {
        case .caf: start = data.startIndex + 8
        case .aiff: start = data.startIndex + 12
        }
        let chunks = try ChunkParser.topLevelChunks(in: data, format: format, start: start)

        // A `.mid` chunk (a real embedded Standard MIDI File, confirmed by
        // inspecting real Logic-authored software-instrument loops) is the
        // exact performance that produced the audio — prefer it whenever
        // it's present, and only fall back to estimating from the audio
        // itself when it isn't.
        if let midiChunk = chunks.first(where: { $0.id == ".mid" }) {
            let midiData = data.subdata(in: midiChunk.dataOffset..<midiChunk.dataOffset + midiChunk.dataLength)
            let histogram = try StandardMidiFile.pitchClassHistogram(from: midiData)
            return suggestion(from: KeyProfileAnalysis.rankedCandidates(for: histogram), source: .midiChunk)
        } else {
            let histogram = try AudioChromaAnalyzer.pitchClassHistogram(forFileAt: url)
            return suggestion(from: KeyProfileAnalysis.rankedCandidates(for: histogram), source: .audio)
        }
    }

    private static func suggestion(from candidates: [KeyProfileAnalysis.Candidate], source: KeyModeSuggestion.Source) -> KeyModeSuggestion {
        guard let best = candidates.first, best.score > 0 else {
            return KeyModeSuggestion(key: "", mode: "", source: source, confidence: 0)
        }
        let key = AppleLoopKeyEncoding.noteNames[best.tonic]

        // Look up the OTHER mode at the same tonic — that's what "Both"
        // means in this format: this root works either way, not "the
        // relative key was also a close match".
        if let parallel = candidates.first(where: { $0.tonic == best.tonic && $0.isMajor != best.isMajor }),
           best.score - parallel.score < ambiguityGapThreshold {
            return KeyModeSuggestion(key: key, mode: "Both", source: source, confidence: best.score)
        }

        return KeyModeSuggestion(key: key, mode: best.isMajor ? "Major" : "Minor", source: source, confidence: best.score)
    }
}
