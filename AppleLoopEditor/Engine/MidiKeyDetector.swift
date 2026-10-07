// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

/// Key detection from a loop's embedded MIDI performance (the Standard MIDI
/// File Logic stores in a CAF 'midi' chunk or an AIFF '.mid' chunk of
/// software-instrument loops). Used together with the audio detector, never
/// on its own: on the 5,462 Apple Loops that carry MIDI (cross-validated by
/// pack) audio alone finds the right tonic 67 % of the time, these learned
/// MIDI profiles 65 %, the two combined 70 % (tonic + mode: 57 → 60 %).
/// The previous analyzer (MIDI + Krumhansl profiles) scored 55 % / 36 %.
///
/// Port of KeyDetectLab `midi_extract.py` + `midi_reference.py`: 7 note
/// statistics per pitch class, then a transposition-equivariant linear
/// model (same weights for each of the 12 tonics).
enum MidiKeyDetector {
    struct Note {
        let start: Int
        let end: Int
        let pitch: Int
        let channel: Int
    }

    /// 24 log-probabilities (index t = t Major, 12 + t = t Minor), or nil if
    /// the file has no usable MIDI performance (none, unreadable, drums only).
    static func logProbabilities(forFileAt url: URL) -> [Double]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let smf = embeddedMidi(in: data),
              let notes = notes(smf),
              let raw = rawFeatures(notes) else { return nil }
        return logProbabilities(rawFeatures: raw)
    }

    /// The embedded Standard MIDI File ('midi' in CAF, '.mid' in AIFF), or nil.
    static func embeddedMidi(in data: Data) -> Data? {
        guard let format = ChunkParser.detectFormat(data) else { return nil }
        let start: Int
        let chunkID: String
        switch format {
        case .caf: start = data.startIndex + 8; chunkID = "midi"
        case .aiff: start = data.startIndex + 12; chunkID = ".mid"
        }
        guard let chunks = try? ChunkParser.topLevelChunks(in: data, format: format, start: start),
              let chunk = chunks.first(where: { $0.id == chunkID }),
              chunk.dataLength >= 14 else { return nil }
        let smf = data.subdata(in: chunk.dataOffset..<chunk.dataOffset + chunk.dataLength)
        return Array(smf.prefix(4)) == Array("MThd".utf8) ? smf : nil
    }

    private struct OutOfData: Error {}

    /// Every note that has both a Note On and a Note Off (a Note On with
    /// velocity 0 counts as Note Off), all tracks, in the order they end.
    /// nil for malformed data.
    static func notes(_ smf: Data) -> [Note]? {
        let b = [UInt8](smf)
        func byte(_ k: Int) throws -> UInt8 {
            guard k >= 0, k < b.count else { throw OutOfData() }
            return b[k]
        }
        func be(_ k: Int, _ count: Int) throws -> Int {
            var v = 0
            for i in 0..<count {
                let x = try byte(k + i)
                v = (v << 8) | Int(x)
            }
            return v
        }
        func variableLength(_ j: inout Int) throws -> Int {
            var v = 0
            while true {
                let x = try byte(j); j += 1
                v = (v << 7) | Int(x & 0x7F)
                if x < 0x80 { return v }
            }
        }
        do {
            guard b.count >= 14, Array(b[0..<4]) == Array("MThd".utf8) else { return nil }
            let headerLength = try be(4, 4)
            let trackCount = try be(10, 2)
            var i = 8 + headerLength
            var out: [Note] = []
            for _ in 0..<trackCount {
                guard i + 8 <= b.count, Array(b[i..<(i + 4)]) == Array("MTrk".utf8) else { break }
                let length = try be(i + 4, 4)
                var j = i + 8
                let end = j + length
                var tick = 0
                var runningStatus: UInt8?
                var active: [Int: Int] = [:]
                trackLoop: while j < end {
                    tick += try variableLength(&j)
                    var status = try byte(j)
                    if status & 0x80 != 0 {
                        j += 1
                        runningStatus = status
                    } else {
                        guard let rs = runningStatus else { return nil }
                        status = rs
                    }
                    let high = status & 0xF0
                    let channel = Int(status & 0x0F)
                    switch high {
                    case 0x80, 0x90:
                        let pitchByte = try byte(j)
                        let pitch = Int(pitchByte)
                        let velocity = try byte(j + 1)
                        j += 2
                        let key = channel << 8 | pitch
                        if high == 0x90 && velocity > 0 {
                            active[key] = tick
                        } else if let s = active.removeValue(forKey: key) {
                            out.append(Note(start: s, end: tick, pitch: pitch, channel: channel))
                        }
                    case 0xA0, 0xB0, 0xE0:
                        j += 2
                    case 0xC0, 0xD0:
                        j += 1
                    default:
                        if status == 0xFF {
                            j += 1
                            let l = try variableLength(&j); j += l
                        } else if status == 0xF0 || status == 0xF7 {
                            let l = try variableLength(&j); j += l
                        } else {
                            break trackLoop
                        }
                    }
                }
                i = end
            }
            return out
        } catch {
            return nil
        }
    }

    /// 7 × 12 raw statistics (pitched notes only, GM drum channel 10
    /// ignored): note durations, note counts, durations below E3 (bass),
    /// notes starting at the first onset, at the last onset, the lowest
    /// note, and the bass line (lowest sounding note at each onset, weighted
    /// by its duration). nil if there is no pitched note.
    static func rawFeatures(_ allNotes: [Note]) -> [[Double]]? {
        let notes = allNotes.filter { $0.channel != 9 }
        guard !notes.isEmpty else { return nil }
        var f = [[Double]](repeating: [Double](repeating: 0, count: 12), count: 7)
        let firstOnset = notes.map(\.start).min()!
        let lastOnset = notes.map(\.start).max()!
        let lowest = notes.map(\.pitch).min()!
        for n in notes {
            let length = Double(max(n.end - n.start, 1))
            let pc = n.pitch % 12
            f[0][pc] += length
            f[1][pc] += 1
            if n.pitch < 52 { f[2][pc] += length }
            if n.start == firstOnset { f[3][pc] += 1 }
            if n.start == lastOnset { f[4][pc] += 1 }
        }
        f[5][lowest % 12] = 1
        for onset in Set(notes.map(\.start)).sorted() {
            var sounding = notes.filter { $0.start <= onset && onset < $0.end }
            if sounding.isEmpty { sounding = notes.filter { $0.start == onset } }
            var bassNote = sounding[0]
            for n in sounding where n.pitch < bassNote.pitch { bassNote = n }
            f[6][bassNote.pitch % 12] += Double(max(bassNote.end - bassNote.start, 1))
        }
        return f
    }

    static func logProbabilities(rawFeatures raw: [[Double]]) -> [Double] {
        var X = [[Double]](repeating: [Double](repeating: 0, count: 12), count: raw.count)
        for (k, row) in raw.enumerated() {
            let total = row.reduce(0, +) + 1e-9
            let normalized = row.map { $0 / total }
            let mean = normalized.reduce(0, +) / 12
            X[k] = normalized.map { ($0 - mean) / Double(featureStd[k]) }
        }
        var z = [Double](repeating: 0, count: 24)
        for t in 0..<12 {
            var major = Double(biases[0]), minor = Double(biases[1])
            for k in 0..<raw.count {
                for j in 0..<12 {
                    let v = X[k][(j + t) % 12]
                    major += v * Double(weightsMajor[k * 12 + j])
                    minor += v * Double(weightsMinor[k * 12 + j])
                }
            }
            z[t] = major; z[12 + t] = minor
        }
        let m = z.max()!
        let logTotal = log(z.map { exp($0 - m) }.reduce(0, +)) + m
        return z.map { $0 - logTotal }
    }

    /// Trained by KeyDetectLab `midi_final.py` on the 5,462 keyed Apple Loops
    /// that carry a MIDI performance (equivariant linear model).
    static let featureStd: [Float] = [
            0.1451610994473026, 0.13857799294229467, 0.1542557953418298, 0.2521866693342483,
            0.26239969310353495, 0.27638539891990893, 0.17681770332852337,
        ]
    static let weightsMajor: [Float] = [
            0.48170688985438115, -0.2566433845729637, -0.0683006031204205, -0.2810842037242281, 0.21045242684552917, 0.09588312813088759,
            -0.3516556607716005, 0.33735774308492816, -0.14015799434344586, 0.10485619251341757, -0.13987358617640697, 0.007459052279927053,
            0.31795976177844176, -0.24020001467841295, 0.06459583621448406, -0.3604369714062871, 0.35810805366499054, 0.1949691294704355,
            -0.3323275685510912, 0.2929014614085371, -0.2471770719176663, 0.16693050470635037, -0.22472413004025138, 0.00940100935048722,
            0.2097550317466949, 0.08793823071298956, -0.006804923698731124, -4.163279276597812e-05, -0.22528199492712192, 0.05765720805297146,
            0.1268020279885395, -0.1763340792010121, 0.020650180312153057, 0.03053588992067729, -0.06687634054272305, -0.05799959757166879,
            0.2723654187174138, -0.12108765245206958, -0.06619531773879335, 0.06503373636637017, 0.11363705808758236, -0.08453839526536272,
            -0.07119164122509995, 0.08360089306384476, -0.12272286922546598, -0.08203206233247319, -0.017423491638420767, 0.030554323642481847,
            0.07706849677967731, -0.061531764997774935, 0.08434229552920323, -0.10421885713719373, -0.002723765385066805, 0.05620837748990288,
            -0.02685870105506209, 0.07330360539158363, -0.09698705344601874, -0.016227016980110774, -0.05530217984755184, 0.07292656365841894,
            0.0650797191858592, -0.05008744990340726, 0.03141454170645777, 0.011698974982996315, 0.06757895282874984, 0.011680388555601467,
            -0.05510545523264953, 0.12095279284773812, -0.14709280446292916, -0.011431713879332344, -0.04711970164340686, 0.0024317550143112387,
            0.05713852845617983, -0.1324522509489612, -0.06424174937282819, 0.029253868421106447, -0.03388202685508652, 0.08462116200221634,
            -0.10136684772160219, 0.09100334880715252, -0.0471035067636873, -0.037188161916845194, 0.16061509177037542, -0.006397455878015115,
        ]
    static let weightsMinor: [Float] = [
            0.25210130997458013, -0.18521447351580608, 0.1370193857649138, 0.21539396027786128, -0.4208283709803775, 0.05094585520046344,
            -0.19014240889882889, 0.31311922442198475, 0.046359813253760256, -0.20993593157743565, 0.02211010291578917, -0.030928466836884206,
            0.38623472401516684, -0.3690450044079666, 0.07520670209806765, 0.5131046167545215, -0.6083796602328825, 0.10111528404340964,
            -0.2814183981835801, 0.4087816234925397, 0.02542616233648667, -0.4867191669902565, 0.2606934804578705, -0.025000363383381168,
            0.15326476010568627, -0.00373299801813154, -0.16290484630283392, 0.03749786707994299, -0.025161756294205258, 0.07310367063030582,
            0.10433705419637139, -0.1313441109395965, 0.14173390837324754, -0.09970586780945019, -0.05092282295824185, -0.0361648580630891,
            0.32504091938621466, -0.005205706879725802, -0.10987764280831497, 0.07527359540004248, -0.005556201058051441, -0.06310101876276798,
            -0.09847200946193914, 0.06344042332853185, 0.07218337047324011, -0.1195928044594334, 0.012341643969974087, -0.14647456912775209,
            0.10694559087728578, -0.04954809108647096, 0.00818099647910753, -0.011244910511476776, -0.03636771925062421, 0.012560376220917905,
            -0.07310931803656676, 0.0875601419346104, -0.05431518985405579, -0.12403887749029556, 0.05060577569521101, 0.08277122502235236,
            0.07325301961827174, -0.08149252957417465, 0.004684062877025908, -0.07128148680507067, -0.03434658634807576, 0.021721771331645826,
            -0.10480855512660028, 0.08308973450506668, -0.011565011178373604, 0.08129142797892432, 0.012885840592764153, 0.026568312128607455,
            0.17163885973727058, -0.14362935743633012, -0.0817107157819324, -0.07236906455476047, -0.0656264987075301, -0.007300879346919102,
            0.009770617293430116, 0.052805597587999326, 0.06680803845729522, 0.01863770334996158, 0.08808550761120777, -0.03710980820968335,
        ]
    static let biases: [Float] = [
            0.027810093335801513, -0.027810093335802175,
        ]
}
