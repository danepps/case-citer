#if canImport(AppKit)
import AppKit
import SwiftUI
import BluebookFormat
import CourtListener
import KeyboardShortcuts

/// Agent (LSUIElement) app delegate: owns the menu-bar item, the global hotkey,
/// and the floating search panel. Captures the frontmost app before showing the
/// panel so paste-back can restore focus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: SearchPanel?
    private var model: SearchViewModel?
    private var priorApp: NSRunningApplication?
    private var keyMonitor: Any?
    private let preferences = PreferencesWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon (also set LSUIElement)

        // Nudge the Accessibility permission early so paste-back works on first use.
        Permissions.ensureTrusted(prompt: true)

        setUpMainMenu()
        setUpMenuBar()
        setUpPanel()
        installBackspaceMonitor()

        KeyboardShortcuts.onKeyUp(for: .summon) { [weak self] in
            // KeyboardShortcuts dispatches this on the main thread via its Carbon
            // event handler, so it is safe to assume MainActor isolation here.
            MainActor.assumeIsolated {
                self?.togglePanel()
            }
        }
    }

    /// Agent apps don't get a main menu for free, so the standard text-editing
    /// shortcuts (⌘A/⌘C/⌘V/⌘X/⌘Z) won't reach the search field's editor. Install a
    /// minimal Edit menu wired to the first-responder selectors to restore them.
    private func setUpMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
    }

    private func setUpMenuBar() {
        let item = NSStatusItem.let_make()
        item.button?.image = NSImage(systemSymbolName: "books.vertical.fill", accessibilityDescription: "Case Citer")
        let menu = NSMenu()
        menu.addItem(withTitle: "Search…", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func setUpPanel() {
        let client = SearchClient(apiKey: AppSettings.shared.apiKey)
        let model = SearchViewModel(client: client)
        self.model = model
        let view = SearchView(
            model: model,
            onInsert: { [weak self] rich in self?.insert(rich) },
            onHeightChange: { [weak self] height in self?.panel?.setContentHeight(height) },
            onOpenSettings: { [weak self] in self?.showPreferences() }
        )
        panel = SearchPanel(rootView: view)
    }

    /// Make Backspace peel off the bubble before the cursor when the query is empty
    /// (the signal chip first, then the most recent cite). A focused TextField's field
    /// editor consumes ⌫ before SwiftUI's `onKeyPress` sees it, so we catch it here, at
    /// the AppKit level, before it reaches the editor. Returning nil swallows the event;
    /// returning it lets the field delete a character as usual.
    private func installBackspaceMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode   // pull the scalar out so NSEvent doesn't cross the actor hop
            let consume = MainActor.assumeIsolated { () -> Bool in
                guard let self, let model = self.model, self.panel?.isKeyWindow == true,
                      keyCode == 51,                        // kVK_Delete (Backspace)
                      model.query.isEmpty,                  // not mid-edit
                      !model.showingCiteOptions, !model.showingSignalPicker  // not in a popover field
                else { return false }
                if model.signal != nil { model.signal = nil; return true }
                if let last = model.pendingCites.last { model.removeCite(last.id); return true }
                return false
            }
            return consume ? nil : event
        }
    }

    /// Open the Settings window. Dismiss the floating panel first if it's up (clicking
    /// the gear in the pill, or the menu-bar item) so focus moves cleanly to Settings.
    @objc private func showPreferences() {
        panel?.orderOut(nil)
        preferences.show()
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        // Remember who had focus so we can paste back into it.
        priorApp = NSWorkspace.shared.frontmostApplication
        // Reset transient state for a fresh invocation.
        model?.query = ""
        model?.results = []
        model?.pincite = ""
        model?.parenthetical = ""
        model?.signal = nil
        model?.statusMessage = nil
        model?.pendingCites = []
        model?.showingCiteOptions = false
        model?.showCount += 1 // re-focus the search field (see SearchView)
        NSApp.activate(ignoringOtherApps: true)
        panel.positionTopCentered()
        panel.makeKeyAndOrderFront(nil)
    }

    private func insert(_ rich: RichText) {
        Paster.writeToPasteboard(rich)
        panel?.orderOut(nil)
        Paster.paste(into: priorApp)
    }
}

private extension NSStatusItem {
    static func let_make() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
}
#endif
