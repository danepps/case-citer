# Feature idea: "(en banc)" parenthetical for court of appeals decisions

**Status:** Proposal only — not implemented.

## Goal

When a selected case is a U.S. court of appeals decision issued by the full court
sitting en banc, append the Bluebook `(en banc)` weight-of-authority parenthetical
to the formatted cite, e.g.:

> *Peruta v. County of San Diego*, 824 F.3d 919 (9th Cir. 2016) (en banc).

## What CourtListener gives us

There is **no dedicated `en_banc` field** in the CourtListener API. Verified against
the v4 API (both the `type=o` search endpoint and the `/clusters/{id}/` detail
endpoint) — neither carries a boolean, enum, or tag marking en banc.

Two signals can be used to *infer* it:

### 1. Judge count (primary structured signal)

The cluster detail (`/clusters/{id}/`) exposes a `judges` field: a comma-separated
string of the deciding judges' last names. A normal merits panel has 3; an en banc
court has many more.

Confirmed with *Peruta v. County of San Diego* (which exists in CL as both the panel
and the en banc rehearing):

| Decision                         | `judges`                                                                                  | Count |
| -------------------------------- | ----------------------------------------------------------------------------------------- | ----- |
| 3-judge panel (742 F.3d 1144)    | `O'Scannlain, Thomas, Callahan`                                                           | 3     |
| En banc (824 F.3d 919)           | `Thomas, Pregerson, Silverman, Graber, McKeown, Fletcher, Paez, Callahan, Bea, Smith, Owens` | 11    |

**Heuristic:** for a COA decision, a `judges` count > 3 strongly indicates en banc.

Caveats:
- `judges` is a string, not an array — split on commas and count.
- No single magic threshold: the Ninth Circuit uses an 11-judge *limited* en banc,
  while most circuits sit with *all* active judges (~6–17, court-dependent). So
  "> 3" is the reliable rule, not "== N".
- The field is occasionally empty or messy in CL's data.

### 2. Literal "en banc" in the opinion text (corroborating signal)

The opinion resource (`/opinions/{id}/`, e.g. `plain_text` / `html*`) typically
contains the phrase. The Peruta en banc opinion includes:

> "Argued and Submitted **En Banc** June 16, 2015"

Other forms: "ON REHEARING EN BANC", "Before: ... En Banc". This is the most explicit
signal but is plain text-matching, with false-positive risk (e.g. an opinion that
merely *mentions* "denied rehearing en banc" in a procedural note).

## Integration cost / the catch

The **search results the app already fetches do not carry any of this.** The
`type=o` search index returned empty `panel_names`, `posture`, and
`procedural_history` for the Peruta results. The `judges` string and opinion text
only populate on the **cluster / opinion detail endpoints**.

So supporting the parenthetical requires an **extra API round-trip** beyond the
current single `searchOpinions` call:

1. From the search result, take `cluster_id`.
2. `GET /api/rest/v4/clusters/{cluster_id}/` → read `judges`.
3. (Optional) `GET` a `sub_opinion` → scan text for "en banc".

## Suggested approach (if pursued)

- **Gate to COA courts only** — `court_id` in `{ca1…ca11, cadc, cafc}` (en banc is a
  COA concept; SCOTUS always sits full, district courts don't sit en banc).
- **Fetch the cluster lazily** — only on result selection / when building the final
  cite, not for every search hit, to avoid N extra requests per keystroke.
- **Primary rule:** `judges`-count > 3 ⇒ treat as en banc.
- **Optional confirmation:** corroborate with an "en banc" text match near the top of
  the opinion before adding the parenthetical, to suppress false positives.
- Thread an `enBanc: Bool` (or similar) through `CaseRecord` so `Reporter.render` /
  the formatter can emit the trailing `(en banc)` per the selected citation style.

## Open questions

- Is one extra round-trip per selection acceptable for the UX, or should en banc
  detection be opt-in?
- How to handle ambiguous judge counts (e.g. a 4-judge listing — data error vs. small
  en banc)? Lean conservative (omit the parenthetical when unsure) since a wrong
  weight-of-authority parenthetical is a substantive citation error.
- Should this be one of the configurable Bluebook "signals" already in `Settings`?
