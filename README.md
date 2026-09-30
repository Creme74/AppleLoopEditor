# Apple Loop Editor

Apple Loop metadata editor for `.aif` and `.caf` files — edit the **Scale**, **Genre**, **Key**, **Type** (Loop / One-Shot) tags and the **Instrument Descriptors** embedded directly in the file, without going through Logic Pro or the Apple Loops Utility.

![AppleLoopEditor preview](Docs/screenshot.png)

## Features

- Edit the **Scale**, **Genre**, **Key**, **Type** (Loop / One-Shot) tags
- Full **Instrument Descriptors** editing (category, subcategory, and attributes such as Single/Ensemble, Clean/Distorted, Acoustic/Electric, etc.)
- **Suggestive Key/Mode analysis**: suggests a key and mode from the loop's embedded MIDI performance if present, or from audio analysis otherwise (FFT + Krumhansl-Schmuckler key-profile correlation) — purely indicative, never overwrites existing tags
- **Batch** editing (multi-file selection)
- Built-in audio playback/preview of the selected loop
- Drag and drop of files or entire folders
- Automatic container format detection (classic AIFF or CAF)

## Download

No Xcode needed: download the latest compiled build directly from the **[Releases](https://github.com/Creme74/AppleLoopEditor/releases/latest)** page, unzip it, and launch `AppleLoopEditor.app`.

> **First launch:** since the app isn't signed with a paid Apple Developer account, macOS (Gatekeeper) will show a warning the first time you open it. Right-click (or Ctrl-click) `AppleLoopEditor.app` → **Open**, then confirm. This is only needed once.

## Build from source

- macOS 13 or later
- Xcode 16 or later

```bash
git clone https://github.com/Creme74/AppleLoopEditor.git
cd AppleLoopEditor
open AppleLoopEditor.xcodeproj
```

Then Run (⌘R) in Xcode.

## License

This project is distributed under the **GPL-3.0-or-later** license — see [LICENSE](LICENSE).

## Author

Made by **Nicolas Scaravilli** (Kid Creme)

- [Bandcamp](https://kidcreme.bandcamp.com/)
- [Spotify](https://open.spotify.com/artist/21LRoheW1z49N5d52wlQ5X)
