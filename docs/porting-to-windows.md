# Porting Case Citer to Windows (PC)

**Status:** Analysis / handover notes — not implemented.

This document is for a developer picking up the task of bringing Case Citer to
Windows. It explains what the app does, which parts of the codebase already
travel, which parts must be rebuilt, and the concrete decisions and gotchas
involved. Read the top-level `README.md` first for product behavior; this file
focuses only on the port.

## TL;DR

The port is **feasible and the repo is well-positioned for it**, but it is a
**UI/system-integration rewrite, not a recompile**. The citation engine (~40%
of the code) is platform-neutral Swift and should move with little change. The
remaining ~60% lives in one target, `Sources/App/`, and is entirely macOS UI
and OS glue with no Windows equivalent. SwiftUI does **not** exist on Windows,
so every view must be re-authored regardless of which language you choose.

Rough estimate for a solo developer to reach feature parity: **1–3 weeks**, with
nearly all the risk and effort in the floating-panel UX and the global
hotkey + paste-back glue — not in the legal-citation logic, which is already
isolated and unit-tested.

## How the code is organized (and why that matters)

The project is three SwiftPM targets, and platform coupling lines up exactly
along those boundaries:

| Target | ~Lines | Imports | Portable as-is? |
|---|---|---|---|
| `BluebookFormat` | ~723 | Foundation only | ✅ Yes |
| `CourtListener` | ~382 | Foundation (+ `FoundationNetworking`) | ✅ Yes |
| `App` | ~1,760 | AppKit, SwiftUI, Carbon (via KeyboardShortcuts), ServiceManagement, ApplicationServices | ❌ Rewrite |

Two existing signals show the author already anticipated cross-platform builds:

1. `Sources/CourtListener/SearchClient.swift` already guards networking with
   `#if canImport(FoundationNetworking)` — the exact shim Swift needs for HTTP
   on non-Apple platforms. The network layer is already cross-platform.
2. `Sources/App/Paster.swift` is wrapped in `#if canImport(AppKit)` — the
   macOS-only code is already fenced rather than assumed.

So the hard *domain* work — Bluebook formatting, the T6/T10 case-name
abbreviation tables, the CourtListener REST client, and the offline SCOTUS
index loader — is the part that is already done and portable.

## What travels unchanged

- **`BluebookFormat`** — pure formatter. No UI, network, or OS calls. This is
  the substantive core and it is fully unit-tested
  (`Tests/BluebookFormatTests`). On a Windows Swift toolchain it should compile
  and pass tests as-is.
- **`CourtListener`** — async REST client + Codable wire models. Foundation
  only, already `FoundationNetworking`-aware.
- **`scotus-index.json`** and `LocalCaseIndex` logic — the offline index is
  plain JSON; the loader is Foundation. It now lives **in the `CourtListener`
  library target** (`Sources/CourtListener/LocalCaseIndex.swift`), resolved via
  `Bundle.module`, so a Windows front-end gets the offline index for free.

## What must be rebuilt

Everything in `Sources/App/` is macOS system integration. Each piece has a
Windows analog, but no shared code:

| Feature (macOS) | macOS API used | Windows equivalent |
|---|---|---|
| Global summon hotkey | `KeyboardShortcuts` → Carbon `RegisterEventHotKey` | Win32 `RegisterHotKey` |
| Floating Spotlight panel | `NSPanel` + SwiftUI (`SearchView.swift`, ~543 ln) | WinUI 3 / WPF / Avalonia window |
| Paste-back into frontmost app | `CGEvent` synthesizing ⌘V | `SendInput` synthesizing Ctrl+V |
| Clipboard (RTF + plain) | `NSPasteboard` (`.rtf` + `.string`) | `System.Windows.Clipboard` / Win32 clipboard (`CF_RTF` + `CF_UNICODETEXT`) |
| Launch at login | `SMAppService.mainApp` | Registry `Run` key or a Startup-folder shortcut |
| Background/menu-bar agent | `LSUIElement` + `NSStatusItem` | System-tray (notification area) icon |
| Hotkey recorder UI | `KeyboardShortcuts` recorder | Custom key-capture control |

### Things that get *easier* on Windows

- **No Accessibility permission.** macOS requires the Accessibility grant
  (`AXIsProcessTrustedWithOptions`, see `Sources/App/Permissions.swift`) before
  it can synthesize ⌘V. Windows `SendInput` needs no special grant, so the
  entire permission-prompt flow (`Permissions.swift`) simply disappears.
- **No Gatekeeper / notarization.** The macOS distribution story (ad-hoc
  signing, right-click ▸ Open) is replaced by ordinary Windows code-signing,
  which is optional for local use.

### Things that get *harder* / need care on Windows

- **RTF on the clipboard.** macOS apps broadly accept pasted RTF so italics
  survive into Word/Pages/Mail. On Windows, target apps vary: Word and Outlook
  honor `CF_RTF`, but many editors take only plain text. Keep the existing
  dual-write strategy (rich + plain fallback) and test against Word, Outlook,
  and a browser `contenteditable`.
- **Focus return + timing.** macOS reactivates the previously frontmost app and
  posts ⌘V after a 50 ms delay (`Paster.paste`). On Windows you must track the
  foreground window (`GetForegroundWindow`) *before* showing your panel, restore
  it (`SetForegroundWindow`, which has focus-stealing restrictions), then
  `SendInput`. Expect to tune timing and possibly use
  `AllowSetForegroundWindow`.
- **Per-monitor DPI / panel placement.** The Spotlight-style centered panel must
  be DPI-aware and placed on the monitor with the cursor/active window.

## Recommended path

Your main decision is **what language the new UI/system layer is written in**,
because that determines how much of the Swift core you can keep.

### Option A — Swift on Windows + native UI
Reuse both Swift libraries verbatim; write the UI and OS glue against Win32 and
a Windows UI binding. *Max code reuse, but Swift's Windows UI ecosystem is
immature and you'll be on a thin, sparsely-supported path.*

### Option B — Rewrite the UI in .NET (C# / WPF or WinUI 3)  ← recommended for a Windows-only target
Best Windows tooling and the most mature tray / hotkey / clipboard story. Cost:
you reimplement `BluebookFormat` and `CourtListener` in C# (~1,000 lines of pure
logic). This is mechanical, and the existing `BluebookFormatTests` /
`CourtListenerTests` become your acceptance spec — port the tests first, then
make them pass.

### Option C — Cross-platform shell (Avalonia / Tauri / Electron)  ← recommended if you want one codebase for Mac + Windows
Same reimplementation cost as B, but you get both OSes from a single source
going forward and stop maintaining two native apps.

**Recommendation:** Option B for a one-time Windows target; Option C if you want
to retire the separate macOS app over time. In both B and C the citation engine
is low-risk because it is already isolated and test-covered.

## Suggested first steps (regardless of option)

1. **Refactor first, port second.** ✅ *Done:* the platform-neutral
   `LocalCaseIndex` loader and the `scotus-index.json` resource now live in the
   `CourtListener` library target rather than the macOS `App` target, so the
   offline index isn't trapped behind AppKit. (Re-run `swift test` after cloning
   to confirm on your toolchain.)
2. **Stand up the core on Windows / in the target language.** Either build
   `BluebookFormat` + `CourtListener` with a Windows Swift toolchain (Option A)
   or port them to C# test-first (Options B/C). Green tests here de-risk the
   whole project before any UI exists.
3. **Prove the system glue with a throwaway spike:** a tray app that registers a
   global hotkey, shows an empty window, captures the prior foreground window,
   and pastes a hard-coded string into it via `SendInput`. This validates the
   riskiest Windows-specific behavior (focus return + paste) in isolation.
4. **Rebuild the panel UX.** Re-author `SearchView`'s keyboard-only flow
   (`⌘⇧-Space` → type → `↑/↓` → `⌃S` signal → `⇥` pincite → `⏎` insert →
   `esc`). This is the largest single chunk of UI work; budget accordingly.
5. **Wire settings:** hotkey recorder, citation-style toggle, launch-at-login,
   and the CourtListener token. Note the token is **opt-in** — the app defaults
   to the anonymous API (`AppSettings.effectiveAPIKey` returns `nil` unless the
   user turns on "Use a personal API token"), so a fresh install needs no
   credential and the repo never carries one. Preserve that default in the port.
   Anonymous search works (verified June 2026), but CourtListener changed its API
   access model in May 2026 and lowered the old flat 5,000 req/hr default — handle
   `429` (throttled) and `401` (auth required) defensively rather than assuming the
   anonymous path is unlimited, and check the
   [current limits](https://www.courtlistener.com/help/api/rest/v4/overview).

## Reference: macOS files and their Windows responsibilities

| File | Responsibility | Port target |
|---|---|---|
| `Sources/App/main.swift` | App entry / agent bootstrap | Windows app entry + tray |
| `Sources/App/AppDelegate.swift` | Lifecycle, hotkey wiring, menu-bar item | Tray + hotkey registration |
| `Sources/App/SearchPanel.swift` | `NSPanel` host for the floating UI | Borderless top-most window |
| `Sources/App/SearchView.swift` | The search/results/keyboard UX (largest file) | Main UI rewrite |
| `Sources/App/SearchViewModel.swift` | Search orchestration, merge/rank, state | Mostly logic — portable in spirit, rewrite in target language |
| `Sources/App/SignalPicker.swift` | Bluebook signal picker UI | UI rewrite |
| `Sources/App/PreferencesView.swift` | Settings UI | Settings window |
| `Sources/App/Settings.swift` | Persisted prefs + hotkey storage | Registry / app-settings store |
| `Sources/App/Paster.swift` | Clipboard write + ⌘V synth | Clipboard + `SendInput` |
| `Sources/App/Permissions.swift` | Accessibility prompt | **Delete** — not needed on Windows |
| `Sources/App/LaunchAtLogin.swift` | `SMAppService` | Registry `Run` key / Startup shortcut |
| `Sources/CourtListener/LocalCaseIndex.swift` | Offline SCOTUS index loader | Already in the shared `CourtListener` lib (platform-neutral) — reuse as-is |

## Open questions to resolve with the new owner

- Windows-only, or one cross-platform codebase replacing both?
- Minimum Windows version (affects WinUI 3 vs. WPF vs. Avalonia choice)?
- Is RTF/italics paste-back a hard requirement, or is plain-text acceptable as a
  v1 to cut clipboard-compatibility risk?
- Distribution: unsigned local build, signed installer, or Microsoft Store?
