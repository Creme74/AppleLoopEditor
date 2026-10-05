// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Nicolas Scaravilli

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

// MARK: - AudioFile

/// Wraps a real `AppleLoopFile` (the engine) with the pending, unsaved edits
/// the UI is currently showing. `file.tags` is always "what's on disk";
/// `pending*` is always "what the user currently has selected in the form".
/// `hasChanges` compares the two, which is what drives the red "•" in the
/// file list.
final class AudioFile: Identifiable, Hashable {
    let id = UUID()
    let file: AppleLoopFile

    var name: String { file.url.lastPathComponent }

    /// `name` without its extension, for the Files list — the extension is
    /// shown separately in its own "Type" column instead.
    var displayName: String { (name as NSString).deletingPathExtension }

    /// ".aif"/".caf" -> "AIF"/"CAF", for the "Type" column.
    var fileExtension: String { file.url.pathExtension.uppercased() }

    /// Tempo (BPM), for display only — never read back into an edit, never
    /// written to disk. Apple Loops don't tag a BPM value directly, only a
    /// beat count (`file.tags.beatCount`, from 'basc' on AIFF or the
    /// "num beats" pair on CAF); tempo is derived from that plus the
    /// audio's actual duration: beats / (duration in minutes). `nil` for a
    /// One-Shot (`beatCount == 0`, so there's nothing to divide) or if the
    /// audio itself couldn't be opened to measure its duration. Rounded to
    /// the nearest whole BPM and clamped to 3 digits (0–999) to match the
    /// fixed-width column it's shown in — real loops never approach that
    /// ceiling, this is just a display safety net.
    let tempoBPM: Int?

    var tempoLabel: String {
        guard let tempoBPM else { return "000" }
        return String(format: "%03d", tempoBPM)
    }

    /// Whether the loop carries an embedded MIDI performance, for the
    /// "Midi" column -- display only, never edited.
    var hasMidi: Bool { file.tags.hasMidi }

    private static func computeTempoBPM(beatCount: Int, url: URL) -> Int? {
        guard beatCount > 0 else { return nil }
        // Deliberately NOT `AVAudioFile(forReading:).length`: for a
        // compressed CAF loop (AAC/ALAC — what Apple's own loop library
        // actually ships), that reports the raw encoded frame count
        // *including* the encoder's priming/remainder padding, which
        // undercounts a 140 BPM loop as ~137.8 BPM. `readDurationSeconds`
        // reads the container's own chunks directly (CAF's packet table
        // when present) to get the true musical duration instead.
        guard let durationSeconds = AppleLoopFile.readDurationSeconds(at: url), durationSeconds > 0 else { return nil }
        let bpm = (Double(beatCount) * 60.0 / durationSeconds).rounded()
        return min(max(Int(bpm), 0), 999)
    }

    var pendingCategory: String
    var pendingSubcategory: String
    /// Set when the user clicks a subcategory row, even if it's the one the
    /// file already shows. It lets a loop tagged by an older version with a
    /// name Logic doesn't use ("Hi-Hat", "Elec Piano"...) be fixed by simply
    /// re-clicking its subcategory: the pending value equals the displayed
    /// one, but not what's actually stored on disk.
    var subcategoryTouched = false
    var pendingGenre: String
    var pendingDescriptors: Set<String>
    var pendingKey: String
    var pendingMode: String
    /// Loop <-> One-Shot only ever moves Loop -> One-Shot (see
    /// `AppleLoopTagEdit.convertToOneShot`), so this starts at whatever's
    /// on disk and can only be staged to `true` if it started `false`.
    var pendingIsOneShot: Bool

    init(file: AppleLoopFile) {
        self.file = file
        self.tempoBPM = Self.computeTempoBPM(beatCount: file.tags.beatCount, url: file.url)
        self.pendingCategory = file.tags.category
        self.pendingSubcategory = file.tags.subcategory
        self.pendingGenre = file.tags.genre
        self.pendingDescriptors = Set(file.tags.descriptors)
        self.pendingKey = file.tags.key
        self.pendingMode = file.tags.mode
        self.pendingIsOneShot = file.tags.isOneShot
    }

    /// True when the pending subcategory must be (re)written: it differs from
    /// what's shown, or the user re-picked it and the name on disk isn't the
    /// one Logic uses.
    private var subcategoryNeedsWrite: Bool {
        if pendingSubcategory != file.tags.subcategory { return true }
        return subcategoryTouched &&
            AppleLoopVocabulary.storageName(forDisplaySubcategory: pendingSubcategory) != file.tags.storedSubcategory
    }

    var hasChanges: Bool {
        pendingCategory != file.tags.category ||
        subcategoryNeedsWrite ||
        pendingGenre != file.tags.genre ||
        pendingDescriptors != Set(file.tags.descriptors) ||
        pendingKey != file.tags.key ||
        pendingMode != file.tags.mode ||
        pendingIsOneShot != file.tags.isOneShot
    }

    /// Builds the sparse edit (only the fields that actually differ from
    /// what's on disk) that gets handed to the engine's `apply(_:)`.
    func edit() -> AppleLoopTagEdit {
        let descriptorsChanged = pendingDescriptors != Set(file.tags.descriptors)
        let becomingOneShot = pendingIsOneShot != file.tags.isOneShot && pendingIsOneShot
        return AppleLoopTagEdit(
            category: pendingCategory != file.tags.category ? pendingCategory : nil,
            subcategory: subcategoryNeedsWrite ? pendingSubcategory : nil,
            genre: pendingGenre != file.tags.genre ? pendingGenre : nil,
            descriptors: descriptorsChanged
                // Keep the app's own vocabulary words in their canonical
                // order, then append anything else the file already carried
                // (tags from Logic/other tools outside this app's 18-word
                // list) instead of silently dropping them. Those extra tags
                // are never shown or editable in the UI, but any edit here
                // must not erase them.
                ? AppleLoopVocabulary.descriptors.filter { pendingDescriptors.contains($0) }
                    + pendingDescriptors.subtracting(AppleLoopVocabulary.descriptors).sorted()
                : nil,
            key: pendingKey != file.tags.key ? pendingKey : nil,
            mode: pendingMode != file.tags.mode ? pendingMode : nil,
            convertToOneShot: becomingOneShot ? true : nil
        )
    }

    static func == (lhs: AudioFile, rhs: AudioFile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Called after a successful save (so the red dot clears, and the
    /// engine's own normalization — e.g. lowercase key type on disk — is
    /// reflected back into the form) and after Cancel (to discard edits).
    func resetPendingToCurrentTags() {
        pendingCategory = file.tags.category
        pendingSubcategory = file.tags.subcategory
        subcategoryTouched = false
        pendingGenre = file.tags.genre
        pendingDescriptors = Set(file.tags.descriptors)
        pendingKey = file.tags.key
        pendingMode = file.tags.mode
        pendingIsOneShot = file.tags.isOneShot
    }
}

// MARK: - UI size preset (View menu > Resize Window)

/// The three fixed window sizes selectable from the app's View menu.
/// Medium is exactly the original layout (scale 1.0); Small/Big are a flat
/// ±20% applied to EVERY font size, frame, padding and spacing in the
/// window — the Files sidebar included, so the whole window changes
/// proportion together rather than just the metadata editor on the right.
///
/// The window itself is not user-resizable (see `.windowResizability` on
/// `AppleLoopEditorApp`): its size is always exactly what the current
/// preset (and the longest loaded file name) computes to, so there is
/// nothing to drag a corner to — only these three fixed steps.
enum UISizePreset: String, CaseIterable {
    case small, medium, big

    var scale: CGFloat {
        switch self {
        case .small: return 0.8
        case .medium: return 1.0
        case .big: return 1.2
        }
    }

    var menuTitle: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .big: return "Large"
        }
    }
}

// MARK: - AppleLoopEditorView

struct AppleLoopEditorView: View {
    /// Shared (via the key, not an object reference) with the `Picker` in
    /// the View menu's "Resize Window" submenu, declared separately on
    /// `AppleLoopEditorApp` below — `@AppStorage` on the same key stays in
    /// sync between the two automatically, and the choice survives relaunch.
    @AppStorage("uiSizePreset") private var uiSizePresetRaw: String = UISizePreset.medium.rawValue
    private var uiScale: CGFloat {
        (UISizePreset(rawValue: uiSizePresetRaw) ?? .medium).scale
    }

    @State private var files: [AudioFile] = []
    /// Bumped on every edit to a file's pending* fields (and after Save /
    /// Cancel). AudioFile is a reference type, so mutating its properties
    /// in place doesn't change `files` by Swift's Equatable/== rules
    /// (AudioFile == compares only `id`), which means SwiftUI can decide
    /// nothing changed and skip redrawing the "changed" dot. Tagging the
    /// file list with `.id(changeTick)` forces it to redraw whenever this
    /// ticks, independent of that optimization.
    @State private var changeTick: Int = 0
    @State private var selectedFileID: UUID?

    // MARK: - Loop playback (Space bar)
    //
    // Space toggles play/pause of whatever file is currently selected, on
    // an infinite loop (numberOfLoops = -1) so it plays the way it would
    // inside a DAW's loop browser. `playingFileID` is tracked separately
    // from `selectedFileID`: if the user picks a different row *while*
    // something is playing, playback follows the new selection immediately
    // (no need to hit Space again); if the selection is cleared or becomes
    // a multi-selection, playback stops outright.
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingFileID: UUID?
    @State private var spaceKeyMonitor: Any?
    /// All rows currently highlighted in the Files list (drives multi-select
    /// for Cmd+A / Cmd-click and bulk "- Remove"). `selectedFileID` (above)
    /// stays the single file shown in the editor panel: it tracks this set
    /// via `syncEditorSelection()` and is nil whenever 0 or 2+ files are
    /// selected, since editing only makes sense for exactly one file.
    @State private var selectedFileIDs: Set<UUID> = []
    /// The row a plain click or Cmd-click last landed on — the starting
    /// point Shift-click extends a range from, exactly like Finder: click
    /// row 2, Shift-click row 5 selects 2...5; Shift-click row 1 next
    /// reselects 1...2 from the same anchor, not from wherever the last
    /// Shift-click landed.
    @State private var selectionAnchorID: UUID?
    @State private var isFileDropTargeted: Bool = false
    @State private var errorMessage: String?
    /// True while a background Key/Mode analysis is running (see
    /// `analyzeSelectedFilesKey()`) — disables the Analyze button and swaps
    /// its label so a second click can't start an overlapping run.
    @State private var isAnalyzing: Bool = false
    /// Last `KeyModeAnalyzer` result per file, purely informational (see
    /// `analysisInfoText`) — analysis never writes into
    /// `pendingKey`/`pendingMode` itself; the user reads the suggestion here
    /// and applies it by hand via the Key/Scale Pickers if they agree with
    /// it, exactly like picking any other value.
    @State private var keyModeAnalysisResults: [UUID: KeyModeSuggestion] = [:]

    // MARK: - Files list sorting (click a column header, Finder-style)

    private enum SortColumn {
        case name, type, midi, bpm, changes
    }
    /// `nil` until the user clicks a column header for the first time, so
    /// the list starts out in plain "order added" order exactly like
    /// before this feature existed.
    @State private var sortColumn: SortColumn? = nil
    /// Ascending the first time a header is clicked; clicking the SAME
    /// header again flips this instead of changing `sortColumn` — the same
    /// two-click cycle Finder's own list-view column headers use.
    @State private var sortAscending: Bool = true

    // IMPORTANT ARCHITECTURE NOTE (root-caused live on the user's Mac,
    // across two separate broken designs):
    //
    // 1) `.onChange(of:)` on macOS fires ASYNCHRONOUSLY relative to the
    //    code that changed the observed value — a later onChange callback
    //    can silently clobber an earlier edit.
    // 2) `List(data, selection: someComputedBinding)` on macOS was ALSO
    //    found unreliable here: the row highlights correctly (the List's
    //    own internal selection state updates), but our computed Binding's
    //    `set` closure — the thing that was supposed to also write into
    //    `files[idx].pendingX` — did not reliably fire. Proven live: after
    //    clicking "Bass", the category row highlighted, the subcategory
    //    list correctly showed Bass's subcategories (that one reads plain
    //    @State directly), but `files[idx].pendingCategory` stayed "All
    //    Drums" and Save had nothing to write.
    //
    // Fix: category / subcategory are no longer backed by SwiftUI `List`
    // selection at all. They're plain VStacks of tappable rows (Buttons),
    // exactly like the descriptor toggle buttons and the "+ Add Files"
    // button that were proven, live, on this Mac, to respond reliably to
    // every click. Each row's action directly and synchronously does BOTH
    // things a click should do: update the @State that drives the
    // highlight, and write into `files[idx].pendingX`. No List selection
    // binding, no onChange, no async race, nothing to silently drop.
    @State private var selectedScale: String = "(None)"
    @State private var selectedGenre: String = "(None)"
    @State private var selectedKey: String = "(None)"
    /// nil = mixed selection (some Loop, some One-Shot) or nothing selected.
    @State private var selectedIsOneShot: Bool?
    @State private var selectedCategory: String?
    @State private var selectedSubcategory: String?
    @State private var selectedDescriptors: Set<String> = []

    let descriptorsData = [
        ("Single", "Ensemble"), ("Clean", "Distorted"),
        ("Acoustic", "Electric"), ("Relaxed", "Intense"),
        ("Cheerful", "Dark"), ("Dry", "Processed"),
        ("Grooving", "Arrhythmic"), ("Melodic", "Dissonant"),
        ("Part", "Fill")
    ]

    private let categoryOptions = AppleLoopVocabulary.categories
    private let genreOptions = ["(None)"] + AppleLoopVocabulary.genres
    private let keyOptions = ["(None)"] + AppleLoopKeyEncoding.noteNames
    private let scaleOptions = ["(None)"] + AppleLoopKeyEncoding.scaleNames

    /// Prepends the "(Multiple)" placeholder to a Picker's options, but only
    /// while it's the value actually being displayed (a multi-selection
    /// whose files don't all agree on this field) — never shown otherwise,
    /// so a normal single-file selection never has an extra bogus row.
    private func displayOptions(_ options: [String], current: String) -> [String] {
        current == "(Multiple)" ? [current] + options : options
    }

    // MARK: - Window sizing (fixed per preset, grows for a long file name)

    /// The sidebar's width with an empty or short file list, AT `uiScale
    /// == 1.0` — same visual size the list had before the Name column
    /// existed as a dynamically-sized thing: room for the Type/Midi/BPM/
    /// Mod columns plus roughly the same Name space the fixed 280pt
    /// sidebar used to give (328 before the 46pt Midi column + its 8pt gap
    /// were added, hence 382). Actual on-screen base width is this times
    /// `uiScale`.
    private static let baseSidebarWidth: CGFloat = 382

    /// Everything in a row *besides* the Name text itself, AT `uiScale ==
    /// 1.0`: the playing icon's reserved slot, the Type/Midi/BPM/Mod
    /// columns, the HStack's own inter-item spacing (5 gaps x 8), the row's horizontal
    /// padding, and the sidebar's own horizontal padding. Kept in one place
    /// so the Name-measurement math below and the column `.frame(width:)`s
    /// in the body can't drift apart. Actual chrome width is this times
    /// `uiScale`, matching every one of those frames being written as
    /// `<value> * uiScale`.
    private static let sidebarChromeWidth: CGFloat = 16 + 42 + 46 + 46 + 60 + 40 + 12 + 30

    /// The right panel's own width at `uiScale == 1.0` — everything the
    /// old fixed `998` minimum window width meant besides the sidebar's
    /// (then 328pt) width and the hairline `Divider()` between them. Kept as
    /// a constant so widening the sidebar for a new column widens the
    /// window instead of squeezing the editor panel.
    private static let rightPanelBaseWidth: CGFloat = 998 - 328 - 1

    /// The window's height at `uiScale == 1.0` — what the old fixed `650`
    /// meant before the View menu's size presets existed.
    private static let windowBaseHeight: CGFloat = 650

    /// The font `Text(audioFile.displayName)` actually renders with at the
    /// current preset — used to measure how wide the longest name actually
    /// needs to be, so the sidebar (and the fixed window built around it)
    /// grows by exactly enough and no more.
    private var rowNameFont: NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize * uiScale)
    }

    /// `baseSidebarWidth * uiScale` normally; grows just enough to fit the
    /// longest loaded file's name (extension excluded — that's its own
    /// column) the moment one wouldn't fit at that base width. Shrinks back
    /// down again once that file is removed, since this is computed from
    /// `files` fresh on every access rather than stored.
    private var sidebarWidth: CGFloat {
        let longestNameWidth = files
            .map { ($0.displayName as NSString).size(withAttributes: [.font: rowNameFont]).width }
            .max() ?? 0
        return max(Self.baseSidebarWidth * uiScale, longestNameWidth.rounded(.up) + Self.sidebarChromeWidth * uiScale)
    }

    /// The window's exact width: the (possibly name-widened) sidebar, the
    /// hairline divider, and the right panel at the current preset's scale.
    /// This is an exact size, not a minimum — see `.windowResizability` on
    /// `AppleLoopEditorApp`, which is what actually makes the window
    /// non-resizable by the user while still letting it change size on its
    /// own when this computed value changes (a new preset, a long name).
    private var windowWidth: CGFloat {
        sidebarWidth + 1 + Self.rightPanelBaseWidth * uiScale
    }

    /// The window's exact height at the current preset.
    private var windowHeight: CGFloat {
        Self.windowBaseHeight * uiScale
    }

    // MARK: Where the edited file actually lives

    private var selectedIndex: Int? {
        guard let selectedFileID else { return nil }
        return files.firstIndex(where: { $0.id == selectedFileID })
    }

    private var selectedFile: AudioFile? {
        guard let idx = selectedIndex else { return nil }
        return files[idx]
    }

    /// Every row currently selected in the Files list, as indices into
    /// `files` — one entry for a normal single selection, several for a
    /// multi-selection. Every field-edit action below writes through this
    /// (instead of the single `selectedIndex`) so editing works the same
    /// way whether one file or many are selected.
    private var activeIndices: [Int] {
        files.indices.filter { selectedFileIDs.contains(files[$0].id) }
    }

    /// Subcategory list is driven off the @State `selectedCategory`, not
    /// off `files[idx].pendingCategory` — this is what makes it refresh
    /// reliably the moment a category row is clicked.
    private var subcategoryOptions: [String] {
        guard let cat = selectedCategory, !cat.isEmpty else {
            return AppleLoopVocabulary.allSubcategories
        }
        return AppleLoopVocabulary.subcategories(for: cat)
    }

    /// Jingles / Other Inst / Textures genuinely have no subcategories in
    /// Logic — this distinguishes that from "no category picked yet" so the
    /// subcategory list isn't wrongly populated with everything.
    private var subcategoriesApplicable: Bool {
        guard let cat = selectedCategory, !cat.isEmpty else { return true }
        return AppleLoopVocabulary.subcategoriesAreApplicable(for: cat)
    }

    /// Text shown next to the Analyze button: the form's current Key/Mode
    /// (exactly what the Scale/Key Pickers above show) next to the last
    /// analysis suggestion for that same file, so the two can be compared
    /// at a glance. Purely informational — reading this never changes
    /// `pendingKey`/`pendingMode`; only picking a value from the Pickers
    /// does that.
    private var analysisInfoText: String {
        guard let idx = selectedIndex else {
            return activeIndices.count > 1
                ? "\(activeIndices.count) files selected — Analyze, then select one to compare its suggestion."
                : "Suggests Key/Mode from the loop's MIDI performance, or its audio if it has none."
        }
        let audioFile = files[idx]

        guard let suggestion = keyModeAnalysisResults[audioFile.id] else {
            return "Click Analyze for a suggestion."
        }
        guard !suggestion.key.isEmpty, !suggestion.mode.isEmpty else {
            return "Suggestion: couldn't determine a key."
        }
        let sourceLabel = suggestion.source == .midiChunk ? "MIDI" : "audio"
        return "Suggestion (\(sourceLabel)): \(suggestion.key) \(suggestion.mode)."
    }

    /// `files` in the order the Files list actually shows them: unchanged
    /// (order added) until a column header is clicked, then sorted by that
    /// column exactly like Finder — Name/Type alphabetically, BPM
    /// numerically (a One-Shot's "000" sorts as 0), Mod groups changed
    /// files together. This is a display-only view: `files` itself is
    /// never reordered, so row mutations elsewhere keep addressing `files`
    /// by `id`. Row order, arrow-key navigation and Shift-click range
    /// selection all read from this instead of `files` directly, so they
    /// stay in sync with whatever the user is actually looking at.
    private var displayedFiles: [AudioFile] {
        guard let sortColumn else { return files }
        let ascending: [AudioFile]
        switch sortColumn {
        case .name:
            ascending = files.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        case .type:
            ascending = files.sorted {
                $0.fileExtension == $1.fileExtension
                    ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    : $0.fileExtension < $1.fileExtension
            }
        case .midi:
            // Loops WITH embedded MIDI first on the first click (that's
            // what someone clicking this header is looking for), name as
            // the tiebreaker like every other column.
            ascending = files.sorted {
                $0.hasMidi == $1.hasMidi
                    ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    : ($0.hasMidi && !$1.hasMidi)
            }
        case .bpm:
            ascending = files.sorted {
                let lhs = $0.tempoBPM ?? 0
                let rhs = $1.tempoBPM ?? 0
                return lhs == rhs
                    ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    : lhs < rhs
            }
        case .changes:
            ascending = files.sorted {
                $0.hasChanges == $1.hasChanges
                    ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    : (!$0.hasChanges && $1.hasChanges)
            }
        }
        return sortAscending ? ascending : ascending.reversed()
    }

    /// Whether at least one loaded file has an unsaved change — the
    /// "Mod" column header only sorts while this is true, since
    /// sorting on an all-unchanged column has nothing meaningful to do.
    private var hasAnyChanges: Bool {
        files.contains { $0.hasChanges }
    }

    /// Small chevron next to whichever column header is the active sort
    /// key, pointing the way the arrow keys/Finder convention does: up for
    /// ascending, down for descending.
    @ViewBuilder
    private func sortIndicator(for column: SortColumn) -> some View {
        if sortColumn == column {
            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                .font(.system(size: 8 * uiScale, weight: .heavy))
        }
    }

    /// The "Midi" column header, sortable like Type/BPM/Mod. Kept out of
    /// `body` on purpose: that view builder is already close to the
    /// compiler's type-checking limit, and inlining this pushed it over.
    private var midiColumnHeader: some View {
        Button(action: { toggleSort(.midi) }) {
            HStack(spacing: 3 * uiScale) {
                Text("Midi")
                sortIndicator(for: .midi)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Whether the loop contains an embedded MIDI performance")
        .frame(width: 46 * uiScale, alignment: .center)
    }

    /// ✓ when the loop carries an embedded MIDI performance, ✗ when it
    /// doesn't (audio only). Read-only, like BPM. Also kept out of `body`
    /// for the same type-checking reason as `midiColumnHeader`.
    private func midiCell(for audioFile: AudioFile) -> some View {
        Text(audioFile.hasMidi ? "✓" : "✗")
            .font(.system(size: 12 * uiScale, weight: .semibold))
            .foregroundColor(Self.vintageYellow.opacity(audioFile.hasMidi ? 1 : 0.4))
            .frame(width: 46 * uiScale, alignment: .center)
    }

    /// Clicking a column header sorts the Files list by that column: a
    /// first click sorts ascending, clicking the same header again reverses
    /// to descending, clicking a different header switches to that column
    /// (ascending) — the same two-click cycle Finder's own column headers
    /// use. Purely a `displayedFiles` concern; never reorders `files`.
    private func toggleSort(_ column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
    }

    /// One row of the Files list. Pulled out of `body` (with the header and
    /// the sidebar itself) so the Swift type-checker never has to solve the
    /// whole window layout as a single expression.
    private func fileRow(for audioFile: AudioFile) -> some View {
        Button(action: { handleRowClick(audioFile.id) }) {
            HStack {
                playingIndicator(for: audioFile, isSelected: selectedFileIDs.contains(audioFile.id))

                Text(audioFile.displayName)
                    .font(.system(size: 13 * uiScale))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The extension, shown here instead of as
                // part of the name above (which is always
                // displayed without one).
                Text(audioFile.fileExtension)
                    .font(.system(size: 10 * uiScale, design: .monospaced))
                    .foregroundColor(Self.vintageYellow)
                    .frame(width: 46 * uiScale, alignment: .center)

                midiCell(for: audioFile)

                // Indicative only — read from the tagged
                // beat count + the audio's real duration,
                // never edited or written back. "000" for
                // One-Shots (no beat count to derive from).
                Text(audioFile.tempoLabel)
                    .font(.system(size: 11 * uiScale, design: .monospaced))
                    .foregroundColor(Self.vintageYellow)
                    .frame(width: 42 * uiScale, alignment: .trailing)

                Text(audioFile.hasChanges ? "•" : "")
                    .font(.system(size: 20 * uiScale))
                    .foregroundColor(Self.logoRed)
                    .frame(width: 60 * uiScale, alignment: .center)
            }
            .padding(.horizontal, 6 * uiScale)
            .padding(.vertical, 4 * uiScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedFileIDs.contains(audioFile.id) ? Color.accentColor : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The Files list's column headers (Name / Type / Midi / BPM / Mod).
    private var filesListHeader: some View {
        HStack {
            Button(action: { toggleSort(.name) }) {
                HStack(spacing: 3 * uiScale) {
                    Text("Name")
                    sortIndicator(for: .name)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { toggleSort(.type) }) {
                HStack(spacing: 3 * uiScale) {
                    Text("Type")
                    sortIndicator(for: .type)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 46 * uiScale, alignment: .center)

            midiColumnHeader

            Button(action: { toggleSort(.bpm) }) {
                HStack(spacing: 3 * uiScale) {
                    Text("BPM")
                    sortIndicator(for: .bpm)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 42 * uiScale, alignment: .trailing)

            Button(action: { toggleSort(.changes) }) {
                HStack(spacing: 3 * uiScale) {
                    Text("Mod")
                    sortIndicator(for: .changes)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasAnyChanges)
            .opacity(hasAnyChanges ? 1 : 0.4)
            .frame(width: 60 * uiScale, alignment: .center)
        }
        .font(.system(size: 11 * uiScale))
        .foregroundColor(Self.vintageYellow)
        .padding(.horizontal, 8 * uiScale)
        .padding(.vertical, 4 * uiScale)
        .background(Color.black.opacity(0.2))
    }

    /// The left-hand Files panel: buttons, column headers and the list.
    private var filesSidebar: some View {
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            Text("Files")
                .font(.system(size: 13 * uiScale, weight: .semibold))
                .foregroundColor(.white)

            // Invisible button purely to install the Cmd+A shortcut —
            // it has no visual presence but stays live as long as this
            // view is on screen.
            Button("") {
                selectedFileIDs = Set(files.map { $0.id })
                syncEditorSelection()
            }
            .keyboardShortcut("a", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            HStack(spacing: 8 * uiScale) {
                Button(action: addFiles) {
                    Text("+ Add Files").font(.system(size: 11 * uiScale)).frame(maxWidth: .infinity)
                }
                Button(action: removeSelectedFiles) {
                    Text("- Remove").font(.system(size: 11 * uiScale)).frame(maxWidth: .infinity)
                }
                .disabled(selectedFileIDs.isEmpty)
            }
            .controlSize(.small)

            VStack(spacing: 0) {
                filesListHeader

                ScrollView {
                    VStack(spacing: 0) {
                        if files.isEmpty {
                            // A totally empty ForEach leaves this VStack
                            // with zero real content, which — even with
                            // a `.background` painted behind it — was
                            // found live on this Mac to leave the
                            // ScrollView with no genuine hit-testable
                            // area: dropping a file or folder here did
                            // nothing, while the exact same drag worked
                            // fine the moment the list held ≥1 row. This
                            // placeholder guarantees real laid-out
                            // content at all times, so the drop zone is
                            // always actually there.
                            VStack(spacing: 10 * uiScale) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 40 * uiScale, weight: .regular))
                                    .foregroundColor(Self.vintageYellow)
                                Text("Drop files or folder here")
                                    .font(.system(size: 12 * uiScale, weight: .semibold))
                                    .foregroundColor(Self.vintageYellow)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30 * uiScale)
                        }
                        ForEach(displayedFiles) { audioFile in
                            fileRow(for: audioFile)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 200 * uiScale, alignment: .top)
                    .id(changeTick)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.1))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isFileDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: $isFileDropTargeted) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .padding(15 * uiScale)
        .frame(width: sidebarWidth)
        .background(Color.black.opacity(0.15))
    }

    var body: some View {
        HStack(spacing: 0) {
            // -------------------------------------------------------------
            // 1. LEFT SIDEBAR (Files)
            // -------------------------------------------------------------
            filesSidebar

            Divider()

            // -------------------------------------------------------------
            // 2. RIGHT PANEL (Metadata editor)
            // -------------------------------------------------------------
            VStack(spacing: 20 * uiScale) {
                HStack(alignment: .top) {
                    Form {
                        Picker("Scale:", selection: Binding(
                            get: { selectedScale },
                            set: { setScale($0) }
                        )) {
                            ForEach(displayOptions(scaleOptions, current: selectedScale), id: \.self) { Text($0) }
                        }
                        Picker("Genre:", selection: Binding(
                            get: { selectedGenre },
                            set: { setGenre($0) }
                        )) {
                            ForEach(displayOptions(genreOptions, current: selectedGenre), id: \.self) { Text($0) }
                        }
                        Picker("Key:", selection: Binding(
                            get: { selectedKey },
                            set: { setKey($0) }
                        )) {
                            ForEach(displayOptions(keyOptions, current: selectedKey), id: \.self) { Text($0) }
                        }
                    }
                    .font(.system(size: 13 * uiScale))
                    .pickerStyle(.menu)
                    .frame(width: 260 * uiScale)
                    .disabled(activeIndices.isEmpty)

                    loopTypeControl
                        .disabled(activeIndices.isEmpty)

                    Spacer()

                    // The ASCII-art logo above was fragile to scale as text: its
                    // Unicode block glyphs only line up pixel-for-pixel at one
                    // exact font size + negative line-spacing, so scaling either
                    // (even a uniform uiScale) broke the alignment and turned it
                    // into illegible overlapping blocks at Small.
                    //
                    // "logo" (Assets.xcassets/logo.imageset) is a pixel-perfect
                    // bitmap reconstruction of that same art (generated directly
                    // from its glyph data, not a screenshot), at high resolution.
                    // As an image it just scales by ordinary interpolation, so it
                    // stays crisp and legible at all three presets.
                    Image("logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240 * uiScale)
                }

                // Suggestive Key/Mode analysis: reads the loop's own
                // embedded MIDI performance if it has one, otherwise
                // estimates from the audio (see KeyModeAnalyzer). Purely
                // informational — the result is only ever shown as text
                // here, next to the Analyze button (the current Key/Mode is
                // already visible in the Scale/Key Pickers above, so it
                // isn't repeated); it never writes into
                // `pendingKey`/`pendingMode` itself. Applying a suggestion
                // is done by hand via the Scale/Key Pickers above, exactly
                // like picking any other value.
                HStack(spacing: 8 * uiScale) {
                    Button(action: analyzeSelectedFilesKey) {
                        HStack(spacing: 6 * uiScale) {
                            if isAnalyzing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isAnalyzing ? "Analyzing…" : "Analyze Key/Mode")
                                .font(.system(size: 12 * uiScale))
                        }
                    }
                    .disabled(activeIndices.isEmpty || isAnalyzing)

                    Text(analysisInfoText)
                        .font(.system(size: 10 * uiScale))
                        .foregroundColor(Self.vintageYellow)
                }
                // Lines the button up with the Scale/Genre/Key *dropdowns*
                // themselves rather than their labels — this offset is the
                // measured width of the label column Form reserves for
                // "Scale:"/"Genre:"/"Key:" plus its label-to-control gap.
                .padding(.leading, 46 * uiScale)
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8 * uiScale) {
                    Text("Instrument Descriptors:")
                        .font(.system(size: 13 * uiScale, weight: .bold))
                        .foregroundColor(.white)

                    HStack(spacing: 15 * uiScale) {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(categoryOptions, id: \.self) { cat in
                                    optionRow(
                                        text: cat,
                                        isSelected: selectedCategory == cat,
                                        showsDisclosure: AppleLoopVocabulary.subcategoriesAreApplicable(for: cat)
                                    ) {
                                        setCategory(cat)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: 170 * uiScale, height: 350 * uiScale)
                        .background(Color.black.opacity(0.1))
                        .cornerRadius(6)

                        ZStack {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(subcategoryOptions, id: \.self) { sub in
                                        optionRow(text: sub, isSelected: selectedSubcategory == sub) {
                                            setSubcategory(sub)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(width: 170 * uiScale)
                            .background(Color.black.opacity(0.1))
                            .cornerRadius(6)
                            .opacity(subcategoriesApplicable ? 1 : 0)

                            if !subcategoriesApplicable {
                                Text("No subcategories\nfor this category")
                                    .font(.system(size: 11 * uiScale))
                                    .foregroundColor(.gray)
                                    .multilineTextAlignment(.center)
                                    .padding()
                            }
                        }
                        .frame(height: 350 * uiScale)

                        VStack(spacing: 6 * uiScale) {
                            ForEach(0..<descriptorsData.count, id: \.self) { index in
                                HStack(spacing: 8 * uiScale) {
                                    descriptorButton(text: descriptorsData[index].0)
                                    descriptorButton(text: descriptorsData[index].1)
                                }
                            }
                        }
                        .frame(width: 220 * uiScale)
                    }
                }
                .disabled(activeIndices.isEmpty)

                HStack {
                    Spacer()
                    Button(action: cancelSelectedFilesChanges) {
                        Text("Cancel").font(.system(size: 13 * uiScale))
                    }
                    .disabled(!activeIndices.contains(where: { files[$0].hasChanges }))
                    Button(action: saveSelectedFiles) {
                        Text("Save").font(.system(size: 13 * uiScale))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!activeIndices.contains(where: { files[$0].hasChanges }))
                }
            }
            .padding(25 * uiScale)
        }
        .frame(width: windowWidth, height: windowHeight)
        .preferredColorScheme(.dark)
        .alert("Apple Loop Editor", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        // Space bar plays/stops the loop of whatever file is selected, and
        // the Up/Down arrows move the selection to the previous/next file
        // (following playback along if something's currently looping). A
        // local NSEvent monitor (rather than SwiftUI's `.onKeyPress`) is
        // used so this fires regardless of which control currently has
        // keyboard focus, and so the event can be swallowed (`return nil`)
        // instead of also activating a focused button or, for the arrows,
        // moving focus around a control. The closures are kept as tiny
        // one-liners calling out to plain methods — an inline closure with
        // a guard + call + return here was enough extra expression
        // complexity to blow the type-checker's budget for the whole
        // (already large) `body`.
        .onAppear(perform: installSpaceKeyMonitor)
        .onDisappear(perform: teardownSpaceKeyMonitor)
    }

    private func installSpaceKeyMonitor() {
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handleKeyDown)
    }

    private func teardownSpaceKeyMonitor() {
        if let spaceKeyMonitor {
            NSEvent.removeMonitor(spaceKeyMonitor)
        }
        spaceKeyMonitor = nil
        stopPlayback()
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 49: // kVK_Space
            toggleLoopPlayback()
            return nil
        case 126: // kVK_UpArrow
            return moveSelection(by: -1) ? nil : event
        case 125: // kVK_DownArrow
            return moveSelection(by: 1) ? nil : event
        default:
            return event
        }
    }

    /// Moves the single-file selection to the previous (`offset: -1`) or
    /// next (`offset: 1`) row as currently shown in the Files list —
    /// `displayedFiles`, not `files`, so this follows whatever sort order
    /// (if any) the user has clicked into — clamped to the list's bounds
    /// (no wraparound). Routes through `syncEditorSelection()` — the same
    /// path a plain click takes — so this also follows playback along if
    /// something's currently looping, exactly like clicking the row would.
    /// Returns `false` (nothing to do) when the list is empty, so the
    /// caller can let the key event through instead of swallowing it for no
    /// reason.
    @discardableResult
    private func moveSelection(by offset: Int) -> Bool {
        let ordered = displayedFiles
        guard !ordered.isEmpty else { return false }
        let currentIndex = selectedFileID.flatMap { id in ordered.firstIndex(where: { $0.id == id }) }
        let newIndex: Int
        if let currentIndex {
            newIndex = min(max(currentIndex + offset, 0), ordered.count - 1)
        } else {
            // Nothing (or a multi-selection) was active: Down starts at the
            // top of the list, Up starts at the bottom.
            newIndex = offset > 0 ? 0 : ordered.count - 1
        }
        let newID = ordered[newIndex].id
        selectedFileIDs = [newID]
        selectionAnchorID = newID
        syncEditorSelection()
        return true
    }

    /// Small speaker glyph shown in a file row while that file is looping.
    /// Pulled out to its own function (rather than an inline `if` inside
    /// the `ForEach`) to keep the already-large `body` expression cheap
    /// enough for the type-checker.
    @ViewBuilder
    private func playingIndicator(for audioFile: AudioFile, isSelected: Bool) -> some View {
        if playingFileID == audioFile.id {
            // The row's own selection highlight is also `.accentColor`
            // (see the `.background(...)` on the row below), so when the
            // playing file is also the selected row, an accent-colored
            // icon would sit invisibly on an accent-colored background.
            // Use white there instead so the indicator always reads.
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11 * uiScale))
                .foregroundColor(isSelected ? .white : .accentColor)
        }
    }

    /// One row in the plain category/subcategory lists. Deliberately NOT a
    /// SwiftUI `List` row — see the architecture note above.
    @ViewBuilder
    /// "Type: Loop / One-Shot" control. Only Loop -> One-Shot is supported
    /// (see `AppleLoopTagEdit.convertToOneShot`), so the down arrow next to
    /// "Loop" shows that's the only direction that applies; a file that's
    /// already a One-Shot on disk can't be switched back to Loop.
    /// The three rows (Type: / Loop / One-Shot) are laid out to line up
    /// with the neighboring Form's Scale/Genre/Key rows.
    private var loopTypeControl: some View {
        let allAlreadyOneShot = !activeIndices.isEmpty && activeIndices.allSatisfy { files[$0].file.tags.isOneShot }
        return VStack(alignment: .leading, spacing: 10 * uiScale) {
            Text("Type:")
                .font(.system(size: 13 * uiScale))
                .foregroundColor(.secondary)

            HStack(spacing: 4 * uiScale) {
                Button(action: { setIsOneShot(false) }) {
                    HStack(spacing: 6 * uiScale) {
                        Image(systemName: selectedIsOneShot == false ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 13 * uiScale))
                            .foregroundColor(selectedIsOneShot == false ? .accentColor : .secondary)
                        Text("Loop")
                            .font(.system(size: 13 * uiScale))
                    }
                }
                .buttonStyle(.plain)
                .disabled(allAlreadyOneShot)
                .opacity(allAlreadyOneShot ? 0.4 : 1)

                Image(systemName: "arrow.down")
                    .font(.system(size: 10 * uiScale, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Button(action: { setIsOneShot(true) }) {
                HStack(spacing: 6 * uiScale) {
                    Image(systemName: selectedIsOneShot == true ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13 * uiScale))
                        .foregroundColor(selectedIsOneShot == true ? .accentColor : .secondary)
                    Text("One-Shot")
                        .font(.system(size: 13 * uiScale))
                }
            }
            .buttonStyle(.plain)
        }
        .frame(width: 110 * uiScale, alignment: .leading)
    }

    private func optionRow(
        text: String,
        isSelected: Bool,
        showsDisclosure: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4 * uiScale) {
                Text(text)
                    .font(.system(size: 12 * uiScale))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9 * uiScale, weight: .semibold))
                        .opacity(0.6)
                }
            }
            .padding(.horizontal, 8 * uiScale)
            .padding(.vertical, 4 * uiScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - User-edit actions
    //
    // Each of these updates the @State that drives the control's own look
    // AND, in the very same synchronous call, `files[idx].pendingX` — no
    // List selection binding, no onChange, no async race.

    private func selectFile(_ id: UUID) {
        selectedFileID = id
        loadEditorFields(from: files.first(where: { $0.id == id }))
        // If something is already looping, follow the new selection
        // straight away instead of waiting for another Space press.
        if playingFileID != nil, playingFileID != id {
            startPlayback(for: id)
        }
    }

    /// Left-click routing for a file row, matching normal Finder/macOS
    /// behavior: plain click replaces the whole selection with just this
    /// row; Cmd-click toggles this row in/out of the existing selection
    /// (so Cmd+A followed by Cmd-clicking a couple of rows to exclude them
    /// works as expected); Shift-click selects the whole range between the
    /// last plain/Cmd-clicked row and this one.
    private func handleRowClick(_ id: UUID) {
        let modifiers = NSEvent.modifierFlags
        let ordered = displayedFiles
        if modifiers.contains(.shift), let anchorID = selectionAnchorID,
           let anchorIndex = ordered.firstIndex(where: { $0.id == anchorID }),
           let clickedIndex = ordered.firstIndex(where: { $0.id == id }) {
            let range = anchorIndex < clickedIndex ? anchorIndex...clickedIndex : clickedIndex...anchorIndex
            selectedFileIDs = Set(range.map { ordered[$0].id })
            // Anchor deliberately stays put — a second Shift-click re-ranges
            // from the same starting row, not from this one.
        } else if modifiers.contains(.command) {
            if selectedFileIDs.contains(id) {
                selectedFileIDs.remove(id)
            } else {
                selectedFileIDs.insert(id)
            }
            selectionAnchorID = id
        } else {
            selectedFileIDs = [id]
            selectionAnchorID = id
        }
        syncEditorSelection()
    }

    /// The editor panel only ever shows one file at a time, so it tracks
    /// `selectedFileIDs`: exactly one row selected loads that file into the
    /// form, anything else (none, or several for a bulk Remove) clears it.
    private func syncEditorSelection() {
        if selectedFileIDs.count == 1, let onlyID = selectedFileIDs.first {
            selectFile(onlyID)
        } else if selectedFileIDs.count > 1 {
            selectedFileID = nil
            loadEditorFieldsForMultiSelection()
            stopPlayback()
        } else {
            selectedFileID = nil
            loadEditorFields(from: nil)
            stopPlayback()
        }
    }

    /// Starts (or restarts) looped playback of `id`, replacing whatever was
    /// playing before. Silently does nothing if `id` no longer exists in
    /// `files` (e.g. a race with removal) rather than surfacing an alert —
    /// playback failing to switch isn't worth interrupting the user for.
    private func startPlayback(for id: UUID) {
        guard let audioFile = files.first(where: { $0.id == id }) else { return }
        audioPlayer?.stop()
        do {
            let player = try AVAudioPlayer(contentsOf: audioFile.file.url)
            player.numberOfLoops = -1 // loop forever until explicitly stopped
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            playingFileID = id
        } catch {
            audioPlayer = nil
            playingFileID = nil
            errorMessage = "Impossible de lire \(audioFile.name) :\n\(error.localizedDescription)"
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingFileID = nil
    }

    /// Space bar: stop if something's looping, otherwise start looping
    /// whatever's currently selected. No-op if nothing is selected.
    private func toggleLoopPlayback() {
        if playingFileID != nil {
            stopPlayback()
        } else if let selectedFileID {
            startPlayback(for: selectedFileID)
        }
    }

    private func setScale(_ newValue: String) {
        guard newValue != "(Multiple)" else { return }
        selectedScale = newValue
        let value = (newValue == "(None)") ? "" : newValue
        for idx in activeIndices { files[idx].pendingMode = value }
        changeTick += 1
    }

    private func setGenre(_ newValue: String) {
        guard newValue != "(Multiple)" else { return }
        selectedGenre = newValue
        let value = (newValue == "(None)") ? "" : newValue
        for idx in activeIndices { files[idx].pendingGenre = value }
        changeTick += 1
    }

    private func setKey(_ newValue: String) {
        guard newValue != "(Multiple)" else { return }
        selectedKey = newValue
        let value = (newValue == "(None)") ? "" : newValue
        for idx in activeIndices { files[idx].pendingKey = value }
        changeTick += 1
    }

    /// Runs `KeyModeAnalyzer` for every selected file in the background
    /// (file I/O + FFT can take a moment, so this must never block the main
    /// thread), then stores each result in `keyModeAnalysisResults` — purely
    /// informational, shown as text next to the button (`analysisInfoText`).
    /// Never touches `pendingKey`/`pendingMode`: applying a suggestion is
    /// always a deliberate Picker click, not something Analyze does for you.
    private func analyzeSelectedFilesKey() {
        guard !activeIndices.isEmpty, !isAnalyzing else { return }
        isAnalyzing = true
        let targets = activeIndices.map { (id: files[$0].id, url: files[$0].file.url) }

        Task.detached(priority: .userInitiated) {
            var results: [UUID: Result<KeyModeSuggestion, Error>] = [:]
            for target in targets {
                do {
                    results[target.id] = .success(try KeyModeAnalyzer.analyze(url: target.url))
                } catch {
                    results[target.id] = .failure(error)
                }
            }
            await MainActor.run {
                storeAnalysisResults(results, targets: targets)
            }
        }
    }

    /// Stores `analyzeSelectedFilesKey()`'s background results, on the main
    /// actor. Purely informational — never writes `pendingKey`/`pendingMode`
    /// and never touches disk.
    private func storeAnalysisResults(_ results: [UUID: Result<KeyModeSuggestion, Error>], targets: [(id: UUID, url: URL)]) {
        var failures: [String] = []
        for target in targets {
            guard files.contains(where: { $0.id == target.id }) else { continue }
            switch results[target.id] {
            case .success(let suggestion):
                keyModeAnalysisResults[target.id] = suggestion
            case .failure(let error):
                let name = files.first(where: { $0.id == target.id })?.name ?? target.url.lastPathComponent
                failures.append("\(name) : \(error.localizedDescription)")
            case .none:
                break
            }
        }
        isAnalyzing = false
        if !failures.isEmpty {
            errorMessage = "Analyse impossible pour :\n\(failures.joined(separator: "\n"))"
        }
    }

    /// Only ever moves files from Loop -> One-Shot; files already One-Shot
    /// on disk are left alone (see `AppleLoopTagEdit.convertToOneShot`).
    private func setIsOneShot(_ newValue: Bool) {
        for idx in activeIndices where !files[idx].file.tags.isOneShot {
            files[idx].pendingIsOneShot = newValue
        }
        let values = Set(activeIndices.map { files[$0].pendingIsOneShot })
        selectedIsOneShot = values.count == 1 ? values.first : nil
        changeTick += 1
    }

    /// Picking a category always wipes the subcategory of every selected
    /// file: whatever subcategory a file carried (possibly different from
    /// file to file in a multi-selection, or left over from another
    /// category) no longer applies once the category is chosen explicitly.
    /// A subcategory can then be picked again from the list on the right.
    private func setCategory(_ newValue: String) {
        selectedCategory = newValue
        for idx in activeIndices {
            files[idx].pendingCategory = newValue
            files[idx].pendingSubcategory = ""
        }
        selectedSubcategory = nil
        changeTick += 1
    }

    private func setSubcategory(_ newValue: String) {
        selectedSubcategory = newValue
        for idx in activeIndices {
            files[idx].pendingSubcategory = newValue
            files[idx].subcategoryTouched = true
        }
        changeTick += 1
    }

    /// Loads the currently-selected file's pending values into the @State
    /// form fields. Called whenever a new row is picked in the file list
    /// (row click, new file added+selected, selection cleared, or after
    /// Save/Cancel reset the pending values). This writes the plain @State
    /// vars directly — never through setCategory/setGenre/... — so it can
    /// never be mistaken for a user edit and never touches files[idx].
    private func loadEditorFields(from audioFile: AudioFile?) {
        guard let audioFile else {
            selectedScale = "(None)"
            selectedGenre = "(None)"
            selectedKey = "(None)"
            selectedCategory = nil
            selectedSubcategory = nil
            selectedDescriptors = []
            selectedIsOneShot = nil
            return
        }
        selectedScale = audioFile.pendingMode.isEmpty ? "(None)" : audioFile.pendingMode
        selectedGenre = audioFile.pendingGenre.isEmpty ? "(None)" : audioFile.pendingGenre
        selectedKey = audioFile.pendingKey.isEmpty ? "(None)" : audioFile.pendingKey
        selectedCategory = audioFile.pendingCategory.isEmpty ? nil : audioFile.pendingCategory
        selectedSubcategory = audioFile.pendingSubcategory.isEmpty ? nil : audioFile.pendingSubcategory
        selectedDescriptors = audioFile.pendingDescriptors
        selectedIsOneShot = audioFile.pendingIsOneShot
    }

    /// Same as `loadEditorFields`, for a multi-selection: each field shows
    /// the value every selected file agrees on, or "(Multiple)" — never a
    /// blank/disabled form — so picking a new value for just that field and
    /// hitting Save tags every selected file with it, without touching any
    /// of their other (possibly differing) fields.
    private func loadEditorFieldsForMultiSelection() {
        let selected = activeIndices.map { files[$0] }
        guard !selected.isEmpty else {
            loadEditorFields(from: nil)
            return
        }

        func commonValue(_ values: [String]) -> String {
            let unique = Set(values)
            return unique.count == 1 ? unique.first! : "(Multiple)"
        }

        selectedScale = commonValue(selected.map { $0.pendingMode.isEmpty ? "(None)" : $0.pendingMode })
        selectedGenre = commonValue(selected.map { $0.pendingGenre.isEmpty ? "(None)" : $0.pendingGenre })
        selectedKey = commonValue(selected.map { $0.pendingKey.isEmpty ? "(None)" : $0.pendingKey })

        let categories = Set(selected.map { $0.pendingCategory })
        selectedCategory = (categories.count == 1 && !categories.first!.isEmpty) ? categories.first! : nil

        let subcategories = Set(selected.map { $0.pendingSubcategory })
        selectedSubcategory = (subcategories.count == 1 && !subcategories.first!.isEmpty) ? subcategories.first! : nil

        // A descriptor shows "on" only if every selected file currently has
        // it pending, so toggling it always applies uniformly (adds it to
        // every file that's missing it, or removes it from all of them).
        selectedDescriptors = selected.dropFirst().reduce(selected[0].pendingDescriptors) { common, file in
            common.intersection(file.pendingDescriptors)
        }

        let oneShotValues = Set(selected.map { $0.pendingIsOneShot })
        selectedIsOneShot = oneShotValues.count == 1 ? oneShotValues.first : nil
    }

    @ViewBuilder
    private func descriptorButton(text: String) -> some View {
        let isActive = selectedDescriptors.contains(text)
        Button(action: {
            if isActive {
                selectedDescriptors.remove(text)
                for idx in activeIndices { files[idx].pendingDescriptors.remove(text) }
            } else {
                selectedDescriptors.insert(text)
                for idx in activeIndices { files[idx].pendingDescriptors.insert(text) }
            }
            changeTick += 1
        }) {
            Text(text)
                .font(.system(size: 12 * uiScale))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4 * uiScale)
                .background(isActive ? Color.blue : Color.white)
                .foregroundColor(isActive ? .white : .black)
                .cornerRadius(5)
                .shadow(radius: 0.5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - File management (wired to the engine)

    /// Extensions the engine can actually open. Shared by the Open panel,
    /// drag & drop, and folder recursion so all three stay in sync.
    private static let supportedExtensions: Set<String> = ["caf", "aif", "aiff"]

    /// Pale, slightly faded mustard-yellow used for the empty-list drop
    /// hint — a light "vintage" tone rather than a saturated yellow.
    private static let vintageYellow = Color(red: 0.78, green: 0.72, blue: 0.48).opacity(0.85)

    /// Same coral-red as the "APPLE LOOP EDITOR" logo image, used for the
    /// unsaved-changes "•" dot in the Files list so it reads as an accent
    /// color tying back to the logo rather than just another yellow value.
    private static let logoRed = Color(red: 0.94, green: 0.58, blue: 0.47)

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "caf") ?? .audio,
            UTType(filenameExtension: "aif") ?? .audio,
            UTType(filenameExtension: "aiff") ?? .audio
        ]
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            addSingleFile(url)
        }
    }

    /// Loads one loop file into `files`, skipping duplicates and surfacing
    /// load errors the same way `addFiles()` always has.
    private func addSingleFile(_ url: URL) {
        guard !files.contains(where: { $0.file.url == url }) else { return }
        do {
            let loaded = try AppleLoopFile(url: url)
            files.append(AudioFile(file: loaded))
        } catch {
            errorMessage = "Impossible de lire \(url.lastPathComponent) :\n\(error.localizedDescription)"
        }
    }

    /// Adds `url` if it's a supported loop file, or walks it if it's a
    /// folder — used by drag & drop so dropping a folder full of loops adds
    /// every loop inside it (recursively), silently skipping anything that
    /// isn't a .caf/.aif/.aiff file.
    private func addURLRecursively(_ url: URL) {
        // Under App Sandbox, a URL handed to us by a Finder drag only comes
        // with implicit read access to that exact item — reading INTO a
        // dropped folder (enumerating/opening its contents) needs this
        // explicit security-scope call first, or the enumerator silently
        // sees nothing. Harmless no-op for URLs that don't need it (e.g. a
        // single file), so it's safe to wrap every drop through here.
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope { url.stopAccessingSecurityScopedResource() }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for case let fileURL as URL in enumerator {
                if Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                    addSingleFile(fileURL)
                }
            }
        } else if Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
            addSingleFile(url)
        }
        // Unsupported top-level files dropped directly are silently
        // ignored, same as they always were for a folder's contents —
        // dropping a mixed folder shouldn't spam an error per stray file.
    }

    /// Drop handler for the Files list: accepts one or more file/folder
    /// URLs dragged from Finder. Each URL is resolved asynchronously (as
    /// dictated by NSItemProvider) and then added on the main thread, since
    /// `files` is @State and can only be mutated there.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    self.addURLRecursively(url)
                }
            }
        }
        return accepted
    }

    private func removeSelectedFiles() {
        guard !selectedFileIDs.isEmpty else { return }
        if let playingFileID, selectedFileIDs.contains(playingFileID) {
            stopPlayback()
        }
        files.removeAll { selectedFileIDs.contains($0.id) }
        selectedFileIDs.removeAll()
        selectedFileID = nil
        loadEditorFields(from: nil)
    }

    // MARK: - Save / Cancel (writes via the engine)

    private func saveSelectedFiles() {
        guard !activeIndices.isEmpty else { return }
        var failures: [String] = []
        for idx in activeIndices {
            let edit = files[idx].edit()
            do {
                try files[idx].file.apply(edit)
                files[idx].resetPendingToCurrentTags()
            } catch {
                failures.append("\(files[idx].name) : \(error.localizedDescription)")
            }
        }
        refreshEditorFieldsAfterBulkChange()
        changeTick += 1
        if !failures.isEmpty {
            errorMessage = "Impossible d'enregistrer :\n\(failures.joined(separator: "\n"))"
        }
    }

    private func cancelSelectedFilesChanges() {
        guard !activeIndices.isEmpty else { return }
        for idx in activeIndices {
            files[idx].resetPendingToCurrentTags()
        }
        refreshEditorFieldsAfterBulkChange()
        changeTick += 1
    }

    /// After Save/Cancel touches every selected file, reloads the form from
    /// whatever's still selected — the single file's fresh values, or the
    /// multi-selection's new common-values snapshot.
    private func refreshEditorFieldsAfterBulkChange() {
        if let idx = selectedIndex {
            loadEditorFields(from: files[idx])
        } else if selectedFileIDs.count > 1 {
            loadEditorFieldsForMultiSelection()
        } else {
            loadEditorFields(from: nil)
        }
    }
}

/// Custom "About AppleLoopEditor" panel (replaces the default macOS one via
/// `CommandGroup(replacing: .appInfo)` below) so it can carry a real,
/// clickable link — the stock panel's credits are plain text with no way to
/// add one from SwiftUI without dropping into AppKit attributed strings.
struct AboutView: View {
    private static let vintageYellow = Color(red: 0.78, green: 0.72, blue: 0.48).opacity(0.85)
    private static let logoRed = Color(red: 0.94, green: 0.58, blue: 0.47)
    private static let bandcampURL = URL(string: "https://kidcreme.bandcamp.com/")!
    private static let spotifyURL = URL(string: "https://open.spotify.com/artist/21LRoheW1z49N5d52wlQ5X?si=9KZEYBReTcawoRMW4Cb4GA")!

    var body: some View {
        VStack(spacing: 14) {
            Text("AppleLoopEditor")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(Self.vintageYellow)

            VStack(spacing: 4) {
                Text("Version 1.0")
                Text("GPL-3.0")
                Text("2026")
            }
            .font(.system(size: 12))
            .foregroundColor(Self.vintageYellow.opacity(0.8))

            Text("Built by Creme")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.top, 6)

            VStack(spacing: 4) {
                Link("Listen on Bandcamp", destination: Self.bandcampURL)
                Link("Listen on Spotify", destination: Self.spotifyURL)
            }
            .font(.system(size: 12))
            .foregroundColor(Self.logoRed)
        }
        .padding(30)
        .frame(width: 280)
        .background(Color(red: 0.15, green: 0.17, blue: 0.16))
    }
}

@main
struct AppleLoopEditorApp: App {
    /// Same storage key as `AppleLoopEditorView`'s own `@AppStorage` — this
    /// one only exists so the View menu's Picker below has something to
    /// bind to at the Scene level; both stay in sync automatically because
    /// `@AppStorage` is backed by the same `UserDefaults` key, not by a
    /// reference shared between the two.
    @AppStorage("uiSizePreset") private var uiSizePresetRaw: String = UISizePreset.medium.rawValue

    /// Opens the "about" `Window` scene below when the custom About menu
    /// item is chosen.
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            AppleLoopEditorView()
        }
        .windowStyle(.hiddenTitleBar)
        // The window's content now always reports an EXACT size (see
        // `.frame(width: windowWidth, height: windowHeight)` in
        // `AppleLoopEditorView.body`) rather than a minimum, and
        // `.contentSize` ties the window's allowed size range to exactly
        // that — so dragging an edge or corner has nothing to do (min ==
        // max == the content's own size) and the ONLY way the window
        // changes size is the app itself changing that computed value: a
        // new "Resize Window" preset, or the sidebar widening for a long file name.
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About AppleLoopEditor") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(after: .toolbar) {
                Picker("Resize Window", selection: $uiSizePresetRaw) {
                    ForEach(UISizePreset.allCases, id: \.rawValue) { preset in
                        Text(preset.menuTitle).tag(preset.rawValue)
                    }
                }
            }
        }

        Window("About AppleLoopEditor", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}
