#if canImport(AppKit)
import SwiftUI
import BluebookFormat

/// Keyboard-navigable signal overlay (⌃S). Shows each signal in italic preview.
/// For the first cite a curated set of capitalized (sentence-initial) signals leads,
/// followed by the lowercase continuation order; for a later cite in a string citation
/// the lowercase continuation order leads (signals after the first typically stay
/// lowercase within one citation sentence), then the same list capitalized.
/// ↑/↓ to move, ⏎ to choose, Esc to close.
/// Pure display: the search field keeps keyboard focus and drives selection
/// (↑/↓/⏎/Esc) through the view model, so the picker just renders the choices and
/// highlights `selection`. (Focus transfer onto this overlay was unreliable on the
/// nonactivating panel, which made the picker impossible to navigate or dismiss.)
struct SignalPicker: View {
    let choices: [Signal]
    let selection: Int
    /// Mouse fallback: clicking a row chooses it.
    var onChoose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, signal in
                Text(signal.text)
                    .italic()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == selection ? Color.accentColor.opacity(0.25) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .onTapGesture { onChoose(index) }
            }
        }
        .padding(6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(width: 220)
    }
}
#endif
