import CoreGraphics
import Foundation

/// A normal on-screen window as reported by `CGWindowListCopyWindowInfo` (global top-left points).
struct WindowCandidate: Equatable {
    let id: CGWindowID
    let frame: CGRect
    let title: String
    let ownerPID: Int32
}

enum WindowList {
    /// Front-to-back on-screen windows. Titles of other apps are only present with Screen Recording access.
    static func onScreenWindowInfo() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
    }

    /// Layer-0 windows larger than 1×1, preserving front-to-back order. `pid == nil` keeps every owner.
    static func candidates(from info: [[String: Any]], pid: Int32? = nil) -> [WindowCandidate] {
        info.compactMap { window in
            guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid == nil || owner == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsValue = window[kCGWindowBounds as String],
                  let frame = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
                  frame.width > 1, frame.height > 1
            else { return nil }
            return WindowCandidate(
                id: number, frame: frame, title: window[kCGWindowName as String] as? String ?? "", ownerPID: owner)
        }
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    /// Keeps AX traversal, capture, and click bounds tied to the same real window: with a known AX focused
    /// frame only a matching window qualifies (a frontmost popup or an unrelated window is rejected).
    static func select(_ candidates: [WindowCandidate], focusedFrame: CGRect?) -> WindowCandidate? {
        guard let focusedFrame else { return candidates.first }
        return candidates.first { framesMatch($0.frame, focusedFrame) }
    }

    /// For capture the target's recorded frame may be stale (the user moved the window), so fall back
    /// from exact window id to frame match to the app's frontmost window.
    static func selectForCapture(_ candidates: [WindowCandidate], windowNumber: Int, expectedFrame: CGRect) -> WindowCandidate? {
        if windowNumber > 0, let exact = candidates.first(where: { Int($0.id) == windowNumber }) { return exact }
        if !expectedFrame.isEmpty, let matching = select(candidates, focusedFrame: expectedFrame) { return matching }
        return candidates.first
    }
}
