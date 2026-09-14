# App Review reply — Guideline 2.1 (Information Needed)

Paste the "Reply" section into the App Store Connect message thread AND into
App Information → App Review Information → Notes. Attach the screen recording
(item 1) to the thread. The Korean checklist at the bottom is for making the
recording.

---

## Reply (English)

Thank you for the review. Booklip has no accounts, no sign-up, no in-app
purchases, no user-generated content and no paid features, so a demo login
is not applicable. Details below.

### 1. Screen recording

Attached: a recording captured on an iPhone running the latest iOS, starting
from the app launch. It shows: importing an EPUB, a PDF and a TXT file from
the Files app; opening a book; turning pages by tap and swipe; changing theme,
font and size; text-to-speech with the sleep timer; adding a bookmark and a
highlight and jumping back to them from the Contents panel; the library
(folders, grid/list, multi-select) and the Reading Stats screen; and the Cloud
Storage screen (Dropbox / Google Drive / OneDrive connect buttons).

### 2. Purpose and target audience

Booklip is an offline ebook and text reader for files the user already owns.
It solves a simple problem: people who keep their own EPUB, PDF, TXT and
Markdown files (public-domain classics, self-published works, documents,
notes, web-novel exports) have no clean way to read them on iPhone and iPad
with a reading-app experience — proper page turning, fonts, themes, bookmarks,
highlights, a table of contents and listen-aloud. The audience is general
readers, with particular care for Korean-language readers: the system Korean
typefaces are offered, EPUB embedded fonts are rendered faithfully, and legacy
Korean text encodings (EUC-KR / CP949) are detected automatically.

Everything stays on the device: no account, no data collection, no ads, no
network use except when the user chooses to connect a cloud drive.

### 3. Setting up and accessing the main features

No login or credentials are needed.

1. Launch the app. The library is empty on first launch.
2. Tap "+" → "Browse Files" and pick any .epub, .pdf, .txt or .md file from
   the Files app (several can be selected at once). Public-domain sample
   files: https://www.gutenberg.org/ebooks/1342 (Pride and Prejudice — choose
   "EPUB3 (E-Readers incl. images)" or "Plain Text UTF-8").
3. Tap a book to open it.
   - Tap the right / left edge or swipe to turn pages; tap the centre to show
     or hide the toolbars.
   - "Aa" (bottom right): theme, font, size, line spacing, page-turn style.
   - Play icon: text-to-speech (English / Korean voices, speed, pitch, sleep
     timer, auto-scroll).
   - List icon: table of contents, bookmarks, highlights.
   - Bookmark icon (top right): bookmark the current page.
   - Pencil icon: highlight mode — select text, then "Highlight" in the edit
     menu.
   - Magnifier: search inside the book.
4. Library: "Folders" tab to create folders; the checkmark icon for
   multi-select (move / delete); the chart icon for reading statistics.
5. Optional: "+" → "Cloud Storage…" connects Dropbox, Google Drive or OneDrive
   with the user's own account (standard OAuth in a system web sheet, read-only
   scope) and imports files or whole folders. This is optional; every feature
   works without it. If you wish to test it, any personal Dropbox / Google /
   Microsoft account works — the app stores nothing server-side.

### 4. External services, tools and platforms

- Apple frameworks only for core functionality: SwiftUI, TextKit, PDFKit,
  AVSpeechSynthesizer (built-in system voices; no microphone), Core Text.
- Optional cloud import via the providers' public REST APIs with OAuth 2.0 +
  PKCE through ASWebAuthenticationSession, read-only scopes:
  Dropbox API (files.metadata.read, files.content.read), Google Drive API
  (drive.readonly), Microsoft Graph / OneDrive (Files.Read). Tokens are kept
  only on the device.
- Open-source dependency: ZIPFoundation (MIT) for reading EPUB archives.
- No analytics, advertising, crash-reporting, payment, authentication-provider
  or AI services. No servers of our own.

### 5. Regional differences

None. The app functions identically in all regions. The UI is in English; the
reader handles any Unicode text and includes Korean typefaces and voices in
addition to English.

### 6. Regulated industry / protected material

Not applicable. Booklip does not operate in a regulated industry and ships no
third-party books, media or fonts. It contains no bundled content; users open
their own files. The typefaces offered in the Appearance panel are the fonts
that ship with iOS (Georgia, Times New Roman, Apple SD Gothic Neo, Apple
Myungjo, etc.); fonts embedded in a user's EPUB are rendered from that file
only while it is open.

---

## 녹화 체크리스트 (한국어)

실기기(최신 iOS) iPhone에서 화면 녹화(제어 센터 → 화면 기록), 앱 아이콘 탭부터
시작. 3–5분 안에 아래 순서로:

1. 앱 실행 → 빈 서재 또는 기존 서재 화면.
2. "+" → Browse Files → EPUB 1권, PDF 1개, TXT 1개 가져오기 (퍼블릭 도메인
   파일 사용: 구텐베르크 EPUB/TXT, 직접 만든 PDF/노트). 상용·웹소설 파일은 쓰지 않기.
3. EPUB 열기 → 탭/스와이프로 몇 페이지 넘기기 → 가운데 탭으로 막대 토글.
4. Aa → 테마 2~3개 바꾸기, 글꼴/크기 조절, Paper Book ↔ Vertical Slide.
5. 재생 아이콘 → TTS 시작 (몇 초) → 취침 타이머 메뉴 보여 주고 정지.
6. 북마크 아이콘 → 북마크 추가. 연필 → 문장 선택 → Highlight → 색 선택.
7. 목록 아이콘 → Contents / Bookmarks / Highlights 탭 전환, 북마크 탭해서 이동.
8. 돋보기 → 책 안 검색 한 번.
9. 뒤로 → Folders 탭 → 폴더 만들기 → 체크 아이콘으로 여러 권 선택 → Move.
10. 차트 아이콘 → Reading Stats.
11. "+" → Cloud Storage… 화면 보여 주기 (Connect 버튼까지만; 로그인은 생략해도 됨.
    보여 주려면 본인 계정으로 Dropbox 연결 → 파일 하나 가져오기).
12. PDF 열어서 몇 페이지 넘기기 → 종료.

녹화 파일은 App Store Connect 답장 스레드에 첨부(용량 제한 시 iCloud/Drive
링크). 위 "Reply" 본문을 답장과 App Review Information → Notes 양쪽에 붙여 넣기.
