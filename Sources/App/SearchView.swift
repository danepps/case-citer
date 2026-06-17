#if canImport(AppKit)
import SwiftUI
import BluebookFormat
import CourtListener

/// The Spotlight-style search UI. Collapsed to a rounded "pill" until you type;
/// the results card grows downward once there are hits. Fully keyboard-operable:
///  • search field is focused on open; typing drives a debounced query
///  • ↑/↓ move the result selection
///  • ⌃S opens the signal picker
///  • ⇥ moves focus to the pincite field
///  • ⏎ formats the selected result and triggers insertion (`onInsert`)
///  • Esc clears the field first; a second Esc dismisses (handled by the panel)
struct SearchView: View {
    @ObservedObject var model: SearchViewModel
    /// Called with the formatted citation when the user commits (⏎).
    var onInsert: (RichText) -> Void
    /// Reports the content's natural height so the panel can size itself to fit.
    var onHeightChange: (CGFloat) -> Void

    @FocusState private var searchFocused: Bool
    @FocusState private var pinciteFocused: Bool
    /// True once the user has pressed ↓ to navigate results. In this mode → jumps to
    /// the pincite; while still editing the query, → moves the text cursor instead.
    @State private var isNavigating = false

    private var hasResults: Bool { !model.results.isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            searchBar
            if hasResults {
                resultsCard
            }
        }
        .padding(20) // breathing room so the drop shadow isn't clipped
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .topLeading) {
            if model.showingSignalPicker {
                SignalPicker(signals: AppSettings.shared.signals) { chosen in
                    model.signal = chosen
                    model.showingSignalPicker = false
                    searchFocused = true
                }
                .padding(.horizontal, 20)
                .offset(y: 76)
            }
        }
        .background(heightReader)
        .onAppear { searchFocused = true }
        .onChange(of: model.showCount) { _, _ in
            pinciteFocused = false
            searchFocused = true
            isNavigating = false
        }
    }

    // MARK: search pill

    private var searchBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "books.vertical.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            TextField("Search a case…", text: Binding(
                get: { model.query },
                // Typing returns to editing mode, so arrows move the cursor again.
                set: { isNavigating = false; model.queryChanged($0) }
            ))
            .textFieldStyle(.plain)
            .font(.title2)
            .focused($searchFocused)
            .onKeyPress(.upArrow) { isNavigating = true; model.moveSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { isNavigating = true; model.moveSelection(by: 1); return .handled }
            .onKeyPress(.return) { commit(); return .handled }
            .onKeyPress(.tab) { pinciteFocused = true; return .handled }
            .onKeyPress(.rightArrow) {
                // In navigation mode (after ↓), → jumps to the pincite. While editing,
                // let → move the text cursor as usual.
                guard isNavigating, hasResults else { return .ignored }
                pinciteFocused = true
                return .handled
            }
            .onKeyPress(.escape) {
                // First Esc clears the query; a second (empty) Esc falls through to
                // the panel's cancelOperation, which dismisses.
                guard model.query.isEmpty else { model.queryChanged(""); return .handled }
                return .ignored
            }
            .onKeyPress(keys: ["s"]) { press in
                guard press.modifiers.contains(.control) else { return .ignored }
                model.showingSignalPicker = true
                return .handled
            }
            optionsMenu
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }

    /// "…" menu for settings that don't belong on the keyboard-first path.
    private var optionsMenu: some View {
        Menu {
            Toggle("Law review style", isOn: $model.lawReviewStyle)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24)
    }

    // MARK: results card

    private var resultsCard: some View {
        VStack(spacing: 0) {
            resultsList
            Divider()
            footer
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.offset) { index, result in
                        ResultRow(result: result, selected: index == model.selection)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == model.selection
                                        ? Color.accentColor.opacity(0.25) : .clear)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selection = index } // mouse optional
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 320)
            .onChange(of: model.selection) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let signal = model.signal {
                Text(signal.text).italic().foregroundStyle(.secondary)
            }
            Text("pincite").foregroundStyle(.secondary)
            TextField("page", text: $model.pincite)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .focused($pinciteFocused)
                .onKeyPress(.return) { commit(); return .handled }
                .onKeyPress(.leftArrow) {
                    // ← from an empty pincite hops back to the search field.
                    guard model.pincite.isEmpty else { return .ignored }
                    searchFocused = true
                    return .handled
                }
            Spacer()
            if let msg = model.statusMessage {
                Text(msg).foregroundStyle(.orange)
            }
            Text("⌃S signal · ⏎ insert · esc").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    // MARK: helpers

    /// Measures the content's natural height and reports it up so the panel can
    /// resize. Top-anchored, so results appear to grow downward from the pill.
    private var heightReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { onHeightChange(geo.size.height) }
                .onChange(of: geo.size.height) { _, h in onHeightChange(h) }
        }
    }

    private func commit() {
        if let rich = model.formatSelected() {
            onInsert(rich)
        }
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.caseName ?? "—").fontWeight(selected ? .semibold : .regular)
            HStack(spacing: 8) {
                if let cite = result.preferredCitationText { Text(cite) }
                if let court = result.court { Text(court) }
                if let y = result.year { Text(String(y)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
#endif
