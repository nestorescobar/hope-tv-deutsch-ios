# Porting the tvOS UI to iPhone

`scripts/sync-from-awe.sh --seed` copies 18 UI files from awe `apps/tv/tvos/HopeTV` into
`HopeTViOS/`. They compile for tvOS, not for iOS. This file lists every tvOS-only call site at
awe commit `467dde8` and the iPhone replacement.

Port in two passes:

1. **Compile pass.** Replace each tvOS-only API in the table below, so the app builds for the
   iPhone simulator. Change nothing else. Run `scripts/ci.sh` after each file.
2. **Phone pass.** Change sizes, the tab bar, cards and the player for touch (sections below).

Line numbers are from awe `467dde8`. They move after a sync; search for the API name instead.

## Rule: keep ContractKit as it is

`ContractKit/` is a copy. Only `scripts/sync-from-awe.sh` writes it. If an iPhone change seems to
need a ContractKit edit:

1. Prefer an extension or a wrapper in `HopeTViOS/`.
2. If the file must differ, add its path to `scripts/ios-owned.txt` with the reason, run the
   sync, and edit the copy that the sync puts in `HopeTViOS/`.
3. If the change is right for tvOS too, make it in awe first, then sync.

## 1. Compile pass: tvOS-only APIs

| API | Where (awe `HopeTV/`) | iOS status | Replacement |
| --- | --- | --- | --- |
| `.buttonStyle(.card)` | `Render/ScreenView.swift` 632, 641, 826, 2188; `Playback/PlayerPanels.swift` 160, 217 | tvOS only | `.buttonStyle(.plain)` plus the press style in Section 3 (`PressableCardStyle`) |
| `.onMoveCommand { … }` | `Render/ScreenView.swift` 1194, 1204, 1211 | tvOS and macOS only | Delete. Paging on iPhone is a swipe (`TabView` with `.page` style) or the visible buttons |
| `.onExitCommand { dismiss() }` | `Playback/PlayerView.swift` 80 | tvOS and macOS only | Delete. `AVPlayerViewController` has its own Done button; keep `dismiss()` on that path |
| `UIFocusUpdateContext`, `shouldUpdateFocus`, `didUpdateFocus` (a UIKit focus-guard view) | `Render/ScreenView.swift` 1915–1970 | APIs exist, but the job is remote-only | Delete the guard view and its use. It stops the focus engine from leaving a row; touch has no focus engine |
| `prefersDefaultFocus` | `Render/ScreenView.swift` near 2042 | tvOS, macOS, watchOS only | Delete |
| `customInfoViewControllers` | `Playback/PlayerView.swift` 435 | tvOS only | Show Episodes, Related or Schedule under the player as a sheet or a list (Section 4) |
| `transportBarCustomMenuItems` | `Playback/PlayerView.swift` 472 | tvOS only | iOS has no match. Show the Quality menu as a SwiftUI `Menu` over the player, or drop it in the PoC |
| `contentProposalViewController` (Up Next) | `Playback/PlayerView.swift` near 407 | tvOS only | Show Up Next as a SwiftUI overlay near the end of the item, driven by the copied `UpNext` logic in ContractKit |
| `infoViewActions` | `Playback/PlayerView.swift` near 406 | tvOS only | Buttons on the episode screen (Watch later, Like) |
| `.focusSection()` | `Render/ScreenView.swift` 130, 133, 317, 407, 483, 1104, 1367, 1447, 2035; `Render/PeopleRowView.swift` 43 | iOS 17+ compiles; no effect with touch | Delete for clarity |
| `.defaultFocus(…)`, `@FocusState`, `.focused(…)`, `.focusable()` | `ScreenView.swift`, `PlayerPanels.swift`, `PeopleRowView.swift`, `Member/AccountView.swift`, `App/RootView.swift` 259 | iOS 17+ compiles | Delete when it only moves remote focus. Keep `@FocusState` for text fields (search, sign-in) |
| `.searchable` | `Render/MediaSearchView.swift` | Works on iOS | Keep. Add `.searchPresentationToolbarBehavior` if the bar hides the field |
| `UIDevice.current.systemVersion` | `App/HopeTVApp.swift` (Umami user agent) | Works on iOS | Keep |
| Top Shelf, `.brandassets` | asset catalog | tvOS only | Not copied. iOS uses `HopeTViOS/Assets.xcassets/AppIcon` |

If the compiler finds a tvOS-only API that this table misses, add a row.

## 2. Layout: ten-foot sizes to phone sizes

`DesignSystem/Layout.swift` is iOS-owned (`scripts/ios-owned.txt`). Its tvOS values:

| Constant | tvOS | iPhone start value | Why |
| --- | --- | --- | --- |
| `screenMargin` | 64 | 16 | Phone edge margin |
| `focusGrowth` | 30 | 0 | No focus growth on touch |
| `cardCaptionInset` | 18 | 10 | Smaller cards |
| `stageWidth` × `stageHeight` | 1920 × 1080 | Read from the window (`GeometryReader` at the root), not a constant | The phone has many sizes. Umami `screen` should send the real size |
| `screenTopPadding` | 60 | 14, the fade of `StatusBarBand` | |
| `heroHeight` | 740 | about 1.1 × the screen width, cap 520 | The website hero is full width and taller than wide (screen recording) |
| `bannerCardWidth` | 1200 | screen width − 2 × margin | |

Search the seeded UI for fixed point sizes (`frame(width:`, `font(.system(size:`) and move them
to `Layout`. tvOS fonts are about 2× the iPhone size: a 38 pt tvOS title is about 17–20 pt on iPhone.

## 3. Cards and touch

- One press style for all cards: scale to 0.97 and dim to 0.9 while pressed, 120 ms. Name it
  `PressableCardStyle` in `DesignSystem/`.
- Shelves stay horizontal `ScrollView`s. Show part of the next card at the right edge, as the
  website does.
- Grids: 2 columns under 430 pt width, 3 above.
- Hit targets at least 44 × 44 pt.
- Long press on a card: no context menu in the PoC.

## 4. Player

- `PlayerView` wraps `AVPlayerViewController`. On iOS set `allowsPictureInPicturePlayback = true`
  and `canStartPictureInPictureAutomaticallyFromInline = true`.
- Set the audio session once at launch: `AVAudioSession.sharedInstance().setCategory(.playback,
  mode: .moviePlayback)`. `Info.plist` already has `UIBackgroundModes: audio`.
- Full screen stays a `fullScreenCover` (`RootView`). The player rotates to landscape; the app
  stays portrait (`Info.plist`).
- **Inline live player (Live tab).** tvOS plays nothing inline, so its safe boundary is "at a root,
  nothing full screen" (`AppRouter.isAtSafeBoundary`). An inline player on iPhone must count as
  "media plays": a replacement Live screen waits until the player stops. Add this before an
  inline player ships (contract invariant 3).
- The playback rules stay in ContractKit: HTTPS only (`ContractValidator.playableURL`), source
  choice, quality ladder, Up Next timing.

## 5. Tab bar and navigation

- `RootView.LayoutTabs` is a `TabView` with text-only `tabItem`s. On iOS it already becomes a
  bottom tab bar. That is the compile-pass result.
- Phone pass: the website's floating bar (docs/DESIGN.md). `LayoutTabs` is a `ZStack`, not a
  `TabView`: on iPhone a `TabView` moves every tab after the fifth into a system "More" list, and
  production serves six. Draw `FloatingTabBar` with the safe-area inset.
- Tab icons: the manifest sends Font Awesome names in `tabs[].icon` (`circle-play`,
  `magnifying-glass`, `video`). Map them to SF Symbols in one table
  (`circle-play` → `play.circle`, `magnifying-glass` → `magnifyingglass`, `video` → `tv`,
  `house` → `house`, `clock-rotate-left` → `clock.arrow.circlepath`, `download` →
  `arrow.down.circle`). An unknown name falls back to `circle`.
- One `NavigationStack` wraps the `TabView` (`router.state.stack`). A push covers the tab bar.
  Keep this in the PoC; one stack per tab is a later change in `AppRouter`, which is in
  ContractKit (so in awe first).

## 6. Tests

The seeded `HopeTViOSTests` are the tvOS suite with `@testable import HopeTViOS`.

- Keep every test that runs pure code: conformance, contract, registry, navigation tree, stores,
  member client, presets. They are the proof that the copy behaves like tvOS.
- `ContractTests.RegistryKeyListTests` reads `HopeTV/Registry/tvRegistryKeys.json`. Change the
  path to `ContractKit/Registry/tvRegistryKeys.json`.
- Delete or rewrite the tests of the tvOS-only parts you deleted (focus, `onMoveCommand` paging,
  `customInfoViewControllers` tabs, `transportBarCustomMenuItems`). Delete a test only with its
  code, and say so in the commit message.
- `HopeTVUITests` (remote focus) is not copied. Write XCUITests for touch later.

## 7. What the port changed

Seeded from awe `87ac4be893` (staging, 2026-10-30). This section records the choices that differ from
the sections above, and why.

- **`Layout.stageWidth` stays 1920.** ContractKit reads it for the hero art width and for `vw` and
  `vh` units, so it is not the window size (Section 2). The phone size is `Layout.phoneWidth`, and
  Umami `screen` is `Layout.screenName`. An authored `50vh` is 540 pt on a phone. Report such a
  block; do not change ContractKit.
- **Type sizes.** A seeded tvOS size goes through `Layout.text(_:)` (× 0.58). A size written for the
  phone is a plain number. Do not put a phone number through `Layout.text`.
- **Rows become columns.** A `Container` row that holds a detail block, a player, a schedule or a
  shelf draws as a column (`EvaluatedNode.isWideBlock`). Authors place them side by side for 1920 pt.
- **Text panels are gone.** `ReadingPanel`, `FocusCatcher` and `ReadingScroll` existed to scroll text
  under focus. The screen's scroll view does that now.
- **The schedule is a vertical list,** not a horizontal strip.
- **Paging.** A grid or list card that appears asks for the next page. tvOS asked on focus.
- **Search uses a `TextField`.** `.searchable` needs a navigation bar, and a tab root has none
  (Section 5).
- **The player is embedded, so it has no Done button.** Section 4 expected one. `PlayerView` draws
  Close, Like and Quality itself: over the video in portrait, in a rail in landscape. In portrait,
  `PlayerDetails` lists Go to show and the Episodes, Related or Schedule tabs under the video.
- **Up Next is `UpNextCard`,** a SwiftUI card that `PlayerView` shows at `UpNext.offerTime`. The
  viewer closes it for the rest of the item.
- **Live stays a card** that opens the stream full screen, as tvOS ("nothing plays inline"). So
  contract invariant 3 needs no change yet. The website's inline player is not built.
- **A card sets `contentShape`.** Fallback art draws through `drawingGroup`, and without the shape
  a poster card with fallback art took no touches.
- **Under the player.** AVKit draws the Info panel on tvOS only, so `PlayerDetails` draws the
  description and the meta line. The header stays in place and the list scrolls to the current
  episode. A tap opens the rest of the description.
- **From Beginning** is a glyph in the player bar. The contract has no string for it, so VoiceOver
  reads it as Play until awe adds a key.
- **Up Next.** Close after the end closes the player, as on tvOS.
- **Status bar band.** Every screen draws a solid band behind the status bar (`StatusBarBand`).
  The hero starts below it, and scrolled content fades out under it. The website runs the hero
  under the status bar; the phone does not, because a face near the top of the art would sit
  under the Dynamic Island. Landscape needs nothing: the player stays inside the safe area.
- **Mobile hero art.** The hero reads `images.bannerMobile` from the raw resource
  (`MobileBanner`), else the card's `banner`. ContractKit reads `banner` only, so tvOS is
  unchanged. It is usually 1:1, but the CMS also serves 16:9. That art centers the person, so the
  hero draws the logo and Watch now centered, as the website does. The abstract, meta line,
  categories and Trailer stay on the show screen. An item with no `bannerMobile` keeps the
  left-aligned hero with all of its parts.
- **YouTube** plays in an iframe (`YouTubeEmbed`) on the Episode and Movie Screens, only when no
  native source resolves. ContractKit still answers "can't play", because tvOS has no web view.
  YouTube owns that player: no resume, no Keep watching, no Up Next, no Watch later toggle.
- **Sign-in has no QR.** A phone cannot scan its own screen, so the code screen links to
  `verificationUriComplete`. The code and the address stay for a second device. The device-code
  flow itself is unchanged, and the contract's `signInScan` string is not drawn.
- **Colors come from the preset.** Every color a view draws reads `AppTheme`. `danger` is the one
  token the phone adds, read in `AppTheme(preset:)`. Two stay fixed on purpose: black around
  video and the YouTube frame, and the shadow under the tab bar. `LaunchBackground` and
  `AccentColor` are build-time assets, because they draw before a manifest loads.
- **Launch image.** The launch screen shows the app icon on `LaunchBackground`. Both shells use
  the same icon and the same launch image.
- **Not done:** Dynamic Type (Phase 4) and the hero preview loop on a device.
