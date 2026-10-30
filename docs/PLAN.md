# Implementation plan

Goal: a native iPhone app for Hope TV Deutsch. It renders the production CMS App
`hope-tv-deutsch-tv-app` from the same App Contract JSON as the Apple TV app in awe
(`apps/tv/tvos`). Editors change tabs, shelves and screens in the CMS; both apps follow with no release.

Scope, the code-home choice and the risks: [DECISIONS.md](DECISIONS.md). tvOS-to-iOS API
changes: [PORTING.md](PORTING.md). Phone look: [DESIGN.md](DESIGN.md).

Work on a Mac with Xcode 16+ (iOS 18 SDK), XcodeGen and an awe checkout. Every step ends with
`scripts/ci.sh` green unless the step says otherwise.

## Phase 0 — Mac setup (half a day)

1. `brew install xcodegen` (optional: `brew install xcbeautify` for readable logs).
2. Clone awe next to this repo and fetch `staging`: `git clone https://github.com/hope-media/awe ../awe`.
3. `cp Config/Secrets/app.xcconfig.sample Config/Secrets/hope-tv-deutsch-tv-app.xcconfig` and
   put the iPhone build's ClientToken in it. Tests do not need it; the running app does.
   - Verify: the token row in Core is `kind: 'app'` (ADR-0218) and enabled.

## Phase 1 — Seed and compile (week 1)

1. `scripts/sync-from-awe.sh --seed ../awe`. It writes `ContractKit/` (36 files),
   `HopeTViOS/` (18 UI files), `HopeTViOSTests/`, `fixtures/app-contract/` and `UPSTREAM`.
   - Verify: `UPSTREAM` names the awe commit; `git status` shows only new files.
2. Commit the seed as it is, before any edit: "Seed from awe <short sha>". Later diffs then show
   only the iPhone changes.
3. Compile pass ([PORTING.md](PORTING.md) Section 1). One file at a time, smallest first:
   `App/ForegroundTrigger`, `DesignSystem/*`, `Member/AccountView`, `Render/PeopleRowView`,
   `Render/ContentBlockViews`, `Render/FlexStack`, `Render/HeroPreview`, `Render/MediaSearchView`,
   `Playback/PlayerPanels`, `Playback/PlayerView`, `App/*`, `Render/ScreenView` (2,320 lines) last.
   - Verify: `xcodegen generate && xcodebuild build -scheme HopeTViOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` succeeds.
4. Tests ([PORTING.md](PORTING.md) Section 6): fix the registry key-list path; delete the tests
   of deleted tvOS-only code.
   - Verify: `scripts/ci.sh` green. Write the test count in the commit message.
5. Run the app on the simulator with the deutsch shell and a real token.
   - Verify: the manifest loads, the tabs show, Home shows its shelves. Take a screenshot.

**Gate 1:** `scripts/ci.sh` green; the app shows the production tabs and Home.

## Phase 2 — Phone layout and Home (week 2)

1. `Layout.swift` phone values ([PORTING.md](PORTING.md) Section 2). Read the window size at the
   root; send it as the Umami `screen`.
2. `PressableCardStyle`; shelves, grids, hero for touch ([PORTING.md](PORTING.md) Section 3).
3. Floating tab bar with SF Symbol icons ([PORTING.md](PORTING.md) Section 5, [DESIGN.md](DESIGN.md)).
4. Check the colors: the App Preset drives them through `PresetTokens`. Compare with the website
   values in [DESIGN.md](DESIGN.md). Do not hard-code the website values; report a difference.

**Gate 2:** Home matches the website layout in [DESIGN.md](DESIGN.md) on iPhone SE (375 pt),
iPhone 16 (393 pt) and iPhone 16 Pro Max (440 pt). An editor renames a tab in the CMS; the app
shows the new name after the next manifest fetch, with no rebuild.

## Phase 3 — Detail screens and playback (weeks 3–4)

1. Show and episode Template Screens (`ShowDetail`, `ShowMeta`, `EpisodesList`, `EpisodeDetail`).
2. Player: audio session, Picture in Picture, rotation, resume ([PORTING.md](PORTING.md) Section 4).
3. Up Next overlay and the Episodes/Related list that replace the tvOS player tabs.
4. Live: `LivestreamPlayer` and `ScheduleLive`. If the player is inline, add the safe-boundary
   rule first ([PORTING.md](PORTING.md) Section 4).
5. Keep watching (`EpisodeWatchHistory`) from device-local progress.

**Gate 3:** play an episode, quit the app, reopen, and resume within 5 s of the stop point. The
live stream plays and today's schedule marks the current program.

## Phase 4 — Search, accessibility, ship (week 5)

1. `MediaSearch` with the native search field.
2. VoiceOver labels on every card; Dynamic Type up to XXL without clipping.
3. App icon in `HopeTViOS/Assets.xcassets/AppIcon.appiconset` (1024 × 1024, from the brand mark).
4. Archive and upload to TestFlight (internal group) from Xcode, with the bundle id from DECISIONS.md.

**Gate 4:** every success criterion in [DECISIONS.md](DECISIONS.md) passes; go or no-go review.

## Later

- Movie and watch-later blocks (8 registry keys).
- Member sign-in on the phone (the tvOS device-code flow is in ContractKit; the website uses a
  magic link).
- Downloads and a Verlauf tab, if the CMS layout gets them (not contract blocks today).
- iPad layout.

## Keeping up with awe

Run `scripts/sync-from-awe.sh ../awe` after each awe change to `apps/tv/tvos` or to the App
Contract, and at least once a month. It overwrites `ContractKit/` and `fixtures/`, rewrites
`UPSTREAM`, and lists the upstream changes since the last sync. Port the UI ones by hand, then
run `scripts/ci.sh`.
