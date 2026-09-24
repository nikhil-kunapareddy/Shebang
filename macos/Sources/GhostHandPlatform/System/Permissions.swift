import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import GhostHandCore
import Speech

/// TCC permission checks and prompts. Every call is safe without the permission: checks return
/// false, and prompts that would crash a process lacking the Info.plist usage string are skipped.
public enum Permissions {
    public enum Pane: CaseIterable, Sendable {
        case accessibility, screenRecording, microphone, speechRecognition

        public var settingsURL: URL {
            let anchor: String
            switch self {
            case .accessibility: anchor = "Privacy_Accessibility"
            case .screenRecording: anchor = "Privacy_ScreenCapture"
            case .microphone: anchor = "Privacy_Microphone"
            case .speechRecognition: anchor = "Privacy_SpeechRecognition"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility prompt (once per app identity) and returns immediately.
    public static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    public static var isMicrophoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static var isSpeechRecognitionAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    public static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            guard hasUsageDescription("NSMicrophoneUsageDescription") else { return false }
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    public static func requestSpeechRecognition() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            guard hasUsageDescription("NSSpeechRecognitionUsageDescription") else { return false }
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    public static func openSystemSettings(_ pane: Pane) {
        if !NSWorkspace.shared.open(pane.settingsURL) {
            Log.app.error("Could not open System Settings pane \(pane.settingsURL.absoluteString, privacy: .public)")
        }
    }

    /// TCC terminates a process that requests a privacy permission without the matching usage string.
    static func hasUsageDescription(_ key: String, bundle: Bundle = .main) -> Bool {
        if let text = bundle.object(forInfoDictionaryKey: key) as? String, !text.isEmpty { return true }
        Log.app.error("Missing \(key, privacy: .public) in Info.plist; not requesting the permission")
        return false
    }
}
