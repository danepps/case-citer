import Foundation
import BluebookFormat

/// CourtListener v4 search API wire models (`/api/rest/v4/search/?type=o`).
/// Only the fields we consume are modeled; unknown keys are ignored.
public struct SearchResponse: Decodable {
    public let count: Int?
    public let results: [SearchResult]
}

public struct SearchResult: Codable {
    public let caseName: String?
    public let court: String?
    public let courtId: String?
    public let courtCitationString: String?  // CL's ready-made Bluebook court abbr, e.g. "Mass.", "N.D. Iowa", "SCOTUS"
    public let dateFiled: String?      // "2015-06-26"
    public let docketNumber: String?
    public let citation: [String]?     // e.g. ["576 U.S. 644", "135 S. Ct. 2584"]

    enum CodingKeys: String, CodingKey {
        case caseName, court, dateFiled, docketNumber, citation
        case courtId = "court_id"
        case courtCitationString = "court_citation_string"
    }

    /// Decision year parsed from `dateFiled` (the leading four digits).
    public var year: Int? {
        guard let d = dateFiled, d.count >= 4 else { return nil }
        return Int(d.prefix(4))
    }

    /// True if this result carries at least one parseable reporter citation. A
    /// result without one can't yield a Bluebook cite, so it's noise in a citation
    /// tool and gets filtered from the result list.
    public var isCiteable: Bool {
        !(citation ?? []).compactMap(CitationParser.parse).isEmpty
    }

    /// The citation the formatter will actually print (official reporter preferred),
    /// so the result row matches what gets pasted — not CourtListener's arbitrary
    /// first parallel cite.
    public var preferredCitationText: String? {
        // Display/identity preview only — uses the law-review preference; the actual
        // paste re-selects per the user's chosen style in `CaseCitation.format`.
        Reporter.primary(from: toCaseRecord().citations, style: .lawReview)
            .flatMap { Reporter.render($0, pincite: nil) }
    }

    /// Map this CL result onto the formatter's source-agnostic `CaseRecord`.
    public func toCaseRecord() -> CaseRecord {
        let cites = (citation ?? []).compactMap(CitationParser.parse)
        return CaseRecord(
            name: caseName ?? "",
            citations: cites,
            courtID: courtId,
            courtString: courtCitationString,
            year: year,
            docketNumber: docketNumber
        )
    }
}

/// Parses CourtListener's flat citation strings ("576 U.S. 644") into the
/// structured `ReporterCitation` the formatter wants, inferring a rough Bluebook
/// `Kind` from the reporter token so the formatter can prefer the official cite.
public enum CitationParser {

    /// The official U.S. Supreme Court reporter — top precedence in either style.
    static let federalOfficialReporters: Set<String> = ["U.S.", "U.S. App.", "F. Cas."]

    /// Other federal reporters: preferred over any state cite, no style distinction.
    static let federalReporters: Set<String> = [
        "S. Ct.", "L. Ed.", "L. Ed. 2d", "U.S.L.W.",
        "F.", "F.2d", "F.3d", "F.4th",
        "F. Supp.", "F. Supp. 2d", "F. Supp. 3d",
        "F.R.D.", "Fed. Cl.", "Fed. Appx.", "F. App\u{2019}x", "B.R.", "U.S. App. D.C.",
    ]

    /// West's regional reporters (multistate) — the law-review-preferred state cite
    /// (Rule 10.3.1). Anything not federal or regional is treated as a state's own
    /// official reporter.
    static let regionalReporters: Set<String> = [
        "A.", "A.2d", "A.3d",
        "N.E.", "N.E.2d", "N.E.3d",
        "N.W.", "N.W.2d", "N.W.3d",
        "P.", "P.2d", "P.3d",
        "S.E.", "S.E.2d",
        "S.W.", "S.W.2d", "S.W.3d",
        "So.", "So.2d", "So.3d",
    ]

    /// Classify a reporter abbreviation into a Bluebook precedence `Kind`.
    static func kind(for reporter: String) -> ReporterCitation.Kind {
        if federalOfficialReporters.contains(reporter) { return .federalOfficial }
        if federalReporters.contains(reporter) { return .federal }
        if regionalReporters.contains(reporter) { return .regional }
        return .stateOfficial
    }

    public static func parse(_ s: String) -> ReporterCitation? {
        // "<volume> <reporter...> <page>" — reporter may contain spaces ("S. Ct.").
        // Volume is the leading integer; page is the trailing integer; reporter is
        // everything between.
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ").map(String.init)
        guard parts.count >= 3,
              Int(parts.first!) != nil,
              Int(parts.last!) != nil else {
            return nil
        }
        let volume = parts.first!
        let page = parts.last!
        let reporter = parts[1..<(parts.count - 1)].joined(separator: " ")
        return ReporterCitation(volume: volume, reporter: reporter, page: page,
                                kind: kind(for: reporter))
    }
}
