# Hope TV Deutsch — iPhone (agent instructions)

A SwiftUI iPhone renderer of the AWE App Contract for the CMS App `hope-tv-deutsch-tv-app`.
Start with `README.md`, then `docs/PLAN.md` (the current phase), `docs/PORTING.md` and
`docs/DECISIONS.md`.

## Rules

- **`ContractKit/`, `fixtures/` and `UPSTREAM` are copies.** Only `scripts/sync-from-awe.sh`
  writes them. Never edit them by hand. If an iPhone change needs one of these files to differ,
  follow `docs/PORTING.md` → "Rule: keep ContractKit as it is".
- **XcodeGen is the source of truth.** Edit `project.yml`, never the generated
  `HopeTViOS.xcodeproj` or `HopeTViOS/Info.plist`.
- **The gate is `scripts/ci.sh`.** Run it before you call work done, and report its last line and
  the test count. A step is not done while it is red.
- **Keep the contract invariants** (awe `apps/tv/tvos/AGENTS.md`): 256 KiB byte cap; an unknown
  node renders absent and logs once; activate a replacement manifest or screen only at a safe
  boundary; HTTPS-only playback through `ContractValidator.playableURL`; the node map is a graph
  (visited set, depth cap). An inline player counts as "media plays".
- **The CMS decides content; the app decides look.** Never hard-code a tab, a shelf, a collection
  id or a screen. Colors and fonts come from the App Preset through `PresetTokens`; the values in
  `docs/DESIGN.md` are a check, not constants.
- **The ClientToken never enters a tracked file.** It lives in `Config/Secrets/<app>.xcconfig`.
- **Tests:** XCTest, not swift-testing. Delete a seeded test only together with the tvOS-only code
  it tested, and name it in the commit message.
- **Surgical changes.** Port the tvOS code; do not redesign what the phone does not need changed.

## Style

- Swift 5 language mode, iOS 18 floor, no SPM dependencies.
- Match the seeded code's style: `///` doc comments that say why, short and high-signal.
- American English in code, comments and docs. UI strings come from the contract
  (`chrome.strings`), not from the app.
- Write prose in ASD-STE100 Simplified Technical English: active voice, short sentences.

## Commands

```bash
scripts/sync-from-awe.sh --seed ../awe   # once
scripts/sync-from-awe.sh ../awe          # refresh ContractKit + fixtures
scripts/ci.sh                            # gate (APP=hope-tv, SIMULATOR="iPhone 16" optional)
xcodegen generate                        # after a project.yml change
```
