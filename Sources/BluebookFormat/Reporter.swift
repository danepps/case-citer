import Foundation

/// Reporter selection (Bluebook Table T1). CourtListener already stores reporter
/// abbreviations in near-Bluebook form (`U.S.`, `F.3d`, `S. Ct.`), so this module
/// mostly *chooses* among parallel cites rather than reformatting them.
public enum Reporter {

    /// The single citation to print, honoring Bluebook Rule 10.3.1's style split:
    /// federal cites are preferred regardless of style, but among *state* parallel
    /// cites a law-review citation prefers the **regional** reporter (`N.E.2d`)
    /// while a court document prefers the state's **own official** reporter (`Mass.`).
    /// Falls back to whatever's available when the preferred kind is absent.
    public static func primary(from citations: [ReporterCitation],
                               style: CitationStyle) -> ReporterCitation? {
        citations.min { rank($0.kind, style) < rank($1.kind, style) }
    }

    /// Precedence rank (lower = preferred) for a reporter kind under a given style.
    /// Only `regional` vs. `stateOfficial` depends on the style.
    private static func rank(_ kind: ReporterCitation.Kind, _ style: CitationStyle) -> Int {
        switch kind {
        case .federalOfficial: return 0
        case .federal:         return 1
        case .regional:        return style == .lawReview ? 2 : 3
        case .stateOfficial:   return style == .lawReview ? 3 : 2
        case .unknown:         return 4
        }
    }

    /// Render "<vol> <reporter> <page>[, <pincite>]" as roman text. Returns nil
    /// when volume/reporter/page aren't all present (caller falls back to the
    /// docket-number form or greys the result out).
    public static func render(_ c: ReporterCitation, pincite: String?) -> String? {
        let vol = c.volume.trimmingCharacters(in: .whitespaces)
        let rep = c.reporter.trimmingCharacters(in: .whitespaces)
        let page = c.page.trimmingCharacters(in: .whitespaces)
        guard !vol.isEmpty, !rep.isEmpty, !page.isEmpty else { return nil }
        var out = "\(vol) \(rep) \(page)"
        if let p = pincite?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            out += ", \(p)"
        }
        return out
    }
}
