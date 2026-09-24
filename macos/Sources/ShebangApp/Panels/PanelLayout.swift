import CoreGraphics

/// Pure placement math for the floating panels. All rects are AppKit screen coordinates (bottom-left origin)
/// unless a parameter says otherwise.
enum PanelLayout {
    /// Keeps panels this far from the edges of the visible screen area.
    static let screenMargin: CGFloat = 8
    /// Distance from the top of the target window to the top of the prompt, clearing a typical title bar and toolbar.
    static let promptTopInset: CGFloat = 56
    /// Distance from the bottom of the target window to the bottom of the status HUD.
    static let hudBottomInset: CGFloat = 24
    /// Gap between a panel and a window it sits outside of.
    static let gap: CGFloat = 8

    /// Converts a rect in global top-left-origin coordinates (Accessibility, CGWindowList, `AppTarget.windowBounds`)
    /// to AppKit coordinates, where y grows upward from the bottom of the primary screen.
    static func appKitRect(fromTopLeft rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Index of the screen showing most of `window`; else the screen under the mouse; else the first screen.
    static func screenIndex(for window: CGRect?, screenFrames: [CGRect], mouse: CGPoint) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        if let window, !window.isEmpty {
            let areas = screenFrames.map { frame -> CGFloat in
                let overlap = frame.intersection(window)
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
                return best
            }
        }
        return screenFrames.firstIndex { $0.contains(mouse) } ?? 0
    }

    /// Prompt: centred on the target window, just inside its top edge. A window too short for that gets the prompt
    /// just above it (or below, when there is no room above). Without a window: upper part of the screen.
    static func promptFrame(size: CGSize, window: CGRect?, visible: CGRect) -> CGRect {
        let origin: CGPoint
        if let window = usable(window) {
            let x = window.midX - size.width / 2
            if window.height >= size.height + promptTopInset + gap {
                origin = CGPoint(x: x, y: window.maxY - promptTopInset - size.height)
            } else if window.maxY + gap + size.height <= visible.maxY - screenMargin {
                origin = CGPoint(x: x, y: window.maxY + gap)
            } else {
                origin = CGPoint(x: x, y: window.minY - gap - size.height)
            }
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height * 0.22 - size.height)
        }
        return clamp(CGRect(origin: origin, size: size), to: visible)
    }

    /// Status HUD: centred near the bottom of the target window, away from toolbars and address bars the agent may be
    /// typing into. Too-short windows get it just below. Without a window: bottom centre of the screen.
    static func hudFrame(size: CGSize, window: CGRect?, visible: CGRect) -> CGRect {
        let origin: CGPoint
        if let window = usable(window) {
            let x = window.midX - size.width / 2
            if window.height >= size.height + hudBottomInset * 2 {
                origin = CGPoint(x: x, y: window.minY + hudBottomInset)
            } else {
                origin = CGPoint(x: x, y: window.minY - gap - size.height)
            }
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 72)
        }
        return clamp(CGRect(origin: origin, size: size), to: visible)
    }

    /// Confirmation: centred on the target window, else on the screen.
    static func centeredFrame(size: CGSize, window: CGRect?, visible: CGRect) -> CGRect {
        let center = usable(window).map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: visible.midX, y: visible.midY)
        let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        return clamp(frame, to: visible)
    }

    /// Moves `frame` (without resizing) so it lies inside `visible` minus the margin; oversized frames pin to the
    /// left/top edge so their leading content stays visible.
    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let area = visible.insetBy(dx: screenMargin, dy: screenMargin)
        guard area.width > 0, area.height > 0 else { return frame }
        var result = frame
        if frame.width >= area.width {
            result.origin.x = area.minX
        } else {
            result.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        }
        if frame.height >= area.height {
            result.origin.y = area.maxY - frame.height
        } else {
            result.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        }
        return result
    }

    private static func usable(_ window: CGRect?) -> CGRect? {
        guard let window, !window.isNull, window.width >= 1, window.height >= 1 else { return nil }
        return window
    }
}
