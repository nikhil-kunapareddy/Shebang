import CoreGraphics
import Foundation
import ShebangCore
import ScreenCaptureKit
import Vision

public enum VisionOCRError: Error, LocalizedError, Equatable {
    case screenRecordingDenied
    case windowUnavailable(String)
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return "Screen Recording permission is required to read on-screen text. Enable Shebang in "
                + "System Settings > Privacy & Security > Screen Recording, then relaunch."
        case .windowUnavailable(let app):
            return "No visible window of \(app) is available for capture."
        case .captureFailed(let reason):
            return "Window capture failed: \(reason)"
        }
    }
}

/// Coordinate conversion between Vision and the Accessibility/CGEvent space.
public enum VisionGeometry {
    /// Vision boxes are normalized (0…1) to the captured image with a bottom-left origin; AX and CGEvent use
    /// global top-left points. The capture covers `windowFrame` exactly, so pixel density (Retina scale)
    /// cancels out of the normalized mapping.
    public static func screenRect(forNormalizedRect box: CGRect, in windowFrame: CGRect) -> CGRect {
        CGRect(
            x: windowFrame.minX + box.minX * windowFrame.width,
            y: windowFrame.minY + (1 - box.maxY) * windowFrame.height,
            width: box.width * windowFrame.width,
            height: box.height * windowFrame.height
        )
    }

    /// A rect in captured-image pixels (top-left origin, e.g. a 2× Retina capture) → global points.
    public static func screenRect(forPixelRect rect: CGRect, imageSize: CGSize, in windowFrame: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scaleX = windowFrame.width / imageSize.width
        let scaleY = windowFrame.height / imageSize.height
        return CGRect(
            x: windowFrame.minX + rect.minX * scaleX,
            y: windowFrame.minY + rect.minY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }

    /// Capture size in pixels for a window of `size` points at `scale` pixels/point, capped at `maxPixels`
    /// on the longest side to bound OCR time and memory.
    public static func captureSize(for size: CGSize, scale: CGFloat, maxPixels: CGFloat = 4096) -> (width: Int, height: Int) {
        let effectiveScale = max(scale, 1)
        let longest = max(size.width, size.height) * effectiveScale
        let factor = longest > maxPixels ? maxPixels / longest : 1
        return (max(1, Int((size.width * effectiveScale * factor).rounded())),
                max(1, Int((size.height * effectiveScale * factor).rounded())))
    }
}

enum OCRMerging {
    /// OCR contributes text regions, never invented controls; text already covered by an overlapping
    /// accessibility control with the same label is dropped.
    static func merging(ocr: [AccessibilityElement], with controls: [AccessibilityElement]) -> [AccessibilityElement] {
        let extra = ocr.filter { text in
            !controls.contains { control in
                control.frame.intersects(text.frame)
                    && control.displayLabel.localizedCaseInsensitiveContains(text.displayLabel)
            }
        }
        return controls + extra
    }
}

/// ScreenCaptureKit window capture + on-device `VNRecognizeTextRequest` (port of `WindowsOcrService`).
public final class VisionOCRService: OCRService, @unchecked Sendable {
    public var minimumConfidence: Float = 0.5
    public var captureTimeout: TimeInterval = 5
    public var maxObservations = 500

    public init() {}

    public func recognizeText(in target: AppTarget) async throws -> [AccessibilityElement] {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else {
            Log.screen.warning("OCR skipped: Screen Recording permission not granted")
            throw VisionOCRError.screenRecordingDenied
        }
        let capture = try await withDeadline(seconds: captureTimeout, message: "Window capture timed out.") {
            try await Self.captureWindow(of: target)
        }
        try Task.checkCancellation()
        return try recognizeText(in: capture.image, windowFrame: capture.frame)
    }

    /// Runs OCR on an image that depicts `windowFrame` (global top-left points) and maps results to screen space.
    public func recognizeText(in image: CGImage, windowFrame: CGRect) throws -> [AccessibilityElement] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        var elements: [AccessibilityElement] = []
        for observation in (request.results ?? []).prefix(maxObservations) {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            elements.append(AccessibilityElement(
                id: "ocr_\(elements.count + 1)",
                role: "OCRText",
                label: SecretSanitizer.sanitize(text),
                frame: VisionGeometry.screenRect(forNormalizedRect: observation.boundingBox, in: windowFrame),
                source: "ocr"
            ))
        }
        Log.screen.info("OCR recognized \(elements.count) text regions")
        return elements
    }

    private struct Capture: @unchecked Sendable {
        let image: CGImage
        let frame: CGRect
    }

    private static func captureWindow(of target: AppTarget) async throws -> Capture {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw VisionOCRError.captureFailed(error.localizedDescription)
        }
        let windows = content.windows.filter { $0.owningApplication?.processID == target.processId }
        let candidates = windows.compactMap { window -> WindowCandidate? in
            guard window.windowLayer == 0, window.frame.width > 1, window.frame.height > 1 else { return nil }
            return WindowCandidate(id: window.windowID, frame: window.frame, title: window.title ?? "", ownerPID: target.processId)
        }
        guard let chosen = WindowList.selectForCapture(candidates, windowNumber: target.windowNumber, expectedFrame: target.windowBounds),
              let window = windows.first(where: { $0.windowID == chosen.id }) else {
            throw VisionOCRError.windowUnavailable(target.processName)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let size = VisionGeometry.captureSize(for: window.frame.size, scale: CGFloat(filter.pointPixelScale))
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return Capture(image: image, frame: window.frame)
        } catch {
            throw VisionOCRError.captureFailed(error.localizedDescription)
        }
    }
}
