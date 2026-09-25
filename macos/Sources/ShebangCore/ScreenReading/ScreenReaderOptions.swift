public struct ScreenReaderOptions: Sendable, Equatable {
    public var maxNodes = 500
    public var maxDepth = 30
    public var maxCandidates = 40
    public var ocrFallbackThreshold = 0
    public var filterOffscreen = true
    public var filterDisabled = false

    public init() {}

    public static let `default` = ScreenReaderOptions()
}
