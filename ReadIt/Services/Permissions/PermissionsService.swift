import AppKit
import ApplicationServices
import Foundation

enum PermissionsService {
    private static var didPromptThisSession = false

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Current running app path — useful when System Settings lists several stale ReadIt builds.
    static var currentAppPath: String {
        Bundle.main.bundlePath
    }

    @discardableResult
    static func requestAccessibilityIfNeeded(prompt: Bool = true) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard prompt else { return false }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        // macOS 13+ deep link; fall back to legacy pane id.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    /// Non-blocking: triggers the system TCC prompt at most once per launch and opens Settings.
    @MainActor
    static func nudgeAccessibilityPermission() {
        guard !isAccessibilityTrusted else { return }
        guard !didPromptThisSession else { return }
        didPromptThisSession = true

        // Registers *this* binary with TCC (critical after Xcode rebuilds).
        _ = requestAccessibilityIfNeeded(prompt: true)
        openAccessibilitySettings()
    }

    @MainActor
    static func presentAccessibilityAlertIfNeeded() {
        // Prefer non-modal nudge — modal alerts steal focus and dismiss the ReadIt UI.
        nudgeAccessibilityPermission()
    }

    /// Poll briefly after the user returns from System Settings.
    @MainActor
    static func waitUntilTrusted(timeout: TimeInterval = 8) async -> Bool {
        if isAccessibilityTrusted { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if AXIsProcessTrusted() { return true }
        }
        return AXIsProcessTrusted()
    }
}
