import Foundation

/// Assembles a full Bluebook **case** citation as `RichText`:
///
///   [<italic signal> ]<name>, <vol> <reporter> <page>[, <pincite>] (<court> <year>).
///
/// e.g. `See Obergefell v. Hodges, 576 U.S. 644, 681 (2015).`
///
/// Pure and deterministic: given a `CaseRecord` + options it returns styled text
/// you can paste as RTF (italics preserved) or plain (degraded). No UI/network.
public enum CaseCitation {

    public struct Options {
        public var style: CitationStyle
        public var signal: Signal?
        public var pincite: String?
        /// Explanatory parenthetical, rendered roman in parens after the date — e.g.
        /// "en banc" → `... (1954) (en banc).` Just the inner text, no parens.
        public var parenthetical: String?
        public init(style: CitationStyle = .lawReview,
                    signal: Signal? = nil,
                    pincite: String? = nil,
                    parenthetical: String? = nil) {
            self.style = style
            self.signal = signal
            self.pincite = pincite
            self.parenthetical = parenthetical
        }
    }

    public enum FormatError: Error, Equatable {
        case noReporter        // unpublished / no usable reporter citation
        case noYear
    }

    /// Build the citation. Throws when the record can't yield a valid full cite
    /// (no reporter, or no date) so the caller can grey the result out rather
    /// than paste something malformed.
    public static func format(_ record: CaseRecord, options: Options = Options()) throws -> RichText {
        guard let citation = Reporter.primary(from: record.citations),
              let reporterText = Reporter.render(citation, pincite: options.pincite) else {
            throw FormatError.noReporter
        }
        guard let courtYear = Court.parenthetical(courtID: record.courtID, year: record.year) else {
            throw FormatError.noYear
        }

        var out = RichText()

        // Signal (always italic), with a trailing space.
        if let signal = options.signal, !signal.text.isEmpty {
            out.append(signal.text, italic: true)
            out.append(" ")
        }

        // Case name (italic vs roman per style; procedural phrases stay italic).
        out.append(CaseName.render(record.name, style: options.style))

        // ", <vol> <reporter> <page>[, <pincite>] (<court> <year>)"
        out.append(", \(reporterText) \(courtYear)")

        // Optional explanatory parenthetical (roman), then the terminal period:
        // "... (1954) (en banc)."
        if let paren = options.parenthetical?.trimmingCharacters(in: .whitespaces), !paren.isEmpty {
            out.append(" (\(paren))")
        }
        out.append(".")

        return out
    }

    /// One member of a string citation: the fully-formatted cite plus whether it
    /// begins a new citation sentence (i.e. carries a *capitalized* signal). That
    /// flag controls how it joins to the cite before it — see `stringCitation`.
    public struct Member {
        public var rich: RichText
        public var beginsNewSentence: Bool
        public init(_ rich: RichText, beginsNewSentence: Bool = false) {
            self.rich = rich
            self.beginsNewSentence = beginsNewSentence
        }
    }

    /// Join already-formatted single citations into one Bluebook **string citation**.
    /// Members normally chain within a single citation sentence, separated by "; ",
    /// with one terminal period on the whole string. But a member that *begins a new
    /// sentence* (a capitalized signal) ends the preceding cite with a period instead
    /// — so "See A; B" stays one sentence, while a capitalized "But see" on the second
    /// cite yields "See A. But see B." (Bluebook Rule 1.2–1.3).
    ///
    /// Each input is expected to be a complete cite ending in a period (as `format`
    /// produces); that trailing period is dropped before joining so we don't get
    /// "...(1973).; ...". Signals stay inline on their own cite as the caller cased
    /// them — this does not re-case them.
    public static func stringCitation(_ members: [Member]) -> RichText {
        var out = RichText()
        for (i, member) in members.enumerated() {
            if i > 0 { out.append(member.beginsNewSentence ? ". " : "; ") }
            out.append(trimmingTrailingPeriod(member.rich))
        }
        if !out.runs.isEmpty { out.append(".") }
        return out
    }

    /// Convenience overload for callers without per-cite sentence info: joins every
    /// member with "; " (a single citation sentence).
    public static func stringCitation(_ cites: [RichText]) -> RichText {
        stringCitation(cites.map { Member($0) })
    }

    private static func trimmingTrailingPeriod(_ cite: RichText) -> RichText {
        guard let last = cite.runs.last, last.text.hasSuffix(".") else { return cite }
        var runs = cite.runs
        runs[runs.count - 1] = RichText.Run(String(last.text.dropLast()), italic: last.italic)
        return RichText(runs)
    }
}
