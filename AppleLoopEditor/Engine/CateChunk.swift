// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

/// Legacy AIFF 'cate' chunk layout (see APPLE_LOOPS_METADATA_FORMAT.md §2b):
///
/// reserved (4B) | category (50B) | subcategory (50B) | genre (50B) |
/// reserved 4th slot (50B) | reserved (16B) | descriptor count (2B) |
/// descriptor[0..count] (50B each)
struct CateChunk {
    static let slotSize = 50

    var headerReserved: Data      // 4 bytes
    var category: String
    var subcategory: String
    var genre: String
    var reservedFourthSlot: Data  // 50 bytes, preserved as-is
    var midReserved: Data         // 16 bytes, preserved as-is
    var descriptors: [String]

    static func parse(from data: Data, dataOffset: Int, dataLength: Int) throws -> CateChunk {
        let base = dataOffset
        guard dataLength >= 4 + slotSize * 4 + 16 + 2 else {
            throw AppleLoopFileError.corruptChunkTable("'cate' chunk too small (\(dataLength) bytes)")
        }

        var cursor = base
        let headerReserved = data.subdata(in: cursor..<cursor + 4)
        cursor += 4

        let category = readSlot(data, cursor); cursor += slotSize
        let subcategory = readSlot(data, cursor); cursor += slotSize
        let genre = readSlot(data, cursor); cursor += slotSize
        let reservedFourthSlot = data.subdata(in: cursor..<cursor + slotSize); cursor += slotSize
        let midReserved = data.subdata(in: cursor..<cursor + 16); cursor += 16

        let descriptorCount = Int(data.readUInt16BE(at: cursor - data.startIndex))
        cursor += 2

        var descriptors: [String] = []
        for _ in 0..<descriptorCount {
            guard cursor + slotSize <= base + dataLength else { break }
            let d = readSlot(data, cursor)
            if !d.isEmpty { descriptors.append(d) }
            cursor += slotSize
        }

        return CateChunk(
            headerReserved: headerReserved,
            category: category,
            subcategory: subcategory,
            genre: genre,
            reservedFourthSlot: reservedFourthSlot,
            midReserved: midReserved,
            descriptors: descriptors
        )
    }

    func serialized() -> Data {
        var data = Data()
        data.append(headerReserved)
        data.append(Self.writeSlot(category))
        data.append(Self.writeSlot(subcategory))
        data.append(Self.writeSlot(genre))
        data.append(reservedFourthSlot)
        data.append(midReserved)
        data.appendUInt16BE(UInt16(descriptors.count))
        for d in descriptors {
            data.append(Self.writeSlot(d))
        }
        return data
    }

    private static func readSlot(_ data: Data, _ offset: Int) -> String {
        let slot = data.subdata(in: offset..<offset + slotSize)
        let nullIdx = slot.firstIndex(of: 0) ?? slot.endIndex
        let strData = slot.subdata(in: slot.startIndex..<nullIdx)
        return String(data: strData, encoding: .utf8) ?? ""
    }

    private static func writeSlot(_ string: String) -> Data {
        var bytes = Array(string.utf8.prefix(slotSize - 1))
        while bytes.count < slotSize { bytes.append(0) }
        return Data(bytes)
    }
}
