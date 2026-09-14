import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorderView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                beginRecording()
            } label: {
                Text(isRecording ? "Press shortcut…" : preferences.hasHotkey ? preferences.hotkeyDisplay : "Record")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isRecording ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.08))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(isRecording ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Click, then press the new keyboard shortcut")

            if preferences.hasHotkey && !isRecording {
                Button {
                    preferences.clearHotkey()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .onDisappear { endRecording() }
    }

    private func beginRecording() {
        endRecording()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                endRecording()
                return nil
            }

            let carbonMods = HotkeyModifierBridge.carbon(from: event.modifierFlags)
            // Require at least one modifier to avoid eating plain typing.
            guard carbonMods != 0 else { return event }

            preferences.setHotkey(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
            endRecording()
            return nil
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }
}
