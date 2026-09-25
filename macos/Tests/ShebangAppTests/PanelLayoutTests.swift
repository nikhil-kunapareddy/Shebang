import CoreGraphics
import Testing
@testable import ShebangApp

@Suite struct PanelLayoutTests {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let promptSize = CGSize(width: 600, height: 140)

    @Test func convertsTopLeftRectsToAppKitCoordinates() {
        let rect = PanelLayout.appKitRect(
            fromTopLeft: CGRect(x: 100, y: 50, width: 400, height: 300), primaryScreenHeight: 1000)
        #expect(rect == CGRect(x: 100, y: 650, width: 400, height: 300))
    }

    @Test func promptSitsInsideTheTopOfTheWindow() {
        let window = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = PanelLayout.promptFrame(size: promptSize, window: window, visible: visible)
        #expect(frame.midX == window.midX)
        #expect(frame.maxY == window.maxY - PanelLayout.promptTopInset)
        #expect(frame.size == promptSize)
    }

    @Test func promptGoesAboveAShortWindow() {
        let window = CGRect(x: 100, y: 300, width: 700, height: 150)
        let frame = PanelLayout.promptFrame(size: promptSize, window: window, visible: visible)
        #expect(frame.minY == window.maxY + PanelLayout.gap)
        #expect(frame.midX == window.midX)
    }

    @Test func promptGoesBelowAShortWindowAtTheTopOfTheScreen() {
        let window = CGRect(x: 100, y: 700, width: 700, height: 150)
        let frame = PanelLayout.promptFrame(size: promptSize, window: window, visible: visible)
        #expect(frame.maxY == window.minY - PanelLayout.gap)
    }

    @Test func promptWithoutAWindowUsesTheUpperScreen() {
        let frame = PanelLayout.promptFrame(size: promptSize, window: nil, visible: visible)
        #expect(frame.midX == visible.midX)
        #expect(frame.minY > visible.midY)
        #expect(visible.contains(frame))
    }

    @Test func promptIgnoresEmptyWindowBounds() {
        let frame = PanelLayout.promptFrame(size: promptSize, window: .zero, visible: visible)
        #expect(frame == PanelLayout.promptFrame(size: promptSize, window: nil, visible: visible))
    }

    @Test func promptIsClampedOnScreen() {
        let window = CGRect(x: -500, y: 100, width: 600, height: 700)
        let frame = PanelLayout.promptFrame(size: promptSize, window: window, visible: visible)
        #expect(frame.minX == visible.minX + PanelLayout.screenMargin)
    }

    @Test func hudSitsNearTheBottomOfTheWindow() {
        let window = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let size = CGSize(width: 380, height: 60)
        let frame = PanelLayout.hudFrame(size: size, window: window, visible: visible)
        #expect(frame.midX == window.midX)
        #expect(frame.minY == window.minY + PanelLayout.hudBottomInset)
    }

    @Test func hudWithoutAWindowUsesTheBottomOfTheScreen() {
        let size = CGSize(width: 380, height: 60)
        let frame = PanelLayout.hudFrame(size: size, window: nil, visible: visible)
        #expect(frame.midX == visible.midX)
        #expect(frame.maxY < visible.midY)
    }

    @Test func hudStaysOnScreenBelowAShortWindowAtTheBottom() {
        let window = CGRect(x: 200, y: 10, width: 500, height: 60)
        let size = CGSize(width: 380, height: 60)
        let frame = PanelLayout.hudFrame(size: size, window: window, visible: visible)
        #expect(frame.minY == visible.minY + PanelLayout.screenMargin)
    }

    @Test func confirmationIsCentredOnTheWindow() {
        let window = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = PanelLayout.centeredFrame(size: CGSize(width: 480, height: 300), window: window, visible: visible)
        #expect(frame == CGRect(x: 360, y: 250, width: 480, height: 300))
    }

    @Test func oversizedFramesPinToTheTopLeft() {
        let small = CGRect(x: 0, y: 0, width: 300, height: 200)
        let frame = PanelLayout.clamp(CGRect(x: 50, y: 50, width: 500, height: 400), to: small)
        #expect(frame.minX == PanelLayout.screenMargin)
        #expect(frame.maxY == small.maxY - PanelLayout.screenMargin)
        #expect(frame.size == CGSize(width: 500, height: 400))
    }

    @Test func picksTheScreenShowingMostOfTheWindow() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let mouse = CGPoint(x: 10, y: 10)
        #expect(PanelLayout.screenIndex(for: CGRect(x: 1500, y: 100, width: 800, height: 600), screenFrames: screens, mouse: mouse) == 1)
        #expect(PanelLayout.screenIndex(for: CGRect(x: 1000, y: 100, width: 600, height: 600), screenFrames: screens, mouse: mouse) == 0)
    }

    @Test func fallsBackToTheScreenWithTheMouse() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let mouse = CGPoint(x: 2000, y: 500)
        #expect(PanelLayout.screenIndex(for: nil, screenFrames: screens, mouse: mouse) == 1)
        #expect(PanelLayout.screenIndex(for: CGRect(x: 9000, y: 9000, width: 10, height: 10), screenFrames: screens, mouse: mouse) == 1)
        #expect(PanelLayout.screenIndex(for: nil, screenFrames: screens, mouse: CGPoint(x: -50, y: -50)) == 0)
        #expect(PanelLayout.screenIndex(for: nil, screenFrames: [], mouse: mouse) == nil)
    }
}
