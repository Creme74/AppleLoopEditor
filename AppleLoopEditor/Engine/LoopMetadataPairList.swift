// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

public enum AppleLoopMetadataKey {
    public static let category = "category"
    public static let subcategory = "subcategory"
    public static let genre = "genre"
    public static let descriptors = "descriptors"
    public static let keySignature = "key signature"
    public static let keyType = "key type"
    public static let beatCount = "beat count"
    public static let timeSignature = "time signature"
}

/// The ordered list of key\0value\0 pairs found in a CAF Apple Loop
/// metadata `uuid` chunk. Order is preserved on round-trip since Apple's own
/// files aren't alphabetized and nothing guarantees order is insignificant.
public struct LoopMetadataPairList {
    public private(set) var pairs: [(key: String, value: String)]

    public init(pairs: [(key: String, value: String)] = []) {
        self.pairs = pairs
    }

    public static func parse(from data: Data, offset: Int) -> LoopMetadataPairList {
        var result: [(String, String)] = []
        var cursor = offset
        guard cursor + 4 <= data.startIndex + data.count else { return LoopMetadataPairList() }
        let count = data.readUInt32BE(at: cursor - data.startIndex)
        cursor += 4

        for _ in 0..<count {
            guard let key = readCString(data, &cursor) else { break }
            guard let value = readCString(data, &cursor) else { break }
            result.append((key, value))
        }

        return LoopMetadataPairList(pairs: result)
    }

    private static func readCString(_ data: Data, _ cursor: inout Int) -> String? {
        let end = data.startIndex + data.count
        guard cursor < end else { return nil }
        var scan = cursor
        while scan < end, data[scan] != 0 {
            scan += 1
        }
        guard scan < end else { return nil }
        let strData = data.subdata(in: cursor..<scan)
        let str = String(data: strData, encoding: .utf8) ?? ""
        cursor = scan + 1
        return str
    }

    public func serialized() -> Data {
        var data = Data()
        data.appendUInt32BE(UInt32(pairs.count))
        for (key, value) in pairs {
            data.append(key.data(using: .utf8) ?? Data())
            data.append(0)
            data.append(value.data(using: .utf8) ?? Data())
            data.append(0)
        }
        return data
    }

    public func value(for key: String) -> String? {
        pairs.first(where: { $0.key == key })?.value
    }

    public mutating func set(_ key: String, to value: String?) {
        if let value, !value.isEmpty {
            if let idx = pairs.firstIndex(where: { $0.key == key }) {
                pairs[idx] = (key, value)
            } else {
                pairs.append((key, value))
            }
        } else {
            pairs.removeAll { $0.key == key }
        }
    }
}
