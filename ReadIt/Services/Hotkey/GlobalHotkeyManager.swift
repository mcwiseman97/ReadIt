import AppKit
import Carbon
import Foundation

/// Holds hotkey callback state reachable from Carbon's C callback without MainActor hops.
private final class HotkeyCallbackBox: @unchecked Sendable {
    var handler: (() -> Void)?
    let signature: OSType
    let id: UInt32

    init(signature: OSType, id: UInt32) {
        self.signature = signature
        self.id = id
    }
}

@MainActor
final class GlobalHotkeyManager: ObservableObject {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var handlerInstalled = false
    private let box = HotkeyCallbackBox(signature: OSType(0x52444954), id: 1) // 'RDIT'

    private var registeredKeyCode: UInt32 = 0
    private var registeredModifiers: UInt32 = 0
    private var isEnabled = false

    func setHandler(_ handler: @escaping () -> Void) {
        box.handler = handler
    }

    func register(keyCode: UInt32, modifiers: UInt32, enabled: Bool) {
        unregister()
        registeredKeyCode = keyCode
        registeredModifiers = modifiers
        isEnabled = enabled
        guard enabled else { return }

        installCarbonHandlerIfNeeded()
        registerCarbonHotKey(keyCode: keyCode, modifiers: modifiers)
        installEventMonitors(keyCode: keyCode, carbonModifiers: modifiers)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        isEnabled = false
    }

    private func registerCarbonHotKey(keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: box.signature, id: box.id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
            NSLog("ReadIt: Carbon hotkey registered (key=%u mods=%u)", keyCode, modifiers)
        } else {
            NSLog("ReadIt: Carbon hotkey failed (%d) — relying on NSEvent monitors", status)
        }
    }

    private func installCarbonHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(box).toOpaque()
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                let box = Unmanaged<HotkeyCallbackBox>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if hkID.signature == box.signature && hkID.id == box.id {
                    DispatchQueue.main.async {
                        box.handler?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
        handlerInstalled = status == noErr
        if !handlerInstalled {
            NSLog("ReadIt: Carbon event handler install failed (%d)", status)
        }
    }

    /// Backup path — works when Accessibility is granted even if Carbon registration fails.
    private func installEventMonitors(keyCode: UInt32, carbonModifiers: UInt32) {
        let match: (NSEvent) -> Bool = { [weak self] event in
            guard let self, self.isEnabled else { return false }
            guard UInt32(event.keyCode) == keyCode else { return false }
            let eventCarbon = HotkeyModifierBridge.carbon(from: event.modifierFlags)
            // Compare only the modifier bits we care about.
            let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
            return (eventCarbon & mask) == (carbonModifiers & mask)
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, match(event) else { return }
            // Debounce double-fire with Carbon.
            self.fireFromMonitor()
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, match(event) else { return event }
            self.fireFromMonitor()
            return nil // consume when we're frontmost
        }
    }

    private var lastFire: Date = .distantPast
    private func fireFromMonitor() {
        let now = Date()
        guard now.timeIntervalSince(lastFire) > 0.35 else { return }
        lastFire = now
        box.handler?()
    }
}

enum HotkeyModifierBridge {
    static func carbon(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }
}
