// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

/// Represents one Apple Loop file on disk (CAF or legacy AIFF/AIFF-C).
/// Reads tags on init; `apply(_:)` writes an edit straight back to the
/// original file (no backup/undo — removed per product decision) and
/// re-derives `tags` from the freshly written bytes so any normalization
/// Apple's own encoding does (e.g. lowercase `key type`) is reflected
/// accurately rather than mirrored field-by-field from the edit.
public final class AppleLoopFile {
    public let url: URL
    public private(set) var tags: AppleLoopTags
    public private(set) var hadNoMetadataChunk: Bool

    public init(url: URL) throws {
        self.url = url
        let data = try Self.readData(at: url)
        let (parsedTags, hadNone) = try Self.parseTags(from: data)
        self.tags = parsedTags
        self.hadNoMetadataChunk = hadNone
    }

    // MARK: - Reading

    private static func readData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw AppleLoopFileError.ioError(error.localizedDescription)
        }
    }

    private static func parseTags(from data: Data) throws -> (AppleLoopTags, Bool) {
        guard let format = ChunkParser.detectFormat(data) else {
            throw AppleLoopFileError.unrecognizedContainer
        }

        switch format {
        case .caf:
            let start = data.startIndex + 8 // 'caff' + version(2) + flags(2)
            let chunks = try ChunkParser.topLevelChunks(in: data, format: format, start: start)
            guard let metaChunk = findUUIDMetadataChunk(chunks, in: data) else {
                throw AppleLoopFileError.notAnAppleLoop
            }
            let pairOffset = metaChunk.dataOffset + 16 // past the 16-byte identifier
            let pairs = LoopMetadataPairList.parse(from: data, offset: pairOffset)

            let storedCategory = pairs.value(for: AppleLoopMetadataKey.category) ?? ""
            let tags = AppleLoopTags(
                category: storedCategory.isEmpty ? "" : AppleLoopVocabulary.displayName(forStorageCategory: storedCategory),
                subcategory: AppleLoopVocabulary.displayName(forStorageSubcategory: pairs.value(for: AppleLoopMetadataKey.subcategory) ?? ""),
                storedSubcategory: pairs.value(for: AppleLoopMetadataKey.subcategory) ?? "",
                genre: pairs.value(for: AppleLoopMetadataKey.genre) ?? "",
                descriptors: splitCommaList(pairs.value(for: AppleLoopMetadataKey.descriptors)),
                key: AppleLoopKeyEncoding.canonicalNoteName(pairs.value(for: AppleLoopMetadataKey.keySignature) ?? ""),
                mode: AppleLoopKeyEncoding.scaleName(forKeyTypeString: pairs.value(for: AppleLoopMetadataKey.keyType) ?? ""),
                beatCount: Int(pairs.value(for: AppleLoopMetadataKey.beatCount) ?? "") ?? 0,
                hasMidi: hasEmbeddedMidi(chunks, in: data, format: format)
            )
            return (tags, false)

        case .aiff:
            let start = data.startIndex + 12 // 'FORM' + size(4) + 'AIFF'/'AIFC'
            let chunks = try ChunkParser.topLevelChunks(in: data, format: format, start: start)
            guard let cateInfo = chunks.first(where: { $0.id == "cate" }) else {
                throw AppleLoopFileError.notAnAppleLoop
            }
            let cate = try CateChunk.parse(from: data, dataOffset: cateInfo.dataOffset, dataLength: cateInfo.dataLength)

            var key = ""
            var mode = ""
            var beatCount = 0
            if let bascInfo = chunks.first(where: { $0.id == "basc" }) {
                let basc = try BascChunk.parse(from: data, dataOffset: bascInfo.dataOffset, dataLength: bascInfo.dataLength)
                key = AppleLoopKeyEncoding.noteName(forMIDINote: basc.keyMIDINote)
                mode = AppleLoopKeyEncoding.scaleName(forCode: basc.scale, hasKey: basc.keyMIDINote > 0)
                beatCount = Int(basc.beatCount.readUInt32BE(at: 0))
            }

            let tags = AppleLoopTags(
                category: cate.category.isEmpty ? "" : AppleLoopVocabulary.displayName(forStorageCategory: cate.category),
                subcategory: AppleLoopVocabulary.displayName(forStorageSubcategory: cate.subcategory),
                storedSubcategory: cate.subcategory,
                genre: cate.genre,
                descriptors: cate.descriptors,
                key: key,
                mode: mode,
                beatCount: beatCount,
                hasMidi: hasEmbeddedMidi(chunks, in: data, format: format)
            )
            return (tags, false)
        }
    }

    /// True when the loop has an embedded MIDI performance: the container's
    /// MIDI chunk ('.mid' in AIFF, 'midi' in CAF -- confirmed against real
    /// Logic-authored loops of both formats) holding an actual Standard MIDI
    /// File, i.e. starting with the 'MThd' header. A chunk that's present but
    /// empty or not a real SMF doesn't count.
    private static func hasEmbeddedMidi(_ chunks: [ChunkInfo], in data: Data, format: ContainerFormat) -> Bool {
        let midiChunkID: String
        switch format {
        case .caf: midiChunkID = "midi"
        case .aiff: midiChunkID = ".mid"
        }
        guard let chunk = chunks.first(where: { $0.id == midiChunkID }),
              chunk.dataLength >= 14 // 'MThd' + length + format/ntrks/division
        else { return false }
        return data.subdata(in: chunk.dataOffset..<chunk.dataOffset + 4) == Data("MThd".utf8)
    }

    private static func splitCommaList(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func findUUIDMetadataChunk(_ chunks: [ChunkInfo], in data: Data) -> ChunkInfo? {
        for chunk in chunks where chunk.id == "uuid" {
            guard chunk.dataLength >= 16 else { continue }
            let marker = data.subdata(in: chunk.dataOffset..<chunk.dataOffset + 16)
            if Array(marker) == AppleLoopUUID.metadata {
                return chunk
            }
        }
        return nil
    }

    // MARK: - Writing

    /// Pure function: computes the new file bytes for `edit` without
    /// touching disk or mutating `self.tags`. Used by `apply(_:)`, and
    /// separately testable.
    public func dataApplying(_ edit: AppleLoopTagEdit) throws -> Data {
        let original = try Self.readData(at: url)
        guard let format = ChunkParser.detectFormat(original) else {
            throw AppleLoopFileError.unrecognizedContainer
        }

        switch format {
        case .caf:
            return try applyCAF(edit: edit, to: original)
        case .aiff:
            return try applyAIFF(edit: edit, to: original)
        }
    }

    /// Writes `edit` to `url`, then re-reads tags from the freshly written
    /// bytes so `self.tags` always reflects exactly what's on disk
    /// (including any normalization, e.g. lowercase 'key type').
    ///
    /// The write itself is atomic (Foundation writes to a temp file on the
    /// same volume, then renames it into place), so an interruption mid-write
    /// (crash, power loss) can never leave a truncated/corrupted loop at
    /// `url` -- the original stays intact until the new data is fully on
    /// disk. When `keepBackup` is true (the default), a `.bak` copy of the
    /// file as it was *before* this edit is written alongside it first, as
    /// a best-effort safety net; a backup failure never blocks the save.
    public func apply(_ edit: AppleLoopTagEdit, keepBackup: Bool = true) throws {
        guard !edit.isEmpty else { return }
        let newData = try dataApplying(edit)

        if keepBackup {
            let backupURL = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: url, to: backupURL)
        }

        do {
            try newData.write(to: url, options: .atomic)
        } catch {
            throw AppleLoopFileError.ioError(error.localizedDescription)
        }
        let (newTags, hadNone) = try Self.parseTags(from: newData)
        self.tags = newTags
        self.hadNoMetadataChunk = hadNone
    }

    // MARK: - CAF write path

    private func applyCAF(edit: AppleLoopTagEdit, to original: Data) throws -> Data {
        let format = ContainerFormat.caf
        let start = original.startIndex + 8
        let chunks = try ChunkParser.topLevelChunks(in: original, format: format, start: start)
        guard let metaChunk = Self.findUUIDMetadataChunk(chunks, in: original) else {
            throw AppleLoopFileError.notAnAppleLoop
        }

        if (edit.key != nil || edit.mode != nil) {
            // CAF stores key/mode as ordinary string pairs alongside the
            // rest — no separate fixed chunk requirement like AIFF's basc.
        }

        let pairOffset = metaChunk.dataOffset + 16
        var pairs = LoopMetadataPairList.parse(from: original, offset: pairOffset)

        if let category = edit.category {
            pairs.set(AppleLoopMetadataKey.category, to: AppleLoopVocabulary.storageName(forDisplayCategory: category))
        }
        if let subcategory = edit.subcategory {
            pairs.set(AppleLoopMetadataKey.subcategory, to: AppleLoopVocabulary.storageName(forDisplaySubcategory: subcategory))
        }
        if let genre = edit.genre {
            pairs.set(AppleLoopMetadataKey.genre, to: genre)
        }
        if let descriptors = edit.descriptors {
            pairs.set(AppleLoopMetadataKey.descriptors, to: descriptors.joined(separator: ","))
        }
        if let key = edit.key {
            pairs.set(AppleLoopMetadataKey.keySignature, to: key.isEmpty ? nil : key)
        }
        if let mode = edit.mode {
            pairs.set(AppleLoopMetadataKey.keyType, to: mode.isEmpty ? nil : AppleLoopKeyEncoding.keyTypeString(forScaleName: mode))
        }
        if edit.convertToOneShot == true {
            // Confirmed against real Apple-authored files: a genuine
            // One-Shot CAF simply has no "beat count" pair at all (Loops
            // have one, e.g. "8" or "16") — it isn't set to "0". Removing
            // the key (LoopMetadataPairList.set(_, to: nil) deletes it)
            // matches Apple's own format exactly.
            pairs.set(AppleLoopMetadataKey.beatCount, to: nil)
        }

        var newChunkData = Data()
        newChunkData.append(contentsOf: AppleLoopUUID.metadata)
        newChunkData.append(pairs.serialized())

        return Self.replaceChunk(id: "uuid", in: original, format: format, chunk: metaChunk, withData: newChunkData)
    }

    // MARK: - AIFF write path

    private func applyAIFF(edit: AppleLoopTagEdit, to original: Data) throws -> Data {
        let format: ContainerFormat
        let magic = String(data: original.subdata(in: original.startIndex + 8..<original.startIndex + 12), encoding: .ascii) ?? "AIFF"
        format = .aiff(formType: magic)

        let start = original.startIndex + 12
        var chunks = try ChunkParser.topLevelChunks(in: original, format: format, start: start)
        guard let cateInfo = chunks.first(where: { $0.id == "cate" }) else {
            throw AppleLoopFileError.notAnAppleLoop
        }

        var working = original

        // 1. basc first: fixed size, in-place edit, no resize/FORM bookkeeping needed.
        if edit.key != nil || edit.mode != nil || edit.convertToOneShot == true {
            guard let bascInfo = chunks.first(where: { $0.id == "basc" }) else {
                throw AppleLoopFileError.keyEditRequiresBascChunk
            }
            var basc = try BascChunk.parse(from: working, dataOffset: bascInfo.dataOffset, dataLength: bascInfo.dataLength)
            if let key = edit.key {
                basc.keyMIDINote = key.isEmpty ? 0 : AppleLoopKeyEncoding.midiNote(forNoteName: key)
            }
            if let mode = edit.mode {
                basc.scale = mode.isEmpty ? 0 : AppleLoopKeyEncoding.scaleCode(forName: mode)
            }
            if edit.convertToOneShot == true {
                // Confirmed by diffing a real Logic loop against a real
                // one-shot: beatCount 0 + time signature 0/0 is what marks
                // a file as a One-Shot. Key/Scale/loopableFlag are left
                // untouched — they're independent of loop-vs-one-shot.
                var zero4 = Data(); zero4.appendUInt32BE(0)
                var zero2 = Data(); zero2.appendUInt16BE(0)
                basc.beatCount = zero4
                basc.timeSigNumerator = zero2
                basc.timeSigDenominator = zero2
            }
            let newBascData = basc.serialized()
            precondition(newBascData.count == bascInfo.dataLength, "basc edit must not change chunk size")
            working.replaceSubrange(bascInfo.dataOffset..<bascInfo.dataOffset + bascInfo.dataLength, with: newBascData)
        }

        // 2. cate second: variable size, may resize the chunk + FORM size.
        // Re-locate cate's offset in `working` (basc edit above didn't move
        // anything since it kept the same size, so offsets are still valid).
        chunks = try ChunkParser.topLevelChunks(in: working, format: format, start: start)
        guard let cateInfoNow = chunks.first(where: { $0.id == "cate" }) else {
            throw AppleLoopFileError.notAnAppleLoop
        }
        _ = cateInfo // silence unused-if-untouched warning path

        if edit.category != nil || edit.subcategory != nil || edit.genre != nil || edit.descriptors != nil {
            var cate = try CateChunk.parse(from: working, dataOffset: cateInfoNow.dataOffset, dataLength: cateInfoNow.dataLength)
            if let category = edit.category {
                cate.category = AppleLoopVocabulary.storageName(forDisplayCategory: category)
            }
            if let subcategory = edit.subcategory {
                cate.subcategory = AppleLoopVocabulary.storageName(forDisplaySubcategory: subcategory)
            }
            if let genre = edit.genre {
                cate.genre = genre
            }
            if let descriptors = edit.descriptors {
                cate.descriptors = descriptors
            }
            let newCateData = cate.serialized()
            working = Self.replaceChunk(id: "cate", in: working, format: format, chunk: cateInfoNow, withData: newCateData)
        }

        return working
    }

    // MARK: - Chunk splicing helpers

    private static func replaceChunk(id: String, in data: Data, format: ContainerFormat, chunk: ChunkInfo, withData newData: Data) -> Data {
        var result = data

        let oldTotal = chunk.totalLength
        var newChunkBytes = Data()
        newChunkBytes.append(id.data(using: .ascii) ?? Data())

        switch format {
        case .caf:
            newChunkBytes.appendUInt64BE(UInt64(newData.count))
        case .aiff:
            newChunkBytes.appendUInt32BE(UInt32(newData.count))
        }
        newChunkBytes.append(newData)

        var needsPad = false
        if case .aiff = format, newData.count % 2 != 0 {
            newChunkBytes.append(0)
            needsPad = true
        }
        _ = needsPad

        result.replaceSubrange(chunk.headerOffset..<chunk.headerOffset + oldTotal, with: newChunkBytes)

        if case .aiff = format {
            let delta = newChunkBytes.count - oldTotal
            if delta != 0 {
                result = updateAIFFFormSize(in: result, byteDelta: delta)
            }
        }

        return result
    }

    private static func updateAIFFFormSize(in data: Data, byteDelta: Int) -> Data {
        var result = data
        let sizeOffset = result.startIndex + 4
        let currentSize = result.readUInt32BE(at: sizeOffset - result.startIndex)
        let newSize = UInt32(Int64(currentSize) + Int64(byteDelta))
        var newSizeData = Data()
        newSizeData.appendUInt32BE(newSize)
        result.replaceSubrange(sizeOffset..<sizeOffset + 4, with: newSizeData)
        return result
    }

    // MARK: - Duration (for display-only tempo derivation)

    /// The loop's musical duration in seconds, read straight from the
    /// container's own frame-count fields — never from a media framework's
    /// reported `.duration`/`.length`. This matters specifically for
    /// compressed CAF loops (AAC/ALAC, the format Apple's own loop library
    /// actually ships in): the encoder pads the stream with "priming" and
    /// "remainder" frames that aren't part of the musical content, and
    /// CAF's `pakt` chunk's `mNumberValidFrames` is the one place that
    /// already excludes them. Confirmed against a loop hand-labelled
    /// "140 BPM": the file's raw total frame count implied ~137.8 BPM,
    /// while `pakt`'s valid-frame count gives exactly 140.
    public static func readDurationSeconds(at url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let format = ChunkParser.detectFormat(data) else { return nil }
        switch format {
        case .caf:
            return cafDurationSeconds(data)
        case .aiff:
            return aiffDurationSeconds(data)
        }
    }

    private static func cafDurationSeconds(_ data: Data) -> Double? {
        let start = data.startIndex + 8 // 'caff' + version(2) + flags(2)
        guard let chunks = try? ChunkParser.topLevelChunks(in: data, format: .caf, start: start) else { return nil }
        guard let descInfo = chunks.first(where: { $0.id == "desc" }), descInfo.dataLength >= 8 else { return nil }
        let descBase = descInfo.dataOffset - data.startIndex
        let sampleRate = data.readFloat64BE(at: descBase)
        guard sampleRate > 0 else { return nil }

        // The common case for real Apple Loops: they're AAC/ALAC-compressed,
        // which requires a packet table. `mNumberValidFrames` there is
        // exactly the musical frame count, priming/remainder already
        // excluded — no further arithmetic needed.
        if let paktInfo = chunks.first(where: { $0.id == "pakt" }), paktInfo.dataLength >= 16 {
            let validFrames = data.readUInt64BE(at: paktInfo.dataOffset - data.startIndex + 8)
            return Double(validFrames) / sampleRate
        }

        // No packet table: CAF only requires one for VBR/compressed formats,
        // so this is constant-bitrate (typically uncompressed 'lpcm') and
        // every byte in 'data' is real audio — derive the frame count
        // straight from its size instead.
        if descInfo.dataLength >= 28, let dataInfo = chunks.first(where: { $0.id == "data" }) {
            let bytesPerFrame = data.readUInt32BE(at: descBase + 24)
            guard bytesPerFrame > 0 else { return nil }
            // CAF's 'data' chunk content starts with a 4-byte "edit count"
            // field before the raw audio bytes.
            let audioByteCount = dataInfo.dataLength - 4
            guard audioByteCount > 0 else { return nil }
            let frames = audioByteCount / Int(bytesPerFrame)
            return Double(frames) / sampleRate
        }

        return nil
    }

    private static func aiffDurationSeconds(_ data: Data) -> Double? {
        let start = data.startIndex + 12 // 'FORM' + size(4) + 'AIFF'/'AIFC'
        guard let chunks = try? ChunkParser.topLevelChunks(in: data, format: .aiff(formType: "AIFF"), start: start) else { return nil }
        guard let commInfo = chunks.first(where: { $0.id == "COMM" }), commInfo.dataLength >= 18 else { return nil }
        let base = commInfo.dataOffset - data.startIndex
        let numSampleFrames = data.readUInt32BE(at: base + 2)
        let sampleRate = data.readIEEEExtendedBE(at: base + 8)
        guard sampleRate > 0 else { return nil }
        return Double(numSampleFrames) / sampleRate
    }
}
