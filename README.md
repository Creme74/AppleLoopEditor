# Apple Loop Editor

Apple Loop metadata editor — this app edits any **Apple Loop-specific metadata** (**Scale**, **Genre**, **Key**, **Type** and **Instrument Descriptors**) already embedded in existing Apple Loops, without going through Logic Pro or GarageBand. It replaces Apple's discontinued Apple Loops Utility, which is no longer compatible with modern ARM64 architectures.

![AppleLoopEditor preview](Docs/screenshot.png)

## Features

- Edit the **Scale**, **Genre**, **Key**, **Type** (Loop / One-Shot) tags
- Full **Instrument Descriptors** editing (category, subcategory, and attributes such as Single/Ensemble, Clean/Distorted, Acoustic/Electric, etc.)
- **Suggestive Key/Mode analysis**: suggests a key and mode from the loop's embedded MIDI performance if present, or from audio analysis otherwise (FFT + Krumhansl-Schmuckler key-profile correlation) — purely indicative, never overwrites existing tags
- **Batch** editing (multi-file selection)
- Built-in audio playback/preview of the selected loop, using spacebar
- Drag and drop of files or entire folders
- Automatic container format detection (classic AIFF or CAF)

## Download

No Xcode needed: download the latest compiled build directly from the **[Releases](https://github.com/Creme74/AppleLoopEditor/releases/latest)** page, unzip it, and launch `AppleLoopEditor.app`.

> **First launch:** since the app isn't signed with a paid Apple Developer account, macOS (Gatekeeper) will show a warning the first time you open it. This is only needed once.
> - **macOS Ventura and earlier:** right-click (or Ctrl-click) `AppleLoopEditor.app` → **Open**, then confirm.
> - **macOS Sequoia (15) and later:** the right-click shortcut no longer works. Go to **System Settings → Privacy & Security**, find the message about `AppleLoopEditor` being blocked, click **Open Anyway**, then confirm with your password.

## Build from source

- macOS 13 or later (tested on macOS 14)
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
