import CoreGraphics
import Foundation
import ShebangCore
import Testing
@testable import ShebangPlatform

@Suite struct FrontmostWindowTrackerTests {
    private let finderDesktop = AppTarget(processId: 300, processName: "Finder", bundleIdentifier: "com.apple.finder")
    private let safari = AppTarget(processId: 555, processName: "Safari", bundleIdentifier: "com.apple.Safari",
                                   windowTitle: "Apple", windowNumber: 41, windowBounds: CGRect(x: 0, y: 25, width: 1200, height: 800))

    @Test func desktopOrShellDetection() {
        #expect(FrontmostWindowTracker.isDesktopOrShell(nil))
        #expect(FrontmostWindowTracker.isDesktopOrShell(finderDesktop))
        var desktop = finderDesktop
        desktop.windowTitle = "Desktop"
        #expect(FrontmostWindowTracker.isDesktopOrShell(desktop))
        var documents = finderDesktop
        documents.windowTitle = "Documents"
        #expect(!FrontmostWindowTracker.isDesktopOrShell(documents))
        #expect(!FrontmostWindowTracker.isDesktopOrShell(safari))
        #expect(FrontmostWindowTracker.isDesktopOrShell(AppTarget(processId: 300, processName: "Finder")))
    }

    @Test func followsFocusFromTheDesktopIntoAnApp() {
        #expect(FrontmostWindowTracker.resolveActiveTarget(current: finderDesktop, frontmost: safari) == safari)
    }

    @Test func followsAnotherWindowOfTheSameApp() {
        var otherWindow = safari
        otherWindow.windowNumber = 42
        otherWindow.windowTitle = "Downloads"
        #expect(FrontmostWindowTracker.resolveActiveTarget(current: safari, frontmost: otherWindow) == otherWindow)
        #expect(FrontmostWindowTracker.resolveActiveTarget(current: safari, frontmost: safari) == safari)
    }

    @Test func doesNotFollowADifferentApp() {
        let notes = AppTarget(processId: 777, processName: "Notes", windowTitle: "Notes", windowNumber: 7)
        #expect(FrontmostWindowTracker.resolveActiveTarget(current: safari, frontmost: notes) == safari)
        #expect(FrontmostWindowTracker.resolveActiveTarget(current: safari, frontmost: nil) == safari)
    }

    @Test func windowIdentityFallsBackToTitleAndBounds() {
        var a = safari, b = safari
        a.windowNumber = 0
        b.windowNumber = 0
        #expect(!FrontmostWindowTracker.isDifferentWindow(a, b))
        b.windowTitle = "Other"
        #expect(FrontmostWindowTracker.isDifferentWindow(a, b))
    }

    private let pid: Int32 = 4321
    private let appInfo = FrontmostWindowTracker.RunningAppInfo(
        name: "TextEdit", bundleIdentifier: "com.apple.TextEdit",
        executablePath: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit")

    private func windowInfo(_ windows: [(number: UInt32, frame: CGRect, name: String?)]) -> [[String: Any]] {
        windows.map { window in
            var info: [String: Any] = [
                kCGWindowOwnerPID as String: NSNumber(value: pid),
                kCGWindowNumber as String: NSNumber(value: window.number),
                kCGWindowLayer as String: NSNumber(value: 0),
                kCGWindowBounds as String: window.frame.dictionaryRepresentation,
            ]
            if let name = window.name { info[kCGWindowName as String] = name }
            return info
        }
    }

    @Test func describesAProcessUsingItsAXFocusedWindow() throws {
        let ax = FakeAXBackend()
        let focusedFrame = CGRect(x: 40, y: 60, width: 640, height: 480)
        ax.window(pid: pid, title: "Report.txt", frame: focusedFrame)
        let windows = windowInfo([(90, CGRect(x: 300, y: 300, width: 200, height: 40), nil), (91, focusedFrame, nil)])
        let tracker = FrontmostWindowTracker(ax: ax, appInfo: { [appInfo] in $0 == 4321 ? appInfo : nil }, windowInfo: { windows })

        let target = try #require(tracker.target(forProcessID: pid))
        #expect(target == AppTarget(processId: pid, processName: "TextEdit", bundleIdentifier: "com.apple.TextEdit",
                                    executablePath: appInfo.executablePath, windowTitle: "Report.txt",
                                    windowNumber: 91, windowBounds: focusedFrame))
    }

    @Test func untrustedAccessibilityFallsBackToTheWindowList() throws {
        let ax = FakeAXBackend()
        ax.isTrusted = false
        ax.window(pid: pid, title: "Hidden")
        let frame = CGRect(x: 10, y: 30, width: 900, height: 700)
        let windows = windowInfo([(77, frame, "Untitled")])
        let tracker = FrontmostWindowTracker(ax: ax, appInfo: { [appInfo] _ in appInfo }, windowInfo: { windows })

        let target = try #require(tracker.target(forProcessID: pid))
        #expect(target.windowTitle == "Untitled")
        #expect(target.windowNumber == 77)
        #expect(target.windowBounds == frame)
        #expect(ax.snapshotReads == 0)
    }

    @Test func unknownProcessesYieldNothing() {
        let tracker = FrontmostWindowTracker(ax: FakeAXBackend())
        let ghost = AppTarget(processId: 99_999_999, processName: "Ghost")
        #expect(tracker.target(forProcessID: ghost.processId) == nil)
        #expect(tracker.activate(ghost) == false)
    }

    @Test func systemSurfacesAreIgnored() {
        #expect(FrontmostWindowTracker.isIgnored("com.apple.SecurityAgent"))
        #expect(FrontmostWindowTracker.isIgnored("com.apple.loginwindow"))
        #expect(!FrontmostWindowTracker.isIgnored("com.apple.Safari"))
        #expect(!FrontmostWindowTracker.isIgnored(nil))
    }
}

@Suite struct WindowListTests {
    private func info(pid: Int32, number: UInt32, frame: CGRect, layer: Int = 0, name: String? = nil) -> [String: Any] {
        var window: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowNumber as String: NSNumber(value: number),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowBounds as String: frame.dictionaryRepresentation,
        ]
        if let name { window[kCGWindowName as String] = name }
        return window
    }

    @Test func parsesNormalWindowsInFrontToBackOrder() {
        let windows = [
            info(pid: 10, number: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 25), layer: 25),  // menu bar
            info(pid: 10, number: 2, frame: CGRect(x: 100, y: 100, width: 800, height: 600), name: "Doc"),
            info(pid: 11, number: 3, frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            info(pid: 10, number: 4, frame: CGRect(x: 0, y: 0, width: 1, height: 1)),
            info(pid: 10, number: 5, frame: CGRect(x: -1200, y: 25, width: 1200, height: 800)),
        ]
        let mine = WindowList.candidates(from: windows, pid: 10)
        #expect(mine.map(\.id) == [2, 5])
        #expect(mine.first?.title == "Doc")
        #expect(mine.last?.frame == CGRect(x: -1200, y: 25, width: 1200, height: 800))
        #expect(WindowList.candidates(from: windows).map(\.id) == [2, 3, 5])
    }

    // Ported from the original app's WindowSnapshot tests.
    @Test func selectionIgnoresFrontmostTemporaryWindow() {
        let main = WindowCandidate(id: 1, frame: CGRect(x: -1200, y: 25, width: 1200, height: 800), title: "", ownerPID: 1)
        let popup = WindowCandidate(id: 2, frame: CGRect(x: -700, y: 80, width: 200, height: 30), title: "", ownerPID: 1)
        #expect(WindowList.select([popup, main], focusedFrame: main.frame) == main)
    }

    @Test func selectionRejectsUnrelatedWindowWhenFocusedFrameIsKnown() {
        let other = WindowCandidate(id: 2, frame: CGRect(x: 0, y: 0, width: 200, height: 100), title: "", ownerPID: 1)
        #expect(WindowList.select([other], focusedFrame: CGRect(x: 500, y: 100, width: 1200, height: 800)) == nil)
        #expect(WindowList.select([other], focusedFrame: nil) == other)
    }

    @Test func captureSelectionPrefersIdThenFrameThenFrontmost() {
        let a = WindowCandidate(id: 7, frame: CGRect(x: 0, y: 0, width: 400, height: 300), title: "", ownerPID: 1)
        let b = WindowCandidate(id: 9, frame: CGRect(x: 50, y: 50, width: 800, height: 600), title: "", ownerPID: 1)
        #expect(WindowList.selectForCapture([a, b], windowNumber: 9, expectedFrame: .zero) == b)
        #expect(WindowList.selectForCapture([a, b], windowNumber: 0, expectedFrame: CGRect(x: 51, y: 49, width: 800, height: 600)) == b)
        #expect(WindowList.selectForCapture([a, b], windowNumber: 3, expectedFrame: CGRect(x: 900, y: 0, width: 10, height: 10)) == a)
        #expect(WindowList.selectForCapture([], windowNumber: 9, expectedFrame: .zero) == nil)
    }
}
