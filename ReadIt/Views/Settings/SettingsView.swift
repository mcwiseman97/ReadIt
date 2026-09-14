import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var engine: TTSEngine
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Read Aloud")
                        Text("Turning this off also disables the feature’s shortcuts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section {
                Picker("Provider", selection: $preferences.provider) {
                    ForEach(TTSProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                HStack {
                    Picker("Language", selection: languageBinding) {
                        ForEach(engine.languages) { language in
                            Text(language.pickerLabel).tag(language.code)
                        }
                    }

                    Button {
                        Task { await engine.refreshVoices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(engine.isRefreshingVoices)
                    .help("Refresh voices")
                }

                Picker("Voice", selection: voiceBinding) {
                    ForEach(voicePickerVoices) { voice in
                        Text(voice.pickerLabel).tag(voice.id)
                    }
                }

                Picker("Speed", selection: $preferences.rate) {
                    ForEach(AppPreferences.rateOptions, id: \.self) { rate in
                        Text(rateLabel(rate)).tag(rate)
                    }
                }
            } header: {
                Text("Read Aloud")
            } footer: {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Read selection aloud")
                        Text("Press to read the selected text. Press again to pause.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorderView()
                }
            } header: {
                Text("Shortcut")
            }

            Section {
                if PermissionsService.isAccessibilityTrusted {
                    Label("Accessibility is enabled for this build.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Accessibility is off for this build", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Xcode rebuilds look like a new app to macOS. In System Settings → Privacy & Security → Accessibility, remove old ReadIt rows, click +, choose the running ReadIt, enable it, then click Check Again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(PermissionsService.currentAppPath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        HStack {
                            Button("Grant Access…") {
                                _ = PermissionsService.requestAccessibilityIfNeeded(prompt: true)
                                PermissionsService.openAccessibilitySettings()
                            }
                            Button("Check Again") {
                                appState.syncHotkey()
                                // Force view refresh
                                appState.objectWillChange.send()
                            }
                        }
                    }
                }
            } header: {
                Text("Permissions")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .onAppear {
            Task { await engine.refreshVoices() }
        }
        .onChange(of: preferences.provider) { _, _ in
            Task { await engine.refreshVoices() }
        }
        .onChange(of: preferences.isEnabled) { _, _ in
            appState.syncHotkey()
        }
        .onChange(of: preferences.hasHotkey) { _, _ in
            appState.syncHotkey()
        }
        .onChange(of: preferences.hotkeyKeyCode) { _, _ in
            appState.syncHotkey()
        }
        .onChange(of: preferences.hotkeyModifiers) { _, _ in
            appState.syncHotkey()
        }
    }

    /// Voices for the picker — always includes the currently saved voice so SwiftUI can't reset it.
    private var voicePickerVoices: [TTSVoice] {
        var list = engine.voicesForCurrentLanguage()
        let current = preferences.selectedVoice
        if !list.contains(where: { $0.id == current.id }) {
            list.insert(current, at: 0)
        }
        return list
    }

    /// Language changes should pick a default voice for that language — voice changes must not bounce back.
    private var languageBinding: Binding<String> {
        Binding(
            get: { preferences.languageCode },
            set: { newCode in
                guard newCode != preferences.languageCode else { return }
                preferences.languageCode = newCode
                if let first = engine.voices.first(where: { $0.language == newCode }) {
                    engine.selectVoice(first)
                }
            }
        )
    }

    private var voiceBinding: Binding<String> {
        Binding(
            get: { preferences.voiceID },
            set: { newID in
                if let voice = engine.voices.first(where: { $0.id == newID })
                    ?? EdgeTTSProvider.curatedVoices.first(where: { $0.id == newID }) {
                    engine.selectVoice(voice)
                }
            }
        )
    }

    private func rateLabel(_ rate: Double) -> String {
        if rate == 1.0 { return "1x" }
        if rate == floor(rate) { return "\(Int(rate))x" }
        return String(format: "%.2gx", rate)
    }

    private var footerText: String {
        switch preferences.provider {
        case .edgeTTS:
            return "Free, no key. If Microsoft’s service is unreachable, Read Aloud falls back to the macOS voice."
        case .appleSpeech:
            return "Uses voices installed on this Mac. Works fully offline."
        }
    }
}
