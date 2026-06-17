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
    @Published var signal: Signal? = nil
    @Published var statusMessage: String? = nil
    @Published var showingSignalPicker = false
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
        // Clear any stale error from a prior attempt and show progress, so a slow
        // first request doesn't leave "Offline" lingering on screen.
        self.statusMessage = "Searching…"
        do {
            // Drop results with no parseable reporter citation — they can't yield a
            // Bluebook cite, so they're dead weight in the picker.
            let hits = try await client.searchOpinions(q).filter(\.isCiteable)
            if Task.isCancelled { return }
            self.results = hits
            self.selection = 0
            self.statusMessage = hits.isEmpty ? "No results" : nil
        } catch let SearchClient.ClientError.http(code) {
            self.statusMessage = code == 429 ? "Rate limited — try again shortly" : "Server error (\(code))"
        } catch SearchClient.ClientError.timedOut {
            self.statusMessage = "CourtListener is slow — try again"
        } catch SearchClient.ClientError.transport {
            // A cancelled in-flight request (the user kept typing) surfaces here as a
            // transport error — that's not an outage, so don't cry "Offline".
            if Task.isCancelled { return }
            self.statusMessage = "Offline — check your connection"
        } catch {
            self.statusMessage = "Search failed"
        }
    }

    // MARK: formatting

    /// Format the selected result, or nil if it can't yield a valid full cite
    /// (sets `statusMessage` so the panel can grey/explain).
    func formatSelected() -> RichText? {
        guard let record = selectedRecord else { return nil }
        let opts = CaseCitation.Options(
            style: AppSettings.shared.style,
            signal: signal,
            pincite: pincite.isEmpty ? nil : pincite
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
#endif
