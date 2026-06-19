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

    @Published var apiKey: String {
        didSet {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            AppSettings.shared.apiKey = trimmed.isEmpty ? nil : trimmed
        }
    }

    init() {
        launchAtLogin = LaunchAtLogin.isEnabled
        lawReviewStyle = AppSettings.shared.style == .lawReview
        apiKey = AppSettings.shared.apiKey ?? ""
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

            Section("CourtListener") {
                TextField("API token", text: $model.apiKey, prompt: Text("optional — raises rate limits"))
                    .textFieldStyle(.roundedBorder)
                Text("Anonymous search works but is throttled. A free token lifts the limit.")
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
