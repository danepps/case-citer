import Foundation
import CourtListener

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
struct LocalCaseIndex {
    private let records: [SearchResult]
    /// Lowercased case name alongside its record, computed once, so matching a query
    /// is a cheap substring scan rather than re-lowercasing on every keystroke.
    private let haystack: [(name: String, record: SearchResult)]

    /// The shared index loaded from the app bundle. Empty if the resource is missing
    /// or unreadable — the caller then simply gets no local hits and uses the network.
    static let shared = LocalCaseIndex(bundleResource: "scotus-index")

    init(records: [SearchResult]) {
        self.records = records
        self.haystack = records.map { ($0.caseName?.lowercased() ?? "", $0) }
    }

    init(bundleResource name: String) {
        // The index ships as a resource in two build flavors: SwiftPM (`swift run`,
        // tests) puts it in the generated module bundle (`Bundle.module`); the native
        // Xcode app target copies it into the app's own Resources (`Bundle.main`).
        // SWIFT_PACKAGE is defined only by SwiftPM, so this picks the right one — and
        // never references `Bundle.module` (an SPM-only symbol) in the Xcode build.
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SearchResult].self, from: data) else {
            self.init(records: [])
            return
        }
        self.init(records: decoded)
    }

    var isEmpty: Bool { records.isEmpty }

    /// Citeable local matches for `query`, ranked most-cited-first (the file's order is
    /// preserved by the stable scan). A match requires every whitespace-separated query
    /// token to appear in the case name, so "roe wade" and "wade roe" both find
    /// *Roe v. Wade* without depending on word order or the "v."
    ///
    /// Returns at most `limit` results; an empty array means "not covered locally —
    /// go to the network."
    func search(_ query: String, limit: Int = 25) -> [SearchResult] {
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
