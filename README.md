# Case Citer

A standalone macOS utility: press a global hotkey (default **⌘⇧-Space**) from *any*
app, get a floating Spotlight-style search box, type a case name, pick a result from
**CourtListener**, optionally add an introductory signal and a pincite, and have a
properly-formatted Bluebook **case** citation pasted into whatever you're typing in.

> This project is self-contained and shares **no code** with the Zotero plugins it
> currently sits beside in this repo — only Bluebook *domain knowledge* carries over.
> It is intended to graduate into its own repository.

## Status

Phase 1 (the substantive core) is implemented and tested: the pure `BluebookFormat`
library and its unit tests. The `CourtListener` client and the `App` agent layer are
scaffolded per the plan and build on macOS.

## Architecture

```
Sources/
  BluebookFormat/   pure, dependency-free formatter (no UI/network) — fully tested
  CourtListener/    async REST client + Codable models -> CaseRecord
  App/              menu-bar/LSUIElement agent: hotkey, floating panel, paste-back
Tests/
  BluebookFormatTests/   fixture -> expected Bluebook string (both style modes, signals)
```

The formatter assembles, as styled text projectable to RTF or plain:

```
[<italic signal> ]<name>, <vol> <reporter> <page>[, <pincite>] (<court> <year>).
e.g.  See Obergefell v. Hodges, 576 U.S. 644, 681 (2015).
```

### Citation style toggle

Bluebook italicizes the **full** case name in court documents/briefs, but **not** in
law-review footnote citations (there the full name is roman; only procedural phrases
like *In re* / *ex rel.*, short forms, and textual references are italic). The
`CitationStyle` flag (`lawReview` default vs. `courtDocument`) drives this. Signals are
always italic in both modes.

## Build & test

```sh
swift test                 # runs the BluebookFormat unit tests (any platform)
swift build                # builds everything (macOS)
swift run case-citer       # launches the agent (macOS)
```

### Running the agent locally

For the **real `.app`** (with the bundle id launch-at-login needs, no Dock icon, and
the paste-back permission prompt), build the native Xcode app target. The project is
generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen) —
`CaseCiter.xcodeproj` is disposable/git-ignored, `project.yml` is the source of truth:

```sh
brew install xcodegen          # once
xcodegen generate              # regenerate CaseCiter.xcodeproj after editing project.yml
open CaseCiter.xcodeproj       # then Run (⌘R), or Product ▸ Archive to export
# …or headless:
xcodebuild -project CaseCiter.xcodeproj -scheme CaseCiter -configuration Debug build
```

The build is **ad-hoc signed** for local use; drag `CaseCiter.app` to `/Applications`
to install. For more reliable launch-at-login, open the project in Xcode once and let it
manage signing with your Apple ID (the Apple Development cert). The app target reuses the
SwiftPM sources directly and bundles `scotus-index.json`; `swift build`/`swift run`/
`swift test` still work for the fast logic loop.

The app also needs:

1. The **Accessibility** permission (System Settings ▸ Privacy & Security ▸
   Accessibility) — required to synthesize ⌘V for paste-back. The app prompts on first
   launch via `AXIsProcessTrustedWithOptions`.
2. A free **CourtListener API token** (Settings) for higher rate limits; anonymous
   search works but is throttled.

Open **Settings** from the menu-bar icon or the gear button in the search pill
(⌘,). It holds: launch-at-login, the summon hotkey recorder, the citation-style
choice, and the API token. **Launch at login** uses `SMAppService.mainApp`, which
requires a real `.app` bundle with a bundle identifier — under a bare `swift run`
binary the toggle has no bundle to register and reverts.

Distribution is **local-first** for now (ad-hoc sign, right-click ▸ Open to bypass
Gatekeeper). Notarized-DMG distribution is a later decision.

## Local SCOTUS index (offline-first)

The app ships a prebuilt index of the most-cited Supreme Court cases
(`Sources/App/Resources/scotus-index.json`). A query shows matching cached cases
**instantly and offline** (*Roe*, *Obergefell*, *Marbury*, …), then the live
CourtListener search runs and is **merged in**: results are de-duplicated and
relevance-ranked by name match, so a better web hit (or a lower-court case the
SCOTUS-only index doesn't carry) can rise above — or fill in below — the cache. Each
record is a `CourtListener.SearchResult`, so a cached hit runs through the identical
citeable → `CaseRecord` → formatter path as a network result. If the network fails,
the cached results stay on screen.

Rebuild/refresh the index with:

```sh
python3 Tools/build-scotus-index.py [LIMIT]   # default 20000; reuses the app's API token
```

It pages CL's search API by citation count (the SCOTUS corpus is ~500k opinions, almost
all obscure orders — the most-cited slice is a few MB and covers what anyone cites),
respects the 429 throttle, and checkpoints as it goes. Validate without the GUI:

```sh
.build/debug/case-citer --query "roe wade"     # prints local-index matches + cites
```

## Keyboard-only flow

`⌘⇧-Space` → type query → `↑/↓` select → `⌃S` pick signal → `⇥` enter pincite →
`⏎` insert → `esc` to dismiss. No mouse required.

## Scope (v1)

Cases only. Statutes, secondary sources, and id./supra short forms are out of scope.
The T6/T10 case-name abbreviation tables are intentionally a **permissive subset** —
they abbreviate common words and leave the rest verbatim, and are grown test-first.
