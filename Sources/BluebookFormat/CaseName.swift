import Foundation

/// Case-name handling: Bluebook B10.1.1 abbreviation (Table T6 words + Table T10
/// geographic terms), `v.` normalization, and italicization governed by the
/// `CitationStyle`.
///
/// Deliberately **permissive**: it abbreviates the common, unambiguous words and
/// leaves everything else verbatim. It does *not* yet drop subsequent parties,
/// "et al.", "the State of", procedural-history junk, etc. — those rules are
/// error-prone and are grown test-first. The aim is "never wrong by abbreviating
/// something it shouldn't", at the cost of "sometimes less abbreviated than ideal".
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
        let abbreviated = abbreviate(normalizeV(rawName))

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
        let normalized = normalizeV(rawName)

        // "In re X" / "Ex parte X": the subject after the phrase is the short title.
        for phrase in leadingProceduralPhrases where normalized.hasPrefix(phrase) {
            return shortenParty(abbreviate(String(normalized.dropFirst(phrase.count))))
        }

        let sides = normalized.components(separatedBy: " v. ")
        let primary = (sides.first ?? normalized).trimmingCharacters(in: .whitespaces)
        // Skip a generic governmental/geographic first party for the opposing one.
        let chosen: String
        if sides.count >= 2, isGenericParty(primary) {
            chosen = sides[1].trimmingCharacters(in: .whitespaces)
        } else {
            chosen = primary
        }
        return shortenParty(abbreviate(chosen))
    }

    /// A party that's a generic governmental/geographic litigant rather than a
    /// distinctive name — the one Bluebook drops from the short form. A *named*
    /// state (`Arizona`, `California`) is **not** generic: `Arizona v. United States`
    /// shortens to *Arizona*, while `United States v. Nixon` shortens to *Nixon*.
    private static func isGenericParty(_ party: String) -> Bool {
        let lower = party.lowercased().trimmingCharacters(in: .whitespaces)
        if lower == "united states" || lower == "united states of america" { return true }
        let leads = ["state", "commonwealth", "people", "city of", "county of", "town of", "village of"]
        return leads.contains { lower == $0 || lower.hasPrefix($0 + " ") }
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
                       "fund", "company", "council", "union", "found"]
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
