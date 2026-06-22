# Changelog

All notable changes to Case Citer are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Case-name cleanup for messy CourtListener captions.** CourtListener often
  returns the full, unabbreviated party roster as a case name. The formatter now
  reduces these to a clean Bluebook caption:
  - First-listed party on each side only, dropping the rest and any "et al."
    (Rule 10.2.1(a)). Trailing designations that belong to the first party
    (`Jr.`, `Inc.`, `Co.`, …) are kept.
  - Chained `v.` segments from consolidated cases and cross-appeals are collapsed
    to the first two sides.
  - Consolidated cross-appeals re-listed after a period (`…Authority. Hester Lee
    Searles … v. …`) are truncated at that sentence boundary, with an allowlist so
    abbreviations (`No.`, `Dr.`, `Bros.`, `ex rel.`, …) are not mistaken for one.
  - Individual parties are reduced to a surname while business, governmental, and
    state party names are kept whole (Rule 10.2.1(g)).
  - These cleanups apply to both the search-results list and the inserted citation.

### Changed

- The CourtListener API token is now read per request, so toggling it in Settings
  takes effect on the next search without relaunching the app.

### Fixed

- JSON decoding failures are now classified separately from transport errors,
  surfacing a concise "Unexpected response" message while logging the detail for
  diagnostics (previously a generic "Search failed").

### Known limitations

- Captions that concatenate multiple parties with no delimiter at all
  (e.g. `Lloyd W. Cramer Daniel E. Lipich` or `Little Rock School District Lorene
  Joshua`) are left intact: there is no reliable signal for where one party ends
  and the next begins, and guessing would risk mangling legitimate names.
