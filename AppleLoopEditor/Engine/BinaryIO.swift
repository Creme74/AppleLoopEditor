// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

// Manual big-endian read/write helpers for Data.
// We avoid `load(as:)` because chunk data is not guaranteed to be aligned,
// and Apple Loop containers (CAF/AIFF) are always big-endian regardless of
// host architecture.
extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[self.startIndex + offset])
        let b1 = UInt16(self[self.startIndex + offset + 1])
        return (b0 << 8) | b1
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[self.startIndex + offset])
        let b1 = UInt32(self[self.startIndex + offset + 1])
        let b2 = UInt32(self[self.startIndex + offset + 2])
        let b3 = UInt32(self[self.startIndex + offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(self[self.startIndex + offset + i])
        }
        return value
    }

    /// Big-endian IEEE 754 double, reinterpreted from the same 8 raw bytes
    /// `readUInt64BE` reads — used for CAF's `desc` chunk, whose
    /// `mSampleRate` field is a `Float64`.
    func readFloat64BE(at offset: Int) -> Double {
        Double(bitPattern: readUInt64BE(at: offset))
    }

    /// Decodes an 80-bit IEEE 754 "extended" float, big-endian: the format
    /// AIFF's `COMM` chunk always uses for its sample rate field (there's no
    /// simpler encoding for it in the spec, and no built-in Swift/Foundation
    /// type for it either). `offset` is the start of the 10-byte field.
    func readIEEEExtendedBE(at offset: Int) -> Double {
        let b0 = Int(self[self.startIndex + offset])
        let b1 = Int(self[self.startIndex + offset + 1])
        let sign: Double = (b0 & 0x80) != 0 ? -1.0 : 1.0
        let exponent = ((b0 & 0x7f) << 8) | b1
        var mantissa: UInt64 = 0
        for i in 2..<10 {
            mantissa = (mantissa << 8) | UInt64(self[self.startIndex + offset + i])
        }
        if exponent == 0 && mantissa == 0 { return 0 }
        let exp = exponent - 16383 - 63
        return sign * Double(mantissa) * pow(2.0, Double(exp))
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
