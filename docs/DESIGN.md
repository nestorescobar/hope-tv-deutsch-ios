# Design reference

Source: a 52-second iPhone screen recording of the website app.hopetv.de, 2026-10-30 (1206 ×
2622 px). Colors are sampled pixels; confirm them against the website CSS.

The App Preset in the manifest is the source of truth for colors and fonts. The app reads it
through `PresetTokens` (ContractKit). Use this file to check the result, not as values to
hard-code.

## Tokens

| Token (`PresetTokens`) | Preset path | Website value |
| --- | --- | --- |
| `accent` | `colors.{primary}.400` | `#EDCB2A` — active tab pill, show names on cards, chevrons, "Alle anzeigen", NOW badge, focused search field |
| `background` | `colors.{neutral}.950` | `#0E151A` |
| `surface` | `colors.{neutral}.900` | `#121F2A` — cards, schedule rows, tab bar |
| `surfaceSelected` | `colors.{neutral}.800` | `#1B262A` — pressed card, search field |
| `textPrimary` | `colors.{neutral}.50` | white |
| `textSecondary` | `colors.{neutral}.400` | white at about 60% |
| `headingFont`, `bodyFont` | `fonts.{h1 / p family}.family` | bold sans-serif; name to confirm |

Brand mark (app icon, launch): blue `#1D4A8B`, yellow `#FFD400` (awe `apps/tv/tvos/AGENTS.md`).
The launch background color is `#0E151A` (`LaunchBackground` in the asset catalog).

## Chrome

- **Tab bar:** floating, rounded, inset from the screen edges, icon-only. The active tab sits in
  an `accent` rounded pill with a dark icon. Five tabs on the website: Home, Live (TV icon),
  Suche, Downloads (cloud icon), Verlauf (history icon). The app shows the tabs the CMS layout
  lists, in its order.
- **No top bar on Home.** The hero runs under the status bar. Light status bar content.
- **Screen titles** ("Suche", "Downloads", "Verlauf"): large, bold, left-aligned, about 28 pt.
- **Shelf headings:** uppercase, wide letter spacing, about 17 pt, a yellow `>` at the right
  when the shelf links to a list.

## Components

- **Hero carousel** (`CollectionTeaser`): full-width show art, show logo near the bottom, a light
  gray pill button "JETZT ANSCHAUEN" with a play icon, page dots below. Auto-advance every 15 s
  (the website and tvOS value).
- **Episode card:** 16:9 thumbnail on top; card body in `surface`; show name uppercase in
  `accent`; episode title in white, at most two lines.
- **Poster card:** about 3:4, rounded corners, no text.
- **Schedule row** (`ScheduleLive`): thumbnail, title, subtitle, time at the right, NOW badge in
  `accent` on the current program.
- **Category tile** (Suche): two columns, image tile, label at the bottom left.
- **Search results:** "Episoden" and "Sendungen" groups, each with "Alle anzeigen (n)".

## Screens seen in the recording

| Screen | Content, top to bottom |
| --- | --- |
| Home | Hero carousel · "Neueste Episoden" · "Brandneu bei Hope TV" · "Beiträge aus 'Hope Magazin live'" · "Jede Woche eine neue Episode" · "Bibel-Sendungen" · "Primetime-Sendungen" · "Lebensgeschichten" · "Aktuelles und Wissen" · "Für Kinder" · "Rund um die Bibel" · "Für junge Erwachsene und Teens" |
| Live | Inline 16:9 player (play, red LIVE, volume, settings, full screen) · "Heute auf Hope TV" schedule |
| Suche | Search field · "Kategorien" tiles; while typing "Wird gesucht …", then grouped results |
| Downloads | Storage bar · "Auswählen" · "Auf dem Gerät" list with size, date, duration, "Abgelaufen" |
| Verlauf | "Löschen" · "Weiterschauen" row with progress · history grouped by date |

UI language: German (`CONTENT_LANGUAGE = de`; chrome strings come from `chrome.strings`).
