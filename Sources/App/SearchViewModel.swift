#if canImport(AppKit)
import Foundation
import BluebookFormat
import CourtListener

/// Drives the search panel: debounced CourtListener queries, result selection,
/// signal + pincite state, and final formatting. Kept separate from the view so
/// the selection/format logic is unit-testable without SwiftUI.
@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [SearchResult] = []
    @Published var selection: Int = 0
    @Published var pincite: String = ""
    /// Explanatory parenthetical for the in-progress cite (e.g. "en banc"), entered in
    /// the → cite-options popover. Baked into the bubble when the cite is added.
    @Published var parenthetical: String = ""
    @Published var signal: Signal? = nil
    @Published var statusMessage: String? = nil
    @Published var showingSignalPicker = false
    /// The → cite-options popover (pincite + parenthetical for the current selection).
    @Published var showingCiteOptions = false
    /// Cites already committed to the string citation, shown as bubbles in the pill.
    /// Empty = single-cite mode (⏎ inserts immediately).
    @Published var pendingCites: [PendingCite] = []
    /// Bumped each time the panel is (re)shown so the view re-focuses the search
    /// field — `.onAppear` only fires once, but the panel is reused across shows.
    @Published var showCount = 0
    /// Law-review style: checked = full case name roman (footnote style); unchecked
    /// = court-document style, where the full caption is italicized. Persisted.
    @Published var lawReviewStyle: Bool = (AppSettings.shared.style == .lawReview) {
        didSet { AppSettings.shared.style = lawReviewStyle ? .lawReview : .courtDocument }
    }

    private let client: SearchClient
    private var searchTask: Task<Void, Never>?
    private let debounce: Duration = .milliseconds(250)

    init(client: SearchClient) {
        self.client = client
    }

    var selectedRecord: CaseRecord? {
        guard results.indices.contains(selection) else { return nil }
        return results[selection].toCaseRecord()
    }

    // MARK: keyboard-driven navigation

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + delta), results.count - 1)
    }

    // MARK: debounced search

    func queryChanged(_ newValue: String) {
        // Ignore no-op re-sets of the same text (e.g. SwiftUI re-pushing the binding
        // when focus leaves the field on Tab). Re-running the search would reset the
        // result selection to 0 and yank the user's pick out from under them.
        guard newValue != query else { return }
        query = newValue
        searchTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            statusMessage = nil   // don't leave a stale "No results"/error pill up
            return
        }
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            if Task.isCancelled { return }
            await self.runSearch(trimmed)
        }
    }

    private func runSearch(_ q: String) async {
        // Show instant results from the bundled SCOTUS index first, then fetch the
        // network and merge. Canonical cases appear with no perceptible latency; the
        // live search still fills in — and can outrank the cache for — better name
        // matches and the lower-court cases the SCOTUS-only index never carries.
        let local = LocalCaseIndex.shared.search(q).filter(\.isCiteable)
        if !local.isEmpty {
            self.results = local
            self.selection = 0
            self.statusMessage = nil
        } else {
            // No cache hit yet, so signal progress while the network request runs.
            self.statusMessage = "Searching…"
        }
        do {
            // Drop results with no parseable reporter citation — they can't yield a
            // Bluebook cite, so they're dead weight in the picker.
            let web = try await client.searchOpinions(q).filter(\.isCiteable)
            if Task.isCancelled { return }
            let merged = Self.mergeRanked(local: local, web: web, query: q)
            // Keep the user's pick under their cursor across the re-rank, if it survives.
            let priorID = results.indices.contains(selection) ? Self.identity(results[selection]) : nil
            self.results = merged
            self.selection = priorID.flatMap { id in merged.firstIndex { Self.identity($0) == id } } ?? 0
            self.statusMessage = merged.isEmpty ? "No results" : nil
        } catch {
            // A cancelled in-flight request (the user kept typing) surfaces as a
            // transport error — that's not an outage, so bail quietly.
            if Task.isCancelled { return }
            // A failed network fetch must not wipe results already shown from the
            // cache — only surface the error when there's nothing else on screen.
            guard local.isEmpty else { return }
            self.statusMessage = Self.message(for: error)
        }
    }

    // MARK: local + network merge

    /// Stable identity for de-duping a case that appears in both the local index and
    /// the live results: its official cite if we can render one, else the cased name.
    nonisolated private static func identity(_ r: SearchResult) -> String {
        r.preferredCitationText ?? (r.caseName ?? "").lowercased()
    }

    /// Merge cache + web hits into one de-duplicated, relevance-ranked list. Cache
    /// entries are listed first so that, all else equal, the offline canonical case
    /// wins; but a web result whose name matches the query better (exact/prefix/whole-
    /// word, or with fewer extraneous words) is allowed to rank above the cache.
    nonisolated static func mergeRanked(local: [SearchResult], web: [SearchResult], query: String) -> [SearchResult] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let tokens = q.split(separator: " ").map(String.init)
        var seen = Set<String>()
        let combined = (local + web).filter { seen.insert(identity($0)).inserted }
        return combined.enumerated()
            .map { offset, r in (r, score(r, tokens: tokens, query: q), offset) }
            .sorted { a, b in
                if a.1.tier != b.1.tier { return a.1.tier > b.1.tier }             // relevance tier
                if a.1.specificity != b.1.specificity { return a.1.specificity > b.1.specificity }
                return a.2 < b.2                                                    // stable: cache before web
            }
            .map(\.0)
    }

    /// Name-match relevance: a coarse tier (exact > prefix > all-tokens-as-words >
    /// all-tokens-substring > none) plus a specificity ratio (matched words / total),
    /// so a tight match like "Roe v. Wade" outranks a sprawling caption that merely
    /// contains the same tokens.
    nonisolated private static func score(_ r: SearchResult, tokens: [String], query q: String) -> (tier: Int, specificity: Double) {
        let name = (r.caseName ?? "").lowercased()
        let words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let wordSet = Set(words)
        let matched = tokens.filter(wordSet.contains).count
        let specificity = words.isEmpty ? 0 : Double(matched) / Double(words.count)
        let tier: Int
        if name == q { tier = 4 }
        else if name.hasPrefix(q) { tier = 3 }
        else if !tokens.isEmpty && tokens.allSatisfy(wordSet.contains) { tier = 2 }
        else if !tokens.isEmpty && tokens.allSatisfy(name.contains) { tier = 1 }
        else { tier = 0 }
        return (tier, specificity)
    }

    /// Maps a `SearchClient` error onto the short phrase the panel shows when a network
    /// search fails with nothing cached to fall back on.
    private static func message(for error: Error) -> String {
        switch error {
        case SearchClient.ClientError.http(let code):
            return code == 429 ? "Rate limited — try again shortly" : "Server error (\(code))"
        case SearchClient.ClientError.timedOut:
            return "CourtListener is slow — try again"
        case SearchClient.ClientError.transport:
            return "Offline — check your connection"
        default:
            return "Search failed"
        }
    }

    // MARK: multi-cite (string citation) assembly

    /// Format the current selection (with its signal/pincite/parenthetical) and push it
    /// onto the string citation as a bubble, then reset for the next cite. Returns false
    /// — leaving everything in place — if the selection can't be formatted (the failure
    /// is surfaced via `statusMessage`).
    @discardableResult
    func addCurrentCite() -> Bool {
        guard let rich = formatSelected() else { return false }
        let label = selectedRecord?.name ?? "cite"
        // Capture the signal onto the bubble so it stays visible after the chip clears.
        let signalText = (signal?.text).flatMap { $0.isEmpty ? nil : $0 }
        // A capitalized signal starts a new citation sentence: the preceding cite then
        // ends in a period rather than a semicolon when the string is finalized.
        let beginsNewSentence = signal?.isCapitalized ?? false
        pendingCites.append(PendingCite(label: label, signalText: signalText,
                                        beginsNewSentence: beginsNewSentence, rich: rich))
        resetCurrentCite()
        return true
    }

    /// Join the accumulated cites into one Bluebook string citation and clear the list.
    /// Nil when nothing has been added yet.
    func finalizeCitation() -> RichText? {
        guard !pendingCites.isEmpty else { return nil }
        let rich = CaseCitation.stringCitation(pendingCites.map {
            CaseCitation.Member($0.rich, beginsNewSentence: $0.beginsNewSentence)
        })
        pendingCites = []
        return rich
    }

    func removeCite(_ id: PendingCite.ID) {
        pendingCites.removeAll { $0.id == id }
    }

    /// Clear the in-progress query/selection/options so the next cite starts fresh.
    /// Leaves `pendingCites` intact.
    private func resetCurrentCite() {
        searchTask?.cancel()
        query = ""
        results = []
        selection = 0
        signal = nil
        pincite = ""
        parenthetical = ""
        statusMessage = nil
        showingCiteOptions = false
    }

    // MARK: formatting

    /// Format the selected result, or nil if it can't yield a valid full cite
    /// (sets `statusMessage` so the panel can grey/explain).
    func formatSelected() -> RichText? {
        guard let record = selectedRecord else { return nil }
        let opts = CaseCitation.Options(
            style: AppSettings.shared.style,
            signal: signal,
            pincite: pincite.isEmpty ? nil : pincite,
            parenthetical: parenthetical.isEmpty ? nil : parenthetical
        )
        do {
            return try CaseCitation.format(record, options: opts)
        } catch CaseCitation.FormatError.noReporter {
            statusMessage = "No reporter citation (unpublished?) — can't format"
            return nil
        } catch {
            statusMessage = "Missing date — can't format"
            return nil
        }
    }
}

/// One committed cite in a string citation: its display label (the case name, shown in
/// the bubble) and the fully-formatted `RichText` that gets joined at insert time.
struct PendingCite: Identifiable {
    let id = UUID()
    let label: String
    /// The signal applied to this cite (if any), shown italic in the bubble so the
    /// signal stays visible after its blue chip clears on commit.
    let signalText: String?
    /// True when this cite's signal is capitalized (sentence-initial) — it begins a
    /// new citation sentence, ending the preceding cite with a period not a semicolon.
    let beginsNewSentence: Bool
    let rich: RichText
}
#endif
