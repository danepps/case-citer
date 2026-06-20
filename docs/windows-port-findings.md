# Findings from the Windows port (for the macOS codebase)

While porting the citation engine to C# for the Windows build, real-world testing
against CourtListener data surfaced a few issues that exist in the **original
Swift source too** (`Sources/BluebookFormat/`), not just in the port. Writing them
up here so they can be fixed on the macOS side as well.

> **Status (macOS): all three applied.** As of June 2026 the Swift source carries
> fixes for all three findings below, with unit-test coverage in
> `Tests/BluebookFormatTests/CaseCitationTests.swift`:
> 1. RTF `\uN?` fallback char — `RichText.escapeRTF`.
> 2. Court designation sourced from CL's `court_citation_string` (with the
>    `"SCOTUS"`-means-omit wrinkle) — `CaseRecord.courtString`, `Court.designation`,
>    `SearchResult.court_citation_string`.
> 3. Style-aware reporter `Kind` split (`federalOfficial`/`federal`/`regional`/
>    `stateOfficial`) and `Reporter.primary(from:style:)` per Rule 10.3.1.
>
> The notes below are kept as the rationale/spec; they double as a reference for
> keeping the two implementations in sync.

## 1. RTF Unicode escaping truncates output on some RTF readers

`RichText.escapeRTF` (`Sources/BluebookFormat/RichText.swift`) escapes non-ASCII
characters as:

```
\uN{}
```

e.g. a curly apostrophe (U+2019, as in "Dep't") becomes `舗{}`.

**The problem:** per the RTF spec, a `\uN` Unicode escape must be followed by
exactly **one literal fallback character** (for readers that don't support
`\u`), not an empty group. On Windows, every RTF consumer we tried (Word,
WordPad, RichEdit-based text boxes) silently **stopped parsing the rest of the
document** as soon as it hit `舗{}` — so a citation like:

> Goodridge v. Dep't of Public Health, ...

would get cut off right after "Dep'" — everything after the bad escape was
dropped.

**Is this actually a live bug on macOS?** Probably not urgently. Cocoa's RTF
reader (`NSAttributedString`) is generally more lenient about malformed escapes
than Windows' parsers, and the app's been in regular use without this surfacing
— that's decent evidence it isn't breaking in practice for the apps you've
pasted into (Pages, Mail, etc.). But the escape is non-conformant RTF
regardless of platform, so it's a latent risk: a stricter RTF consumer, or a
macOS parser change down the line, could trigger the same silent truncation.
Since the fix is a one-line change, seems worth doing regardless, but you
shouldn't treat this as an active bug affecting users today the way it was for
us on Windows.

**Fix applied on the Windows side:** emit a literal `?` as the fallback
character instead of `{}`:

```diff
- else sb.Append($"\\u{rune.Value}{{}}");
+ else sb.Append($"\\u{rune.Value}?");
```

Swift equivalent would be the same change in `RichText.escapeRTF`:

```swift
// before
out += "\\u\(scalar.value){}"
// after
out += "\\u\(scalar.value)?"
```

## 2. `Court` table only covers SCOTUS + federal circuits — no state or district courts

`Court.swift`'s `table` dictionary only has entries for `scotus` and the 13
federal circuits. Any state court or federal district court case falls through
to the "unknown court" branch, which prints only the year — e.g. `(1998)`
instead of `(Ariz. 1998)`. This is a real Bluebook gap (Rule 10.4 requires a
court designation for non-SCOTUS reporters whose name doesn't make the court
obvious), not just a Windows-port omission.

**Fix applied on the Windows side:** rather than trying to hand-maintain a
table for every U.S. court (there are hundreds), we pull a ready-made
abbreviation directly from CourtListener's own search API response —
`court_citation_string` — and pass it through `CaseRecord` as an explicit
override:

```
"court_citation_string":"N.D. Iowa"
"court_citation_string":"Ohio Ct. App."
"court_citation_string":"Mass."
```

This single field already disambiguates court level within a state too (e.g.
`Mass.` vs. `Mass. App. Ct.`), which a hand-built table would otherwise need to
get right per state — including some genuinely tricky historical cases (e.g.
Arizona's `Ariz.` reporter absorbed its separate Court of Appeals reporter in
1976, so the same reporter abbreviation needs different treatment depending on
era — not something a static lookup keyed only on reporter name can express).

We kept the existing federal circuit/SCOTUS table as a fallback for cases where
this field is absent (e.g. the offline-bundled SCOTUS index doesn't carry it),
but `court_citation_string` is now the primary source whenever it's present.
**Important wrinkle:** CourtListener literally returns `"SCOTUS"` for that
field on Supreme Court cases — Bluebook's "omit the court for SCOTUS" rule
(the `U.S.` reporter already implies it) needs to stay a special case rather
than trusting the field there.

We initially also tried to implement Bluebook's optional rule that lets you
*omit* the court designation entirely when a state's reporter name makes the
court unambiguous on its own (Rule 10.4(b)) — but backed out of it. There's too
much state-by-state and era-dependent nuance (see the Arizona example above) to
get right without the actual Bluebook Table T1 text, and the rule is
permissive ("you may omit"), not mandatory — so always showing the court
designation is never a citation **error**, just occasionally more verbose than
the most polished style. We'd recommend the same call on macOS: always show the
court designation rather than attempting the omission heuristic.

## 3. No style-aware reporter preference (Bluebook Rule 10.3.1)

Neither version distinguished *which* parallel reporter citation to print based
on `CitationStyle`. Bluebook Rule 10.3.1 says: law-review citations should cite
**only the regional reporter** (e.g. `N.E.2d`) for state cases, while
court-document citations should cite the state's **own official reporter**
(e.g. `Mass.`). Previously, `Reporter.primary` just picked by a flat precedence
(`official` > everything else), with no style awareness, and no distinction
between "official federal reporter" and "official state reporter" in the first
place — they were both lumped into one `Kind`.

**Fix applied on the Windows side:**
- Split the old `Kind` enum (`official`/`neutral`/`regional`/`specialty`/`unknown`)
  into one that actually distinguishes federal reporters (always top priority,
  no style split — there's no academic/practitioner distinction for federal
  cites) from the two state-specific kinds: `regional` (multistate reporters —
  `A.`/`N.E.`/`N.W.`/`P.`/`S.E.`/`S.W.`/`So.` and their numbered series) and
  `stateOfficial` (everything else — a state's own official reporter).
- `Reporter.primary` now takes the `CitationStyle` and prefers `regional` in
  law-review mode, `stateOfficial` in court-document mode, falling back to the
  other state kind (or whatever's available) if the case's data doesn't carry
  a citation in the preferred kind.

Worth noting: this surfaced in testing because *CourtListener's own data*
doesn't always carry both parallel citations — e.g. it has no `N.E.2d` cite for
*Goodridge v. Department of Public Health* at all, only the official `Mass.`
cite. That's a CourtListener data-completeness limitation, not a bug in the
preference logic — the formatter already falls back correctly when only one
reporter is available.

## Suggested fix order for the macOS side

1. RTF escaping (#1) — small, isolated, no API changes.
2. Reporter `Kind` split + style-aware `Reporter.primary` (#3) — touches the
   public `ReporterCitation.Kind` enum, so anything constructing citations with
   explicit kinds needs updating.
3. Court abbreviation sourcing from CourtListener (#2) — touches `CaseRecord`
   (new optional field) and `Court.parenthetical`'s signature.
