import ApplicationServices
import CoreGraphics
import Foundation
import ShebangCore

public enum ScreenReaderError: Error, LocalizedError, Equatable {
    case invalidTarget(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTarget(let reason): return reason
        }
    }
}

/// Reads the target app's focused window through the Accessibility API (port of `UiaScreenReader`).
/// Missing Accessibility permission, hung apps, and empty trees degrade to OCR or an empty list — never a crash or hang.
public final class AXScreenReader: ScreenReader, @unchecked Sendable {
    private let options: ScreenReaderOptions
    private let ocr: OCRService?
    private let registry: AXElementRegistry
    private let ax: AXBackend
    private let clock: Clock
    private let isChromiumBased: (AppTarget) -> Bool
    private let lock = NSLock()
    private var webAccessibilityEnabledPIDs: Set<Int32> = []
    private var warnedUntrusted = false
    /// Wall-clock budget for one tree walk.
    var walkTimeBudget: TimeInterval = 2.0
    /// One-time pause after asking Chromium to build its web tree.
    var webTreeSettleSeconds: TimeInterval = 0.3
    /// Pause before the single retry of an empty walk (fresh web tree or unresponsive app).
    var retryDelaySeconds: TimeInterval = 0.5

    public convenience init(
        options: ScreenReaderOptions = .default,
        ocr: OCRService? = VisionOCRService(),
        registry: AXElementRegistry = .shared
    ) {
        self.init(options: options, ocr: ocr, registry: registry, ax: LiveAXBackend.shared, clock: SystemClock(),
                  isChromiumBased: ChromiumDetector.isChromiumBased)
    }

    init(
        options: ScreenReaderOptions,
        ocr: OCRService?,
        registry: AXElementRegistry,
        ax: AXBackend,
        clock: Clock,
        isChromiumBased: @escaping (AppTarget) -> Bool
    ) {
        self.options = options
        self.ocr = ocr
        self.registry = registry
        self.ax = ax
        self.clock = clock
        self.isChromiumBased = isChromiumBased
    }

    public func readElements(target: AppTarget) async throws -> [AccessibilityElement] {
        try Task.checkCancellation()
        guard target.processId > 0 else {
            throw ScreenReaderError.invalidTarget(
                "Cannot read screen: invalid process id \(target.processId) for '\(target.processName)'.")
        }

        var raw: [AccessibilityElement] = []
        var handles: [AXUIElement] = []

        if ax.isTrusted {
            let app = ax.applicationElement(pid: target.processId)
            let justEnabledWebTree = try await enableWebAccessibilityIfNeeded(app: app, target: target)
            if let root = ax.windowRoot(of: app) {
                var walker = AXTreeWalker(backend: ax, options: options)
                walker.timeBudget = walkTimeBudget
                let clip = ax.frame(of: root) ?? (target.windowBounds.isEmpty ? nil : target.windowBounds)
                var result = try walker.walk(root: root, clipFrame: clip)
                // Chromium rebuilds its tree right after opting in and briefly stops answering; retry once.
                if result.elements.isEmpty, justEnabledWebTree || result.stopReason == "unresponsive" {
                    try await clock.sleep(seconds: retryDelaySeconds)
                    result = try walker.walk(root: root, clipFrame: clip)
                }
                raw = result.elements
                handles = result.handles
                Log.screen.info("""
                    AX walk \(target.processName, privacy: .public): \(raw.count) elements, visited \(result.visited), \
                    secure skipped \(result.skippedSecure), stop \(result.stopReason ?? "complete", privacy: .public)
                    """)
            } else {
                Log.screen.warning("AX: no window available for \(target.processName, privacy: .public)")
            }
        } else {
            let shouldWarn = lock.withLock { () -> Bool in
                defer { warnedUntrusted = true }
                return !warnedUntrusted
            }
            if shouldWarn {
                Log.screen.warning("Accessibility permission not granted; skipping the AX tree (OCR fallback only)")
            }
        }

        // Tag AX elements so they can be traced back to their AXUIElement after ranking reassigns ids.
        for index in raw.indices { raw[index].id = "ax_\(index)" }

        let interactiveCount = raw.filter { ElementRanker.isInteractive($0.role) }.count
        let needsOCR = raw.isEmpty
            || (options.ocrFallbackThreshold > 0 && interactiveCount < options.ocrFallbackThreshold)
        if needsOCR, let ocr {
            Log.screen.info("Interactive AX element count (\(interactiveCount)) requires OCR fallback")
            do {
                let ocrElements = try await ocr.recognizeText(in: target)
                raw = OCRMerging.merging(ocr: ocrElements, with: raw)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.screen.warning("OCR fallback failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        try Task.checkCancellation()
        let ranked = ElementRanker.rankAndFilter(raw, options: options)
        registry.replaceAll(Self.registryMapping(ranked: ranked, raw: raw, handles: handles))
        return ranked
    }

    /// Chromium/Electron apps expose their web tree only after an assistive client opts in; done once per
    /// process. Returns whether the flags were set by this call.
    private func enableWebAccessibilityIfNeeded(app: AXUIElement, target: AppTarget) async throws -> Bool {
        let alreadyEnabled = lock.withLock { webAccessibilityEnabledPIDs.contains(target.processId) }
        guard !alreadyEnabled, isChromiumBased(target) else { return false }
        let manual = ax.setBool("AXManualAccessibility", true, on: app)
        let enhanced = ax.setBool("AXEnhancedUserInterface", true, on: app)
        // A busy, just-launched app can time out both writes; try again on the next read.
        guard manual || enhanced else { return false }
        lock.withLock { _ = webAccessibilityEnabledPIDs.insert(target.processId) }
        Log.screen.info("Enabled web accessibility for \(target.processName, privacy: .public) (manual \(manual), enhanced \(enhanced))")
        try await clock.sleep(seconds: webTreeSettleSeconds)
        return true
    }

    /// Maps ranked ids (e1…eN) back to AXUIElements. `ElementRanker` sorts stably, so identical elements keep
    /// their relative order and matching the first unused raw element with equal content is exact.
    static func registryMapping(
        ranked: [AccessibilityElement],
        raw: [AccessibilityElement],
        handles: [AXUIElement]
    ) -> [String: AXUIElement] {
        var queues: [ElementKey: [AXUIElement]] = [:]
        for element in raw where element.source == "accessibility" {
            guard element.id.hasPrefix("ax_"), let index = Int(element.id.dropFirst(3)), index < handles.count else { continue }
            queues[ElementKey(element), default: []].append(handles[index])
        }
        var mapping: [String: AXUIElement] = [:]
        for element in ranked where element.source == "accessibility" {
            let key = ElementKey(element)
            guard var queue = queues[key], !queue.isEmpty else { continue }
            mapping[element.id] = queue.removeFirst()
            queues[key] = queue
        }
        return mapping
    }

    private struct ElementKey: Hashable {
        let role: String
        let label: String
        let value: String
        let enabled: Bool
        let focused: Bool
        let frame: [CGFloat]
        let actions: [String]

        init(_ element: AccessibilityElement) {
            role = element.role
            label = element.label
            value = element.value
            enabled = element.enabled
            focused = element.focused
            frame = [element.frame.minX, element.frame.minY, element.frame.width, element.frame.height]
            actions = element.actions
        }
    }
}
