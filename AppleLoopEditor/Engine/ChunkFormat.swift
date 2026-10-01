// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

public enum ContainerFormat: Equatable {
    case caf
    case aiff(formType: String) // "AIFF" or "AIFC"
}

public struct ChunkInfo {
    public let id: String
    public let headerOffset: Int
    public let dataOffset: Int
    public let dataLength: Int
    public let hasPadByte: Bool

    public var totalLength: Int {
        (dataOffset - headerOffset) + dataLength + (hasPadByte ? 1 : 0)
    }
}

public enum AppleLoopFileError: Error, LocalizedError {
    case notAnAppleLoop
    case unrecognizedContainer
    case corruptChunkTable(String)
    case missingChunk(String)
    case keyEditRequiresBascChunk
    case unsupportedValue(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .notAnAppleLoop:
            return "This file doesn't contain Apple Loop metadata (no 'cate' chunk or Apple Loop 'uuid' chunk found)."
        case .unrecognizedContainer:
            return "This file isn't a recognized CAF or AIFF/AIFF-C container."
        case .corruptChunkTable(let detail):
            return "The file's chunk table looks corrupt: \(detail)"
        case .missingChunk(let id):
            return "Missing expected chunk: \(id)"
        case .keyEditRequiresBascChunk:
            return "This file has no 'basc' chunk, so its Key/Mode can't be edited safely (there's no confirmed way to create a new one with correct fields)."
        case .unsupportedValue(let detail):
            return detail
        case .ioError(let detail):
            return "I/O error: \(detail)"
        }
    }
}

enum ChunkParser {
    static func detectFormat(_ data: Data) -> ContainerFormat? {
        guard data.count >= 12 else { return nil }
        let magic = String(data: data.subdata(in: data.startIndex..<data.startIndex + 4), encoding: .ascii) ?? ""
        if magic == "caff" {
            return .caf
        }
        if magic == "FORM" {
            let formType = String(data: data.subdata(in: data.startIndex + 8..<data.startIndex + 12), encoding: .ascii) ?? ""
            if formType == "AIFF" || formType == "AIFC" {
                return .aiff(formType: formType)
            }
        }
        return nil
    }

    /// Returns the top-level chunks starting at `start` (the byte right after
    /// the file header) through the end of `data`.
    static func topLevelChunks(in data: Data, format: ContainerFormat, start: Int) throws -> [ChunkInfo] {
        var chunks: [ChunkInfo] = []
        var offset = start
        let end = data.startIndex + data.count

        while offset + 8 <= end {
            guard let idData = try? safeSubdata(data, offset, 4) else {
                throw AppleLoopFileError.corruptChunkTable("truncated chunk id at offset \(offset)")
            }
            let id = String(data: idData, encoding: .ascii) ?? "????"

            let dataOffset: Int
            let dataLength: Int

            switch format {
            case .caf:
                guard offset + 12 <= end else {
                    throw AppleLoopFileError.corruptChunkTable("truncated CAF chunk size at offset \(offset)")
                }
                let size = data.readUInt64BE(at: offset - data.startIndex + 4)
                dataOffset = offset + 12
                if size == UInt64.max {
                    // CAF spec: a chunk size of -1 (all 64 bits set) means
                    // "this chunk's data runs to the end of the file" --
                    // legal only for the file's last chunk (typically a
                    // streamed 'data' chunk whose final size wasn't known
                    // up front). UInt64.max doesn't fit in Int, so Int(size)
                    // would trap here; compute the real remaining length
                    // from the end of the buffer instead.
                    dataLength = end - dataOffset
                } else {
                    dataLength = Int(size)
                }
            case .aiff:
                guard offset + 8 <= end else {
                    throw AppleLoopFileError.corruptChunkTable("truncated AIFF chunk size at offset \(offset)")
                }
                let size = data.readUInt32BE(at: offset - data.startIndex + 4)
                dataOffset = offset + 8
                dataLength = Int(size)
            }

            guard dataLength >= 0, dataOffset + dataLength <= end else {
                throw AppleLoopFileError.corruptChunkTable("chunk '\(id)' size \(dataLength) runs past end of file")
            }

            let isOdd = (dataLength % 2) != 0
            let hasPad: Bool
            switch format {
            case .caf:
                hasPad = false // CAF chunk sizes are exact, no IFF-style padding
            case .aiff:
                hasPad = isOdd && (dataOffset + dataLength) < end
            }

            chunks.append(ChunkInfo(id: id, headerOffset: offset, dataOffset: dataOffset, dataLength: dataLength, hasPadByte: hasPad))

            offset = dataOffset + dataLength + (hasPad ? 1 : 0)
        }

        return chunks
    }

    private static func safeSubdata(_ data: Data, _ offset: Int, _ length: Int) throws -> Data {
        guard offset >= data.startIndex, offset + length <= data.startIndex + data.count else {
            throw AppleLoopFileError.corruptChunkTable("out of range read at \(offset)")
        }
        return data.subdata(in: offset..<offset + length)
    }
}
