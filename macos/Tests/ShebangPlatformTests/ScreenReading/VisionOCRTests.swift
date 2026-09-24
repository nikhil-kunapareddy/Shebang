import CoreGraphics
import CoreText
import Foundation
import ShebangCore
import Testing
@testable import ShebangPlatform

@Suite struct VisionGeometryTests {
    @Test func fullImageMapsToWindowFrame() {
        let window = CGRect(x: 100, y: 50, width: 1000, height: 500)
        #expect(VisionGeometry.screenRect(forNormalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), in: window) == window)
    }

    @Test func flipsBottomLeftNormalizedBoxToTopLeftScreenPoints() {
        let window = CGRect(x: 100, y: 50, width: 1000, height: 500)
        // Box near the top-left of the image: Vision's y is measured from the bottom.
        let box = CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1)
        let rect = VisionGeometry.screenRect(forNormalizedRect: box, in: window)
        #expect(abs(rect.minX - 200) < 0.001)
        #expect(abs(rect.minY - 150) < 0.001)
        #expect(abs(rect.width - 200) < 0.001)
        #expect(abs(rect.height - 50) < 0.001)
    }

    @Test func handlesDisplaysLeftOfAndAbovePrimary() {
        let window = CGRect(x: -1920, y: -300, width: 1000, height: 800)
        let rect = VisionGeometry.screenRect(forNormalizedRect: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), in: window)
        #expect(rect == CGRect(x: -1920, y: -300, width: 500, height: 400))
    }

    @Test func captureSizeUsesBackingScaleAndCapsLongestSide() {
        #expect(VisionGeometry.captureSize(for: CGSize(width: 1000, height: 800), scale: 2) == (2000, 1600))
        #expect(VisionGeometry.captureSize(for: CGSize(width: 1000, height: 800), scale: 0) == (1000, 800))
        let capped = VisionGeometry.captureSize(for: CGSize(width: 3000, height: 2000), scale: 2)
        #expect(capped.width == 4096)
        #expect(capped.height == 2731)
    }
}

@Suite struct OCRMergingTests {
    private func element(_ id: String, _ label: String, role: String = "AXButton", source: String = "accessibility", x: CGFloat = 20) -> AccessibilityElement {
        AccessibilityElement(id: id, role: role, label: label, frame: CGRect(x: x, y: 20, width: 100, height: 30), source: source)
    }

    @Test func preservesControlsAndAddsDistinctTextRegions() {
        let controls = [element("ax_0", "Save")]
        let ocr = [element("ocr_1", "Save", role: "OCRText", source: "ocr"),
                   element("ocr_2", "Cancel", role: "OCRText", source: "ocr", x: 150)]
        let result = OCRMerging.merging(ocr: ocr, with: controls)
        #expect(result.map(\.id) == ["ax_0", "ocr_2"])
        #expect(result[1].role == "OCRText")
        #expect(result[1].source == "ocr")
        #expect(result[1].actions.isEmpty)
    }

    @Test func sameLabelAtDifferentLocationIsKept() {
        let result = OCRMerging.merging(ocr: [element("ocr_1", "Save", role: "OCRText", source: "ocr", x: 300)],
                                        with: [element("ax_0", "Save")])
        #expect(result.count == 2)
    }
}

@Suite struct VisionOCRServiceTests {
    /// Renders black text on white at `scale` pixels per point (bottom-left CG origin).
    private func render(_ text: String, size: CGSize, scale: CGFloat) throws -> CGImage {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 40, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 80)
        CTLineDraw(line, context)
        return try #require(context.makeImage())
    }

    // A known bitmap yields text, role, source, and screen-space bounds.
    @Test func recognizesRenderedTextAndMapsToScreen() throws {
        let window = CGRect(x: -1000, y: 200, width: 600, height: 200)
        let results = try VisionOCRService().recognizeText(in: try render("Shebang Test", size: window.size, scale: 1),
                                                           windowFrame: window)
        let text = try #require(results.first { $0.label.contains("Shebang") })
        #expect(text.role == "OCRText")
        #expect(text.source == "ocr")
        #expect(text.id.hasPrefix("ocr_"))
        #expect(text.actions.isEmpty)
        #expect(window.contains(text.frame))
        #expect(text.frame.width > 0 && text.frame.height > 0)
        // Drawn with its baseline 80 pt above the bottom of a 200 pt image → roughly 70–125 pt from the top.
        #expect(text.frame.minY > window.minY + 50 && text.frame.maxY < window.minY + 135)
    }

    @Test func retinaCaptureMapsToSamePoints() throws {
        let window = CGRect(x: 300, y: 100, width: 600, height: 200)
        let service = VisionOCRService()
        let standard = try service.recognizeText(in: try render("Retina Check", size: window.size, scale: 1), windowFrame: window)
        let retina = try service.recognizeText(in: try render("Retina Check", size: window.size, scale: 2), windowFrame: window)
        let a = try #require(standard.first { $0.label.contains("Retina") }).frame
        let b = try #require(retina.first { $0.label.contains("Retina") }).frame
        #expect(abs(a.midX - b.midX) < 6)
        #expect(abs(a.midY - b.midY) < 6)
    }

    @Test func recognizedSecretsAreSanitized() throws {
        let window = CGRect(x: 0, y: 0, width: 900, height: 200)
        let results = try VisionOCRService().recognizeText(in: try render("4111 2222 3333 4444", size: window.size, scale: 2),
                                                           windowFrame: window)
        #expect(!results.contains { $0.label.contains("4111 2222 3333 4444") })
    }

    @Test func errorsExplainTheRemedy() {
        #expect(VisionOCRError.screenRecordingDenied.localizedDescription.contains("Screen Recording"))
        #expect(VisionOCRError.windowUnavailable("Notes").localizedDescription.contains("Notes"))
    }
}
