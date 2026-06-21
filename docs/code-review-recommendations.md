# Case Citer Code Review Recommendations

Reviewed: 2026-06-21

## Scope

This review covered the SwiftPM package, the macOS app shell, the CourtListener client/cache/index path, the Bluebook formatter, tests, packaging config, and user-facing docs.

No application source changes were made as part of this review.

## Current Strengths

- The project has a clean target split: `BluebookFormat` is pure formatting logic, `CourtListener` owns API/cache/index behavior, and `App` owns macOS integration.
- The formatter has meaningful unit coverage across citation style, signals, string citations, reporter preference, parentheticals, short forms, and RTF escaping.
- The CourtListener path is intentionally resilient: bundled SCOTUS hits render instantly, network search is debounced, local and web results are merged, timeouts are bounded, and cache failures degrade quietly.
- macOS-specific behavior is fenced with `#if canImport(...)`, which keeps the core libraries portable.
- The README reflects real operational constraints: Accessibility permission, anonymous-vs-token API use, launch-at-login bundle requirements, local distribution, and the offline index.

## High-Priority Recommendations

### 1. Rebuild or refresh `SearchClient` when CourtListener token settings change

`AppDelegate.setUpPanel()` creates one `SearchClient` from `AppSettings.shared.effectiveAPIKey` at launch (`Sources/App/AppDelegate.swift:74`). `SearchViewModel` then holds that client in an immutable property (`Sources/App/SearchViewModel.swift:61`). The Settings window updates `useCustomAPIKey` and `apiKey` in `UserDefaults` (`Sources/App/PreferencesView.swift:36`, `Sources/App/PreferencesView.swift:41`), but the already-created client will continue using the old token until the app restarts.

Recommended fix:

- Make the client use a token provider closure, e.g. `() -> String?`, evaluated per request.
- Or rebuild the model/client when Settings closes or when token-related settings change.
- Add a small test with an injected URL protocol/session proving that a token toggle affects the next request without relaunching.

### 2. Store the CourtListener API token in Keychain instead of `UserDefaults`

The app is clear that the token is local-only, but it is currently persisted through `UserDefaults` (`Sources/App/Settings.swift:57`). `UserDefaults` is acceptable for preferences, but API tokens should be treated as credentials.

Recommended fix:

- Store the token in Keychain via Security framework.
- Keep `useCustomAPIKey` in `UserDefaults`.
- Migrate an existing `courtListenerAPIKey` value once, then remove it from defaults.

### 3. Add tests for search ranking, deduping, and error messages

`SearchViewModel.mergeRanked` has a lot of important product behavior in a compact heuristic: identity, relevance tiers, court prominence, SCOTUS citation rank, and stable ordering (`Sources/App/SearchViewModel.swift:153`). There are no tests exercising this behavior.

Recommended coverage:

- Landmark surname queries: `garner`, `nixon`, `bivens`.
- Deduping local and web hits by rendered preferred citation (`Sources/App/SearchViewModel.swift:145`).
- Web result outranking local result when its name match is materially better.
- Lower-court results filling in below local SCOTUS hits.
- User-facing error mapping for `429`, timeout, transport, and other HTTP statuses (`Sources/App/SearchViewModel.swift:223`).

This can stay unit-level if the ranking functions move into a small platform-neutral search-ranking type in `CourtListener` or a testable app-support module.

### 4. Harden `CitationParser` for CourtListener citation variants

`CitationParser.parse` only accepts citations shaped like `<integer volume> <reporter...> <integer page>` (`Sources/CourtListener/Models.swift:100`). That is a reasonable v1, but real legal citations often include variants this parser will drop, such as slip opinions, star pages, docket citations, old nominative reporters, page ranges, and occasional punctuation.

Recommended path:

- Build a small fixture file from real CourtListener `citation` arrays that currently fail parsing but should be citeable.
- Extend parsing test-first for high-value variants only.
- Track intentionally unsupported variants so they do not look like accidental misses.

### 5. Classify decoding failures separately from transport failures

`SearchClient.dataRetryingTimeout` maps non-timeout errors to `.transport`, while JSON decoding errors from `fetch` currently flow out as a generic error and become `"Search failed"` in the UI (`Sources/CourtListener/SearchClient.swift:101`, `Sources/App/SearchViewModel.swift:223`). That is not wrong, but it gives little diagnostic signal if CourtListener changes its response shape.

Recommended fix:

- Add `ClientError.decoding(String)` or similar.
- Catch `DecodingError` in `fetch`.
- Surface a concise user message while logging the detailed decoding issue for diagnostics.

## Medium-Priority Recommendations

### 6. Add integration tests for `SearchClient` request construction and cache behavior

The cache actor is tested well, but `SearchClient` itself is not. Its correctness depends on query construction, headers, auth, fallback search, status handling, timeout mapping, and cache writes (`Sources/CourtListener/SearchClient.swift:56`).

Recommended coverage with an injected `URLSession`/`URLProtocol`:

- `caseName:(query)` search is attempted first.
- Full-text fallback is attempted only when the case-name response is empty.
- `Authorization: Token ...` appears only when a token is active.
- `429` maps to `.http(429)`.
- Successful empty results are cached.
- Failed responses are not cached.

### 7. Introduce a manual smoke-test checklist for macOS paste-back

The riskiest behavior is hard to unit test: previous-app focus, clipboard flavor negotiation, Accessibility permission, and the 50 ms paste delay (`Sources/App/Paster.swift:26`). A short manual checklist would catch regressions before daily use or packaging.

Suggested matrix:

- Word or Pages: RTF italics preserved.
- TextEdit rich text: RTF italics preserved.
- TextEdit plain text or a terminal: plain text fallback works.
- Browser `contenteditable`: RTF or acceptable plain fallback.
- No Accessibility permission: app prompts and does not paste silently.
- Slow app activation: paste lands in the prior app, not the search panel.

### 8. Consider extracting search orchestration out of the SwiftUI-facing view model

`SearchViewModel` currently owns debouncing, local/web merge, result ranking, citation assembly, signal state, short-form state, and committed-cite editing. It is still readable, but it is now the densest behavioral object in the app.

Recommended refactor when you next touch this area:

- Keep UI state in `SearchViewModel`.
- Move local/web search orchestration and ranking into a small service.
- Move pending string-citation editing into a focused model with tests.

This would make the keyboard-heavy UI safer to evolve without requiring AppKit/SwiftUI tests for every logic branch.

### 9. Make cache persistence failures observable in debug builds

`SearchCache.persist()` intentionally ignores disk failures (`Sources/CourtListener/SearchCache.swift:94`). That is fine for user-facing behavior, but it makes cache corruption or directory permission problems invisible during development.

Recommended fix:

- Keep production behavior best-effort.
- Add optional logger injection or `#if DEBUG` logging when load/write/decode fails.

### 10. Validate the bundled SCOTUS index in CI or a lightweight script

The bundled index is about 5.1 MB and is central to the offline-first experience. There is no automated check that it decodes, has expected landmark cases, or remains sorted by intended relevance/citation count.

Recommended checks:

- Decode `scotus-index.json` as `[SearchResult]`.
- Assert it is non-empty and contains a few canonical cases.
- Assert known queries like `roe wade`, `obergefell`, and `marbury` return citeable local hits.

## Lower-Priority Recommendations

### 11. Review packaging signing settings before broader distribution

`project.yml` is intentionally local-first: automatic signing, no hardened runtime, no sandbox. That matches current usage, but it should be revisited before shipping outside trusted local installs.

Recommended next step:

- Keep current settings for local development.
- Add a separate release/distribution note or config if you decide to notarize.
- Re-test Accessibility and paste-back behavior if hardened runtime or sandboxing changes.

### 12. Expand formatter fixtures from real-world citations over time

The formatter is deliberately conservative, which is the right default for legal citation output. The next gains should come from real examples rather than broad rules.

Good fixture sources:

- CourtListener results that users actually select.
- State cases with parallel official/regional reporters.
- Captions with `et al.`, consolidated parties, agencies, and procedural phrases.
- Short-form titles where the heuristic needs an override.

## Verification

`swift test` was run on 2026-06-21 and passed:

- 50 tests executed
- 0 failures
- Targets covered by the suite: `BluebookFormatTests`, `CourtListenerTests`

