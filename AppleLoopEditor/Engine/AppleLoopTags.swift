// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

/// The current tags read from an Apple Loop file.
public struct AppleLoopTags: Equatable {
    public var category: String
    public var subcategory: String
    public var genre: String
    public var descriptors: [String]
    public var key: String   // root note, e.g. "A"; "" = none
    public var mode: String  // "Major"/"Minor"/"Both"/"Neither"; "" = none

    /// Number of beats the loop spans. Apple's own convention (confirmed by
    /// comparing a real Logic-authored loop against a one-shot): 0 means the
    /// file is a One-Shot (no musical grid, never time-stretched to the
    /// project tempo); any value > 0 means it's a Loop with that many beats.
    public var beatCount: Int

    public var isOneShot: Bool { beatCount == 0 }

    public var descriptorsJoined: String {
        descriptors.joined(separator: ", ")
    }

    public init(
        category: String = "",
        subcategory: String = "",
        genre: String = "",
        descriptors: [String] = [],
        key: String = "",
        mode: String = "",
        beatCount: Int = 0
    ) {
        self.category = category
        self.subcategory = subcategory
        self.genre = genre
        self.descriptors = descriptors
        self.key = key
        self.mode = mode
        self.beatCount = beatCount
    }
}

/// A requested edit. Any field left `nil` means "leave untouched" — this is
/// how batch editing only changes the fields the user explicitly selected.
public struct AppleLoopTagEdit {
    public var category: String?
    public var subcategory: String?
    public var genre: String?
    public var descriptors: [String]?
    public var key: String?
    public var mode: String?

    /// Set to `true` to convert a Loop into a One-Shot (beatCount -> 0).
    /// The reverse (One-Shot -> Loop) isn't supported: a real beat count
    /// requires knowing the target tempo, which we don't have, so this is
    /// always nil or true, never false.
    public var convertToOneShot: Bool?

    public var isEmpty: Bool {
        category == nil && subcategory == nil && genre == nil &&
        descriptors == nil && key == nil && mode == nil &&
        convertToOneShot == nil
    }

    public init(
        category: String? = nil,
        subcategory: String? = nil,
        genre: String? = nil,
        descriptors: [String]? = nil,
        key: String? = nil,
        mode: String? = nil,
        convertToOneShot: Bool? = nil
    ) {
        self.category = category
        self.subcategory = subcategory
        self.genre = genre
        self.descriptors = descriptors
        self.key = key
        self.mode = mode
        self.convertToOneShot = convertToOneShot
    }
}
