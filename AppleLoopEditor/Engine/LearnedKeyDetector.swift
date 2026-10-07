// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation
import AVFoundation
import Accelerate

/// One of the 24 candidate keys, with the model's probability for it.
public struct KeyCandidate: Equatable {
    /// One of `AppleLoopKeyEncoding.noteNames`.
    public let key: String
    /// "Major" or "Minor" (the app's internal scale names).
    public let mode: String
    public let probability: Double
}

/// Key detector learned from Apple's own tagged loops (KeyDetectLab, model v1).
///
/// Cross-validated on 20,234 Apple Loops (5 folds grouped by pack, so a pack
/// is never seen in training when it is tested): right tonic 61 % of the
/// time (vs 35 % for the previous Krumhansl-profile analyzer), right tonic
/// AND mode 52 % (vs 20 %), right tonic among the top 3 suggestions 86 %.
///
/// Pipeline — a line-for-line port of KeyDetectLab's `keydetect.py`, which is
/// the reference implementation (the unit test checks this port against it):
///  1. decode → mono → 22,050 Hz, first 60 s at most;
///  2. STFT (symmetric Hann, 16,384 points, hop 8,192); the power spectrum is
///     integrated between the edges of 252 log-frequency bands (36 per
///     octave from C1 = 32.7032 Hz);
///  3. per-file tuning (±1/3 semitone), energy per semitone (84, C1…B7);
///  4. 36 twelve-value descriptors (registers, harmonic/peak variants,
///     lowest-note histograms, start/end of the loop, chord-root histograms);
///  5. a small transposition-equivariant network (the same weights score
///     each of the 12 tonics; 3 seeds averaged) → 24 log-probabilities.
enum LearnedKeyDetector {
    struct AnalysisError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let sampleRate: Double = 22050
    static let fftSize = 16384
    static let hopSize = 8192
    static let maxSeconds: Double = 60
    static let bandsPerOctave = 36
    static let bandCount = 252
    static let lowestBandHz = 32.7032
    static let semitoneCount = 84

    /// Descriptor order the model was trained with (KeyDetectLab `FULL`).
    static let featureNames = [
        "raw_mix", "harm_mix", "peak_mix", "raw_bass", "harm_bass", "peak_bass", "lownote", "raw_mid", "firstq",
        "salw_mix", "dompc", "lown_sub", "lown_b2", "lown_b3", "bass_first", "bass_last", "bass_loud", "lownote_w",
        "first_mix", "maxchroma", "sqrtmix", "bass_energy", "mix_first2", "mix_last2", "mid_first", "mid_last",
        "chordM_mix", "chordm_mix", "chordM_harm", "chordm_harm", "chordM_first_mix", "chordm_first_mix",
        "chordM_last_mix", "chordm_last_mix", "chord_bass_M", "chord_bass_m",
    ]

    // MARK: - Public entry points

    /// 24 log-probabilities for `url` (index t = tonic t Major, 12 + t = tonic t Minor).
    static func logProbabilities(forFileAt url: URL) throws -> [Double] {
        try logProbabilities(samples: decodeMono(url: url))
    }

    /// Same, for mono samples already at `sampleRate`.
    static func logProbabilities(samples: [Float]) throws -> [Double] {
        let limit = Int(sampleRate * maxSeconds)
        let x = samples.count > limit ? Array(samples[0..<limit]) : samples
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count))
        guard !x.isEmpty, peak > 1e-5 else {
            throw AnalysisError(message: "audio is silent")
        }
        let spec = spectrogram(x)
        return try KeyModel.shared().logProbabilities(features(spec))
    }

    /// Candidates sorted best-first, with probabilities renormalized from
    /// `logProbabilities` (softmax).
    static func rankedCandidates(_ logProbabilities: [Double]) -> [KeyCandidate] {
        let m = logProbabilities.max() ?? 0
        let e = logProbabilities.map { exp($0 - m) }
        let total = e.reduce(0, +)
        return (0..<24).map { i in
            KeyCandidate(key: AppleLoopKeyEncoding.noteNames[i % 12],
                         mode: i < 12 ? "Major" : "Minor",
                         probability: e[i] / total)
        }
        .sorted { $0.probability > $1.probability }
    }

    // MARK: - 1. Decoding

    /// Decodes `url` (anything Core Audio reads: PCM, AAC, ALAC…) to mono
    /// Float32 at 22,050 Hz, first 60 s only.
    static func decodeMono(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AnalysisError(message: "couldn't open audio: \(error.localizedDescription)")
        }
        let format = file.processingFormat
        let inRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let maxFrames = AVAudioFramePosition((inRate * maxSeconds).rounded(.up)) + 4096
        let frameCount = min(file.length, maxFrames)
        guard channelCount > 0, frameCount > 0, inRate > 0 else {
            throw AnalysisError(message: "empty audio")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw AnalysisError(message: "couldn't allocate audio buffer")
        }
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
        } catch {
            throw AnalysisError(message: "couldn't read audio: \(error.localizedDescription)")
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else {
            throw AnalysisError(message: "empty audio")
        }

        // Plain average of the channels (scale doesn't matter downstream).
        var mono = [Float](repeating: 0, count: frames)
        var gain = 1 / Float(channelCount)
        mono.withUnsafeMutableBufferPointer { m in
            let p = m.baseAddress!
            for c in 0..<channelCount {
                vDSP_vadd(p, 1, channels[c], 1, p, 1, vDSP_Length(frames))
            }
            vDSP_vsmul(p, 1, &gain, p, 1, vDSP_Length(frames))
        }

        if abs(inRate - sampleRate) < 0.5 { return mono }
        return try resample(mono, from: inRate)
    }

    private static func resample(_ mono: [Float], from inRate: Double) throws -> [Float] {
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inRate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(mono.count)) else {
            throw AnalysisError(message: "couldn't set up resampling")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: mono.count)
        }

        let chunk = AVAudioFrameCount(65536)
        var output: [Float] = []
        output.reserveCapacity(Int(Double(mono.count) * sampleRate / inRate) + 1024)
        var inputGiven = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else {
                throw AnalysisError(message: "couldn't allocate resampling buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
                if inputGiven {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputGiven = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                throw AnalysisError(message: "resampling failed: \(conversionError?.localizedDescription ?? "unknown error")")
            }
            let n = Int(out.frameLength)
            if n > 0 {
                output.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: n))
            }
            if status == .endOfStream || (status == .inputRanDry && n == 0) { break }
        }
        return output
    }

    // MARK: - 2. Log-frequency spectrogram

    /// Row-major frames × 252 magnitude matrix.
    struct Spectrogram {
        let frames: Int
        var values: [Float]
        subscript(frame: Int, band: Int) -> Float { values[frame * bandCount + band] }
    }

    static func spectrogram(_ samples: [Float]) -> Spectrogram {
        var x = samples
        if x.count < fftSize { x += [Float](repeating: 0, count: fftSize - x.count) }
        let frameCount = 1 + (x.count - fftSize) / hopSize
        let half = fftSize / 2
        let log2n = vDSP_Length(14)   // 2^14 = 16384
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }

        // numpy.hanning: symmetric Hann window.
        let window = (0..<fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize - 1))) }

        // Band edges as fractional FFT-bin positions, clipped to the cumulative array.
        let binHz = sampleRate / Double(fftSize)
        let cumCount = half + 2                 // [0, cumsum(power[0...half])]
        let edges: [(lo: Int, hi: Int, frac: Double)] = (0...bandCount).map { k in
            var pos = lowestBandHz * pow(2, (Double(k) - 0.5) / Double(bandsPerOctave)) / binHz
            pos = min(max(pos, 0), Double(cumCount - 1))
            let lo = Int(pos.rounded(.down))
            return (lo, min(lo + 1, cumCount - 1), pos - Double(lo))
        }

        var values = [Float](repeating: 0, count: frameCount * bandCount)
        var frame = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var cumulative = [Double](repeating: 0, count: cumCount)

        for f in 0..<frameCount {
            x.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + f * hopSize, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
            }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            // vDSP_fft_zrip returns 2× the DFT; DC sits in real[0], Nyquist in imag[0].
            // The model was trained on float32 power and a float32 running sum
            // (numpy 2 FFTs float32 input in float32), so this accumulates in
            // Float on purpose; only the band interpolation below is Double.
            var running: Float = 0
            cumulative[0] = 0
            for bin in 0...half {
                let power: Float
                if bin == 0 {
                    let v = real[0] * 0.5; power = v * v
                } else if bin == half {
                    let v = imag[0] * 0.5; power = v * v
                } else {
                    let re = real[bin] * 0.5, im = imag[bin] * 0.5
                    power = re * re + im * im
                }
                running += power
                cumulative[bin + 1] = Double(running)
            }
            var previous = cumulative[edges[0].lo] * (1 - edges[0].frac) + cumulative[edges[0].hi] * edges[0].frac
            for k in 0..<bandCount {
                let e = edges[k + 1]
                let next = cumulative[e.lo] * (1 - e.frac) + cumulative[e.hi] * e.frac
                values[f * bandCount + k] = Float(max(next - previous, 0).squareRoot())
                previous = next
            }
        }
        return Spectrogram(frames: frameCount, values: values)
    }

    // MARK: - 3–4. Descriptors

    /// Small row-major matrix helper (rows = frames).
    struct Rows {
        let count: Int
        let width: Int
        var data: [Float]
        init(count: Int, width: Int) {
            self.count = count; self.width = width
            data = [Float](repeating: 0, count: count * width)
        }
        subscript(r: Int, c: Int) -> Float {
            get { data[r * width + c] }
            set { data[r * width + c] = newValue }
        }
        func row(_ r: Int) -> ArraySlice<Float> { data[(r * width)..<((r + 1) * width)] }
    }

    /// The 36 descriptors, in `featureNames` order, 12 values each.
    static func features(_ spec: Spectrogram) -> [[Float]] {
        let n = spec.frames
        let nb = bandCount

        // Tuning: phase of the energy over the 3 bands of each semitone (65 Hz–2 kHz).
        var sinSum = 0.0, cosSum = 0.0
        for k in 36..<216 {
            var a: Float = 0
            for f in 0..<n { let v = spec[f, k]; a += v * v }
            let angle = 2 * Double.pi * Double(k) / 3
            sinSum += Double(a) * sin(angle); cosSum += Double(a) * cos(angle)
        }
        let phase = atan2(sinSum, cosSum) / (2 * Double.pi) * 3
        let tune = Int(min(max(phase, -1), 1).rounded(.toNearestOrEven))

        // Band-domain variants: S² (raw energy), peak (whitened) and harmonic sums, each raised so
        // that the semitone sums below match the reference exactly.
        var sm = [Float](repeating: 0, count: n * nb)
        for i in 0..<(n * nb) { sm[i] = spec.values[i].squareRoot() }

        var rawPower = [Float](repeating: 0, count: n * nb)
        var peakPower = [Float](repeating: 0, count: n * nb)
        var harmPower = [Float](repeating: 0, count: n * nb)
        let harmonicShifts = (1...6).map { Int((36 * log2(Double($0))).rounded()) }
        var extended = [Double](repeating: 0, count: nb + 72)
        for f in 0..<n {
            let base = f * nb
            for k in 0..<nb { let v = spec.values[base + k]; rawPower[base + k] = v * v }

            // scipy uniform_filter1d(size 72, mode "reflect"): mean of [k-36, k+35].
            var running = 0.0
            extended[0] = 0
            for j in 0..<(nb + 71) {
                var idx = j - 36
                if idx < 0 { idx = -idx - 1 }
                if idx >= nb { idx = 2 * nb - idx - 1 }
                running += Double(sm[base + idx])
                extended[j + 1] = running
            }
            for k in 0..<nb {
                let mean = Float((extended[k + 72] - extended[k]) / 72)
                let p = max(sm[base + k] - mean, 0)
                let p2 = p * p
                peakPower[base + k] = p2 * p2
            }

            for k in 0..<nb {
                var h: Float = 0
                for (i, shift) in harmonicShifts.enumerated() where k + shift < nb {
                    h += Float(pow(0.8, Double(i))) * sm[base + k + shift]
                }
                let h2 = h * h
                harmPower[base + k] = h2 * h2
            }
        }

        let M = semitoneMagnitudes(rawPower, frames: n, tune: tune)
        let Mp = semitoneMagnitudes(peakPower, frames: n, tune: tune)
        let Mh = semitoneMagnitudes(harmPower, frames: n, tune: tune)

        var out: [String: [Float]] = [:]
        for (tag, X) in [("raw", M), ("peak", Mp), ("harm", Mh)] {
            out["\(tag)_mix"] = meanRows(normalized(fold(X, 12, 84)))
            out["\(tag)_bass"] = meanRows(normalized(fold(X, 12, 36)))
            out["\(tag)_mid"] = meanRows(normalized(fold(X, 36, 60)))
        }
        let Cn = normalized(fold(M, 12, 84))
        let bassFold = fold(M, 12, 36)
        let Bs = normalized(bassFold)
        let Mid = normalized(fold(M, 36, 60))

        out["first_mix"] = Array(Cn.row(0))
        out["lownote"] = meanRows(lowestNote(M, 12, 36, weighted: false))
        out["lown_sub"] = meanRows(lowestNote(M, 0, 24, weighted: false))
        out["lown_b2"] = meanRows(lowestNote(M, 12, 36, weighted: false))
        out["lown_b3"] = meanRows(lowestNote(M, 24, 48, weighted: false))

        // Salience-weighted chroma (peaky frames count more), dominant pitch class, max, sqrt.
        var salience = [Float](repeating: 0, count: n)
        var dominant = Rows(count: n, width: 12)
        for r in 0..<n {
            let row = Cn.row(r)
            let mx = row.max() ?? 0
            salience[r] = mx / (row.reduce(0, +) / 12 + 1e-9)
            dominant[r, firstArgmax(row)] = 1
        }
        let salienceTotal = salience.reduce(0, +)
        var salw = [Float](repeating: 0, count: 12)
        var maxChroma = [Float](repeating: -.infinity, count: 12)
        var sqrtSum = [Float](repeating: 0, count: 12)
        for r in 0..<n {
            let w = salience[r] / salienceTotal
            for c in 0..<12 {
                let v = Cn[r, c]
                salw[c] += v * w
                maxChroma[c] = max(maxChroma[c], v)
                sqrtSum[c] += v.squareRoot()
            }
        }
        out["salw_mix"] = salw
        out["dompc"] = meanRows(dominant)
        out["maxchroma"] = maxChroma
        out["sqrtmix"] = sqrtSum.map { $0 / Float(n) }
        out["firstq"] = meanRows(Cn, 0..<max(1, n / 4))

        var bassTotal = [Float](repeating: 0, count: 12)
        var bassEnergy = [Float](repeating: 0, count: n)
        for r in 0..<n {
            for c in 0..<12 { bassTotal[c] += bassFold[r, c]; bassEnergy[r] += bassFold[r, c] }
        }
        let bassSum = bassTotal.reduce(0, +)
        out["bass_energy"] = bassTotal.map { $0 / (bassSum + 1e-9) }

        let first2 = 0..<min(2, n)
        let last2 = max(0, n - 2)..<n
        out["bass_first"] = meanRows(Bs, first2); out["bass_last"] = meanRows(Bs, last2)
        out["mix_first2"] = meanRows(Cn, first2); out["mix_last2"] = meanRows(Cn, last2)
        out["mid_first"] = meanRows(Mid, first2); out["mid_last"] = meanRows(Mid, last2)

        // Bass chroma of the loudest quarter of frames (numpy quantile, linear interpolation).
        let sortedEnergy = bassEnergy.map(Double.init).sorted()
        let position = 0.75 * Double(n - 1)
        let lo = Int(position.rounded(.down)), hi = min(lo + 1, n - 1)
        let threshold = sortedEnergy[lo] + (sortedEnergy[hi] - sortedEnergy[lo]) * (position - Double(lo))
        var loud = [Float](repeating: 0, count: 12)
        var loudCount = 0
        for r in 0..<n where Double(bassEnergy[r]) >= threshold {
            loudCount += 1
            for c in 0..<12 { loud[c] += Bs[r, c] }
        }
        out["bass_loud"] = loud.map { $0 / Float(max(loudCount, 1)) }

        let weightedLow = lowestNote(M, 12, 36, weighted: true)
        var lw = [Float](repeating: 0, count: 12)
        for r in 0..<n { for c in 0..<12 { lw[c] += weightedLow[r, c] } }
        let lwSum = lw.reduce(0, +)
        out["lownote_w"] = lw.map { $0 / (lwSum + 1e-9) }

        // Chord-root histograms (soft triad matching per frame).
        let Charm = normalized(fold(Mh, 12, 84))
        for (tag, C) in [("mix", Cn), ("harm", Charm)] {
            let P = chordProbabilities(C)
            out["chordM_\(tag)"] = meanRows(P, 0..<n, columns: 0..<12)
            out["chordm_\(tag)"] = meanRows(P, 0..<n, columns: 12..<24)
            out["chordM_first_\(tag)"] = meanRows(P, first2, columns: 0..<12)
            out["chordm_first_\(tag)"] = meanRows(P, first2, columns: 12..<24)
            out["chordM_last_\(tag)"] = meanRows(P, last2, columns: 0..<12)
            out["chordm_last_\(tag)"] = meanRows(P, last2, columns: 12..<24)
        }
        var chordBassMajor = [Float](repeating: 0, count: 12)
        var chordBassMinor = [Float](repeating: 0, count: 12)
        for r in 0..<n {
            let (maj, mnr) = triads(Cn.row(r))
            for c in 0..<12 {
                chordBassMajor[c] += maj[c] * Bs[r, c]
                chordBassMinor[c] += mnr[c] * Bs[r, c]
            }
        }
        out["chord_bass_M"] = chordBassMajor.map { $0 / Float(n) }
        out["chord_bass_m"] = chordBassMinor.map { $0 / Float(n) }

        return featureNames.map { out[$0]! }
    }

    /// Energy per semitone (3 bands centred on 3m + tune, wrapping like numpy.roll), square-rooted.
    private static func semitoneMagnitudes(_ power: [Float], frames n: Int, tune: Int) -> Rows {
        var M = Rows(count: n, width: semitoneCount)
        for f in 0..<n {
            let base = f * bandCount
            for m in 0..<semitoneCount {
                var s: Float = 0
                for j in 0..<3 {
                    let idx = ((3 * m + j - 1 + tune) % bandCount + bandCount) % bandCount
                    s += power[base + idx]
                }
                M[f, m] = s.squareRoot()
            }
        }
        return M
    }

    /// Folds semitones [a, b) onto 12 pitch classes (semitone 0 = C1).
    private static func fold(_ M: Rows, _ a: Int, _ b: Int) -> Rows {
        var out = Rows(count: M.count, width: 12)
        for r in 0..<M.count {
            for m in a..<b { out[r, m % 12] += M[r, m] }
        }
        return out
    }

    private static func normalized(_ C: Rows) -> Rows {
        var out = C
        for r in 0..<C.count {
            let s = C.row(r).reduce(0, +) + 1e-9
            for c in 0..<C.width { out[r, c] = C[r, c] / s }
        }
        return out
    }

    private static func meanRows(_ C: Rows, _ rows: Range<Int>? = nil, columns: Range<Int>? = nil) -> [Float] {
        let rr = rows ?? 0..<C.count
        let cc = columns ?? 0..<C.width
        var out = [Float](repeating: 0, count: cc.count)
        for r in rr { for (i, c) in cc.enumerated() { out[i] += C[r, c] } }
        return out.map { $0 / Float(rr.count) }
    }

    /// Index of the first maximum (numpy.argmax semantics).
    private static func firstArgmax(_ v: ArraySlice<Float>) -> Int {
        var best = v.startIndex
        for i in v.indices where v[i] > v[best] { best = i }
        return best - v.startIndex
    }

    /// Per frame, the loudest semitone in [a, b) as a one-hot pitch class (or weighted by its level).
    private static func lowestNote(_ M: Rows, _ a: Int, _ b: Int, weighted: Bool) -> Rows {
        var out = Rows(count: M.count, width: 12)
        for r in 0..<M.count {
            let slice = M.data[(r * M.width + a)..<(r * M.width + b)]
            let am = firstArgmax(slice)
            let mx = slice[slice.startIndex + am]
            out[r, (am + a) % 12] = weighted ? mx : (mx > 0 ? 1 : 0)
        }
        return out
    }

    private static func triads(_ row: ArraySlice<Float>) -> (major: [Float], minor: [Float]) {
        let c = Array(row)
        var maj = [Float](repeating: 0, count: 12), mnr = [Float](repeating: 0, count: 12)
        for r in 0..<12 {
            maj[r] = c[r] + c[(r + 4) % 12] + c[(r + 7) % 12]
            mnr[r] = c[r] + c[(r + 3) % 12] + c[(r + 7) % 12]
        }
        return (maj, mnr)
    }

    /// Per frame: standardized triad scores → softmax(2·score) over 12 major + 12 minor chords.
    private static func chordProbabilities(_ C: Rows) -> Rows {
        var P = Rows(count: C.count, width: 24)
        for r in 0..<C.count {
            let (maj, mnr) = triads(C.row(r))
            let s = maj + mnr
            let mean = s.reduce(0, +) / 24
            let std = (s.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 24).squareRoot()
            let z = s.map { ($0 - mean) / (std + 1e-9) * 2 }
            let zMax = z.max() ?? 0
            let e = z.map { exp($0 - zMax) }
            let total = e.reduce(0, +)
            for i in 0..<24 { P[r, i] = e[i] / total }
        }
        return P
    }
}

/// The trained network (bundled resource `KeyModel_v1.bin`, exported by
/// KeyDetectLab `export_for_swift.py`): "KDM1", UInt32 nets, features,
/// hidden; then Float32 little-endian std[features] and, per net, W1
/// [features·12 × hidden], b1[hidden], V[hidden × 2], c[2].
final class KeyModel {
    let featureCount: Int
    let hidden: Int
    let featureStd: [Float]
    let nets: [(w1: [Float], b1: [Float], v: [Float], c: [Float])]

    private static let loaded: Result<KeyModel, Error> = Result {
        let bundle = Bundle(for: KeyModel.self)
        guard let url = bundle.url(forResource: "KeyModel_v1", withExtension: "bin")
                ?? Bundle.main.url(forResource: "KeyModel_v1", withExtension: "bin") else {
            throw LearnedKeyDetector.AnalysisError(message: "key model resource missing from the app bundle")
        }
        return try KeyModel(data: Data(contentsOf: url))
    }

    static func shared() throws -> KeyModel { try loaded.get() }

    init(data: Data) throws {
        func fail() -> Error { LearnedKeyDetector.AnalysisError(message: "key model resource is corrupt") }
        guard data.count >= 16, String(data: data.prefix(4), encoding: .ascii) == "KDM1" else { throw fail() }
        let header = data.subdata(in: 4..<16).withUnsafeBytes { raw in
            (0..<3).map { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        let netCount = header[0]
        featureCount = header[1]
        hidden = header[2]
        let inputs = featureCount * 12
        let perNet = inputs * hidden + hidden + hidden * 2 + 2
        let floatCount = featureCount + netCount * perNet
        guard featureCount == LearnedKeyDetector.featureNames.count, netCount > 0,
              data.count == 16 + floatCount * 4 else { throw fail() }
        let floats: [Float] = data.subdata(in: 16..<data.count).withUnsafeBytes { raw in
            (0..<floatCount).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        featureStd = Array(floats[0..<featureCount])
        var cursor = featureCount
        func take(_ count: Int) -> [Float] {
            defer { cursor += count }
            return Array(floats[cursor..<(cursor + count)])
        }
        var loadedNets: [(w1: [Float], b1: [Float], v: [Float], c: [Float])] = []
        for _ in 0..<netCount {
            loadedNets.append((take(inputs * hidden), take(hidden), take(hidden * 2), take(2)))
        }
        nets = loadedNets
    }

    /// Averaged log-softmax over the ensemble: index t = tonic t Major, 12 + t = tonic t Minor.
    func logProbabilities(_ features: [[Float]]) -> [Double] {
        let inputs = featureCount * 12
        // Centre each descriptor, scale by its training std.
        var X = [Float](repeating: 0, count: inputs)
        for f in 0..<featureCount {
            let v = features[f]
            let mean = v.reduce(0, +) / 12
            for j in 0..<12 { X[f * 12 + j] = (v[j] - mean) / featureStd[f] }
        }
        // Row t = the descriptors seen from tonic t: R[t][f·12 + j] = X[f][(j + t) % 12].
        var R = [Float](repeating: 0, count: 12 * inputs)
        for t in 0..<12 {
            for f in 0..<featureCount {
                for j in 0..<12 { R[t * inputs + f * 12 + j] = X[f * 12 + (j + t) % 12] }
            }
        }
        var average = [Double](repeating: 0, count: 24)
        var hiddenOut = [Float](repeating: 0, count: 12 * hidden)
        for net in nets {
            vDSP_mmul(R, 1, net.w1, 1, &hiddenOut, 1, 12, vDSP_Length(hidden), vDSP_Length(inputs))
            var z = [Double](repeating: 0, count: 24)
            for t in 0..<12 {
                var major = Double(net.c[0]), minor = Double(net.c[1])
                for h in 0..<hidden {
                    let a = max(hiddenOut[t * hidden + h] + net.b1[h], 0)
                    major += Double(a * net.v[h * 2])
                    minor += Double(a * net.v[h * 2 + 1])
                }
                z[t] = major; z[12 + t] = minor
            }
            let m = z.max()!
            let logTotal = log(z.map { exp($0 - m) }.reduce(0, +)) + m
            for i in 0..<24 { average[i] += (z[i] - logTotal) / Double(nets.count) }
        }
        return average
    }
}
