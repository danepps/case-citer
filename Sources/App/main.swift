#if canImport(AppKit)
import AppKit
import CourtListener

// Headless diagnostic: `case-citer --query "roe wade"` prints the bundled SCOTUS
// index's matches; add `--web` to also fetch CourtListener and print the merged,
// relevance-ranked list exactly as the panel would show it. Validates the search
// path without driving the GUI. See Tools/build-scotus-index.py.
if let qi = CommandLine.arguments.firstIndex(of: "--query"), qi + 1 < CommandLine.arguments.count {
    let query = CommandLine.arguments[qi + 1]
    let index = LocalCaseIndex.shared
    let local = index.search(query, limit: 25).filter(\.isCiteable)
    func dump(_ label: String, _ rs: [SearchResult]) {
        print("\(label): \(rs.count) hit(s) for \(query.debugDescription)")
        for r in rs.prefix(10) {
            print("  \(r.caseName ?? "—") — \(r.preferredCitationText ?? "?") (\(r.year.map(String.init) ?? "?"))")
        }
    }
    if CommandLine.arguments.contains("--web") {
        let sem = DispatchSemaphore(value: 0)
        Task {
            let client = SearchClient(apiKey: AppSettings.shared.effectiveAPIKey)
            let web = ((try? await client.searchOpinions(query)) ?? []).filter(\.isCiteable)
            dump("local index (\(index.isEmpty ? "EMPTY" : "loaded"))", local)
            dump("web", web)
            dump("MERGED", SearchViewModel.mergeRanked(local: local, web: web, query: query))
            sem.signal()
        }
        sem.wait()
    } else {
        dump("local index (\(index.isEmpty ? "EMPTY" : "loaded"))", local)
    }
    exit(0)
}

// SPM executable entry point. We drive NSApplication directly (rather than @main
// SwiftUI App) so the agent can run headless with a floating panel and no main
// window. LSUIElement is also declared in the bundle Info.plist (see README).
// main.swift top-level code runs on the main thread at process start, so it is
// safe to assume MainActor isolation for the AppDelegate and NSApplication setup.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
#else
// Non-macOS toolchains (e.g. CI on Linux) can still build/test the pure
// BluebookFormat library; the agent app itself is macOS-only.
print("Case Citer is a macOS app; build on macOS.")
#endif
