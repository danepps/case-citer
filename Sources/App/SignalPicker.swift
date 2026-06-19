#if canImport(AppKit)
import SwiftUI
import BluebookFormat

/// Keyboard-navigable signal overlay (⌃S). Shows each signal in italic preview.
/// For the first cite a curated set of capitalized (sentence-initial) signals leads,
/// followed by the lowercase continuation order; for a later cite in a string citation
/// the lowercase continuation order leads (signals after the first typically stay
/// lowercase within one citation sentence), then the same list capitalized.
/// ↑/↓ to move, ⏎ to choose, Esc to close.
struct SignalPicker: View {
    /// When true (a non-first cite), surface the lowercase variants on top.
    var lowercaseFirst: Bool = false
    var onChoose: (Signal) -> Void
    var onCancel: () -> Void

    @State private var selection = 0
    @FocusState private var focused: Bool

    private var ordered: [Signal] {
        if lowercaseFirst {
            // Continuation cite: a curated lowercase-led order, then the same capitalized.
            let base = Signal.continuationOrder
            return base + base.map(\.capitalized)
        }
        // First cite: curated capitalized signals lead, then the lowercase continuation order.
        return Signal.firstCiteLeading + Signal.continuationOrder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { index, signal in
                Text(signal.text)
                    .italic()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == selection ? Color.accentColor.opacity(0.25) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(width: 220)
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
        .onKeyPress(.downArrow) { selection = min(ordered.count - 1, selection + 1); return .handled }
        .onKeyPress(.return) { onChoose(ordered[selection]); return .handled }
        // Esc closes the picker only — consume it so it doesn't fall through to the
        // panel's cancelOperation and dismiss the whole search panel.
        .onKeyPress(.escape) { onCancel(); return .handled }
    }
}
#endif
