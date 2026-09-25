import ApplicationServices
import CoreGraphics
import Foundation
import ShebangCore
import Testing
@testable import ShebangPlatform

@Suite struct AXScreenReaderTests {
    let pid: Int32 = 4242
    var target: AppTarget {
        AppTarget(processId: pid, processName: "FakeApp", bundleIdentifier: "com.example.fake",
                  windowTitle: "Main", windowBounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
    }

    private func makeReader(
        _ ax: FakeAXBackend,
        ocr: OCRService? = nil,
        options: ScreenReaderOptions = .default,
        registry: AXElementRegistry = AXElementRegistry(),
        chromium: Bool = false
    ) -> AXScreenReader {
        AXScreenReader(options: options, ocr: ocr, registry: registry, ax: ax, clock: InstantClock(),
                       isChromiumBased: { _ in chromium })
    }

    private func frame(_ index: Int) -> CGRect {
        CGRect(x: 10, y: 10 + index * 30, width: 120, height: 24)
    }

    // Controls keep raw AX roles, labels and values; secure fields never appear.
    @Test func readsControlsWithRoleLabelAndValueAndNeverPasswords() async throws {
        let ax = FakeAXBackend()
        let window = ax.window(pid: pid)
        ax.add("AXButton", title: "Submit Button", frame: frame(0), actions: ["AXPress"], to: window)
        ax.add("AXTextField", value: "Sample Document Text", frame: frame(1), to: window)
        ax.add("AXTextField", subrole: "AXSearchField", placeholder: "Search", frame: frame(2), to: window)
        ax.add("AXSecureTextField", title: "Password", value: "SecretUserPassword", frame: frame(3), to: window)

        let elements = try await makeReader(ax).readElements(target: target)

        #expect(elements.contains { $0.role == "AXButton" && $0.label == "Submit Button" && $0.actions == ["AXPress"] })
        #expect(elements.contains { $0.role == "AXTextField" && $0.value == "Sample Document Text" })
        #expect(elements.contains { $0.role == "AXSearchField" && $0.label == "Search" })
        #expect(!elements.contains { $0.role.contains("Secure") || $0.label == "Password" })
        #expect(!elements.contains { $0.value.contains("SecretUserPassword") })
        #expect(elements.map(\.id) == (1...elements.count).map { "e\($0)" })
        #expect(elements.allSatisfy { $0.source == "accessibility" })
    }

    @Test func secureFieldsAreSkippedWithoutReadingValueOrChildren() async throws {
        let ax = FakeAXBackend()
        let window = ax.window(pid: pid)
        let secure = ax.add("AXSecureTextField", value: "hunter2", frame: frame(0), to: window)
        let secureSubrole = ax.add("AXTextField", subrole: "AXSecureTextField", value: "hunter3", frame: frame(1), to: window)
        let inner = ax.add("AXStaticText", value: "inner secret", frame: frame(1), to: secureSubrole)
        ax.add("AXButton", title: "Sign In", frame: frame(2), actions: ["AXPress"], to: window)

        let elements = try await makeReader(ax).readElements(target: target)

        #expect(elements.map(\.label) == ["Sign In"])
        #expect(!ax.valueReads.contains(secure))
        #expect(!ax.valueReads.contains(secureSubrole))
        #expect(!ax.valueReads.contains(inner))
    }

    @Test func sanitizesSecretsInLabelsAndValues() async throws {
        let ax = FakeAXBackend()
        let window = ax.window(pid: pid)
        ax.add("AXStaticText", value: "Card 4111 2222 3333 4444 on file", frame: frame(0), to: window)
        ax.add("AXButton", title: "Copy vck_dummy_test_key_sample1234567890abcdef", frame: frame(1),
               actions: ["AXPress"], to: window)

        let elements = try await makeReader(ax).readElements(target: target)
        let text = elements.map { $0.label + " " + $0.value }.joined(separator: "\n")

        #expect(!text.contains("4111 2222 3333 4444"))
        #expect(text.contains("[REDACTED_CARD]"))
        #expect(!text.contains("vck_dummy_test_key_sample1234567890abcdef"))
        #expect(text.contains("[REDACTED_KEY]"))
    }

    @Test func skipsLayoutAndUnlabelledContainersButKeepsControls() async throws {
        let ax = FakeAXBackend()
        let window = ax.window(pid: pid)
        let scroll = ax.add("AXScrollArea", description: "content", frame: frame(0), to: window)
        let group = ax.add("AXGroup", frame: frame(0), to: scroll)
        ax.add("AXGroup", description: "Decorative section", frame: frame(1), to: group)
        ax.add("AXGroup", description: "Open conversation", frame: frame(2), actions: ["AXPress"], to: group)
        ax.add("AXImage", frame: frame(3), to: group)
        let link = ax.add("AXLink", frame: frame(4), actions: ["AXPress"], to: group)
        ax.add("AXStaticText", value: "Pricing", frame: frame(4), to: link)

        let elements = try await makeReader(ax).readElements(target: target)
        let labels = elements.map(\.displayLabel)

        #expect(!elements.contains { $0.role == "AXScrollArea" || $0.role == "AXImage" })
        #expect(!labels.contains("Decorative section"))
        #expect(elements.contains { $0.role == "AXGroup" && $0.label == "Open conversation" })
        // An unlabelled link takes its name from its first descendant text.
        #expect(elements.contains { $0.role == "AXLink" && $0.label == "Pricing" })
    }

    @Test func registryResolvesEveryRankedAccessibilityElement() async throws {
        let ax = FakeAXBackend()
        let window = ax.window(pid: pid)
        for index in 0..<25 {
            ax.add(index.isMultiple(of: 2) ? "AXButton" : "AXStaticText",
                   title: index.isMultiple(of: 2) ? "Button \(index)" : nil,
                   value: index.isMultiple(of: 2) ? nil : "Text \(index)",
                   frame: frame(index), actions: index.isMultiple(of: 2) ? ["AXPress"] : [], to: window)
        }
        let registry = AXElementRegistry()
        let elements = try await makeReader(ax, registry: registry).readElements(target: target)

        #expect(elements.count == 25)
        #expect(Set(elements.compactMap { registry.element(for: $0.id) }).count == 25)
        for element in elements {
            let handle = try #require(registry.element(for: element.id))
            let node = try #require(ax.node(handle))
            #expect((node.snapshot.title ?? node.value) == element.displayLabel)
        }
    }

    @Test func mappingIsExactForIdenticalElements() {
        let handles = (0..<3).map { AXUIElementCreateApplication(2_100_002_000 + Int32($0)) }
        let same = AccessibilityElement(id: "", role: "AXButton", label: "Delete", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        var raw = [same, same, same]
        for index in raw.indices { raw[index].id = "ax_\(index)" }
        let ranked = ElementRanker.rankAndFilter(raw, options: .default)
        let mapping = AXScreenReader.registryMapping(ranked: ranked, raw: raw, handles: handles)
        #expect(mapping["e1"] == handles[0])
        #expect(mapping["e2"] == handles[1])
        #expect(mapping["e3"] == handles[2])
    }

    @Test func enforcesMaxDepth() async throws {
        let ax = FakeAXBackend()
        var parent = ax.window(pid: pid)
        for _ in 0..<40 { parent = ax.add("AXGroup", frame: frame(0), to: parent) }
        ax.add("AXButton", title: "Too Deep", frame: frame(1), actions: ["AXPress"], to: parent)

        let deep = try await makeReader(ax).readElements(target: target)
        #expect(deep.isEmpty)

        var shallowOptions = ScreenReaderOptions()
        shallowOptions.maxDepth = 50
        let found = try await makeReader(ax, options: shallowOptions).readElements(target: target)
        #expect(found.map(\.label) == ["Too Deep"])
    }

    @Test func enforcesNodeAndVisitCaps() async throws {
        let ax = FakeAXBackend()
        let window = ax.window(pid: pid)
        for index in 0..<100 {
            ax.add("AXButton", title: "Button \(index)", frame: frame(index % 20), actions: ["AXPress"], to: window)
        }
        var options = ScreenReaderOptions()
        options.maxNodes = 20
        let capped = try await makeReader(ax, options: options).readElements(target: target)
        #expect(capped.count == 20)

        // Unlabelled noise before the only control: the visit cap (6 × maxNodes) stops the walk first.
        let noisy = FakeAXBackend()
        let noisyWindow = noisy.window(pid: pid)
        for _ in 0..<500 { noisy.add("AXGroup", frame: frame(0), to: noisyWindow) }
        noisy.add("AXButton", title: "Hidden", frame: frame(1), actions: ["AXPress"], to: noisyWindow)
        options.maxNodes = 10
        let limited = try await makeReader(noisy, options: options).readElements(target: target)
        #expect(limited.isEmpty)
        #expect(noisy.snapshotReads <= 61)
    }

    @Test func filtersControlsScrolledOutsideTheWindow() async throws {
        let ax = FakeAXBackend()
        let window = ax.window(pid: pid, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        ax.add("AXButton", title: "Visible", frame: frame(0), actions: ["AXPress"], to: window)
        ax.add("AXButton", title: "Below the fold", frame: CGRect(x: 10, y: 2000, width: 100, height: 20),
               actions: ["AXPress"], to: window)

        let filtered = try await makeReader(ax).readElements(target: target)
        #expect(filtered.map(\.label) == ["Visible"])

        var options = ScreenReaderOptions()
        options.filterOffscreen = false
        let unfiltered = try await makeReader(ax, options: options).readElements(target: target)
        #expect(Set(unfiltered.map(\.label)) == ["Visible", "Below the fold"])
    }

    @Test func missingAccessibilityPermissionFallsBackToOCR() async throws {
        let ax = FakeAXBackend()
        ax.isTrusted = false
        let window = ax.window(pid: pid)
        ax.add("AXButton", title: "Unreachable", frame: frame(0), actions: ["AXPress"], to: window)
        let ocr = FakeOCRService()
        ocr.result = .success([AccessibilityElement(id: "ocr_1", role: "OCRText", label: "Welcome", frame: frame(2), source: "ocr")])
        let registry = AXElementRegistry()

        let elements = try await makeReader(ax, ocr: ocr, registry: registry).readElements(target: target)

        #expect(ax.snapshotReads == 0)
        #expect(ocr.calls == 1)
        #expect(elements.map(\.label) == ["Welcome"])
        #expect(elements.first?.id == "e1")
        #expect(registry.element(for: "e1") == nil)
    }

    @Test func ocrOnlyRunsWhenTheTreeIsEmptyOrBelowThreshold() async throws {
        let ax = FakeAXBackend()
        let window = ax.window(pid: pid)
        ax.add("AXButton", title: "Save", frame: CGRect(x: 20, y: 20, width: 100, height: 30), actions: ["AXPress"], to: window)
        let ocr = FakeOCRService()
        ocr.result = .success([
            AccessibilityElement(id: "ocr_1", role: "OCRText", label: "Save", frame: CGRect(x: 20, y: 20, width: 100, height: 30), source: "ocr"),
            AccessibilityElement(id: "ocr_2", role: "OCRText", label: "Cancel", frame: CGRect(x: 150, y: 20, width: 100, height: 30), source: "ocr"),
        ])

        _ = try await makeReader(ax, ocr: ocr).readElements(target: target)
        #expect(ocr.calls == 0)

        var options = ScreenReaderOptions()
        options.ocrFallbackThreshold = 3
        let merged = try await makeReader(ax, ocr: ocr, options: options).readElements(target: target)
        #expect(ocr.calls == 1)
        // The OCR "Save" duplicates the button; only the distinct "Cancel" region is added.
        #expect(merged.count == 2)
        #expect(merged.contains { $0.role == "AXButton" && $0.label == "Save" })
        #expect(merged.contains { $0.role == "OCRText" && $0.label == "Cancel" && $0.source == "ocr" })
    }

    @Test func ocrFailuresAreSwallowed() async throws {
        let ax = FakeAXBackend()
        ax.window(pid: pid)
        let ocr = FakeOCRService()
        ocr.result = .failure(VisionOCRError.screenRecordingDenied)
        let elements = try await makeReader(ax, ocr: ocr).readElements(target: target)
        #expect(elements.isEmpty)
        #expect(ocr.calls == 1)
    }

    // An invalid target is rejected with a clear message.
    @Test func invalidProcessIdIsRejected() async {
        let reader = makeReader(FakeAXBackend())
        let invalid = AppTarget(processId: 0, processName: "System", windowTitle: "Invalid")
        await #expect(throws: ScreenReaderError.self) { try await reader.readElements(target: invalid) }
        do {
            _ = try await reader.readElements(target: invalid)
        } catch {
            #expect(error.localizedDescription.contains("invalid process id"))
        }
    }

    @Test func chromiumAppsGetWebAccessibilityEnabledOnce() async throws {
        let ax = FakeAXBackend()
        ax.window(pid: pid)
        let reader = makeReader(ax, chromium: true)
        _ = try await reader.readElements(target: target)
        _ = try await reader.readElements(target: target)

        let app = ax.app(pid: pid)
        let flags = ax.setBools.filter { $0.element == app }
        #expect(flags.map(\.attribute) == ["AXManualAccessibility", "AXEnhancedUserInterface"])
        #expect(flags.allSatisfy { $0.value })

        let plain = FakeAXBackend()
        plain.window(pid: pid)
        _ = try await makeReader(plain, chromium: false).readElements(target: target)
        #expect(plain.setBools.isEmpty)
    }

    @Test func unresponsiveAppStopsTheWalkAfterOneRetry() async throws {
        let ax = FakeAXBackend()
        let window = ax.window(pid: pid)
        ax.setReadResult(.timedOut, for: window)
        let ocr = FakeOCRService()
        let clock = InstantClock()
        let reader = AXScreenReader(options: .default, ocr: ocr, registry: AXElementRegistry(), ax: ax, clock: clock,
                                    isChromiumBased: { _ in false })
        let elements = try await reader.readElements(target: target)
        #expect(elements.isEmpty)
        #expect(ax.snapshotReads == 2)  // root timed out, retried once
        #expect(clock.sleeps == [0.5])
        #expect(ocr.calls == 1)

        let busy = FakeAXBackend()
        let busyWindow = busy.window(pid: pid)
        for index in 0..<10 {
            let child = busy.add("AXButton", title: "B\(index)", frame: frame(index), actions: ["AXPress"], to: busyWindow)
            busy.setReadResult(.timedOut, for: child)
        }
        _ = try await makeReader(busy).readElements(target: target)
        #expect(busy.snapshotReads == 8)  // (window + three timeouts) per walk, two walks
    }

    @Test func freshWebTreeIsRetriedOnce() async throws {
        let ax = FakeAXBackend()
        let window = ax.window(pid: pid)
        ax.add("AXButton", title: "Subscribe", frame: frame(0), actions: ["AXPress"], to: window)
        ax.setTransientTimeouts(1, for: window)
        let clock = InstantClock()
        let reader = AXScreenReader(options: .default, ocr: nil, registry: AXElementRegistry(), ax: ax, clock: clock,
                                    isChromiumBased: { _ in true })
        let elements = try await reader.readElements(target: target)
        #expect(elements.map(\.label) == ["Subscribe"])
        #expect(clock.sleeps == [0.3, 0.5])
    }

    @Test func cancellationIsHonoured() async {
        let ax = FakeAXBackend()
        let window = ax.window(pid: pid)
        for index in 0..<50 { ax.add("AXButton", title: "B\(index)", frame: frame(index % 20), actions: ["AXPress"], to: window) }
        let reader = makeReader(ax)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.readElements(target: target)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func truncatesHugeValuesAtWordBoundaries() {
        let text = String(repeating: "word ", count: 400) + "sk-" + String(repeating: "a", count: 40)
        let truncated = AXRoleMapper.truncated(text, limit: 1000)
        #expect(truncated.count <= 1001)
        #expect(truncated.hasSuffix("…"))
        #expect(!truncated.contains("sk-"))
        #expect(AXRoleMapper.truncated("short") == "short")
    }

    @Test func roleMappingKeepsRawAXRoles() {
        #expect(AXRoleMapper.elementRole(role: "AXButton", subrole: "AXCloseButton") == "AXButton")
        #expect(AXRoleMapper.elementRole(role: "AXTextField", subrole: "AXSearchField") == "AXSearchField")
        #expect(AXRoleMapper.elementRole(role: "", subrole: nil) == "AXUnknown")
        #expect(AXRoleMapper.isSecure(role: "AXSecureTextField", subrole: nil))
        #expect(AXRoleMapper.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
        #expect(!AXRoleMapper.isSecure(role: "AXTextField", subrole: nil))
        #expect(ElementRanker.isInteractive(AXRoleMapper.elementRole(role: "AXTextField", subrole: "AXSearchField")))
    }

    @Test func labelPrefersTitleThenDescriptionThenPlaceholder() {
        #expect(AXRoleMapper.label(for: AXNodeSnapshot(role: "AXButton", title: " ", description: "Close")) == "Close")
        #expect(AXRoleMapper.label(for: AXNodeSnapshot(role: "AXTextField", placeholder: "Search")) == "Search")
        #expect(AXRoleMapper.label(for: AXNodeSnapshot(role: "AXButton", title: "OK", description: "Confirm")) == "OK")
    }

    @Test func decodesAXGeometryValues() {
        var point = CGPoint(x: -1200, y: 25)
        var size = CGSize(width: 300, height: 40)
        let position = AXValueCreate(.cgPoint, &point)
        let dimensions = AXValueCreate(.cgSize, &size)
        #expect(AXDecoding.frame(position: position, size: dimensions) == CGRect(x: -1200, y: 25, width: 300, height: 40))
        #expect(AXDecoding.frame(position: dimensions, size: position) == nil)
        #expect(AXDecoding.stringOrNumber(NSNumber(value: 1)) == "1")
        #expect(AXDecoding.stringOrNumber("text" as NSString) == "text")
    }
}
