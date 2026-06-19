#if canImport(AppKit)
import AppKit
import SwiftUI

/// A nonactivating floating panel that can still become key (so its text field
/// accepts typing) while the app runs as an agent. Spotlight-style: a rounded pill
/// floating in the upper third, transparent background, auto-sized to its content
/// (so results grow downward), dismisses on Esc / click-outside.
final class SearchPanel: NSPanel {

    init(rootView: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 120),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        // Transparent window so the SwiftUI rounded shapes define the visible chrome.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // SwiftUI draws the shadow on the rounded shapes instead
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: rootView)
        contentView = hosting
    }

    // Must be overridable to true for a nonactivating panel to accept key input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Place the panel horizontally centered with its top edge ~18% down from the
    /// top of the screen, so it (and the results below it) sit in the upper third.
    func positionTopCentered() {
        guard let screen = NSScreen.main else { center(); return }
        let vf = screen.visibleFrame
        let topY = vf.minY + vf.height * 0.82
        var f = frame
        f.origin.x = vf.minX + (vf.width - f.width) / 2
        f.origin.y = topY - f.height
        setFrame(f, display: true)
    }

    /// Resize to the content's natural height, keeping the top edge fixed so the
    /// pill stays put while results expand/collapse beneath it.
    ///
    /// The height is reported from a SwiftUI `GeometryReader`, i.e. from *inside* a
    /// layout pass — resizing the window synchronously there trips AppKit's
    /// "-layoutSubtreeIfNeeded … already being laid out" recursion warning. Hop to the
    /// next runloop tick so the frame change lands after the current pass completes;
    /// the delay is sub-frame and imperceptible.
    func setContentHeight(_ height: CGFloat) {
        let target = ceil(height)
        guard target > 0, abs(frame.height - target) > 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, abs(self.frame.height - target) > 0.5 else { return }
            var f = self.frame
            let top = f.maxY
            f.size.height = target
            f.origin.y = top - target
            self.setFrame(f, display: true)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil) // Esc dismisses (after the field is already empty)
    }

    /// Spotlight-style: clicking anywhere outside the panel (which resigns key)
    /// dismisses it, so the user doesn't have to click in and press Esc.
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}
#endif
