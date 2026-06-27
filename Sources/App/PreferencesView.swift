#if canImport(AppKit)
import AppKit
import SwiftUI
import BluebookFormat
#if canImport(KeyboardShortcuts)
import KeyboardShortcuts
#endif

/// Backing store for the preferences window. Bridges the persisted `AppSettings`
/// values and the system-owned launch-at-login state into `@Published` properties so
/// the SwiftUI form stays in sync (and reverts the toggle if registration fails).
@MainActor
final class PreferencesModel: ObservableObject {
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            LaunchAtLogin.isEnabled = launchAtLogin
            // The system may reject the change (e.g. unbundled dev binary); reflect
            // the real status back so the toggle never lies.
            let actual = LaunchAtLogin.isEnabled
            if actual != launchAtLogin { launchAtLogin = actual }
        }
    }

    @Published var lawReviewStyle: Bool {
        didSet { AppSettings.shared.style = lawReviewStyle ? .lawReview : .courtDocument }
    }

    @Published var mergePaste: Bool {
        didSet { AppSettings.shared.mergePaste = mergePaste }
    }

    @Published var appearance: AppAppearance {
        didSet {
            AppSettings.shared.appearance = appearance
            appearance.apply()   // take effect immediately, no relaunch
        }
    }

    /// Opt-in to a personal CourtListener token. Off by default → anonymous API.
    @Published var useCustomAPIKey: Bool {
        didSet { AppSettings.shared.useCustomAPIKey = useCustomAPIKey }
    }

    @Published var apiKey: String {
        didSet {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            AppSettings.shared.apiKey = trimmed.isEmpty ? nil : trimmed
        }
    }

    init() {
        launchAtLogin = LaunchAtLogin.isEnabled
        lawReviewStyle = AppSettings.shared.style == .lawReview
        mergePaste = AppSettings.shared.mergePaste
        useCustomAPIKey = AppSettings.shared.useCustomAPIKey
        apiKey = AppSettings.shared.apiKey ?? ""
        appearance = AppSettings.shared.appearance
    }
}

extension AppAppearance {
    /// Apply this choice app-wide. `auto` clears the override so windows follow the
    /// system; light/dark force the corresponding aqua appearance on every window.
    @MainActor func apply() {
        switch self {
        case .auto:  NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:  NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// The Settings window contents: a standard macOS form. Groups the launch-at-login
/// toggle, the citation-style choice, the global hotkey recorder, and the
/// CourtListener API token (the last two were referenced by the README but had no UI).
struct PreferencesView: View {
    @StateObject private var model = PreferencesModel()

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Picker("Appearance", selection: $model.appearance) {
                    Text("Auto").tag(AppAppearance.auto)
                    Text("Light").tag(AppAppearance.light)
                    Text("Dark").tag(AppAppearance.dark)
                }
                .pickerStyle(.segmented)
                #if canImport(KeyboardShortcuts)
                KeyboardShortcuts.Recorder("Summon hotkey:", name: .summon)
                #endif
            }

            Section("Citation style") {
                Picker("Style", selection: $model.lawReviewStyle) {
                    Text("Law review footnote").tag(true)
                    Text("Court document / brief").tag(false)
                }
                .pickerStyle(.radioGroup)
                Text("Court documents italicize the full case name; law-review footnotes leave it roman.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Paste") {
                Toggle("Merge formatting paste (\u{2318}\u{21E7}\u{2325}V)", isOn: $model.mergePaste)
                Text(model.mergePaste
                     ? "Sends \u{2318}\u{21E7}\u{2325}V instead of \u{2318}V. Bind that combo to a Word “Merge Formatting” macro so citations take your document’s font and size while keeping case-name italics."
                     : "Sends a plain \u{2318}V. Works everywhere; the citation keeps its own formatting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("CourtListener") {
                Toggle("Use a personal API token", isOn: $model.useCustomAPIKey)
                if model.useCustomAPIKey {
                    TextField("API token", text: $model.apiKey, prompt: Text("paste your CourtListener token"))
                        .textFieldStyle(.roundedBorder)
                }
                Text(model.useCustomAPIKey
                     ? "Your token raises the rate limit. It's stored locally on this Mac only."
                     : "Searching anonymously (throttled). Turn this on to use your own free CourtListener token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Owns the single, reusable Settings window. The app runs as an accessory, so we
/// activate it (and order the window front) explicitly on open.
@MainActor
final class PreferencesWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: PreferencesView())
            let win = NSWindow(contentViewController: hosting)
            win.title = "Case Citer Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
#endif
