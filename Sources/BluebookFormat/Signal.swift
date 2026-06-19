import Foundation

/// Introductory signals (Bluebook B1 / Rule 1). Always italicized, in both style
/// modes. The default list mirrors the companion Zotero `bluebook-signals` plugin
/// (`defaultprefs.js`) so users see the same vocabulary.
public struct Signal: Equatable {
    public var text: String   // as typed/stored, lowercase, e.g. "see", "but see"
    public init(_ text: String) { self.text = text }

    /// Capitalize the first letter for sentence-initial use, leaving the rest
    /// (e.g. "See, e.g.,") intact.
    public var capitalized: Signal {
        guard let first = text.first else { return self }
        return Signal(String(first).uppercased() + text.dropFirst())
    }

    /// Whether this signal is in sentence-initial (capitalized) form. A capitalized
    /// signal begins a new citation sentence, which changes how it joins to a prior
    /// cite in a string citation (period vs. semicolon — see `stringCitation`).
    public var isCapitalized: Bool {
        text.first?.isUppercase ?? false
    }

    /// Default signal vocabulary, matching the bluebook-signals plugin.
    public static let defaults: [Signal] = [
        Signal("e.g.,"),
        Signal("accord"),
        Signal("see"),
        Signal("see also"),
        Signal("see, e.g.,"),
        Signal("cf."),
        Signal("contra"),
        Signal("but see"),
        Signal("see generally"),
    ]

    /// Capitalized signals shown first for the *first* cite (sentence-initial use),
    /// in a curated order. The picker follows these with the lowercase
    /// `continuationOrder` for the rarer lowercase-first-cite case.
    public static let firstCiteLeading: [Signal] = [
        Signal("See"),
        Signal("See, e.g.,"),
        Signal("See generally"),
        Signal("E.g.,"),
        Signal("Cf."),
    ]

    /// Signal order surfaced for a *continuation* cite in a string citation (2nd+),
    /// where lowercase signals lead. A curated ordering distinct from `defaults`:
    /// the picker shows these lowercase first, then the same list capitalized.
    public static let continuationOrder: [Signal] = [
        Signal("see"),
        Signal("see also"),
        Signal("see, e.g.,"),
        Signal("see also, e.g.,"),
        Signal("but see"),
        Signal("cf."),
        Signal("accord"),
        Signal("contra"),
    ]
}
