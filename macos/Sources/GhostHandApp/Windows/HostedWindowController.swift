import AppKit
import SwiftUI

/// A standard titled window hosting a SwiftUI view. Kept alive and reused, never released on close.
@MainActor
final class HostedWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?

    init<Content: View>(title: String, rootView: Content) {
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = [.intrinsicContentSize]
        window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        super.init()
        window.delegate = self
    }

    var isVisible: Bool { window.isVisible }

    /// Brings the window forward; GhostHand has no Dock icon, so it activates itself to take keyboard focus.
    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
