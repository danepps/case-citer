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
    /// Opens the Settings window (gear button in the pill).
    var onOpenSettings: () -> Void

    @FocusState private var searchFocused: Bool

    private var hasResults: Bool { !model.results.isEmpty }

    var body: some View {
        // The signal picker floats in this ZStack instead of sitting in the VStack flow,
        // so it overlays the top of the results rather than pushing them down. It's still
        // a sibling here, so it counts toward the measured height (heightReader below) and
        // the panel grows to fit it — no clipping even when there are no results.
        ZStack(alignment: .topLeading) {
            VStack(spacing: 8) {
                searchBar
                // The cite-options form stays in the flow (it's a form you fill in, and
                // briefly nudging the results is fine).
                if model.showingCiteOptions { citeOptionsPopoverView }
                if hasResults {
                    resultsCard
                } else if let msg = model.statusMessage {
                    // No results yet: surface progress/errors here, since the footer (which
                    // also shows statusMessage) only exists once the results card appears.
                    // Without this, a slow request leaves the pill looking frozen.
                    statusPill(msg)
                }
            }
            if model.showingSignalPicker {
                signalPickerView
                    .padding(.top, 60 + 8) // just below the pill (pill height + VStack spacing)
            }
        }
        .padding(20) // breathing room so the drop shadow isn't clipped
        .fixedSize(horizontal: false, vertical: true)
        // Translucency on the whole pill + results so what's behind shows through.
        .opacity(0.8)
        .background(heightReader)
        // Pin the content to the top of the window. The panel resizes to fit (see
        // SearchPanel.setContentHeight) but that resize lags the content by one runloop
        // tick; without a top anchor, NSHostingView vertically centers the natural-size
        // content during that gap, so the pill visibly drifts up/down as results
        // expand/collapse. Top-aligning keeps the search field fixed in place.
        // Placed *after* heightReader so the measured height stays the natural content
        // height, not the filled window height (which would feed back into the resize).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { searchFocused = true }
        .onChange(of: model.showCount) { _, _ in
            searchFocused = true
        }
    }

    // MARK: popovers

    /// The signal picker (⌃S). Keyboard nav (↑/↓/⏎/Esc) is handled by the search field,
    /// which keeps focus; this renders the choices and supports a mouse click to choose.
    private var signalPickerView: some View {
        SignalPicker(choices: model.signalChoices,
                     selection: model.signalSelection,
                     onChoose: { index in
            model.signalSelection = index
            model.chooseHighlightedSignal()
            searchFocused = true
        })
    }

    /// The → cite-options form (pincite / parenthetical / short title).
    private var citeOptionsPopoverView: some View {
        CiteOptionsPopover(
            pincite: $model.pincite,
            parenthetical: $model.parenthetical,
            shortForm: model.shortForm,
            shortTitle: $model.shortTitle,
            onCommit: {
                if let i = model.editingCiteIndex {
                    // Editing a committed cite: write the options back and keep it
                    // selected so ◀/▶ keep working.
                    model.applyCiteOptions(toCiteAt: i)
                    model.editingCiteIndex = nil
                    model.showingCiteOptions = false
                    model.citeFocus = .selected(i)
                } else if model.addCurrentCite() {
                    // empty editor / new cite path resets focus on its own
                }
                searchFocused = true
            },
            onClose: {
                // ▲ / esc: close without changing the cite; re-select it if we were
                // editing a committed one.
                if let i = model.editingCiteIndex {
                    model.editingCiteIndex = nil
                    model.citeFocus = .selected(i)
                }
                model.showingCiteOptions = false
                searchFocused = true
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: search pill

    private var searchBar: some View {
        HStack(spacing: 14) {
            pillLeading
            TextField(model.pendingCites.isEmpty ? "Search a case…" : "Add another cite…", text: Binding(
                get: { model.query },
                set: { model.queryChanged($0) }
            ))
            .textFieldStyle(.plain)
            .font(.title2)
            .focused($searchFocused)
            .onKeyPress(.upArrow) {
                if model.showingSignalPicker { model.moveSignalSelection(by: -1); return .handled }
                model.moveSelection(by: -1); return .handled
            }
            .onKeyPress(.downArrow) {
                if model.showingSignalPicker { model.moveSignalSelection(by: 1); return .handled }
                // ▼ on a selected committed cite opens its pincite/parenthetical editor;
                // otherwise it moves the result selection.
                if case .selected(let i) = model.citeFocus {
                    model.beginEditingCiteOptions(at: i)
                    return .handled
                }
                model.moveSelection(by: 1)
                return .handled
            }
            .onKeyPress(keys: [.return]) { press in
                if model.showingSignalPicker {
                    model.chooseHighlightedSignal()
                    return .handled
                }
                return handleReturn(shift: press.modifiers.contains(.shift))
            }
            .onKeyPress(.leftArrow) {
                // With an empty query, ◀ walks a "cite cursor" back through the committed
                // bubbles so ⌃S can attach a signal to a specific one. With text in the
                // field, let ◀ move the text cursor as usual.
                guard model.query.isEmpty, !model.pendingCites.isEmpty else { return .ignored }
                model.moveCiteCursorLeft()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                // ▶ walks the cite cursor back toward (and into) the text field. Otherwise,
                // once there are results, → opens the cite-options popover (pincite +
                // parenthetical); with no results, let → move the text cursor as usual.
                if model.citeFocus != .none { model.moveCiteCursorRight(); return .handled }
                guard hasResults else { return .ignored }
                model.showingCiteOptions = true
                return .handled
            }
            // NOTE: Backspace-on-empty (delete the preceding bubble) is handled by a
            // local NSEvent monitor in AppDelegate — a focused TextField's field editor
            // swallows ⌫ before SwiftUI's onKeyPress(.delete) can see it.
            .onKeyPress(.escape) {
                // Esc closes an open signal picker first, then parks the cite cursor,
                // then clears the query; a final (empty) Esc falls through to the panel's
                // cancelOperation, which dismisses.
                if model.showingSignalPicker { model.closeSignalPicker(); return .handled }
                if model.citeFocus != .none { model.citeFocus = .none; return .handled }
                guard model.query.isEmpty else { model.queryChanged(""); return .handled }
                return .ignored
            }
            .onKeyPress(keys: ["s"]) { press in
                guard press.modifiers.contains(.control) else { return .ignored }
                // Toggle: ⌃S again closes the picker rather than re-opening it.
                if model.showingSignalPicker { model.closeSignalPicker() } else { model.openSignalPicker() }
                return .handled
            }
            .onKeyPress(keys: ["f"]) { press in
                guard press.modifiers.contains(.control) else { return .ignored }
                model.toggleShortForm()
                return .handled
            }
            optionsMenu
            settingsButton
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }

    /// The pill's leading content (icon + committed-cite bubbles + signal / short-form
    /// chips), split out so the search bar's HStack stays type-checkable.
    @ViewBuilder private var pillLeading: some View {
        // Design option C: in short-form mode the books icon tints accent and gains a
        // small "S" badge — a fixed-position cue that persists even while typing.
        Image(systemName: "books.vertical.fill")
            .font(.title2)
            .foregroundStyle(model.shortForm ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .overlay(alignment: .topTrailing) {
                if model.shortForm {
                    Text("S")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(Color.accentColor))
                        .overlay(Circle().strokeBorder(.regularMaterial, lineWidth: 1.5))
                        .offset(x: 6, y: -6)
                }
            }
        ForEach(Array(model.pendingCites.enumerated()), id: \.element.id) { index, cite in
            if model.citeFocus == .ahead(index) { citeCursor }
            citeBubble(cite, selected: model.citeFocus == .selected(index))
        }
        if let signal = model.signal, !signal.text.isEmpty {
            signalChip(signal.text)
        }
    }

    /// Inline confirmation that a Bluebook signal is active, sitting in the pill ahead
    /// of the query (italic, like the signal will render). Click to clear it; ⌃S still
    /// reopens the picker to change it.
    private func signalChip(_ text: String) -> some View {
        Button {
            model.signal = nil
            searchFocused = true
        } label: {
            HStack(spacing: 5) {
                Text(text).italic()
                Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .font(.title3)
            .foregroundStyle(.white)
            .padding(.leading, 12).padding(.trailing, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .help("Click to clear signal (⌃S to change)")
        .fixedSize()
    }

    /// The cite cursor: a thin accent caret drawn in front of the focused bubble to show
    /// where a ⌃S signal will land (positioned with ◀/▶ on an empty query).
    private var citeCursor: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 2, height: 28)
            .accessibilityHidden(true)
    }

    /// A committed cite, shown as a neutral bubble in the pill ahead of the query
    /// (distinct from the accent signal chip). Click to remove it from the string cite;
    /// when the cite cursor is on it, an accent ring shows ⌃S will target it.
    private func citeBubble(_ cite: PendingCite, selected: Bool) -> some View {
        Button {
            model.removeCite(cite.id)
            searchFocused = true
        } label: {
            HStack(spacing: 5) {
                if let sig = cite.signalText { Text(sig).italic() }
                Text(cite.label).italic(cite.form == .short).lineLimit(1).truncationMode(.tail)
                Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .font(.title3)
            .foregroundStyle(.primary)
            .padding(.leading, 12).padding(.trailing, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(.quaternary))
            .overlay(selected ? Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5) : nil)
        }
        .buttonStyle(.plain)
        .help(selected ? "▼ pincite/parenthetical · ◀ for signal" : "Click to remove from the citation")
        .frame(maxWidth: 170)
        .fixedSize()
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

    /// Gear button opening the Settings window (launch-at-login, hotkey, style, token).
    /// Mouse-only affordance — the keyboard path never needs to leave the pill.
    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            Image(systemName: "gearshape")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Settings")
        .fixedSize()
    }

    /// Lightweight status row shown beneath the pill while there are no results —
    /// a spinner for "Searching…", plain text for "No results"/errors.
    private func statusPill(_ msg: String) -> some View {
        HStack(spacing: 8) {
            if msg == "Searching…" {
                ProgressView().controlSize(.small)
            }
            Text(msg).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
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
                        ResultRow(result: result, selected: index == model.selection, shortForm: model.shortForm)
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
            // Signal lives in the pill chip; pincite/parenthetical live in the → popover.
            Spacer()
            if let msg = model.statusMessage {
                Text(msg).foregroundStyle(.orange)
            }
            Text(footerHint).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    /// Keyboard cheat-sheet; wording shifts once cites are accumulating.
    private var footerHint: String {
        model.pendingCites.isEmpty
            ? "→ pincite · ⌃S signal · ⌃F short · ⏎ add · ⇧⏎ insert"
            : "→ pincite · ⌃F short · ⏎ add · ⇧⏎ / ⏎ again to insert"
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

    /// ⏎ / ⇧⏎ semantics for the string-cite builder:
    ///  • a result is selected → add it as a bubble (⇧⏎ also inserts right away)
    ///  • nothing to add but cites are queued → insert the string citation
    private func handleReturn(shift: Bool) -> KeyPress.Result {
        if hasResults {
            if model.addCurrentCite() {
                searchFocused = true
                if shift { finalize() }
            }
            return .handled
        }
        if !model.pendingCites.isEmpty {
            finalize()
        }
        return .handled
    }

    private func finalize() {
        if let rich = model.finalizeCitation() {
            onInsert(rich)
        }
    }
}

/// The → cite-options popover: pincite + explanatory parenthetical for the current
/// selection. ⇥ moves between fields, ⏎ adds the cite (closing the popover), Esc
/// closes without adding. An in-panel overlay (not a real popover) so it doesn't
/// resign the floating panel's key state and dismiss it.
private struct CiteOptionsPopover: View {
    @Binding var pincite: String
    @Binding var parenthetical: String
    /// When the cite is in short form, expose the editable short-title override at the
    /// bottom (it's used rarely — the derived guess is usually right), so Pincite keeps
    /// the default focus.
    var shortForm: Bool
    @Binding var shortTitle: String
    var onCommit: () -> Void
    var onClose: () -> Void

    @FocusState private var field: Field?
    private enum Field { case shortTitle, pincite, parenthetical }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledField("Pincite", placeholder: "page, e.g. 483", text: $pincite, field: .pincite)
            labeledField("Parenthetical", placeholder: "e.g. en banc", text: $parenthetical, field: .parenthetical)
            if shortForm {
                labeledField("Short title", placeholder: "e.g. Obergefell", text: $shortTitle, field: .shortTitle)
            }
            Text("⏎ add cite · ⇥ next field · esc")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
        .onAppear { field = .pincite }
    }

    /// ⇥ cycles through the visible fields in order (short title last, only when shown).
    private var tabOrder: [Field] {
        shortForm ? [.pincite, .parenthetical, .shortTitle] : [.pincite, .parenthetical]
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>, field which: Field) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .focused($field, equals: which)
                .onKeyPress(.return) { onCommit(); return .handled }
                .onKeyPress(.tab) {
                    let order = tabOrder
                    if let i = order.firstIndex(of: which) {
                        field = order[(i + 1) % order.count]
                    }
                    return .handled
                }
                // ▲ (and Esc) close the popover without committing.
                .onKeyPress(.upArrow) { onClose(); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
        }
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let selected: Bool
    /// When short-form mode is on, the row keeps the full case name (for identification)
    /// and adds a preview of the short form that will actually be inserted.
    var shortForm: Bool = false

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
            if let preview = shortPreview {
                (Text("short form  ").foregroundStyle(.tertiary) + preview)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    /// The short-form citation rendered as styled `Text` (italic title), or nil when off
    /// or the record can't be formatted. No pincite here — it's chosen per cite later —
    /// so the preview stops at the reporter, mirroring a no-pincite short cite.
    private var shortPreview: Text? {
        guard shortForm,
              let rich = try? CaseCitation.format(
                result.toCaseRecord(),
                options: .init(style: AppSettings.shared.style, form: .short))
        else { return nil }
        return rich.runs.reduce(Text("")) { acc, run in
            acc + (run.italic ? Text(run.text).italic() : Text(run.text))
        }
    }
}
#endif
