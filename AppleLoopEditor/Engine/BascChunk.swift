// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

/// Legacy AIFF 'basc' chunk. Fixed 16-byte header, then a variable-length
/// filler whose meaning is unconfirmed and whose length is NOT fixed across
/// files (see APPLE_LOOPS_METADATA_FORMAT.md §2b) — a real Logic-authored
/// loop had an 82-byte chunk (66-byte filler) where a third-party source
/// claimed 84 bytes (68-byte filler) was universal. We always read "whatever
/// remains" rather than assuming a constant.
struct BascChunk {
    static let headerSize = 16

    var loopableFlag: Data      // 4 bytes, preserved as-is
    var beatCount: Data         // 4 bytes, preserved as-is (never edited)
    var keyMIDINote: UInt16     // 0 = no key
    var scale: UInt16           // 1=Minor 2=Major 3=Neither 4=Both
    var timeSigNumerator: Data  // 2 bytes, preserved as-is
    var timeSigDenominator: Data // 2 bytes, preserved as-is
    var filler: Data            // whatever remains, preserved as-is

    static func parse(from data: Data, dataOffset: Int, dataLength: Int) throws -> BascChunk {
        guard dataLength >= headerSize else {
            throw AppleLoopFileError.corruptChunkTable("'basc' chunk too small (\(dataLength) bytes)")
        }
        let base = dataOffset
        var cursor = base

        let loopableFlag = data.subdata(in: cursor..<cursor + 4); cursor += 4
        let beatCount = data.subdata(in: cursor..<cursor + 4); cursor += 4
        let keyMIDINote = data.readUInt16BE(at: cursor - data.startIndex); cursor += 2
        let scale = data.readUInt16BE(at: cursor - data.startIndex); cursor += 2
        let timeSigNumerator = data.subdata(in: cursor..<cursor + 2); cursor += 2
        let timeSigDenominator = data.subdata(in: cursor..<cursor + 2); cursor += 2

        let fillerLength = dataLength - headerSize
        let filler = fillerLength > 0 ? data.subdata(in: cursor..<cursor + fillerLength) : Data()

        return BascChunk(
            loopableFlag: loopableFlag,
            beatCount: beatCount,
            keyMIDINote: keyMIDINote,
            scale: scale,
            timeSigNumerator: timeSigNumerator,
            timeSigDenominator: timeSigDenominator,
            filler: filler
        )
    }

    func serialized() -> Data {
        var data = Data()
        data.append(loopableFlag)
        data.append(beatCount)
        data.appendUInt16BE(keyMIDINote)
        data.appendUInt16BE(scale)
        data.append(timeSigNumerator)
        data.append(timeSigDenominator)
        data.append(filler)
        return data
    }
}

/// Shared key/mode <-> MIDI-note/scale-code translation, used by both the
/// AIFF 'basc' chunk and the CAF 'uuid' metadata pairs (`key signature` /
/// `key type`), so both containers present the same Key/Mode vocabulary.
public enum AppleLoopKeyEncoding {
    public static let noteNames: [String] = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"
    ]

    /// Apple Loops encode key root as a MIDI note in the 48–59 range
    /// (C3..B3), with 0 meaning "no key".
    public static func midiNote(forNoteName name: String) -> UInt16 {
        guard let idx = noteNames.firstIndex(of: name) else { return 0 }
        return UInt16(48 + idx)
    }

    public static func noteName(forMIDINote note: UInt16) -> String {
        guard note > 0 else { return "" }
        let idx = (Int(note) - 48) % 12
        guard idx >= 0, idx < noteNames.count else { return "" }
        return noteNames[idx]
    }

    public static let scaleNames: [String] = ["Minor", "Major", "Neither", "Both"]

    public static func scaleCode(forName name: String) -> UInt16 {
        switch name.lowercased() {
        case "minor": return 1
        case "major": return 2
        case "neither": return 3
        case "both": return 4
        default: return 0
        }
    }

    public static func scaleName(forCode code: UInt16) -> String {
        switch code {
        case 1: return "Minor"
        case 2: return "Major"
        case 3: return "Neither"
        case 4: return "Both"
        default: return ""
        }
    }

    /// CAF 'key type' values are lowercase strings, not the same casing as
    /// the AIFF numeric scale codes' display names.
    public static func keyTypeString(forScaleName name: String) -> String {
        name.lowercased()
    }

    public static func scaleName(forKeyTypeString value: String) -> String {
        switch value.lowercased() {
        case "minor": return "Minor"
        case "major": return "Major"
        case "neither": return "Neither"
        case "both": return "Both"
        default: return ""
        }
    }
}
