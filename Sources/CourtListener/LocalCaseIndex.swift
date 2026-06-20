import Foundation

/// In-memory search over the bundled top-by-citation SCOTUS index
/// (`Resources/scotus-index.json`, built by `Tools/build-scotus-index.py`).
///
/// The file is a JSON array of `SearchResult` — the same Codable type the network
/// path returns — pre-sorted most-cited-first. So a hit here is a drop-in substitute
/// for a live search: it flows through the identical `isCiteable` → `CaseRecord` →
/// formatter pipeline. This makes the canonical, frequently-cited cases resolve
/// instantly and offline; the long tail still falls through to CourtListener.
///
/// Loading is lazy and one-shot (the index is a few thousand small records), so the
/// cost is paid on the first query, not at launch.
///
/// This lives in the platform-neutral `CourtListener` library (not the macOS app
/// target) so any front-end — the macOS agent today, a Windows port tomorrow — gets
/// the offline index for free. See `docs/porting-to-windows.md`.
public struct LocalCaseIndex {
    private let records: [SearchResult]
    /// Lowercased case name alongside its record, computed once, so matching a query
    /// is a cheap substring scan rather than re-lowercasing on every keystroke.
    private let haystack: [(name: String, record: SearchResult)]

    /// The shared index loaded from the library's resource bundle. Empty if the
    /// resource is missing or unreadable — the caller then simply gets no local hits
    /// and uses the network.
    public static let shared = LocalCaseIndex(bundleResource: "scotus-index")

    public init(records: [SearchResult]) {
        self.records = records
        self.haystack = records.map { ($0.caseName?.lowercased() ?? "", $0) }
    }

    public init(bundleResource name: String) {
        // The index ships as a resource of this package target, so it resolves through
        // `Bundle.module` in both build flavors: a plain `swift build`/`swift test`,
        // and the native Xcode app target, which consumes CourtListener as a SwiftPM
        // package product and embeds its generated resource bundle automatically.
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SearchResult].self, from: data) else {
            self.init(records: [])
            return
        }
        self.init(records: decoded)
    }

    public var isEmpty: Bool { records.isEmpty }

    /// Citeable local matches for `query`, ranked most-cited-first (the file's order is
    /// preserved by the stable scan). A match requires every whitespace-separated query
    /// token to appear in the case name, so "roe wade" and "wade roe" both find
    /// *Roe v. Wade* without depending on word order or the "v."
    ///
    /// Returns at most `limit` results; an empty array means "not covered locally —
    /// go to the network."
    public func search(_ query: String, limit: Int = 25) -> [SearchResult] {
        let tokens = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        var hits: [SearchResult] = []
        for (name, record) in haystack where tokens.allSatisfy(name.contains) {
            hits.append(record)
            if hits.count >= limit { break }
        }
        return hits
    }
}
