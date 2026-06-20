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
    /// Short-form toggle for the in-progress cite (⌃F). Full form is the default.
    @Published var shortForm: Bool = false
    /// Editable short-form title override for the in-progress cite; empty derives it
    /// from the selected case name. Shown in the → popover when `shortForm` is on.
    @Published var shortTitle: String = ""
    @Published var signal: Signal? = nil
    @Published var statusMessage: String? = nil
    @Published var showingSignalPicker = false
    /// Highlighted row in the signal picker. Driven from the search field's key handlers
    /// (↑/↓/⏎) rather than the picker stealing focus — focus transfer is unreliable on
    /// the nonactivating panel, which left the picker impossible to navigate or dismiss.
    @Published var signalSelection = 0
    /// The → cite-options popover (pincite + parenthetical for the current selection).
    @Published var showingCiteOptions = false
    /// Cites already committed to the string citation, shown as bubbles in the pill.
    /// Empty = single-cite mode (⏎ inserts immediately).
    @Published var pendingCites: [PendingCite] = []
    /// Where keyboard focus sits among the committed cite bubbles, walked with ◀/▶ on an
    /// empty query: `.none` is the text field; `.selected(i)` highlights a bubble (▼ opens
    /// its pincite/parenthetical editor); `.ahead(i)` is the caret in front of a bubble
    /// (⌃S attaches a signal there). ◀ steps text-field → selected(last) → ahead(last) →
    /// selected(last-1) → … ; ▶ reverses it.
    @Published var citeFocus: CiteFocus = .none
    /// When set, the cite-options popover is editing this committed cite (vs. nil =
    /// entering options for the in-progress cite being appended).
    @Published var editingCiteIndex: Int? = nil

    /// Index of the bubble currently under the cite cursor (selected or ahead), if any.
    var focusedCiteIndex: Int? {
        switch citeFocus {
        case .none: return nil
        case .selected(let i), .ahead(let i): return i
        }
    }
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
        citeFocus = .none   // typing returns the cursor to the text field
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
        // The bundled SCOTUS index is ordered by citation count (built `citeCount desc`),
        // so a record's position in `local` is its cite rank — lower is more-cited. Cases
        // not in the index (lower courts, the SCOTUS long tail) get Int.max and fall
        // through to the specificity/offset tiebreaks below.
        var citeRank: [String: Int] = [:]
        for (i, r) in local.enumerated() { citeRank[identity(r)] = i }
        return combined.enumerated()
            .map { offset, r in (r, score(r, tokens: tokens, query: q), courtProminence(r),
                                 citeRank[identity(r)] ?? .max, offset) }
            .sorted { a, b in
                if a.1.tier != b.1.tier { return a.1.tier > b.1.tier }             // relevance tier
                if a.2 != b.2 { return a.2 > b.2 }                                  // court prominence
                if a.3 != b.3 { return a.3 < b.3 }                                  // citation count (SCOTUS index)
                if a.1.specificity != b.1.specificity { return a.1.specificity > b.1.specificity }
                return a.4 < b.4                                                    // stable: cache before web
            }
            .map(\.0)
    }

    /// How prominent the deciding court is, used to break ties between results that
    /// match the query equally well by name. Without it a bare surname query ("bivens")
    /// makes *every* hit a prefix match, so the next tiebreak — specificity (matched
    /// words ÷ total) — rewards the *shortest* caption and buries landmark cases with
    /// long captions (e.g. *Bivens v. Six Unknown Named Agents …*, 403 U.S. 388) under
    /// obscure state cases. Ranking SCOTUS, then the federal courts of appeals, above
    /// everything else surfaces the case the user almost certainly means.
    nonisolated private static func courtProminence(_ r: SearchResult) -> Int {
        guard let id = r.courtId else { return 0 }
        if id == "scotus" { return 3 }
        // The T7 table holds exactly the federal courts of appeals (non-empty
        // abbreviation); reuse it so state ids like "cal" aren't caught by a "ca" prefix.
        if let abbr = Court.abbreviation(for: id), !abbr.isEmpty { return 2 }
        return 1
    }

    /// Name-match relevance: a coarse tier (exact > party-prefix > all-tokens-as-words >
    /// all-tokens-substring > none) plus a specificity ratio (matched words / total),
    /// so a tight match like "Roe v. Wade" outranks a sprawling caption that merely
    /// contains the same tokens.
    ///
    /// "Party-prefix" means the query begins one of the parties (either side of "v."),
    /// not just the whole caption. Landmark cases routinely put the person second —
    /// *Tennessee v. Garner*, *United States v. Nixon* — so a surname query must match the
    /// respondent as strongly as it would a petitioner; otherwise a `Garner v. …` lower-
    /// court case (a whole-caption prefix) buries the SCOTUS case the user means. With
    /// both at this tier, the SCOTUS court-prominence tiebreak surfaces the right one.
    nonisolated private static func score(_ r: SearchResult, tokens: [String], query q: String) -> (tier: Int, specificity: Double) {
        let name = (r.caseName ?? "").lowercased()
        let words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let wordSet = Set(words)
        let matched = tokens.filter(wordSet.contains).count
        let specificity = words.isEmpty ? 0 : Double(matched) / Double(words.count)
        // Each party as it appears in the caption (trimmed), e.g. ["tennessee", "garner"].
        let parties = name.components(separatedBy: " v. ").map { $0.trimmingCharacters(in: .whitespaces) }
        let tier: Int
        if name == q { tier = 4 }
        else if name.hasPrefix(q) || parties.contains(where: { $0.hasPrefix(q) }) { tier = 3 }
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
        guard let record = selectedRecord, let rich = formatSelected() else { return false }
        // Retain the signal and the formatting inputs so the cite can be re-formatted
        // later if its signal/pincite/parenthetical are edited (they're baked into `rich`).
        let form: CaseCitation.CitationForm = shortForm ? .short : .full
        let override = shortTitle.isEmpty ? nil : shortTitle
        pendingCites.append(PendingCite(label: Self.bubbleLabel(form: form, shortTitle: override, record: record),
                                        signal: signal, rich: rich,
                                        record: record,
                                        pincite: pincite.isEmpty ? nil : pincite,
                                        parenthetical: parenthetical.isEmpty ? nil : parenthetical,
                                        form: form,
                                        shortTitle: override))
        resetCurrentCite()
        return true
    }

    /// The case name shown in a cite's bubble: the derived/overridden short title in
    /// short form, otherwise the full case name.
    private static func bubbleLabel(form: CaseCitation.CitationForm, shortTitle: String?, record: CaseRecord) -> String {
        guard form == .short else { return record.name }
        let t = shortTitle?.trimmingCharacters(in: .whitespaces)
        return (t?.isEmpty == false) ? t! : CaseName.shortTitle(record.name)
    }

    /// ⌃F: toggle short form. On the cursor-focused committed cite if there is one
    /// (re-formatting it), otherwise on the in-progress cite — prefilling the editable
    /// short-title with the derived guess so the → popover can correct it.
    func toggleShortForm() {
        if let index = focusedCiteIndex, pendingCites.indices.contains(index) {
            var cite = pendingCites[index]
            cite.form = (cite.form == .short) ? .full : .short
            cite.label = Self.bubbleLabel(form: cite.form, shortTitle: cite.shortTitle, record: cite.record)
            if let rich = reformat(cite) { cite.rich = rich; pendingCites[index] = cite }
            return
        }
        shortForm.toggle()
        if shortForm, shortTitle.isEmpty, let record = selectedRecord {
            shortTitle = CaseName.shortTitle(record.name)
        }
    }

    /// ⌃F from inside the cite-options popover: flip the scratch `shortForm` the popover
    /// edits (applied on commit), prefilling the derived short title. Unlike
    /// `toggleShortForm`, this never reformats a committed cite directly — when the popover
    /// is editing one, the change is staged in the scratch fields and written back by
    /// `applyCiteOptions` on ⏎. The short-title source is the cite being edited if there is
    /// one, otherwise the current selection.
    func toggleShortFormInCiteOptions() {
        shortForm.toggle()
        guard shortForm, shortTitle.isEmpty else { return }
        let name = editingCiteIndex
            .flatMap { pendingCites.indices.contains($0) ? pendingCites[$0].record.name : nil }
            ?? selectedRecord?.name
        if let name { shortTitle = CaseName.shortTitle(name) }
    }

    // MARK: cite cursor (edit an already-committed cite)

    /// Whether the signal picker should lead with lowercase (continuation) signals:
    /// true for any cite after the first — whether that's the cursor-focused committed
    /// cite or the in-progress one being appended.
    var signalPickerLowercaseFirst: Bool {
        (focusedCiteIndex ?? pendingCites.count) > 0
    }

    /// The signals shown in the picker, in display order (see `signalPickerLowercaseFirst`).
    /// Single source of truth for both the picker view and the field's key handlers.
    var signalChoices: [Signal] {
        if signalPickerLowercaseFirst {
            let base = Signal.continuationOrder
            return base + base.map(\.capitalized)
        }
        return Signal.firstCiteLeading + Signal.continuationOrder
    }

    /// Open the signal picker with a fresh selection.
    func openSignalPicker() {
        signalSelection = 0
        showingSignalPicker = true
    }

    func closeSignalPicker() {
        showingSignalPicker = false
    }

    func moveSignalSelection(by delta: Int) {
        let count = signalChoices.count
        guard count > 0 else { return }
        signalSelection = min(max(0, signalSelection + delta), count - 1)
    }

    /// Apply the highlighted signal to the cursor-focused committed cite, or the
    /// in-progress cite if none is focused, then close the picker.
    func chooseHighlightedSignal() {
        let choices = signalChoices
        guard choices.indices.contains(signalSelection) else { closeSignalPicker(); return }
        let chosen = choices[signalSelection]
        if focusedCiteIndex != nil {
            applySignalToFocusedCite(chosen)
        } else {
            signal = chosen
        }
        closeSignalPicker()
    }

    /// ◀ on an empty query: text field → select last bubble → in front of it → select the
    /// previous bubble → … (stops at the front of the first cite).
    func moveCiteCursorLeft() {
        guard !pendingCites.isEmpty else { return }
        switch citeFocus {
        case .none:               citeFocus = .selected(pendingCites.count - 1)
        case .selected(let i):    citeFocus = .ahead(i)
        case .ahead(let i):       if i > 0 { citeFocus = .selected(i - 1) }
        }
    }

    /// ▶: the reverse of ◀; stepping right past the last bubble returns to the text field.
    func moveCiteCursorRight() {
        switch citeFocus {
        case .none:               break
        case .ahead(let i):       citeFocus = .selected(i)
        case .selected(let i):    citeFocus = (i + 1 >= pendingCites.count) ? .none : .ahead(i + 1)
        }
    }

    /// ▼ on a selected cite: load its pincite/parenthetical into the editor and open the
    /// options popover bound to that committed cite.
    func beginEditingCiteOptions(at index: Int) {
        guard pendingCites.indices.contains(index) else { return }
        let cite = pendingCites[index]
        pincite = cite.pincite ?? ""
        parenthetical = cite.parenthetical ?? ""
        shortForm = (cite.form == .short)
        shortTitle = cite.shortTitle ?? (shortForm ? CaseName.shortTitle(cite.record.name) : "")
        editingCiteIndex = index
        showingCiteOptions = true
    }

    /// Commit the editor's pincite/parenthetical back onto the cite being edited.
    func applyCiteOptions(toCiteAt index: Int) {
        guard pendingCites.indices.contains(index) else { return }
        var cite = pendingCites[index]
        cite.pincite = pincite.isEmpty ? nil : pincite
        cite.parenthetical = parenthetical.isEmpty ? nil : parenthetical
        cite.form = shortForm ? .short : .full
        cite.shortTitle = shortTitle.isEmpty ? nil : shortTitle
        cite.label = Self.bubbleLabel(form: cite.form, shortTitle: cite.shortTitle, record: cite.record)
        if let rich = reformat(cite) { cite.rich = rich; pendingCites[index] = cite }
    }

    /// The pincite/parenthetical/short-form fields are shared scratch state for *both*
    /// the in-progress cite and the committed-cite editor. Editing a committed cite loads
    /// its values into them (see `beginEditingCiteOptions`); call this when the edit ends
    /// so those values don't leak into — and silently duplicate themselves onto — the next
    /// new cite the user starts.
    func endCiteOptionsEditing() {
        pincite = ""
        parenthetical = ""
        shortForm = false
        shortTitle = ""
        editingCiteIndex = nil
        showingCiteOptions = false
    }

    /// Re-format the cursor-focused cite with `signal` (or clear it), updating its bubble
    /// text and the formatted `rich` joined at insert time.
    func applySignalToFocusedCite(_ signal: Signal?) {
        guard let index = focusedCiteIndex, pendingCites.indices.contains(index) else { return }
        var cite = pendingCites[index]
        cite.signal = signal
        if let rich = reformat(cite) { cite.rich = rich; pendingCites[index] = cite }
    }

    /// Re-run the formatter for a committed cite from its retained inputs.
    private func reformat(_ cite: PendingCite) -> RichText? {
        let opts = CaseCitation.Options(
            style: AppSettings.shared.style,
            signal: cite.signal,
            pincite: cite.pincite,
            parenthetical: cite.parenthetical,
            form: cite.form,
            shortTitle: cite.shortTitle
        )
        return try? CaseCitation.format(cite.record, options: opts)
    }

    /// Join the accumulated cites into one Bluebook string citation and clear the list.
    /// Nil when nothing has been added yet.
    func finalizeCitation() -> RichText? {
        guard !pendingCites.isEmpty else { return nil }
        let rich = CaseCitation.stringCitation(pendingCites.map {
            CaseCitation.Member($0.rich, beginsNewSentence: $0.beginsNewSentence)
        })
        pendingCites = []
        citeFocus = .none
        return rich
    }

    func removeCite(_ id: PendingCite.ID) {
        pendingCites.removeAll { $0.id == id }
        citeFocus = .none
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
        shortForm = false
        shortTitle = ""
        statusMessage = nil
        showingCiteOptions = false
        editingCiteIndex = nil
        citeFocus = .none
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
            parenthetical: parenthetical.isEmpty ? nil : parenthetical,
            form: shortForm ? .short : .full,
            shortTitle: shortTitle.isEmpty ? nil : shortTitle
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
/// Where keyboard focus sits among the committed cite bubbles (see `citeFocus`).
enum CiteFocus: Equatable {
    case none              // the text field
    case selected(Int)     // bubble highlighted; ▼ edits its pincite/parenthetical
    case ahead(Int)        // caret in front of the bubble; ⌃S attaches a signal
}

struct PendingCite: Identifiable {
    let id = UUID()
    /// The case name shown in the bubble — the short title in short form, else the full
    /// name. Mutable so toggling form / editing the short-title override updates it.
    var label: String
    /// The signal applied to this cite (if any). Mutable so a signal can be attached
    /// after the fact via the cite cursor; drives the italic prefix shown in the bubble.
    var signal: Signal?
    var rich: RichText
    /// Formatting inputs retained so the cite can be re-formatted when its signal,
    /// pincite, parenthetical, or form is edited (they're baked into `rich`, not
    /// editable in place).
    let record: CaseRecord
    var pincite: String?
    var parenthetical: String?
    /// Full vs. short form for this cite, and the short-title override (nil = derived).
    var form: CaseCitation.CitationForm = .full
    var shortTitle: String?

    /// The signal text shown italic in the bubble, or nil when there's no signal.
    var signalText: String? { (signal?.text).flatMap { $0.isEmpty ? nil : $0 } }
    /// A capitalized signal starts a new citation sentence: the preceding cite then ends
    /// in a period rather than a semicolon when the string is finalized.
    var beginsNewSentence: Bool { signal?.isCapitalized ?? false }
}
#endif
