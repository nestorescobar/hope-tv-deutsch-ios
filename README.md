# Hope TV Deutsch — iPhone

A native SwiftUI iPhone app for Hope TV Deutsch. It renders the CMS App `hope-tv-deutsch-tv-app`
from the AWE **App Contract**, the same JSON the Apple TV app reads. Editors decide the tabs,
shelves and screens in the CMS; this app decides how they look on a phone.

**Status:** plan and project setup only. The code is not seeded yet: start with
[docs/PLAN.md](docs/PLAN.md), Phase 0.

## Requirements

- macOS with Xcode 16+ (iOS 18 SDK) and an iPhone simulator
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- A checkout of [hope-media/awe](https://github.com/hope-media/awe), the source of the contract code
- For a running app: a ClientToken of an enabled `kind: 'app'` Client row (tests do not need one)

## Quick start

```bash
git clone https://github.com/hope-media/awe ../awe
scripts/sync-from-awe.sh --seed ../awe        # first time only
cp Config/Secrets/app.xcconfig.sample Config/Secrets/hope-tv-deutsch-tv-app.xcconfig
scripts/ci.sh                                 # the CI gate
open HopeTViOS.xcodeproj                      # after ci.sh or `xcodegen generate`
```

## Layout

| Path | Role | Who writes it |
| --- | --- | --- |
| `ContractKit/` | Platform-free App Contract code: client, cache, Craft decoder, block registry, navigation tree, stores, analytics | Only `scripts/sync-from-awe.sh` |
| `HopeTViOS/` | The iPhone UI: app, root view, block views, design system, player | This repo (seeded once from tvOS) |
| `HopeTViOSTests/` | XCTest suite, incl. conformance over the shared fixtures | This repo (seeded once from tvOS) |
| `fixtures/app-contract/` | Captured contract bodies shared with every AWE renderer | Only `scripts/sync-from-awe.sh` |
| `UPSTREAM` | The awe commit `ContractKit/` and `fixtures/` come from | Only `scripts/sync-from-awe.sh` |
| `Config/Shells/<app>.xcconfig` | Per-App binding: API base, App slug, Entity id, language, bundle id | This repo |
| `Config/Secrets/<app>.xcconfig` | The ClientToken, gitignored | Each developer |
| `project.yml` | XcodeGen project; `.xcodeproj` is gitignored | This repo |
| `scripts/ci.sh` | The CI gate on a Mac | This repo |
| `scripts/ios-owned.txt` | Platform-free files this repo owns anyway | This repo |

## Apps (shells)

| Shell | App | Environment |
| --- | --- | --- |
| `hope-tv-deutsch-tv-app` (default) | Hope TV Deutsch | production |
| `hope-tv` | Hope TV (the fixtures capture) | staging |

Pick a shell: `APP=hope-tv scripts/ci.sh`, or for Xcode write `Config/Shell.xcconfig` with
`#include "Shells/hope-tv.xcconfig"`. The environment belongs to the shell, not to Debug or Release.

## CI

`scripts/ci.sh` is the gate. It runs on a Mac only:

1. `xcodegen generate`
2. unit tests on the newest available iPhone simulator (`SIMULATOR="iPhone 16"` picks another)
3. a Release build for the simulator, unsigned

Results go to `build/ci/` (logs and `tests.xcresult`). The tests are offline: they read
`fixtures/`, not the network. `.github/workflows/ci.yml` runs the same script on a self-hosted
Mac runner once one is registered.

## Docs

- [docs/PLAN.md](docs/PLAN.md) — phases, steps and gates
- [docs/PORTING.md](docs/PORTING.md) — every tvOS-only API and its iPhone replacement
- [docs/DESIGN.md](docs/DESIGN.md) — the website's phone look, from a screen recording
- [docs/DECISIONS.md](docs/DECISIONS.md) — decisions, success criteria, risks, open questions
