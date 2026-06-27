import Foundation

/// Case-name handling: Bluebook B10.1.1 abbreviation (Table T6 words + Table T10
/// geographic terms), `v.` normalization, and italicization governed by the
/// `CitationStyle`.
///
/// Deliberately **permissive**: it abbreviates the common, unambiguous words and
/// leaves everything else verbatim. It drops subsequent parties (Rule 10.2.1(a),
/// see `firstPartyEachSide`) but otherwise leaves "the State of", procedural-history
/// junk, etc. alone — those rules are error-prone and are grown test-first. The aim
/// is "never wrong by abbreviating something it shouldn't", at the cost of
/// "sometimes less abbreviated than ideal".
public enum CaseName {

    /// Table T6: words abbreviated in case names. Keyed by lowercased whole word.
    /// Curly apostrophes (U+2019) match Bluebook typography.
    static let t6: [String: String] = [
        "association": "Ass\u{2019}n",
        "associations": "Ass\u{2019}ns",
        "brothers": "Bros.",
        "company": "Co.",
        "corporation": "Corp.",
        "incorporated": "Inc.",
        "limited": "Ltd.",
        "manufacturing": "Mfg.",
        "railroad": "R.R.",
        "railway": "Ry.",
        "department": "Dep\u{2019}t",
        "development": "Dev.",
        "district": "Dist.",
        "division": "Div.",
        "education": "Educ.",
        "electric": "Elec.",
        "engineering": "Eng\u{2019}g",
        "environmental": "Envtl.",
        "federal": "Fed.",
        "government": "Gov\u{2019}t",
        "hospital": "Hosp.",
        "industries": "Indus.",
        "industry": "Indus.",
        "insurance": "Ins.",
        "international": "Int\u{2019}l",
        "laboratory": "Lab.",
        "laboratories": "Labs.",
        "machine": "Mach.",
        "national": "Nat\u{2019}l",
        "number": "No.",
        "product": "Prod.",
        "products": "Prods.",
        "service": "Serv.",
        "services": "Servs.",
        "system": "Sys.",
        "systems": "Sys.",
        "transportation": "Transp.",
        "university": "Univ.",
    ]

    /// Table T10 (subset): geographic terms abbreviated in case names. "United
    /// States" is intentionally absent — as a party it is *not* abbreviated.
    static let t10: [String: String] = [
        "california": "Cal.",
        "connecticut": "Conn.",
        "massachusetts": "Mass.",
        "pennsylvania": "Pa.",
        "virginia": "Va.",
        "washington": "Wash.",
    ]

    /// Procedural phrases that stay italic in *both* style modes (Rule B10.1.1 /
    /// R10.2.1(b)). Detected at the head of the name or inline.
    static let leadingProceduralPhrases = ["In re ", "Ex parte "]
    static let inlineProceduralPhrases = [" ex rel. "]

    /// Abbreviate the words of a (single-party-side or full) name string.
    /// Punctuation attached to a word (trailing comma, etc.) is preserved.
    public static func abbreviate(_ name: String) -> String {
        let tokens = name.split(separator: " ", omittingEmptySubsequences: false)
        let mapped = tokens.map { token -> String in
            abbreviateToken(String(token))
        }
        return mapped.joined(separator: " ")
    }

    private static func abbreviateToken(_ token: String) -> String {
        guard !token.isEmpty else { return token }
        // Split leading/trailing punctuation off the alphabetic core so a word
        // like "Co.," or "(Inc." still matches.
        let leading = token.prefix { !$0.isLetter }
        let trailing = token.reversed().prefix { !$0.isLetter }
        let coreStart = token.index(token.startIndex, offsetBy: leading.count)
        let coreEnd = token.index(token.endIndex, offsetBy: -trailing.count)
        guard coreStart < coreEnd else { return token }
        let core = String(token[coreStart..<coreEnd])
        let key = core.lowercased()
        guard let repl = t6[key] ?? t10[key] else { return token }
        return String(leading) + repl + String(trailing.reversed())
    }

    /// Build the styled case name. In law-review mode the party names are roman
    /// but any procedural phrase stays italic; in court-document mode the whole
    /// name is italic.
    public static func render(_ rawName: String, style: CitationStyle) -> RichText {
        let abbreviated = abbreviate(bluebookCaseName(rawName))

        if style == .courtDocument {
            return .italic(abbreviated)
        }

        // Law-review: roman, with procedural phrases italicized.
        return italicizeProceduralPhrases(in: abbreviated)
    }

    /// Derive a Bluebook **short-form** case title (Rule 10.9 / B10.2) from a full
    /// case name: normally one party's name, dropping a generic governmental party
    /// (`United States`, `State`, `People`, `City of …`) in favor of the opposing
    /// party, and reducing a personal-name party to its surname. Always returns the
    /// *plain* string (the caller italicizes it) and is deliberately heuristic — the
    /// UI offers an editable override for the captions it guesses wrong.
    public static func shortTitle(_ rawName: String) -> String {
        // Reduce multi-party sides to the first party up front, so a class-action
        // caption ("Smith, Jones, … v. Acme") yields a clean short title.
        let normalized = firstPartyEachSide(rawName)

        // "In re X" / "Ex parte X": the subject after the phrase is the short title.
        for phrase in leadingProceduralPhrases where normalized.hasPrefix(phrase) {
            return shortenParty(abbreviate(String(normalized.dropFirst(phrase.count))))
        }

        let sides = normalized.components(separatedBy: " v. ").map { $0.trimmingCharacters(in: .whitespaces) }
        let primary = sides.first ?? normalized
        let chosen: String
        if sides.count >= 2, isGenericParty(primary) {
            // A common governmental litigant on the left (United States, State, People,
            // City of …): the distinctive party is the opponent — e.g. *Nixon* in
            // United States v. Nixon.
            chosen = sides[1]
        } else if sides.count >= 2, isStateName(primary), isPersonalName(sides[1]) {
            // A *named* state prosecuting/suing an individual: the short form is that
            // individual, not the state — *Garner* in Tennessee v. Garner. But a state
            // opposite another state or a federal agency keeps the state (Arizona v.
            // United States → *Arizona*; Massachusetts v. EPA → *Massachusetts*).
            chosen = sides[1]
        } else {
            chosen = primary
        }
        // A state standing alone as a party isn't abbreviated (Cal.) or collapsed to a
        // word ("New York" → "York"); keep it whole.
        if isStateName(chosen) { return chosen }
        return shortenParty(abbreviate(chosen))
    }

    /// A party that's a generic governmental/geographic litigant rather than a
    /// distinctive name — the one Bluebook drops from the short form. A *named* state
    /// (`Arizona`, `California`) is **not** generic here: opposite another governmental
    /// party it stays (`Arizona v. United States` → *Arizona*); it yields only to an
    /// *individual* opponent, handled separately in `shortTitle` via `isStateName`.
    private static func isGenericParty(_ party: String) -> Bool {
        let lower = party.lowercased().trimmingCharacters(in: .whitespaces)
        if lower == "united states" || lower == "united states of america" { return true }
        let leads = ["state", "commonwealth", "people", "city of", "county of", "town of", "village of"]
        return leads.contains { lower == $0 || lower.hasPrefix($0 + " ") }
    }

    /// The 50 states (plus D.C. / Puerto Rico), lowercased, for spotting a state acting
    /// as a governmental party. Matched whole (not by prefix) so an organization that
    /// merely starts with a state name — *New York Times Co.* — isn't caught.
    private static let usStates: Set<String> = [
        "alabama", "alaska", "arizona", "arkansas", "california", "colorado",
        "connecticut", "delaware", "florida", "georgia", "hawaii", "idaho", "illinois",
        "indiana", "iowa", "kansas", "kentucky", "louisiana", "maine", "maryland",
        "massachusetts", "michigan", "minnesota", "mississippi", "missouri", "montana",
        "nebraska", "nevada", "new hampshire", "new jersey", "new mexico", "new york",
        "north carolina", "north dakota", "ohio", "oklahoma", "oregon", "pennsylvania",
        "rhode island", "south carolina", "south dakota", "tennessee", "texas", "utah",
        "vermont", "virginia", "washington", "west virginia", "wisconsin", "wyoming",
        "district of columbia", "puerto rico",
    ]

    private static func isStateName(_ party: String) -> Bool {
        usStates.contains(party.lowercased().trimmingCharacters(in: .whitespaces))
    }

    /// A party that reads as an individual (collapsible to a surname) rather than a
    /// government, geographic unit, organization, or acronym — used to decide whether a
    /// state-vs-X caption shortens to X (Tennessee v. *Garner*) or stays the state
    /// (Massachusetts v. EPA, California v. Texas).
    private static func isPersonalName(_ party: String) -> Bool {
        !isGenericParty(party) && !isStateName(party)
            && !looksLikeOrganization(party) && !isAcronym(party)
    }

    /// A short all-caps token like `EPA`, `FCC`, `NLRB` — a governmental/organizational
    /// acronym, not a person.
    private static func isAcronym(_ party: String) -> Bool {
        let core = party.replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard (2...5).contains(core.count) else { return false }
        return core.allSatisfy { $0.isUppercase }
    }

    /// Reduce a (already-abbreviated) party to its short-form token(s): a personal
    /// name collapses to its surname (last word); an organization keeps its
    /// abbreviated name (`Standard Oil Co.`), since one word would lose the cite.
    private static func shortenParty(_ party: String) -> String {
        let tokens = party.split(separator: " ").map(String.init)
        guard tokens.count > 1 else { return party }
        if looksLikeOrganization(party) { return party }
        return tokens.last ?? party
    }

    /// Heuristic: does this party read as an organization (keep the full name) rather
    /// than a personal name (collapse to a surname)?
    private static func looksLikeOrganization(_ party: String) -> Bool {
        let lower = party.lowercased()
        if lower.contains(" of ") || lower.contains(" & ") || lower.contains(" and ") { return true }
        let markers = ["co.", "corp.", "inc.", "ltd.", "ass\u{2019}n", "ass\u{2019}ns",
                       "r.r.", "ry.", "mfg.", "nat\u{2019}l", "int\u{2019}l", "ins.", "bros.",
                       "board", "bureau", "commission", "dep\u{2019}t", "department",
                       "univ.", "university", "bank", "school", "church", "trust",
                       "fund", "company", "council", "union", "found", "authority"]
        return markers.contains { lower.contains($0) }
    }

    /// Normalize the versus separator to Bluebook `v.` (handles "vs.", "vs",
    /// stray casing) without touching party text.
    static func normalizeV(_ name: String) -> String {
        // Replace a standalone "v.", "vs.", "vs", "v" token (surrounded by spaces)
        // with "v.". Anchored on spaces so it can't corrupt a party name.
        let pattern = "\\s+v(?:s)?\\.?\\s+"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return name
        }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return re.stringByReplacingMatches(in: name, range: range, withTemplate: " v. ")
    }

    /// Whole words that legitimately precede a "`. `"-then-capital inside a party name
    /// (titles and Bluebook abbreviations), so they are *not* read as a sentence
    /// boundary by `truncateAtConsolidatedBoundary`. Abbreviations with internal
    /// periods or apostrophes ("U.S.", "Dep't") never reach the 2+-letter test, so
    /// only the plain-letter stems need listing here.
    static let boundarySafeAbbreviations: Set<String> = [
        "no", "dr", "mr", "mrs", "ms", "st", "co", "corp", "inc", "ltd", "jr", "sr",
        "esq", "hon", "bros", "mfg", "dev", "dist", "div", "educ", "elec", "envtl",
        "fed", "hosp", "indus", "ins", "lab", "labs", "mach", "serv", "servs", "sys",
        "transp", "univ", "dept", "etc", "vs", "al", "ry", "rr", "ave", "rd",
        "rel", "ex",  // "ex rel." relator phrase
    ]

    /// CourtListener glues a consolidated cross-appeal onto a caption by re-listing the
    /// whole thing after the defendant, joined only by a period ("…Transportation
    /// Authority. Hester Lee Searles … v. …"). Cut at the first such sentence boundary
    /// — a 2+-letter whole word, then a period, a space, and a capital — so only the
    /// first case survives. Recognized abbreviations (`boundarySafeAbbreviations`,
    /// plus initials/acronyms, which can't match the 2+-letter word) are not boundaries.
    static func truncateAtConsolidatedBoundary(_ name: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "([A-Za-z]{2,})\\. [A-Z]") else {
            return name
        }
        let ns = name as NSString
        let matches = re.matches(in: name, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let word = ns.substring(with: m.range(at: 1))
            if boundarySafeAbbreviations.contains(word.lowercased()) { continue }
            // Keep everything up to and including the boundary word (drop its period).
            return ns.substring(to: m.range(at: 1).location + m.range(at: 1).length)
        }
        return name
    }

    /// Trailing party designations that belong to the *first* party rather than
    /// signalling a second one — so "Cota, Jr." or "Acme, Inc." aren't mistaken for a
    /// party list. Matched case-insensitively against a whole comma-separated segment.
    static let partyDesignations: Set<String> = [
        "jr.", "jr", "sr.", "sr", "ii", "iii", "iv",
        "inc.", "inc", "co.", "corp.", "llc", "l.l.c.", "llp", "l.l.p.",
        "n.a.", "ltd.", "ltd", "esq.", "p.c.", "l.p.", "p.a.",
    ]

    /// Reduce a CourtListener caption to a clean two-party case name (Rule 10.2.1(a)).
    /// Two independent forms of bloat are stripped:
    ///
    /// 1. **Chained `v.` segments.** A real caption has exactly two sides, but
    ///    CourtListener concatenates consolidated cases and cross-appeals into a chain
    ///    ("Harris v. Stephens v. Stephens", "O'Connor v. Clayter v. … v. United
    ///    States"). Only the first two sides are kept.
    /// 2. **Party lists within a side.** When a side lists several parties, cite only
    ///    the first and drop the rest — *without* an "et al." (see `firstParty`).
    ///
    /// A plain two-party caption passes through untouched. Returns the `v.`-normalized
    /// string so callers can feed it straight into `abbreviate`.
    public static func firstPartyEachSide(_ rawName: String) -> String {
        normalizeV(truncateAtConsolidatedBoundary(rawName))
            .components(separatedBy: " v. ")
            .prefix(2)
            .map(firstParty)
            .joined(separator: " v. ")
    }

    /// The case name as Bluebook wants it displayed: `firstPartyEachSide` plus
    /// Rule 10.2.1(g) — an individual party is reduced to a surname, while business,
    /// governmental, and geographic party names are kept whole (see `surnameOnly`).
    /// This is the form shown in the picker and fed to `render`.
    public static func bluebookCaseName(_ rawName: String) -> String {
        firstPartyEachSide(rawName)
            .components(separatedBy: " v. ")
            .map(surnameOnly)
            .joined(separator: " v. ")
    }

    /// Reduce a party to its surname when it reads as an individual with a plain
    /// first/(middle)/last shape (Rule 10.2.1(g)). Organizations, governmental and
    /// state parties, and acronyms are kept whole. A 4+-token string is left intact
    /// too: it's far likelier a space-concatenated multi-party caption (where the last
    /// token is the *wrong* party's surname) than one person's name.
    private static func surnameOnly(_ party: String) -> String {
        let p = party.trimmingCharacters(in: .whitespaces)
        guard isPersonalName(p) else { return p }
        let tokens = p.split(separator: " ").map(String.init)
        guard (2...3).contains(tokens.count) else { return p }
        return tokens.last ?? p
    }

    /// First listed party on one side, keeping any trailing designation that belongs
    /// to it (see `partyDesignations`). Everything from the first genuine party-list
    /// comma onward — including a trailing "et al." or "and …" — is dropped.
    private static func firstParty(_ side: String) -> String {
        let segments = side.components(separatedBy: ",")
        guard segments.count > 1 else { return side.trimmingCharacters(in: .whitespaces) }
        var result = segments[0].trimmingCharacters(in: .whitespaces)
        var i = 1
        while i < segments.count {
            let seg = segments[i].trimmingCharacters(in: .whitespaces)
            guard partyDesignations.contains(seg.lowercased()) else { break }
            result += ", " + seg
            i += 1
        }
        return result
    }

    /// Produce a roman `RichText` with leading "In re "/"Ex parte " and inline
    /// " ex rel. " spans wrapped italic.
    static func italicizeProceduralPhrases(in name: String) -> RichText {
        for phrase in leadingProceduralPhrases where name.hasPrefix(phrase) {
            let rest = String(name.dropFirst(phrase.count))
            var rt = RichText.italic(phrase)            // includes trailing space
            rt.append(italicizeInline(rest))
            return rt
        }
        return italicizeInline(name)
    }

    private static func italicizeInline(_ name: String) -> RichText {
        for phrase in inlineProceduralPhrases {
            if let range = name.range(of: phrase) {
                var rt = RichText.roman(String(name[name.startIndex..<range.lowerBound]))
                rt.append(phrase, italic: true)
                rt.append(String(name[range.upperBound...]), italic: false)
                return rt
            }
        }
        return .roman(name)
    }
}
