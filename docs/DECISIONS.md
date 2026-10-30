# Decisions and open questions

Full proposal (private Claude doc, ask the owner for access):
"Hope TV Deutsch iOS App — App Contract Proposal", 2026-10-30.

## Decided

| # | Decision | Date |
| --- | --- | --- |
| 1 | A native SwiftUI iPhone app, iOS 18+, iPhone only. | 2026-10-30 |
| 2 | It renders the production App `hope-tv-deutsch-tv-app` from the App Contract (`/v1/app/:appSlug/*`), the same JSON as the Apple TV app. No second CMS App. | 2026-10-30 |
| 3 | A separate project in its own repo, not a target in awe `apps/tv/tvos`. | 2026-10-30 |
| 4 | The platform-free tvOS code is copied into `ContractKit/` by `scripts/sync-from-awe.sh`, pinned in `UPSTREAM`. The app never imports from awe at build time. | 2026-10-30 |
| 5 | CI is `scripts/ci.sh` on a local Mac: XcodeGen, unit tests on an iPhone simulator, a Release build. `.github/workflows/ci.yml` runs the same script on a self-hosted Mac runner, once one is registered. | 2026-10-30 |
| 6 | PoC bundle id `de.hopemedia.awe.hopetvdeutsch.ios`, not the tvOS id. | 2026-10-30, open to change (question 5) |

## Success criteria

1. The iPhone app shows the same tabs and screens as the Apple TV app for `hope-tv-deutsch-tv-app`.
2. An editor renames a tab or reorders a shelf in the Backend; both apps show the change after
   their next manifest fetch, with no release.
3. Every registry key the deutsch App uses renders; an unknown key renders absent and logs once.
4. `scripts/ci.sh` passes, including the conformance tests over `fixtures/app-contract/hope-tv/`.
5. A viewer plays an episode and the live stream, and resumes an episode at the same second.

## Risks

| # | Risk | Severity | Mitigation |
| --- | --- | --- | --- |
| 1 | **Architecture.** awe ADR-0164 keeps the phone app on Expo (ADR-0110, ADR-0111). This is a second phone app beside `apps/mobile` for the same content. | High (process) | Agree the PoC with the platform owner; an ADR in awe if it goes past the PoC |
| 2 | **Copy drift.** `ContractKit/` falls behind awe; a contract change can break the iPhone app, and no awe test sees it. | High | `UPSTREAM`, the sync script, the shared fixtures; the app refuses an unknown `contractVersion` and keeps its last-known-good copy |
| 3 | **Inline playback vs contract invariant 3** (activate at a safe boundary). tvOS plays nothing inline. | Medium | An inline player counts as "media plays" (docs/PORTING.md Section 4) |
| 4 | **TV-shaped content on a phone.** Editors author for 1920 × 1080. | Medium | Review with an editor in Phase 2 |
| 5 | **A second repo to run** (signing, secrets, access). | Low | Move to the `hope-media` org before any store release |
| 6 | **ClientToken in the binary.** Readable, as on tvOS. A `kind: 'app'` row reaches only public App Contract content (ADR-0218). | Low | Own Client row, rotatable |

## Open questions

- [ ] Does the platform owner accept a native iPhone app beside `apps/mobile`? Who signs an ADR if it goes past the PoC?
- [ ] Who runs `scripts/sync-from-awe.sh`, and when (each contract change, or monthly)?
- [ ] Same tabs on phone and TV, or a per-device layout in the CMS? Downloads and Verlauf exist on the website, not as contract blocks.
- [ ] Member sign-in on the phone: the tvOS device-code flow, or the website's magic link?
- [ ] Bundle id: the tvOS id (`de.hopemedia.awe.hopetvdeutsch`, one universal purchase) or a separate iOS id?
- [ ] Repo home: move to `hope-media` now or before the first store build?
