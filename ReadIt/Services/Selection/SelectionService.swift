import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum SelectionService {
    /// Prefer Accessibility selected text; fall back to Cmd+C clipboard capture.
    static func selectedText() async -> String? {
        if let ax = accessibilitySelectedText(), !ax.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSLog("ReadIt: got selection via Accessibility (%d chars)", ax.count)
            return ax
        }
        if let clip = await clipboardSelectedText() {
            NSLog("ReadIt: got selection via clipboard (%d chars)", clip.count)
            return clip
        }
        NSLog("ReadIt: no selection found")
        return nil
    }

    // MARK: - Accessibility

    private static func accessibilitySelectedText() -> String? {
        // Frontmost app by PID is more reliable than system-wide focus attributes.
        if let app = NSWorkspace.shared.frontmostApplication {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            if let text = selectedText(from: copyAttribute(appElement, kAXFocusedUIElementAttribute as String)) {
                return text
            }
            if let text = findSelectedTextDeep(in: appElement, depth: 0) {
                return text
            }
        }

        let system = AXUIElementCreateSystemWide()
        if let text = selectedText(from: copyAttribute(system, kAXFocusedUIElementAttribute as String)) {
            return text
        }
        if let app = copyAttribute(system, kAXFocusedApplicationAttribute as String) {
            if let text = selectedText(from: copyAttribute(app, kAXFocusedUIElementAttribute as String)) {
                return text
            }
            if let text = findSelectedTextDeep(in: app, depth: 0) {
                return text
            }
        }
        return nil
    }

    private static func findSelectedTextDeep(in element: AXUIElement, depth: Int) -> String? {
        if depth > 6 { return nil }
        if let text = selectedText(from: element) { return text }

        // Prefer known text-bearing roles first.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            let interesting = [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                kAXComboBoxRole as String,
                "AXWebArea",
                "AXScrollArea",
                kAXStaticTextRole as String
            ]
            if interesting.contains(role), let text = selectedText(from: element) {
                return text
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        // Limit breadth to keep this snappy.
        for child in children.prefix(40) {
            if let text = findSelectedTextDeep(in: child, depth: depth + 1) {
                return text
            }
        }
        return nil
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard result == .success, let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private static func selectedText(from element: AXUIElement?) -> String? {
        guard let element else { return nil }

        var selectedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
           let selected = selectedRef as? String,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selected
        }

        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        let valueOK = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success
        let rangeOK = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success
        guard valueOK, rangeOK, let value = valueRef as? String,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
              range.length > 0,
              range.location >= 0,
              range.location + range.length <= value.utf16.count else {
            return nil
        }

        let start = value.utf16.index(value.utf16.startIndex, offsetBy: range.location)
        let end = value.utf16.index(start, offsetBy: range.length)
        guard let s = String.Index(start, within: value), let e = String.Index(end, within: value) else {
            return nil
        }
        let sliced = String(value[s..<e])
        return sliced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : sliced
    }

    // MARK: - Clipboard fallback

    private static func clipboardSelectedText() async -> String? {
        // Critical: wait until the hotkey modifiers are released.
        // Otherwise synthesized ⌘C becomes ⌃⌥⌘C / ⌘⌥C and never copies.
        let modifiersCleared = await waitForModifierKeysToClear(timeout: 1.5)
        if !modifiersCleared {
            NSLog("ReadIt: modifiers still held — attempting copy anyway")
        }

        let pasteboard = NSPasteboard.general
        let savedTypes = pasteboard.types
        let savedData: [NSPasteboard.PasteboardType: Data] = {
            var map: [NSPasteboard.PasteboardType: Data] = [:]
            for type in savedTypes ?? [] {
                if let data = pasteboard.data(forType: type) {
                    map[type] = data
                }
            }
            return map
        }()

        pasteboard.clearContents()
        // Snapshot change count *after* clear so we only detect a new copy.
        let changeAfterClear = pasteboard.changeCount

        postCommandC()
        // Small beat for the frontmost app to handle the copy.
        try? await Task.sleep(nanoseconds: 80_000_000)
        postCommandC()

        var text: String?
        for _ in 0..<24 { // ~1.2s
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != changeAfterClear,
               let copied = pasteboard.string(forType: .string)
                ?? pasteboard.string(forType: .rtf).flatMap({ _ in pasteboard.string(forType: .string) }),
               !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = copied
                break
            }
            // Some apps put RTF/HTML only — still extract plain string if available.
            if pasteboard.changeCount != changeAfterClear,
               let plain = plainStringFromPasteboard(pasteboard),
               !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = plain
                break
            }
        }

        // Restore prior clipboard.
        pasteboard.clearContents()
        if !savedData.isEmpty {
            pasteboard.declareTypes(Array(savedData.keys), owner: nil)
            for (type, data) in savedData {
                pasteboard.setData(data, forType: type)
            }
        }

        return text
    }

    private static func plainStringFromPasteboard(_ pasteboard: NSPasteboard) -> String? {
        if let s = pasteboard.string(forType: .string) { return s }
        if let s = pasteboard.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text")) { return s }
        if let attributed = NSAttributedString(
            rtf: pasteboard.data(forType: .rtf) ?? Data(),
            documentAttributes: nil
        ) {
            let s = attributed.string
            return s.isEmpty ? nil : s
        }
        return nil
    }

    /// Poll until ⌘⌥⌃⇧ are physically up so our synthetic copy isn't polluted.
    private static func waitForModifierKeysToClear(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.hidSystemState)
            let mods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            if flags.intersection(mods).isEmpty {
                // Extra short settle so key-up finishes propagating.
                try? await Task.sleep(nanoseconds: 40_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return false
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)

        // Force flags to Command only — do not inherit currently held modifiers.
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
