import AppKit
import GhostHandCore
import SwiftUI

/// Borderless floating panel that never activates GhostHand, so the target app stays the active app.
/// Panels that accept key status (prompt, confirmation) receive typing like Spotlight does; the others (status HUD)
/// are click-through and never take focus, so they cannot intercept input meant for the target.
final class FloatingPanel: NSPanel {
    private let acceptsKey: Bool
    /// Called for Esc / Cancel when no view handled it.
    var onCancel: (() -> Void)?

    init(acceptsKey: Bool, level: NSWindow.Level) {
        self.acceptsKey = acceptsKey
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        isFloatingPanel = true
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
        if acceptsKey {
            isMovableByWindowBackground = true
        } else {
            ignoresMouseEvents = true
            collectionBehavior.insert(.ignoresCycle)
        }
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Shows the panel above other apps' windows without activating GhostHand.
    func present(makeKey: Bool) {
        orderFrontRegardless()
        if makeKey && acceptsKey { self.makeKey() }
        invalidateShadow()
    }
}

/// Screen queries for placing panels over an `AppTarget`.
@MainActor
enum ScreenGeometry {
    /// The target's window frame in AppKit coordinates, or nil when unknown.
    static func windowFrame(of target: AppTarget?) -> CGRect? {
        guard let bounds = target?.windowBounds, bounds.width >= 1, bounds.height >= 1,
              let primary = NSScreen.screens.first else { return nil }
        return PanelLayout.appKitRect(fromTopLeft: bounds, primaryScreenHeight: primary.frame.height)
    }

    /// Visible frame of the screen showing most of `window`, else the screen with the mouse.
    static func visibleFrame(for window: CGRect?) -> CGRect {
        let screens = NSScreen.screens
        guard let index = PanelLayout.screenIndex(
            for: window, screenFrames: screens.map(\.frame), mouse: NSEvent.mouseLocation)
        else { return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }
        return screens[index].visibleFrame
    }

    static func icon(for target: AppTarget?) -> NSImage? {
        guard let target else { return nil }
        return NSRunningApplication(processIdentifier: target.processId)?.icon
    }
}

/// Dark vibrant rounded background shared by the panels (behind-window blur like the original macOS overlay).
struct PanelBackground: View {
    var cornerRadius: CGFloat = 14

    var body: some View {
        ZStack {
            VisualEffectBlur(cornerRadius: cornerRadius)
            RoundedRectangle(cornerRadius: cornerRadius).fill(Color.black.opacity(0.28))
            RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        // Behind-window blur is composited by the window server, so a layer mask doesn't clip it; a mask image does.
        view.maskImage = Self.roundedMask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 2
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension StatusLine.Tone {
    var color: Color {
        switch self {
        case .neutral: return Color.white.opacity(0.55)
        case .info: return Color(red: 0.53, green: 0.81, blue: 0.98)
        case .success, .listening: return Color(red: 0.45, green: 0.88, blue: 0.55)
        case .warning: return Color.orange
        case .error: return Color(red: 1.0, green: 0.45, blue: 0.35)
        }
    }
}
