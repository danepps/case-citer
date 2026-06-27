#if canImport(AppKit)
import AppKit
import BluebookFormat

/// Paste-back: put the formatted citation on the pasteboard as **both** RTF (italics
/// preserved) and plain string (graceful degradation), then reactivate the
/// previously-frontmost app and synthesize ⌘V.
///
/// The RTF carries the case-name italics but **no font/size** (see `rtfDocument`).
/// To have the citation adopt the destination document's font and size while
/// keeping those italics, set the destination's paste mode to "merge formatting"
/// (Word: Settings → Edit → "Pasting from other programs" → Merge Formatting).
/// Merge-formatting keeps the emphasis runs and re-flows them into the cursor's
/// own paragraph font/size, so no font needs to be baked into our RTF.
///
/// This is the Raycast/Alfred approach and the most reliable cross-app insertion
/// method; it depends on the Accessibility permission (see `Permissions`).
enum Paster {

    /// Writes both flavors to the general pasteboard.
    static func writeToPasteboard(_ rich: RichText) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let rtfData = rich.rtfDocument.data(using: .utf8) {
            pb.setData(rtfData, forType: .rtf)
        }
        pb.setString(rich.plainText, forType: .string)
    }

    /// Reactivate `app`, then post a paste key-down/up via a private event source so
    /// it lands in the now-frontmost app. Caller must have dismissed our panel
    /// first so focus actually returns to the target.
    static func paste(into app: NSRunningApplication?) {
        app?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            synthesizePaste()
        }
    }

    /// Modifiers for the synthesized paste. Plain **⌘V** by default; when the
    /// "merge formatting paste" setting is on we send **⌘⇧⌥V** instead — the combo a
    /// Word `Selection.PasteAndFormat wdFormatSurroundingFormattingWithEmphasis`
    /// ("Merge Formatting") macro is bound to, so the citation adopts the destination
    /// paragraph's font/size while keeping the case-name italics from our RTF. (A plain
    /// ⌘V is "Keep Source Formatting" and renders our fontless RTF in Word's default,
    /// Times.) The user toggles this in Settings per their Word key binding.
    private static var pasteModifiers: CGEventFlags {
        AppSettings.shared.mergePaste
            ? [.maskCommand, .maskShift, .maskAlternate]
            : [.maskCommand]
    }

    private static func synthesizePaste() {
        guard Permissions.isTrusted else {
            Permissions.ensureTrusted(prompt: true)
            return
        }
        let modifiers = pasteModifiers
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // "v"
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = modifiers
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = modifiers
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
#endif
