import AppKit
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let preferences = AppPreferences.shared
    let engine: TTSEngine
    let hotkeyManager = GlobalHotkeyManager()
    let overlay = OverlayPanelController()

    private var cancellables = Set<AnyCancellable>()
    private var didAskAccessibility = false
    private var settingsCloseObserver: NSObjectProtocol?
    private var lastHotkeyFire = Date.distantPast

    init() {
        engine = TTSEngine(preferences: AppPreferences.shared)
        overlay.configure(engine: engine, preferences: preferences)

        hotkeyManager.setHandler { [weak self] in
            self?.handleHotkey()
        }

        engine.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.overlay.updateVisibility(for: snapshot.status)
            }
            .store(in: &cancellables)

        syncHotkey()
    }

    func bootstrap() {
        NSApp.setActivationPolicy(.accessory)
        // Repair bad state from earlier Edge catalog failures (e.g. Apple "Bad News" novelty voice).
        if preferences.provider == .edgeTTS,
           !preferences.voiceID.contains("Neural"),
           preferences.voiceID != TTSVoice.edgeAva.id {
            preferences.applyVoice(.edgeAva)
        }
        syncHotkey()
        Task {
            await engine.refreshVoices()
        }
    }

    func syncHotkey() {
        if preferences.isEnabled && preferences.hasHotkey {
            hotkeyManager.register(
                keyCode: preferences.hotkeyKeyCode,
                modifiers: preferences.hotkeyModifiers,
                enabled: true
            )
        } else {
            hotkeyManager.unregister()
        }
    }

    /// Menubar accessory apps must become `.regular` before a Settings window can appear.
    func openSettings() {
        observeSettingsWindowCloseIfNeeded()

        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        // showSettingsWindow: is what SwiftUI's Settings scene responds to.
        let shown = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if !shown {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }

        // Settings is created asynchronously — keep bumping it forward briefly.
        for delay in [0.0, 0.05, 0.15, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.bringSettingsWindowForward()
            }
        }
    }

    func bringSettingsWindowForward() {
        // Prefer an obvious Settings window; otherwise any titled non-panel window.
        let settingsWindow = NSApp.windows.first(where: isSettingsWindow)
            ?? NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.isVisible })

        guard let settingsWindow else { return }
        settingsWindow.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        settingsWindow.level = .normal
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window))
        let title = window.title
        return className.localizedCaseInsensitiveContains("settings")
            || window.frameAutosaveName.localizedCaseInsensitiveContains("settings")
            || title.localizedCaseInsensitiveContains("settings")
            || title.localizedCaseInsensitiveContains("read aloud")
            || title.localizedCaseInsensitiveContains("preferences")
            || title.localizedCaseInsensitiveContains("readit")
    }

    private func observeSettingsWindowCloseIfNeeded() {
        guard settingsCloseObserver == nil else { return }
        settingsCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            Task { @MainActor in
                guard let self, let window, self.isSettingsWindow(window) || window.styleMask.contains(.titled) else {
                    return
                }
                let hasOtherTitled = NSApp.windows.contains {
                    $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
                }
                if !hasOtherTitled {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func handleHotkey() {
        let now = Date()
        guard now.timeIntervalSince(lastHotkeyFire) > 0.4 else { return }
        lastHotkeyFire = now

        NSLog("ReadIt: hotkey fired (trusted=%d)", PermissionsService.isAccessibilityTrusted ? 1 : 0)
        guard preferences.isEnabled else {
            NSLog("ReadIt: ignored — feature disabled")
            return
        }

        if engine.snapshot.status == .playing || engine.snapshot.status == .paused {
            engine.toggleOrSpeak(text: engine.snapshot.text)
            return
        }

        if !PermissionsService.isAccessibilityTrusted {
            // Don't block with a modal — it closes the pill/settings and feels broken.
            PermissionsService.nudgeAccessibilityPermission()
            engine.showMessage("Enable ReadIt in Privacy → Accessibility, then press the shortcut again.")
            overlay.show()
            overlay.cancelHide()

            Task { @MainActor in
                if await PermissionsService.waitUntilTrusted(timeout: 12) {
                    engine.showMessage("Permission granted — select text and press the shortcut.")
                    overlay.show()
                    overlay.scheduleHide(after: 2.0)
                    syncHotkey() // re-bind monitors now that AX is allowed
                }
            }
            return
        }

        // Immediate feedback so a slow selection lookup never feels like a dead shortcut.
        engine.showMessage("Looking for selection…")
        overlay.show()

        Task { @MainActor in
            // Let the user finish releasing the hotkey before we synthesize ⌘C.
            try? await Task.sleep(nanoseconds: 120_000_000)
            let text = await SelectionService.selectedText()
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                engine.showMessage("No text selected — highlight text, release keys, try again.")
                overlay.show()
                overlay.scheduleHide(after: 2.2)
                return
            }

            engine.speak(text: text)
        }
    }
}
