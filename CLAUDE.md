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
  `INFOPLIST_KEY_*`). Do NOT add `INFOPLIST_FILE` — there is no plist file and
  doing so breaks the build.

## Build / run
```bash
cd /Users/kevinpark/Workspace/iOS/ReaderApp
xcodebuild -project Booklip.xcodeproj -scheme Booklip \
  -destination 'platform=iOS Simulator,id=39EC201A-8B80-4740-AAC6-B45967A5ED2D' build
# macOS target also builds: -destination 'platform=macOS'
```
Always build after changes. Commit only when the user asks; end commit messages
with `Co-Authored-By: Claude <noreply@anthropic.com>`.

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
- **Paging is character-based** (`page()`): pick the glyph near the view's bottom
  and scroll so it sits at top. Before measuring, `ensureLayout(forBoundingRect:)`
  on the reference region (from the current frontier downward) so the glyph isn't
  clamped to the layout frontier (caused "same page" repeats, worse deeper in).
  Set offset instantly (`animated:false`) + CATransition for the visual; animated
  scroll got reverted by contentSize growth. `pageTargetY` handles rapid taps;
  paging/dragging cancels `pendingRestore`.
- **Position restore** retries until the view is laid out, then verifies the
  offset stuck (SwiftUI's post-`updateUIView` frame set can reset it to 0).
- **EPUB "some books unreadable"** = font-obfuscation. `EPUBParser` extracts
  embedded fonts, de-obfuscates (IDPF SHA-1 / Adobe UUID key, XOR of first
  1040/1024 bytes) using the package unique-identifier, registers via CoreText,
  and renders body text in that font (toggle: Appearance → "Use book's font").
- **TTS** must be chunked (≤500 chars; `TTSManager.maxChunkLength`, paragraphs
  subdivided at sentence boundaries) or AVSpeechSynthesizer crashes on
  whole-document utterances. TTS is stopped only on reader dismissal, never on
  scenePhase `.inactive` (lock screen / Control Center must not kill playback).
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
