import Foundation
import BluebookFormat
#if canImport(KeyboardShortcuts)
import KeyboardShortcuts
#endif

#if canImport(KeyboardShortcuts)
extension KeyboardShortcuts.Name {
    /// Global hotkey to summon the search panel. Default ⌘⇧-Space (user-rebindable
    /// via the recorder in Settings). Avoids Cmd-Space (Spotlight) and Ctrl-Space
    /// (input-source switch).
    static let summon = Self("summon", default: .init(.space, modifiers: [.command, .shift]))
}
#endif

/// The three appearance modes offered in Settings. `auto` follows the system.
enum AppAppearance: String, CaseIterable {
    case auto, light, dark
}

/// User-facing configuration, persisted in `UserDefaults`.
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let style = "citationStyle"          // "lawReview" | "courtDocument"
        static let apiKey = "courtListenerAPIKey"
        static let useCustomAPIKey = "useCustomAPIKey"  // Bool; default false (anonymous)
        static let signals = "signals"              // [String]
        static let appearance = "appearance"        // "auto" | "light" | "dark"
        static let mergePaste = "mergePaste"        // Bool; default false (plain ⌘V)
    }

    /// Paste style for the auto-insert. **Default false** → a plain ⌘V (Keep Source
    /// Formatting), which works everywhere. When true the app sends ⌘⇧⌥V instead, the
    /// combo a Word "Merge Formatting" macro is bound to, so the citation adopts the
    /// destination's font/size while keeping the case-name italics (see `Paster`).
    var mergePaste: Bool {
        get { defaults.bool(forKey: Key.mergePaste) }
        set { defaults.set(newValue, forKey: Key.mergePaste) }
    }

    /// Window appearance. Default **auto** (follow the system setting).
    var appearance: AppAppearance {
        get { AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    /// Citation style. Default **law-review** (full case name roman).
    var style: CitationStyle {
        get { defaults.string(forKey: Key.style) == "courtDocument" ? .courtDocument : .lawReview }
        set { defaults.set(newValue == .courtDocument ? "courtDocument" : "lawReview", forKey: Key.style) }
    }

    /// Whether to send a personal CourtListener token. **Default false**: the app
    /// uses the anonymous (throttled) API out of the box, so nothing personal is
    /// required to run it — and a cloned/handed-over repo carries no credential. Turn
    /// this on in Settings to opt in to your own token (see `effectiveAPIKey`).
    var useCustomAPIKey: Bool {
        get { defaults.bool(forKey: Key.useCustomAPIKey) }
        set { defaults.set(newValue, forKey: Key.useCustomAPIKey) }
    }

    /// The raw stored token, as edited in Settings. This is *not* what the network
    /// client should read — use `effectiveAPIKey`, which honors the opt-in toggle.
    var apiKey: String? {
        get { defaults.string(forKey: Key.apiKey) }
        set { defaults.set(newValue, forKey: Key.apiKey) }
    }

    /// The token actually handed to `SearchClient`: the stored token only when the
    /// user has opted in *and* it's non-empty; otherwise `nil` for an anonymous
    /// request. Centralizing the rule here keeps anonymous the safe default at every
    /// call site.
    var effectiveAPIKey: String? {
        guard useCustomAPIKey, let key = apiKey, !key.isEmpty else { return nil }
        return key
    }

    /// Signal vocabulary; falls back to the shared default list.
    var signals: [Signal] {
        get {
            if let raw = defaults.array(forKey: Key.signals) as? [String], !raw.isEmpty {
                return raw.map(Signal.init)
            }
            return Signal.defaults
        }
        set { defaults.set(newValue.map(\.text), forKey: Key.signals) }
    }
}
