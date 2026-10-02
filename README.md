# Booklip

[English](#english) · [한국어](#한국어)

## English

An offline-first ebook and text reader for iOS and macOS. Users bring their own
files (**.txt · .epub · .pdf · .md**). Written in SwiftUI; the only external
dependency is ZIPFoundation, for unpacking EPUBs.

- Library: folders, sorting, grid/list views, multi-select, search, covers
- Reader: font, size, line spacing and colour themes, vertical-slide or
  paper-book page turns, auto-scroll, table of contents, bookmarks, highlights,
  in-book search, dictionary lookup, reading-position restore
- TTS: English and Korean voices, speed and pitch, sentence highlight, sleep
  timer, background playback
- Cloud import: Dropbox, Google Drive, OneDrive
- Reading stats: time read, day streak

See [CLAUDE.md](CLAUDE.md) for build instructions and architecture, and
[CLOUD_SETUP.md](CLOUD_SETUP.md) for cloud sign-in setup.

### Changelog

Compiled from the commit history, by date, oldest first.

#### 2026-05-30
- Project created (initial commit).

#### 2026-06-01
- Added the full ebook reader implementation.
- Added dark and tinted app icon variants.
- Locked SPM dependency versions (`Package.resolved`).
- Fixed an optional `NSTextStorage` unwrap crash on macOS.
- Fixed TTS panel layout overlap; widened the voice list to all languages, then
  narrowed it to English and Korean.
- Fixed QoS priority inversions in loading and TTS; returned `TTSManager` to
  `@MainActor`.
- Disabled the Thread Performance Checker in the Xcode scheme.

#### 2026-06-02
- Fixed a TTS crash on large ePubs by chunking utterances.
- Added sorting and folder organisation to the library.
- Added URL import (OneDrive, Google Drive, any direct link).
- Added OneDrive and Google Drive cloud browsers, plus the `CLOUD_SETUP.md` guide.
- Cloud fixes: `ObservableObject` conformance, `@MainActor` init errors,
  `OAuthSession` actor isolation, macOS sheet sizing, no crash on unconfigured
  credentials, Google Drive redirect URI, outgoing network access in the sandbox.
- Added an iCloud Drive row, then replaced it with Dropbox; fixed a Dropbox
  redirect URI typo; added PKCE to the OAuth flow.
- Tidied the cloud sheet margins and header; fixed the Done button being cut off
  on iPhone.
- iOS reader scrolling fixes: vertical scrolling, a freeze from restyling every
  frame, a freeze on open, and jitter (progress now updates only when scrolling
  settles).
- Added spoken-text highlight and auto-follow during TTS.
- The progress bar now seeks the text (iOS).
- Added multi-select bulk move/delete and grid/list view modes (also on the
  Folders tab).

#### 2026-06-03
- Multi-select now works inside folders and Unfiled.
- Inline EPUB images are rendered; fixed images made invisible by a zero-width
  layout.
- EPUB OPF is parsed with `XMLParser` instead of regex; marked `nonisolated` for
  background parsing.
- Added tap-zone page turning (iOS).
- Added a selectable page-turn effect (Vertical Slide or Paper Book); Paper Book
  turns horizontally, right to left.
- Added multi-select import to the cloud file browser.
- Added Korean fonts to the font picker.
- Fixed the macOS build (optional unwrap in `applyContent`).

#### 2026-06-06
- EPUB embedded fonts are rendered, fixing font-obfuscated books that were
  unreadable.
- Fixed accidental text selection and scroll stutter after returning from the
  background (iOS).
- Fixed an empty SF Symbol warning in the sort menu.
- Temporarily hid OneDrive from the Cloud Storage list.
- Added sort and view-mode controls inside folders.
- EPUB cover images are shown in the library.
- Reading progress is now character-based; the percentage moved to the bottom
  centre.
- Added a table of contents and bookmarks; nested contents from the NCX / nav
  document.
- Added cross-device progress sync through iCloud KVS (warning silenced when
  iCloud is not configured).
- Added an auto-scroll reading mode.
- TTS improvements: sleep timer and progress tracking; fixed a Swift 6 warning
  in the sleep timer.
- PDFs get TTS and the theme background.
- Added reading statistics.
- Appearance settings are remembered per book.
- Added text highlights through a selection mode.
- Hid the oversized system back button in the reader (also when opened from
  search).
- Saved-position restore fixes: scrolling to the top on open, retrying until
  laid out, and a post-layout pass resetting the position. Added restore
  diagnostics.

#### 2026-06-07
- Books open as a full-screen cover instead of a navigation push.
- iCloud sync is off by default, to stop the KVS warning.
- A run of fixes for page turns repeating the same page: cancelled scroll
  animations, cancelling position restore when paging or scrolling, snapping
  back at the TextKit layout frontier, paging by character position instead of
  pixels, and laying out the reference region before picking the target glyph.
  Added tap/page diagnostics.
- Cloud services sign out when the session cannot be refreshed.

#### 2026-06-09
- Added left/right swipe paging that matches the tap zones.
- Added App Store listing copy.
- Made the app icon (open book, then a white open book, then custom Booklip
  artwork).
- Added a `.gitignore` for build and icon-export artifacts.
- Renamed the project from ReaderApp to **Booklip** and rebranded the App Store
  listing.
- Dropbox OAuth now uses the `booklip://` redirect URI.

#### 2026-06-11
- Added the `CLAUDE.md` project notes.

#### 2026-06-13
- Replaced the deprecated font-registration API with URL-based registration.
- macOS: fixed blank text rendering, broken embedded fonts, and EPUB image
  rendering.
- Free scrolling is disabled in paper mode.
- macOS: left/right arrow-key paging; the reader window is resizable and
  movable, opens larger, and is a standalone window instead of an attached
  sheet.
- Fixed the "Publishing changes from within view updates" warning (including
  its root cause); deferred the PDF progress write.
- Added a double-page view option to the Appearance panel (macOS).

#### 2026-06-14
- Fixed an `EXC_BAD_ACCESS` in the double-page coordinator.

#### 2026-06-17
- Fixed the tiny window on open and both pages showing the same content in
  double-page view.
- Fixed window size, PDF double-page view, and arrow-key navigation.
- Fixed an `EXC_BAD_ACCESS` (`objc_release`) when closing the window in
  double-page mode.
- Prevented a second Library window on macOS launch.

#### 2026-06-18
- Window-close crash fixes: coordinator closures replaced by a weak channel,
  `@Binding` removed from the macOS `NativeTextView`, the reader window's close
  animation disabled, duplicate reader windows prevented.
- Fixed two Library windows on launch (deleted the stale saved-state bundle).
- Fixed two-column mode showing the same page in both columns (the secondary
  column uses the primary's scrollable range).

#### 2026-06-22
- Fixed the two-column same-page issue and an `EXC_BAD_ACCESS` crash.

#### 2026-06-23
- Fixed two-column page sync and the window-close crash.
- Skipped `sizeToFit` on the secondary column; frame height is set in
  `updatePageStep`.
- Window release is deferred past the `NSApplication` pool drain; fixed a
  double-free from an early ARC release.

#### 2026-06-27
- Fixed the window-close `EXC_BAD_ACCESS` (two-hop defer, plus a missing defer
  in `closeWindow`).
- Silenced a capture warning in `deferWindowRelease` (`withExtendedLifetime`).

#### 2026-09-08
- Added search; fixed scroll-position restore after an appearance change.

#### 2026-09-09
- Restored folders, stats and cover images; fixed a main-thread freeze.
- PDF paper mode: one page per screen with tap navigation; vertical-slide mode
  scrolls continuously.
- Uniform book cards (2:3 cover area, identical card height).
- Progress bar fixes: progress sync throttled to 20 Hz to prevent a TextKit 1
  layout freeze, and a stale target capture plus feedback loop fixed (one
  real-time progress bar change was reverted).

#### 2026-09-11
- Fixed the progress bar freeze, a blank screen, PDF page turns, and data
  persistence.
- Fixed five functional gaps: stats, the bookmark button, Korean TTS, PDF
  search, lazy PDF rendering.
- Added exact page pagination; improved EPUB parse performance and scroll
  accuracy under non-contiguous layout.

#### 2026-09-12
- Fixed garbled Hangul, long stalls on seek/restore, and macOS PDF search.
- Landing-loop fixes: an exact character-position probe removes the
  oscillation, and it no longer clamps to a stale maximum offset. Stopped focus
  cycles in highlight mode.
- Fixed 16 code-review findings; wired up highlights, contents and bookmarks;
  unified the index space.
- Fixed the in-book search freeze (incremental, windowed match highlighting).
- Vertical-slide mode scrolls; paper mode pages by swipe.
- macOS: real paper-book paging, hidden scroll bar, character-based progress.
- Fixed EPUB whitespace, anchor-based contents offsets, and the page label
  after restore.
- Commented out all logging code; cleared build warnings (13 in EPUBParser plus
  the remaining 5).
- Added App Store screenshots (iPhone and iPad, Korean and English).
- **Version 1.5.3 (build 7).**

#### 2026-09-13
- Updated the App Store listing copy, added a Korean version, and trimmed the
  promotional text to the 170-character limit.
- Added cloud folder import, sweep selection, and background downloads.
- Paging goes by laid-out line fragments, so turns no longer overlap.
- The page-turn offset is pinned against `UITextView`'s stale scroll restore.
- Search works on the Folders tab and inside folders.
- **Version 1.5.4 (build 9).**

#### 2026-09-14
- Added a draft reply to the App Review information request (Guideline 2.1).

#### 2026-09-29
- TTS keeps playing in the background (own audio-session handling, utterances
  queued ahead, lock-screen controls); tighter highlight sync.
- Added a Define action that shows the dictionary next to the selection.
- Reflowed the App Review reply for pasting into App Store Connect.
- **Version 1.5.4.1.**

#### 2026-10-01
- TTS fixes: added `Booklip-Info.plist` so the audio background mode is really
  in the build (playback used to stop when the screen turned off), made the
  lock-screen play button work, and long sentences are no longer cut
  mid-word — a whole sentence is read and highlighted at once.
- Changed the App Store category from Productivity to Books.
- Added this README with the full changelog in English and Korean.
- macOS: fixed the Navigate panel (Contents / Bookmarks / Highlights) showing
  only its tab picker — the lists had collapsed to zero height.
- Added Mac App Store screenshots (2880×1800, Korean and English, 9 slides)
  and Mac support in `AppStore/screenshots/compose.py`.
- Reader (iOS and macOS): the last line of a page is no longer shown half
  cut off. A line the bottom edge would cut is hidden and becomes the first
  line of the next page.
- Fixed library cards in dark mode: the title and author under each cover were
  invisible on a hard-coded white card; the card background now follows the
  light/dark appearance (macOS and iOS).
- macOS: saved highlights are painted as soon as an EPUB opens — they used to
  appear only after a later refresh such as starting TTS.
- **Version 1.5.5 (build 11).**

## 한국어

오프라인 우선 iOS / macOS 전자책·텍스트 리더입니다. 사용자가 가진 파일
(**.txt · .epub · .pdf · .md**)을 가져와 읽습니다. SwiftUI로 작성했고 외부
의존성은 EPUB 압축 해제용 ZIPFoundation 하나입니다.

- 서재: 폴더, 정렬, 그리드/리스트 보기, 다중 선택, 검색, 표지
- 리더: 글꼴·크기·줄 간격·색 테마, 세로 슬라이드 / 종이책 넘김, 자동 스크롤,
  목차, 책갈피, 하이라이트, 본문 검색, 사전 찾기, 읽던 위치 복원
- TTS: 영어·한국어 음성, 속도·음높이, 문장 하이라이트, 취침 타이머, 백그라운드 재생
- 클라우드 가져오기: Dropbox, Google Drive, OneDrive
- 읽기 통계: 읽은 시간, 연속 일수

빌드 방법과 구조는 [CLAUDE.md](CLAUDE.md), 클라우드 로그인 설정은
[CLOUD_SETUP.md](CLOUD_SETUP.md)를 참고하세요.

### 변경 이력

커밋 기록을 날짜별로 정리한 것입니다(오래된 날짜부터).

#### 2026-05-30
- 프로젝트 생성(초기 커밋).

#### 2026-06-01
- 전자책 리더 전체 구현 추가.
- 다크·틴트 앱 아이콘 추가.
- SPM 의존성 버전 고정(`Package.resolved`).
- macOS에서 `NSTextStorage` 옵셔널 언래핑 크래시 수정.
- TTS 패널 레이아웃 겹침 수정, 음성 목록을 전체 언어로 확장했다가 영어·한국어로 한정.
- 로딩과 TTS의 QoS 우선순위 역전 수정, `TTSManager`를 `@MainActor`로 되돌림.
- Xcode 스킴에서 Thread Performance Checker 비활성화.

#### 2026-06-02
- 큰 ePub에서 TTS가 죽는 문제 수정(발화를 청크로 분할).
- 서재에 정렬과 폴더 정리 추가.
- URL 가져오기(OneDrive, Google Drive, 직접 링크) 추가.
- OneDrive·Google Drive 클라우드 브라우저 연동, 설정 안내서 `CLOUD_SETUP.md` 추가.
- 클라우드 관련 수정: `ObservableObject` 준수, `@MainActor` 초기화 오류,
  `OAuthSession` 액터 격리, macOS 시트 크기, 자격 증명 미설정 시 크래시 방지,
  Google Drive 리디렉트 URI, 샌드박스 외부 네트워크 허용.
- iCloud Drive 행을 추가했다가 Dropbox 연동으로 교체, Dropbox 리디렉트 URI 오타 수정,
  OAuth에 PKCE 추가.
- 클라우드 시트 여백·헤더 정리, iPhone에서 Done 버튼이 잘리던 문제 수정.
- iOS 리더 스크롤 수정: 세로 스크롤, 프레임마다 스타일을 다시 입히던 멈춤,
  열 때 멈춤, 스크롤이 멎을 때만 진행률을 갱신해 떨림 제거.
- TTS 중 읽는 부분 하이라이트와 자동 따라가기 추가.
- 진행 막대로 본문 위치 이동(iOS).
- 다중 선택 일괄 이동/삭제, 그리드/리스트 보기 추가(폴더 탭에도 적용).

#### 2026-06-03
- 폴더와 미분류 안에서도 다중 선택 가능.
- EPUB 본문 내 이미지 렌더링, 폭 0 레이아웃으로 이미지가 안 보이던 문제 수정.
- EPUB OPF를 정규식 대신 `XMLParser`로 파싱, 백그라운드 파싱용 `nonisolated` 처리.
- 탭 영역으로 페이지 넘김(iOS) 추가.
- 페이지 넘김 효과 선택(세로 슬라이드 / 종이책) 추가, 종이책은 가로(오른쪽→왼쪽)로 넘김.
- 클라우드 파일 브라우저에 다중 선택 가져오기 추가.
- 글꼴 선택기에 한국어 글꼴 추가.
- macOS 빌드 오류 수정(`applyContent`의 옵셔널 언래핑).

#### 2026-06-06
- EPUB 내장 글꼴 렌더링(글꼴 난독화된 책이 안 읽히던 문제 해결).
- 의도치 않은 텍스트 선택, 백그라운드 복귀 후 스크롤 끊김 수정(iOS).
- 정렬 메뉴의 빈 SF Symbol 경고 수정.
- Cloud Storage 목록에서 OneDrive 임시 숨김.
- 폴더 안에 정렬·보기 모드 컨트롤 추가.
- 서재에 EPUB 표지 이미지 표시.
- 읽기 진행률을 문자 기준으로 변경, 진행률 표시를 하단 가운데로 이동.
- 목차와 책갈피 추가, NCX / nav 문서로 중첩 목차 지원.
- iCloud KVS로 기기 간 진행률 동기화 추가(미설정 시 경고 억제).
- 자동 스크롤 읽기 모드 추가.
- TTS 개선: 취침 타이머, 진행 위치 추적. 취침 타이머의 Swift 6 경고 수정.
- PDF에도 TTS와 테마 배경 적용.
- 읽기 통계 추가.
- 책별 화면 설정 기억.
- 선택 모드를 통한 텍스트 하이라이트 추가.
- 리더의 과도하게 큰 시스템 뒤로 버튼 숨김(검색에서 열 때 포함).
- 저장 위치 복원 수정: 열 때 맨 위로 가던 문제, 레이아웃 완료까지 재시도,
  레이아웃 후 패스가 위치를 초기화하던 문제. 복원 진단 로그 추가.

#### 2026-06-07
- 책을 내비게이션 푸시 대신 전체 화면 커버로 열도록 변경.
- KVS 경고를 없애기 위해 iCloud 동기화 기본 비활성화.
- 페이지 넘김이 같은 페이지를 반복하던 문제 연속 수정: 취소된 스크롤 애니메이션,
  넘김/스크롤 시 위치 복원 취소, TextKit 레이아웃 경계에서 되돌아가던 문제,
  픽셀 대신 문자 위치로 페이징, 대상 글리프를 고르기 전 기준 영역 레이아웃.
  탭/페이지 진단 로그 추가.
- 세션을 갱신할 수 없으면 클라우드 서비스 로그아웃.

#### 2026-06-09
- 탭 영역과 같은 방향의 좌/우 스와이프 페이징 추가.
- App Store 등록 문구 추가.
- 앱 아이콘 제작(펼친 책 → 흰색 펼친 책 → Booklip 전용 아트워크).
- 빌드·아이콘 산출물용 `.gitignore` 추가.
- 프로젝트 이름을 ReaderApp에서 **Booklip**으로 변경, App Store 문구도 리브랜딩.
- Dropbox OAuth 리디렉트 URI를 `booklip://`로 변경.

#### 2026-06-11
- 프로젝트 메모 `CLAUDE.md` 추가.

#### 2026-06-13
- 폐기 예정 글꼴 등록 API를 URL 기반 등록으로 교체.
- macOS: 빈 텍스트 렌더링과 내장 글꼴 깨짐 수정, EPUB 이미지 렌더링 수정.
- 종이책 모드에서 자유 스크롤 비활성화.
- macOS: 좌/우 화살표 키 페이지 이동, 리더 창 크기 조절·이동 가능, 기본 크기 확대,
  붙은 시트 대신 독립 창으로 변경.
- "Publishing changes from within view updates" 경고 수정(근본 원인 포함),
  PDF 진행률 기록 지연.
- 화면 설정 패널에 두 쪽 보기 옵션 추가(macOS).

#### 2026-06-14
- 두 쪽 보기 코디네이터의 `EXC_BAD_ACCESS` 수정.

#### 2026-06-17
- 열 때 창이 작게 뜨던 문제, 두 쪽 보기에서 양쪽이 같은 페이지이던 문제 수정.
- 창 크기, PDF 두 쪽 보기, 화살표 키 이동 수정.
- 두 쪽 보기에서 창을 닫을 때의 `EXC_BAD_ACCESS`(`objc_release`) 수정.
- macOS 실행 시 서재 창이 두 개 뜨던 문제 방지.

#### 2026-06-18
- 창 닫기 크래시 수정: 코디네이터 클로저를 약한 참조 채널로 교체,
  macOS `NativeTextView`에서 `@Binding` 제거, 리더 창 닫기 애니메이션 비활성화,
  중복 리더 창 방지.
- 서재 창이 두 개 뜨던 문제 수정(오래된 저장 상태 번들 삭제).
- 두 단 모드에서 양쪽이 같은 페이지이던 문제 수정(보조 단이 주 단의 스크롤 범위 사용).

#### 2026-06-22
- 두 단 같은 페이지 문제와 `EXC_BAD_ACCESS` 크래시 수정.

#### 2026-06-23
- 두 단 페이지 동기화와 창 닫기 크래시 수정.
- 보조 단의 `sizeToFit` 생략, `updatePageStep`에서 프레임 높이 설정.
- 창 해제를 `NSApplication` 풀 드레인 이후로 지연, ARC 조기 해제로 인한 이중 해제 수정.

#### 2026-06-27
- 창 닫기 `EXC_BAD_ACCESS` 수정(두 단계 지연, `closeWindow`의 누락된 지연 추가).
- `deferWindowRelease`의 캡처 경고 제거(`withExtendedLifetime`).

#### 2026-09-08
- 검색 추가, 화면 설정 변경 후 스크롤 위치 복원 수정.

#### 2026-09-09
- 폴더·통계·표지 이미지 복구, 메인 스레드 멈춤 수정.
- PDF 종이책 모드: 화면당 한 페이지와 탭 이동, 세로 슬라이드 모드는 연속 스크롤.
- 책 카드 크기 통일(표지 영역 2:3, 카드 높이 동일).
- 진행 막대 수정: 진행률 동기화를 20 Hz로 제한해 TextKit 1 레이아웃 멈춤 방지,
  오래된 대상 값 캡처와 되먹임 루프 수정(실시간 진행 막대 변경은 한 차례 되돌림).

#### 2026-09-11
- 진행 막대 멈춤, 빈 화면, PDF 페이지 넘김, 데이터 저장 문제 수정.
- 기능 공백 5건 수정: 통계, 책갈피 버튼, 한국어 TTS, PDF 검색, PDF 지연 렌더링.
- 정확한 페이지 매김 추가, EPUB 파싱 성능 개선, 비연속 레이아웃 스크롤 정확도 개선.

#### 2026-09-12
- 깨진 한글, 이동/복원 시 긴 멈춤, macOS PDF 검색 수정.
- 착지 루프 수정: 정확한 문자 위치 탐침으로 진동 제거, 오래된 최대 오프셋으로
  잘리던 문제 수정. 하이라이트 모드의 포커스 순환 중단.
- 코드 리뷰 지적 16건 수정, 하이라이트·목차·책갈피 연결, 인덱스 공간 통일.
- 본문 검색 멈춤 수정(증분·구간 단위 일치 하이라이트).
- 세로 슬라이드는 스크롤, 종이책 모드는 스와이프로 페이지 넘김.
- macOS: 실제 종이책 페이징, 스크롤 막대 숨김, 문자 기준 진행률.
- EPUB 공백 처리, 앵커 기반 목차 위치, 복원 후 페이지 표시 수정.
- 로깅 코드 전부 주석 처리, 빌드 경고 정리(EPUBParser 13건 + 나머지 5건).
- App Store 스크린샷 추가(iPhone·iPad, 한국어·영어).
- **버전 1.5.3 (빌드 7).**

#### 2026-09-13
- App Store 등록 문구 갱신, 한국어판 추가, 홍보 문구를 170자 제한에 맞게 축약.
- 클라우드 폴더 가져오기, 쓸어서 선택, 백그라운드 다운로드 추가.
- 레이아웃된 줄 단위로 페이징해 넘길 때 줄이 겹치지 않도록 수정.
- `UITextView`의 오래된 스크롤 복원에 맞서 넘긴 위치를 고정.
- 폴더 탭과 폴더 안에서도 검색 동작.
- **버전 1.5.4 (빌드 9).**

#### 2026-09-14
- App Review 정보 요청(가이드라인 2.1)에 대한 답변 초안 추가.

#### 2026-09-29
- TTS 백그라운드 재생 유지(오디오 세션 직접 관리, 발화 미리 큐잉, 잠금 화면 컨트롤),
  하이라이트 싱크 개선.
- 선택한 단어 옆에 사전을 보여 주는 Define 동작 추가.
- App Review 답변을 App Store Connect에 붙여 넣기 좋게 정리.
- **버전 1.5.4.1.**

#### 2026-10-01
- TTS 수정: 백그라운드 오디오 모드가 빌드에 실제로 들어가도록 `Booklip-Info.plist` 추가
  (화면이 꺼지면 재생이 멈추던 문제), 잠금 화면 재생 버튼 동작, 긴 문장을 단어 중간에서
  자르지 않고 문장 전체를 한 번에 읽고 하이라이트.
- App Store 카테고리를 생산성에서 도서로 변경.
- 전체 변경 이력을 영어와 한국어로 담은 이 README 추가.
- macOS: 탐색 패널(목차 / 책갈피 / 하이라이트)에 탭 선택기만 보이고 목록이 높이 0으로
  접혀 있던 문제 수정.
- Mac App Store 스크린샷 추가(2880×1800, 한국어·영어, 9장),
  `AppStore/screenshots/compose.py`에 Mac 지원 추가.
- 리더(iOS·macOS): 페이지 마지막 줄이 반쯤 잘려 보이지 않도록 수정. 아래쪽에서 잘릴
  줄은 가리고 다음 페이지의 첫 줄로 보여 줌.
- 다크 모드 보관함 카드 수정: 흰색으로 고정된 카드 배경 때문에 표지 아래 제목과 저자가
  보이지 않던 문제 — 카드 배경이 라이트/다크 모드를 따르도록 변경(macOS, iOS).
- macOS: EPUB을 열자마자 저장된 하이라이트가 표시되도록 수정 — 이전에는 TTS 시작 등
  이후 갱신이 있어야 나타났음.
- **버전 1.5.5 (빌드 11).**
