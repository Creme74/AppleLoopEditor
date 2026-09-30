// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

/// Minimal Standard MIDI File (SMF) reader, just enough to recover the notes
/// played by a software-instrument Apple Loop's embedded performance.
///
/// Apple's software-instrument loops (piano, synth, string patches, etc.)
/// carry the exact MIDI performance that triggered the patch in a chunk
/// named `.mid` (confirmed by inspecting real Logic-authored loops: its
/// content starts with the standard `MThd`/`MTrk` SMF header). Audio-only
/// loops (drum breaks, guitar riffs, anything that started as a recording)
/// never have this chunk — `KeyModeAnalyzer` falls back to
/// `AudioChromaAnalyzer` for those.
enum StandardMidiFile {
    struct ParseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Builds a 12-bin pitch-class histogram (index 0 = C, 1 = C#, … 11 = B)
    /// from every Note On/Note Off pair in the file, weighted by how long
    /// each note rang (in MIDI ticks — tempo is irrelevant here since every
    /// note in the same file shares the same tick clock). Channel 10
    /// (index 9, General MIDI's percussion channel) is skipped: drum "notes"
    /// encode which drum sound plays, not a pitch, and would only add noise
    /// to a key estimate.
    static func pitchClassHistogram(from smf: Data) throws -> [Double] {
        var reader = ByteReader(smf)
        guard try reader.readFourCC() == "MThd" else {
            throw ParseError(message: "missing MThd header")
        }
        let headerLength = try reader.readUInt32BE()
        guard headerLength >= 6 else {
            throw ParseError(message: "MThd header too short")
        }
        let headerEnd = reader.offset + Int(headerLength)
        _ = try reader.readUInt16BE() // format (0/1/2) — irrelevant, every track is merged
        let trackCount = try reader.readUInt16BE()
        _ = try reader.readUInt16BE() // division — ticks are only ever compared within one file
        reader.seek(to: headerEnd)

        var histogram = [Double](repeating: 0, count: 12)

        for _ in 0..<trackCount {
            guard try reader.readFourCC() == "MTrk" else {
                throw ParseError(message: "missing MTrk header")
            }
            let trackLength = try reader.readUInt32BE()
            let trackEnd = reader.offset + Int(trackLength)
            try parseTrack(&reader, end: trackEnd, into: &histogram)
            reader.seek(to: trackEnd)
        }

        return histogram
    }

    private static func parseTrack(_ reader: inout ByteReader, end: Int, into histogram: inout [Double]) throws {
        var tick = 0
        var runningStatus: UInt8?
        // (channel, note) -> tick the note started on, so a later Note Off
        // (or a Note On with velocity 0, conventionally the same thing) can
        // compute how long it rang.
        var activeNotes: [UInt16: Int] = [:]

        func noteKey(_ channel: UInt8, _ note: UInt8) -> UInt16 {
            UInt16(channel) << 8 | UInt16(note)
        }

        while reader.offset < end {
            tick += try reader.readVariableLength()

            var status = try reader.peekByte()
            if status & 0x80 != 0 {
                reader.advance(1)
                runningStatus = status
            } else {
                guard let running = runningStatus else {
                    throw ParseError(message: "data byte with no running status")
                }
                status = running
            }

            let highNibble = status & 0xF0
            let channel = status & 0x0F

            switch highNibble {
            case 0x80, 0x90: // Note Off / Note On
                let note = try reader.readByte()
                let velocity = try reader.readByte()
                let key = noteKey(channel, note)
                let isNoteOn = highNibble == 0x90 && velocity > 0
                if isNoteOn {
                    activeNotes[key] = tick
                } else if let start = activeNotes.removeValue(forKey: key) {
                    let duration = max(tick - start, 1)
                    if channel != 9 { // GM percussion channel — not a pitch
                        histogram[Int(note) % 12] += Double(duration)
                    }
                }
            case 0xA0, 0xB0, 0xE0: // Poly pressure / Control change / Pitch bend — 2 data bytes
                reader.advance(2)
            case 0xC0, 0xD0: // Program change / Channel pressure — 1 data byte
                reader.advance(1)
            case 0xF0:
                if status == 0xFF { // Meta event
                    reader.advance(1) // meta type
                    let length = try reader.readVariableLength()
                    reader.advance(length)
                } else { // SysEx (0xF0 / 0xF7) — length-prefixed
                    let length = try reader.readVariableLength()
                    reader.advance(length)
                }
            default:
                throw ParseError(message: "unrecognized MIDI status byte \(status)")
            }
        }
    }

    /// Tiny big-endian cursor over `Data`, private to this file.
    private struct ByteReader {
        private let data: Data
        private(set) var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        mutating func seek(to absoluteOffset: Int) {
            offset = absoluteOffset
        }

        mutating func advance(_ count: Int) {
            offset += count
        }

        func peekByte() throws -> UInt8 {
            guard offset < data.endIndex else { throw ParseError(message: "unexpected end of MIDI data") }
            return data[offset]
        }

        mutating func readByte() throws -> UInt8 {
            let b = try peekByte()
            offset += 1
            return b
        }

        mutating func readFourCC() throws -> String {
            guard offset + 4 <= data.endIndex else { throw ParseError(message: "unexpected end of MIDI data") }
            let bytes = data.subdata(in: offset..<offset + 4)
            offset += 4
            return String(data: bytes, encoding: .ascii) ?? ""
        }

        mutating func readUInt16BE() throws -> Int {
            guard offset + 2 <= data.endIndex else { throw ParseError(message: "unexpected end of MIDI data") }
            let value = (Int(data[offset]) << 8) | Int(data[offset + 1])
            offset += 2
            return value
        }

        mutating func readUInt32BE() throws -> UInt32 {
            guard offset + 4 <= data.endIndex else { throw ParseError(message: "unexpected end of MIDI data") }
            let value = (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
            offset += 4
            return value
        }

        /// MIDI variable-length quantity: 7 bits per byte, MSB set means
        /// "more bytes follow".
        mutating func readVariableLength() throws -> Int {
            var value = 0
            while true {
                let b = try readByte()
                value = (value << 7) | Int(b & 0x7F)
                if b & 0x80 == 0 { break }
            }
            return value
        }
    }
}
