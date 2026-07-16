# iOS Reader App — Xcode Setup

## Requirements
- macOS 14+, Xcode 15+
- iOS 17+ deployment target

## Steps

### 1. Create Xcode Project
1. Open Xcode → **File › New › Project**
2. Choose **iOS › App**
3. Product Name: `ReaderApp`
4. Interface: **SwiftUI**, Language: **Swift**
5. Uncheck "Include Tests" (add later if needed)

### 2. Add SPM Dependency (ZIPFoundation — for ePub)
1. **File › Add Package Dependencies…**
2. Enter URL: `https://github.com/weichsel/ZIPFoundation`
3. Version: **Up to Next Major** from `0.9.19`
4. Add to target **ReaderApp**

### 3. Copy Source Files
Delete the auto-generated `ContentView.swift` and `<AppName>App.swift`.

Then drag all folders from `Sources/ReaderApp/` into the Xcode project navigator:
```
App/
Models/
Persistence/
Parsers/
ViewModels/
Views/
  Library/
  Reader/
  Panels/
```
Make sure **"Copy items if needed"** is checked and the target membership is set to **ReaderApp**.

### 4. Configure Info.plist
Add these keys (required for file import & audio):

| Key | Value |
|-----|-------|
| `UISupportsDocumentBrowser` | YES |
| `LSSupportsOpeningDocumentsInPlace` | YES |
| `NSMicrophoneUsageDescription` | Not needed — TTS uses AVSpeechSynthesizer (no mic) |

For iCloud Drive support (optional), enable **iCloud Documents** in Signing & Capabilities.

### 5. Build & Run
Select a Simulator (iPhone 15 or later) and press **⌘R**.

## Architecture Overview

```
LibraryView  ──────────────────────────────────────────────
│  (bookshelf grid, file import via system document picker)
│
└─► ReaderView
      │  top bar: title + % progress
      │  content: TextReaderView (txt/epub/md) or PDFReaderView
      │  bottom bar: ReadingProgressBar + TTS + Appearance buttons
      │
      ├─► AppearancePanel (sheet)
      │     color presets, font picker, size slider, line spacing
      │
      └─► TTSPanel (sheet)
            voice picker, play/pause/stop, speed, pitch
```

## File Import Sources
The system document picker automatically shows:
- **Files app** (local + iCloud Drive)
- **iCloud Drive**
- **OneDrive** (if Microsoft OneDrive app is installed)
- **Google Drive** (if Google Drive app is installed)

No special integration needed — all cloud providers expose themselves through the standard `UIDocumentPickerViewController`.

## Supported Formats
| Format | Parser | Notes |
|--------|--------|-------|
| `.txt` | `PlainTextParser` | UTF-8 |
| `.epub` | `EPUBParser` | Extracts & strips HTML from spine items via ZIPFoundation |
| `.pdf`  | `PDFParser` + `PDFReaderView` | Uses PDFKit; native rendering |
| `.md`   | `MarkdownParser` | Rendered with `AttributedString(markdown:)` |
