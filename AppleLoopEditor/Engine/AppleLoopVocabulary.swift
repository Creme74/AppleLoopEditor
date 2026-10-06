// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import Foundation

/// The confirmed Instrument / Genre / Descriptor vocabulary, as it appears
/// in Logic Pro's own loop-tagging UI (not the Loop Browser's search
/// filters, which include a few extra names with no way to actually assign
/// them — see `categoryStorageNameOverrides` below).
public enum AppleLoopVocabulary {
    public static let categories: [String] = [
        "All Drums", "Bass", "Brass", "FX", "Guitars",
        "Horn", "Jingles", "Keyboards", "Mallets", "Other Inst", "Percussion",
        "Strings", "Textures", "Vocals", "Woodwind"
    ]

    public static let subcategoriesByCategory: [String: [String]] = [
        "All Drums": ["Beats", "Cymbal", "Hi-Hat", "Kick", "Kits", "Snare", "Tom"],
        "Bass": ["Acoustic Bass", "Elec Bass", "Synthetic Bass"],
        "Brass": ["French Horn", "Harmonica", "Trombone", "Trumpet", "Tuba"],
        "FX": ["Ambience", "Animals", "Explosions", "Foley", "Impacts", "Machines", "Misc.", "People", "Sci-Fi", "Sports", "Stingers", "Textures", "Transportation", "Vocals", "Weapons", "Work/Home"],
        "Guitars": ["Acoustic Guitar", "Banjo", "Elec Guitar", "Mandolin", "Pedal Steel", "Slide Guitar"],
        "Horn": ["Bagpipe", "Bassoon", "Clarinet", "English Horn", "Flute", "French Horn", "Harmonica", "Oboe", "Pan Flute", "Piccolo", "Recorder", "Saxophone", "Trombone", "Trumpet"],
        "Jingles": [],
        "Keyboards": ["Accordion", "Celesta", "Clavinet", "Elec Piano", "Harpsichord", "Organ", "Piano", "Synths"],
        "Mallets": ["Bell", "Kalimba", "Marimba", "Steel Drum", "Timpani", "Vibes", "Xylophone"],
        "Other Inst": [],
        "Percussion": ["Bongo", "Chime", "Clave", "Conga", "Cowbell", "Gong", "Rattler", "Shaker", "Tambourine", "Vinyl"],
        "Strings": ["Cello", "Double Bass", "Harp", "Koto", "Sitar", "Viola", "Violin"],
        "Textures": [],
        "Vocals": ["Choir", "Female", "Male"],
        "Woodwind": ["Bagpipe", "Bassoon", "Clarinet", "Flute", "Oboe", "Pan Flute", "Recorder", "Saxophone"]
    ]

    public static let allSubcategories: [String] = {
        Array(Set(subcategoriesByCategory.values.flatMap { $0 })).sorted()
    }()

    public static func subcategories(for category: String) -> [String] {
        subcategoriesByCategory[category] ?? []
    }

    /// Distinguishes "unknown category" (fall back to showing everything)
    /// from "known category that genuinely has no subcategories" (Jingles,
    /// Other Inst, Textures) — conflating the two broke those three
    /// categories in an earlier version of this app.
    public static func subcategoriesAreApplicable(for category: String) -> Bool {
        guard let list = subcategoriesByCategory[category] else { return true }
        return !list.isEmpty
    }

    /// For 6 of the 15 categories, what Logic's Loop Browser *displays* is
    /// not the string it actually *writes* to the file. Confirmed against
    /// real Logic-authored test loops, one per category — see
    /// APPLE_LOOPS_METADATA_FORMAT.md.
    public static let categoryStorageNameOverrides: [String: String] = [
        "All Drums": "Drums",
        "FX": "Sound Effect",
        "Horn": "Horn/Wind",
        "Jingles": "Mixed",
        "Other Inst": "Other Instrument",
        "Textures": "Texture/Atmosphere",
    ]

    public static func storageName(forDisplayCategory display: String) -> String {
        categoryStorageNameOverrides[display] ?? display
    }

    public static func displayName(forStorageCategory storage: String) -> String {
        if let match = categoryStorageNameOverrides.first(where: { $0.value == storage }) {
            return match.key
        }
        return storage
    }

    /// Same story as the categories, one level down: for many subcategories
    /// the label shown in Logic's tagging UI is NOT the string Logic writes
    /// to the file. Left as-is, a loop tagged here got e.g. "Hi-Hat" or
    /// "Elec Piano" on disk, which Logic's Loop Browser doesn't recognise
    /// (it only matches its own stored names), so the loop landed outside
    /// its subcategory.
    ///
    /// The stored names below were read from the ~31,000 Apple-authored
    /// loops installed with Logic Pro (every distinct category/subcategory
    /// pair), and double-checked against loops tagged by Logic itself.
    /// Display names missing from this table are written unchanged (they
    /// are identical on disk: "Kick", "Snare", "Organ", "Piano"...).
    public static let subcategoryStorageNameOverrides: [String: String] = [
        "Beats": "Electronic Beats",
        "Hi-Hat": "Hi-hat",
        "Kits": "Drum Kit",
        "Elec Bass": "Electric Bass",
        "Elec Guitar": "Electric Guitar",
        "Pedal Steel": "Pedal Steel Guitar",
        "Elec Piano": "Electric Piano",
        "Synths": "Synthesizer",
        "Vibes": "Vibraphone",
        "Vinyl": "Vinyl/Scratch",
        "Impacts": "Impacts & Crashes",
        "Sports": "Sports & Leisure",
        "Stingers": "Motions & Transitions",
        "Machines": "Mech/Tech",
    ]

    public static func storageName(forDisplaySubcategory display: String) -> String {
        subcategoryStorageNameOverrides[display] ?? display
    }

    public static func displayName(forStorageSubcategory storage: String) -> String {
        if let match = subcategoryStorageNameOverrides.first(where: { $0.value == storage }) {
            return match.key
        }
        return storage
    }

    public static let genres: [String] = [
        "Rock/Blues", "Electronic/Dance", "World/Ethnic", "Hip Hop", "Orchestral",
        "Cinematic/New Age", "Modern RnB", "Urban", "Electro House", "Hip Hop/RnB",
        "Funk", "Techno", "Dubstep", "Indie", "Sound_Effects", "Other Genre",
        "Tech House", "House", "Jazz", "Chillwave", "Country/Folk", "Electronic Pop",
        "Deep House", "Future Bass", "Bass House", "Reggaeton Pop",
        "Chinese Traditional", "Experimental", "Vintage Breaks", "Electronic"
    ]

    public static let descriptors: [String] = [
        "Grooving", "Part", "Single", "Melodic", "Clean", "Electric", "Processed",
        "Acoustic", "Dry", "Relaxed", "Cheerful", "Intense", "Ensemble", "Dark",
        "Distorted", "Fill", "Arrhythmic", "Dissonant"
    ]
}
