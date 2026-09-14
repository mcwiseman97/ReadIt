import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var engine: TTSEngine
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Toggle("Enable Read Aloud", isOn: Binding(
            get: { preferences.isEnabled },
            set: { newValue in
                preferences.isEnabled = newValue
                appState.syncHotkey()
            }
        ))

        if engine.isSpeaking {
            Divider()
            Button(engine.snapshot.status == .paused ? "Resume" : "Pause") {
                if engine.snapshot.status == .paused {
                    engine.resume()
                } else {
                    engine.pause()
                }
            }
            Button("Stop") {
                engine.stop()
            }
        }

        Divider()

        Button("Voice: \(preferences.selectedVoice.pickerLabel)") {}
            .disabled(true)
        Button(preferences.hasHotkey ? "Shortcut: \(preferences.hotkeyDisplay)" : "Shortcut: None") {}
            .disabled(true)

        Divider()

        Button("Settings…") {
            // Activation policy flip must happen before SwiftUI opens Settings.
            appState.openSettings()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit ReadIt") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
