import Foundation

/// Citation-style mode. Bluebook italicizes the *full* case name in court
/// documents and briefs, but **not** in law-review footnote citations (there the
/// full name is roman; only short forms, procedural phrases, and textual
/// references are italicized). This flag drives that difference.
public enum CitationStyle: Equatable {
    case lawReview       // full case name roman  (default)
    case courtDocument   // full case name italic

    public var italicizeFullName: Bool { self == .courtDocument }
}

/// A reporter citation (one of possibly several parallel cites for a case).
public struct ReporterCitation: Equatable {
    /// Reporter category, used to pick which parallel cite to print. Federal
    /// reporters always win and carry no law-review/court-document distinction;
    /// the two *state* categories (`regional` vs. `stateOfficial`) swap precedence
    /// by `CitationStyle` per Bluebook Rule 10.3.1 — see `Reporter.primary`.
    public enum Kind: Int, Equatable, Comparable {
        case federalOfficial = 0  // U.S. Reports — the official SCOTUS reporter, top precedence
        case federal = 1          // other federal reporters (S. Ct., L. Ed., F.2d/3d/4th, F. Supp.)
        case regional = 2         // West regional reporters (A./N.E./N.W./P./S.E./S.W./So.)
        case stateOfficial = 3    // a state's own official reporter (Mass., N.Y., Ill.)
        case unknown = 4
        public static func < (l: Kind, r: Kind) -> Bool { l.rawValue < r.rawValue }
    }

    public var volume: String
    public var reporter: String   // already near-Bluebook from CL, e.g. "U.S.", "F.3d"
    public var page: String
    public var kind: Kind

    public init(volume: String, reporter: String, page: String, kind: Kind = .unknown) {
        self.volume = volume
        self.reporter = reporter
        self.page = page
        self.kind = kind
    }
}

/// Source-agnostic case input the formatter consumes. The `CourtListener` module
/// maps CL's JSON onto this; the formatter never sees the wire format.
public struct CaseRecord: Equatable {
    public var name: String                 // raw, e.g. "Obergefell v. Hodges"
    public var citations: [ReporterCitation]
    public var courtID: String?             // CL stable id, e.g. "scotus", "ca9"
    /// Ready-made Bluebook court abbreviation when the source supplies one (CL's
    /// `court_citation_string`, e.g. "Mass.", "N.D. Iowa"). Preferred over the
    /// static `courtID` table since it covers state and district courts too.
    public var courtString: String?
    public var year: Int?
    public var docketNumber: String?

    public init(name: String,
                citations: [ReporterCitation],
                courtID: String? = nil,
                courtString: String? = nil,
                year: Int? = nil,
                docketNumber: String? = nil) {
        self.name = name
        self.citations = citations
        self.courtID = courtID
        self.courtString = courtString
        self.year = year
        self.docketNumber = docketNumber
    }

    /// Preferred reporter to print, law-review style by default (regional over a
    /// state's own official reporter). Style-sensitive selection lives in
    /// `Reporter.primary(from:style:)`.
    public var preferredCitation: ReporterCitation? {
        Reporter.primary(from: citations, style: .lawReview)
    }
}
