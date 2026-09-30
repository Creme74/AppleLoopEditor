// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation
import AVFoundation
import Accelerate

/// Builds a pitch-class ("chroma") histogram straight from a loop's audio,
/// for the common case where it has no embedded `.mid` performance to read
/// instead — a plain audio recording (drums, a guitar take, anything that
/// didn't start life as a software-instrument performance).
///
/// Decodes with `AVAudioFile` (handles every format Core Audio does: PCM,
/// AAC, ALAC — the formats real Apple Loops actually ship in), then a plain
/// windowed FFT (Accelerate/vDSP) maps each frequency bin to the pitch class
/// it's closest to and accumulates its energy there.
enum AudioChromaAnalyzer {
    struct AnalysisError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let fftSize = 4096
    private static let hopSize = 2048
    private static let minFrequencyHz: Double = 60    // below this is rumble/DC, not a musical pitch
    private static let maxFrequencyHz: Double = 5000  // above this, chroma content is mostly noise/harmonics

    static func pitchClassHistogram(forFileAt url: URL) throws -> [Double] {
        let (samples, sampleRate) = try readMonoSamples(from: url)
        guard samples.count >= fftSize else {
            throw AnalysisError(message: "audio too short to analyze")
        }

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw AnalysisError(message: "couldn't set up FFT")
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Which of the 12 pitch classes each FFT bin (0...fftSize/2) belongs
        // to, or nil for a bin outside the musically useful range — fixed
        // for a given sample rate, so computed once up front.
        let binPitchClass: [Int?] = (0...fftSize / 2).map { bin in
            let freq = Double(bin) * sampleRate / Double(fftSize)
            guard freq >= minFrequencyHz, freq <= maxFrequencyHz else { return nil }
            let midi = 69 + 12 * log2(freq / 440)
            return ((Int(midi.rounded()) % 12) + 12) % 12
        }

        var histogram = [Double](repeating: 0, count: 12)
        var real = [Float](repeating: 0, count: fftSize)
        var imag = [Float](repeating: 0, count: fftSize)
        var frameCount = 0
        var start = 0

        while start + fftSize <= samples.count {
            for i in 0..<fftSize { real[i] = samples[start + i] * window[i] }
            for i in 0..<fftSize { imag[i] = 0 }

            real.withUnsafeMutableBufferPointer { realPtr in
                imag.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                    // Magnitude-squared of each bin, computed directly from
                    // the (now frequency-domain) real/imag arrays rather
                    // than through vDSP_zvmags, to avoid an extra buffer.
                    for bin in 0...fftSize / 2 {
                        guard let pitchClass = binPitchClass[bin] else { continue }
                        let re = realPtr[bin]
                        let im = imagPtr[bin]
                        histogram[pitchClass] += Double(re * re + im * im)
                    }
                }
            }

            start += hopSize
            frameCount += 1
        }

        guard frameCount > 0 else {
            throw AnalysisError(message: "audio too short to analyze")
        }
        return histogram
    }

    /// Decodes `url` to mono Float32 samples at the file's own sample rate.
    /// The app's only other audio access (`AVAudioPlayer`, for preview
    /// playback) never exposes raw samples, so this is written fresh here —
    /// the app's first need for actual PCM access.
    private static func readMonoSamples(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AnalysisError(message: "couldn't open audio: \(error.localizedDescription)")
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard channelCount > 0, file.length > 0, file.length < AVAudioFramePosition(AVAudioFrameCount.max) else {
            throw AnalysisError(message: "empty audio")
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AnalysisError(message: "couldn't allocate audio buffer")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw AnalysisError(message: "couldn't read audio: \(error.localizedDescription)")
        }

        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else {
            throw AnalysisError(message: "empty audio")
        }

        var mono = [Float](repeating: 0, count: frames)
        let gain = 1 / Float(channelCount)
        for c in 0..<channelCount {
            let channelData = channels[c]
            for i in 0..<frames {
                mono[i] += channelData[i] * gain
            }
        }
        return (mono, sampleRate)
    }
}
