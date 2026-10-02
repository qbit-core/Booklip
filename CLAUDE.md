# CLAUDE.md — Booklip

Guidance for Claude Code when working in this repo. Read this first; it captures
the app, architecture, decisions, and gotchas so answers can be immediate.

## What this is
**Booklip** (formerly "ReaderApp") — a clean, offline-first iOS/macOS ebook &
text reader. Users bring their own files. SwiftUI, iOS 17+, Swift 6 strict
concurrency ("Approachable Concurrency" → default-main-actor on). Single
dependency: **ZIPFoundation** (SPM, for EPUB).

- Repo root: `/Users/kevinpark/Workspace/iOS/ReaderApp`
- Project: `Booklip.xcodeproj` · Scheme/target: `Booklip` · Source folder: `Booklip/`
- `@main struct BooklipApp` in `Booklip/App/BooklipApp.swift`
- Bundle id: `qbit-core.Booklip` · Team: `RFL8CL8THH`
- Info.plist is **generated** (`GENERATE_INFOPLIST_FILE = YES`, settings via
  `INFOPLIST_KEY_*`) and merged with `Booklip-Info.plist` at the repo root
  (`INFOPLIST_FILE`). That file holds only what `INFOPLIST_KEY_*` cannot
  express — `UIBackgroundModes` — and must stay OUTSIDE `Booklip/` (the
  synchronized folder would also copy it as a resource and break the build).
  `INFOPLIST_KEY_UIBackgroundModes` is silently ignored by Xcode: 1.5.5
  build 10 shipped without the key, so TTS died on screen lock. After touching
  this, check the product: `PlistBuddy -c "Print :UIBackgroundModes"`.

## Build / run
```bash
cd /Users/kevinpark/Workspace/iOS/ReaderApp
xcodebuild -project Booklip.xcodeproj -scheme Booklip \
  -destination 'platform=iOS Simulator,id=39EC201A-8B80-4740-AAC6-B45967A5ED2D' build
# macOS target also builds: -destination 'platform=macOS'
```
Always build after changes. Commit only when the user asks; end commit messages
with `Co-Authored-By: Claude <noreply@anthropic.com>`.

**Changelog is part of every change.** `README.md` holds the changelog twice —
under `## English` and `## 한국어` — newest first: the latest date is the
first heading and the newest item is the first bullet under it. Whenever you
change the app, add the entry at the TOP of BOTH sections (same date heading
`#### YYYY-MM-DD`, same items, version bumps in bold) without being asked, in the same commit as
the change.

## Architecture (Booklip/)
- **App/** — `BooklipApp` (entry, injects `LibraryViewModel` + `ReadingSettings`),
  `ViewExtensions` (`hideNavigationBar`, `readerCover`, `platformTrailing`).
- **Models/** — `Book` (has `progress`, `progressUpdated`, `folderID`,
  `coverFileName`), `BookFolder`, `Bookmark`, `Highlight`(+`HighlightColor`),
  `ReadingSettings` (fonts incl. Korean, color presets, `pageEffect`,
  `useEmbeddedFont`, `autoScrollSpeed`).
- **Parsers/** — `BookParser`/`ParserFactory` (static dispatch, all `nonisolated`),
  `PlainTextParser` (encoding fallback chain: UTF-8→auto→EUC-KR→CP949→UTF-16→…),
  `EPUBParser` (XMLParser OPF, embedded fonts + de-obfuscation, cover, NCX/nav
  TOC), `PDFParser`, `MarkdownParser`, `FontRegistrar` (CoreText registration).
- **Persistence/** — `BookStore` (UserDefaults + Documents files: books, folders,
  bookmarks, highlights, per-book settings, covers), `ProgressSync` (iCloud KVS,
  **disabled** — see below), `ReadingStats` (time + day streak).
- **ViewModels/** — `LibraryViewModel` (library, folders, multi-select, sort,
  view modes, import, `openBook`), `ReaderViewModel` (loads content off-main via
  continuation at userInteractive QoS; chapters/bookmarks/highlights;
  `embeddedFontName`), `TTSManager` (AVSpeechSynthesizer, chunked, sleep timer).
- **Views/** — `Library/` (LibraryView, BookCard, StatsView, ViewModeMenu/SortMenu),
  `Reader/` (ReaderView, **TextReaderView** = the hard part, PDFReaderView,
  ContentsPanel = TOC/Bookmarks/Highlights, ReadingProgressBar),
  `Panels/` (AppearancePanel, TTSPanel), `Cloud/` (CloudConnectView,
  CloudFileBrowserView).

## Features (all implemented)
Formats: **.txt .epub .pdf .md**. Library: folders, sort, grid/list view modes,
multi-select move/delete, real EPUB covers. Reader: customizable
font/size/spacing/color/theme (global; `BookStore.BookSettings` exists but is
not wired), page-turn effects (vertical slide / paper), tap zones + left/right
swipe paging, **auto-scroll**, nested **table of contents** (NCX/nav),
**bookmarks**, **highlights** (4 colors; iOS: highlight-mode toggle in the
bottom bar → select → "Highlight" edit menu; macOS: select → context menu),
`ContentsPanel` (TOC / bookmarks / highlights) from the list button,
reading-position restore. **TTS** (en-US + ko-KR voices, speed/pitch, word
highlight + follow, sleep timer). **Reading stats** (time + streak).
**Cloud import** via OAuth (Dropbox, Google Drive, OneDrive — all live;
listings follow pagination cursors). The browser's Select mode picks files
AND folders (a cloud folder becomes a library folder of the same name,
subfolders flattened into it), supports Photos-style sweep selection and
All/None. Downloads go through `BackgroundDownloader` (background
`URLSession`) so they keep running while the app is suspended; a transfer
that finishes after a relaunch is imported via `orphanHandler`.
Library multi-select also has sweep selection + All/None (`DragSelection.swift`).

## Key decisions & gotchas (don't relearn these)
- **Reader opens as a full-screen cover** (`readerCover`, iOS `fullScreenCover` /
  macOS sheet), NOT a navigation push — pushing fought `.searchable` (stray back
  button, top gap). Driven by `LibraryViewModel.openBook`.
- **TextReaderView uses a native UITextView/NSTextView** (TextKit 1, via
  `UITextView(usingTextLayoutManager: false)`) for lazy layout of multi-MB docs.
  `isSelectable = false` normally (tap = paging); true only in highlight mode.
- **Progress is character-based**, not pixel-based: `charProgress` =
  characterIndex-at-top / textStorage.length. Pixel offsets are unreliable
  because TextKit only *estimates* content height until laid out. Both
  platforms: the macOS view also opts into TextKit 1 + non-contiguous layout
  (`textView.layoutManager?.allowsNonContiguousLayout = true`) and lands on
  the target character's line via the same ensureLayout(forCharacterRange:)
  probe. Paper mode on macOS swallows wheel/trackpad events and pages.
- **One index space.** `ReaderViewModel.plainText` is index-for-index identical
  to the text view's `NSTextStorage`: `EPUBParser` emits `text + "\n\n"` per
  text block and `EPUBParser.imagePlaceholder` (U+FFFC + "\n\n") per image,
  exactly what `applyContent` inserts. Every offset (TTS `spokenRange`,
  `Chapter.progress`, saved `charIndex`, highlights) relies on this — never
  trim or reshape one side without the other.
- **Big-book stalls were font fixing, not layout.** A base font without glyphs
  for the text (Georgia on Korean) makes TextKit insert per-run substitute
  fonts (quadratic memmove) inside ensureLayout — 173 s seeks. `FontRegistrar.
  effectiveFontName` swaps to a covering font; `landingLoop` uses an exact
  `ensureLayout(forCharacterRange:)` probe (0–1 ms). `sample <pid>` before
  trusting layout timings.
- **Paging is line-fragment-based** (`page()` on iOS, `navigatePage` on macOS):
  forward lands on the first line the bottom edge cuts (its ink — baseline +
  descender, `CutLine.isCut` — runs past the viewport bottom); backward on the first
  fragment within one viewport above the current top. No font-metric step —
  `fontSize + lineSpacing` under-measured real line heights (worse for Korean
  faces) and, combined with a 120pt-short "text area", re-showed several lines
  per turn. The search rect always starts at the laid-out visible top: a rect
  that began near the boundary let `glyphRange(forBoundingRect:)` answer from
  estimated geometry under non-contiguous layout and skip a page. Set offset
  instantly (`animated:false`) + CATransition for the visual; animated scroll
  got reverted by contentSize growth. `pageTargetY` handles rapid taps;
  paging/dragging cancels `pendingRestore`.
- **No half-cut last line.** While the page is at rest a cover view in the
  page colour (`cutCover`, both platforms) hides the line the bottom edge cuts
  through, and that same line is where the next page starts — both use
  `CutLine`, so nothing is skipped or repeated. The cover is hidden while the
  text moves under a finger, the scroll wheel or auto-scroll. Do not bring
  back a "mostly visible counts as shown" tolerance in `page()` /
  `navigatePage`: the cover would then hide a line the next page never shows.
- **UITextView silently restores a stale scroll position.** Whenever TextKit
  revises the estimated document height (big txt: every few pages),
  `-[UITextView _updateContentSize]` calls
  `_setContentOffsetWithoutRecordingScrollPosition:` with its own recorded
  offset — still the PREVIOUS page right after a turn — so the view snapped
  back ("read half the last page again", ~1 in 10 turns). `ReaderTextView.
  pinnedOffsetY` undoes any non-finger offset change while set; page() pins
  BEFORE setContentOffset (the restore can fire inside layoutIfNeeded),
  landingLoop pins where it lands, and drag/auto-scroll/TTS-follow unpin.
  Diagnose this class of bug by overriding `contentOffset.didSet` and logging
  `Thread.callStackSymbols`.
- **Position restore** retries until the view is laid out, then verifies the
  offset stuck (SwiftUI's post-`updateUIView` frame set can reset it to 0).
- **EPUB "some books unreadable"** = font-obfuscation. `EPUBParser` extracts
  embedded fonts, de-obfuscates (IDPF SHA-1 / Adobe UUID key, XOR of first
  1040/1024 bytes) using the package unique-identifier, registers via CoreText,
  and renders body text in that font (toggle: Appearance → "Use book's font").
- **TTS** must be chunked or AVSpeechSynthesizer crashes on whole-document
  utterances: whole sentences are packed up to `TTSManager.maxChunkLength`
  (240). A sentence is NEVER cut — one longer than 240 is its own utterance,
  read and highlighted whole (hard-splitting at 240 cut words in half:
  "let me un" / "derstand you"). Only past `maxSentenceLength` (2000, text
  with no sentence punctuation) is it split, at whitespace. TTS is stopped only on reader dismissal, never on
  scenePhase `.inactive` (lock screen / Control Center must not kill playback).
- **TTS in the background.** Needs `UIBackgroundModes = audio` actually in the
  built Info.plist (see `Booklip-Info.plist` above), and that alone is not enough:
  AVSpeechSynthesizer deactivates the audio session whenever its queue empties,
  and one-utterance-at-a-time chunking emptied it at every chunk boundary, so a
  locked phone suspended the app there. `TTSManager` now owns session
  activation (`setActive(true)` on speak, off on stop), keeps `queueDepth`
  utterances queued ahead (per-utterance `UtteranceMeta` maps callbacks back to
  document offsets), pauses on interruptions / headphone unplug, and registers
  MPRemoteCommandCenter + Now Playing so the lock screen can control it.
  Remote play (`remotePlay`) resumes a paused synthesizer, and re-speaks from
  `currentChunkIndex` if the synthesizer lost its queue — it must never
  answer `.commandFailed` just because `isPaused` is false.
- **TTS highlight sync.** `willSpeakRangeOfSpeechString` tracks the synthesizer,
  not the speaker. Measured on the simulator: didFinish lands 0.12 s after the
  rendered audio ends (constant, no cross-utterance accumulation), so any lead
  is within one utterance — hence the 240-char cap — plus the output path
  (`outputLatency + ioBufferDuration`, ≈0.2 s on Bluetooth), which the
  highlight delays by. If a device still shows drift with a neural voice, the
  next step is audio-clock sync: `write(_:toBufferCallback:toMarkerCallback:)`
  + AVAudioPlayerNode with marker offsets (markers are empty on simulator
  voices, so it needs a device to develop).
- **Progress save**: `charIndex` is `nil` when unknown (PDF, text not loaded)
  and a real `0` when at the start — `LibraryViewModel.updateProgress` stores
  any non-nil value.
- **Concurrency**: default-main-actor is on; background types (parsers,
  `OPFDelegate`, `NCXDelegate`) are marked `nonisolated`; cloud service classes
  are main-actor ObservableObjects. ObservableObject classes need explicit
  `import Combine`.

## Cloud / OAuth
- OAuth 2.0 + **PKCE** (`OAuthSession`, `ASWebAuthenticationSession` with
  `callbackURLScheme` — so URL schemes do NOT need Info.plist registration).
- Redirect URIs in `CloudConfig`: Dropbox = `booklip://auth/dropbox`; OneDrive &
  Google still `readerapp://…`. Changing a scheme requires updating the
  provider's console too. Client IDs live in `CloudConfig` (`CLOUD_SETUP.md`).
- macOS needs the outgoing-network entitlement for token exchange.
- Dropbox `Dropbox-API-Arg` must be header-safe JSON: non-ASCII (Korean
  paths) is `\u`-escaped (`DropboxService.headerSafeJSON`).
- Sweep selection needs a `ScrollView`; a `List` (UITableView) swallows the
  horizontal pan, so the cloud browser is a `ScrollView` + `LazyVStack`.

## iCloud sync — OFF
`ProgressSync.enabled = false`. iCloud KVS needs the Key-value-storage
entitlement, which requires a **paid** Apple Developer account (not available on
a free personal team → the capability isn't even listed). Touching
`NSUbiquitousKeyValueStore` without it logs "BUG IN CLIENT OF KVS", so it's
gated off. To enable later: add the capability, set `enabled = true`.

## App icon
`scripts/make_icon.py` (Pillow) generates light/dark/tinted 1024² PNGs into
`Assets.xcassets/AppIcon.appiconset`. HIG: opaque light bg, transparent
dark/tinted, full square, no text. NOTE: the user later replaced these with
custom `app_icon_light/dark/tinted.png` (referenced in Contents.json). Root-level
`app_icon_*.png` and any `Booklip — eBook Reader …` export folder are artifacts
(gitignored).

## App Store / export compliance
- Listing copy: `APP_STORE.md`. Name: "Booklip — eBook Reader".
- Crypto used: HTTPS/TLS (OS, exempt), SHA-256 (PKCE), SHA-1 + XOR (EPUB font
  de-obfuscation, IDPF spec). No AES/RSA, no proprietary crypto, no data-at-rest
  encryption → **non-exempt encryption = NO**. Can set
  `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` to skip the per-upload prompt.

## Privacy
All data (books, settings, bookmarks, highlights, progress, stats) is **local**.
No account required. Cloud is opt-in, read-only OAuth; tokens stored in
UserDefaults.
