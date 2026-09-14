import Combine
import Foundation

@MainActor
final class TTSEngine: ObservableObject {
    @Published private(set) var snapshot = PlaybackSnapshot()
    @Published private(set) var voices: [TTSVoice] = []
    @Published private(set) var languages: [TTSLanguage] = [TTSLanguage.englishUS]
    @Published private(set) var isRefreshingVoices = false

    private let preferences: AppPreferences
    private let edge = EdgeTTSProvider()
    private let apple = AppleSpeechProvider()
    private var speakTask: Task<Void, Never>?
    private var activeProvider: TTSProvider?

    init(preferences: AppPreferences) {
        self.preferences = preferences
        snapshot.rate = preferences.rate
        snapshot.voiceID = preferences.voiceID
        snapshot.voiceLabel = preferences.selectedVoice.pickerLabel
        snapshot.providerLabel = preferences.provider.displayName
    }

    var isSpeaking: Bool {
        snapshot.status == .playing || snapshot.status == .paused || snapshot.status == .loading
    }

    func provider(for kind: TTSProviderKind) -> TTSProvider {
        switch kind {
        case .edgeTTS: return edge
        case .appleSpeech: return apple
        }
    }

    func refreshVoices() async {
        isRefreshingVoices = true
        defer { isRefreshingVoices = false }

        let savedVoiceID = preferences.voiceID
        let savedProvider = preferences.provider

        do {
            let provider = provider(for: savedProvider)
            if let edgeProvider = provider as? EdgeTTSProvider {
                edgeProvider.invalidateCache()
            }
            let fetched = try await provider.availableVoices()
            voices = fetched
            languages = provider.availableLanguages(from: fetched)
            if languages.isEmpty {
                languages = [TTSLanguage.englishUS]
            }

            // Never clobber a user-selected Edge neural voice just because the catalog hiccuped.
            if fetched.contains(where: { $0.id == savedVoiceID }) {
                return
            }
            if savedProvider == .edgeTTS, savedVoiceID.contains("Neural") {
                // Keep Ava / whatever they picked; ensure it appears in the list.
                if let curated = EdgeTTSProvider.curatedVoices.first(where: { $0.id == savedVoiceID }) {
                    voices = merge(fetched, with: [curated])
                }
                return
            }

            let matching = fetched.first { $0.language == preferences.languageCode } ?? fetched.first
            if let matching {
                preferences.applyVoice(matching)
            }
        } catch {
            if savedProvider == .edgeTTS {
                voices = EdgeTTSProvider.curatedVoices
                languages = edge.availableLanguages(from: voices)
                if let curated = EdgeTTSProvider.curatedVoices.first(where: { $0.id == savedVoiceID }) {
                    preferences.applyVoice(curated)
                } else {
                    preferences.applyVoice(TTSVoice.edgeAva)
                }
            }
        }
    }

    private func merge(_ primary: [TTSVoice], with extras: [TTSVoice]) -> [TTSVoice] {
        var byID = Dictionary(uniqueKeysWithValues: primary.map { ($0.id, $0) })
        for voice in extras { byID[voice.id] = voice }
        return byID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func voicesForCurrentLanguage() -> [TTSVoice] {
        voices.filter { $0.language == preferences.languageCode }
    }

    func toggleOrSpeak(text: String) {
        switch snapshot.status {
        case .playing:
            pause()
        case .paused:
            resume()
        case .loading, .idle:
            speak(text: text)
        }
    }

    func speak(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            snapshot.statusMessage = "No text selected."
            return
        }

        speakTask?.cancel()
        activeProvider?.stop()

        snapshot = PlaybackSnapshot(
            status: .loading,
            text: trimmed,
            rate: preferences.rate,
            voiceID: preferences.voiceID,
            voiceLabel: preferences.selectedVoice.pickerLabel,
            providerLabel: preferences.provider.displayName,
            usedFallback: false,
            statusMessage: nil
        )

        let preferred = preferences.provider
        let voice = preferences.selectedVoice
        let rate = preferences.rate

        speakTask = Task { [weak self] in
            guard let self else { return }
            await self.runSpeak(text: trimmed, preferred: preferred, voice: voice, rate: rate)
        }
    }

    func pause() {
        activeProvider?.pause()
        if snapshot.status == .playing {
            snapshot.status = .paused
        }
    }

    func resume() {
        activeProvider?.resume()
        if snapshot.status == .paused {
            snapshot.status = .playing
        }
    }

    func stop() {
        speakTask?.cancel()
        speakTask = nil
        activeProvider?.stop()
        activeProvider = nil
        snapshot.status = .idle
        snapshot.statusMessage = nil
    }

    /// Stop playback and clear the pill immediately.
    func dismiss() {
        stop()
        snapshot.text = ""
        snapshot.statusMessage = nil
        snapshot.usedFallback = false
    }

    func setRate(_ rate: Double) {
        preferences.rate = rate
        snapshot.rate = rate
    }

    func bumpRate(_ delta: Double) {
        preferences.bumpRate(delta)
        snapshot.rate = preferences.rate
    }

    func selectVoice(_ voice: TTSVoice) {
        preferences.applyVoice(voice)
        snapshot.voiceID = voice.id
        snapshot.voiceLabel = voice.pickerLabel
        snapshot.providerLabel = voice.provider.displayName
    }

    func showMessage(_ message: String) {
        var next = snapshot
        next.statusMessage = message
        if next.status == .idle {
            // Keep pill content visible for status-only updates.
            next.status = .idle
        }
        snapshot = next
    }

    private func runSpeak(text: String, preferred: TTSProviderKind, voice: TTSVoice, rate: Double) async {
        var usedFallback = false
        var fallbackLabel: String?

        do {
            try await speakWithProvider(kind: preferred, text: text, voice: voice, rate: rate)
        } catch is CancellationError {
            snapshot.status = .idle
            return
        } catch TTSError.cancelled {
            snapshot.status = .idle
            return
        } catch {
            if preferred == .edgeTTS {
                usedFallback = true
                // Prefer US English system voice — never persist this as the user's selection.
                let appleVoices = (try? await apple.availableVoices()) ?? []
                let speakVoice = appleVoices.first {
                    $0.language.lowercased().hasPrefix("en-us")
                } ?? appleVoices.first {
                    $0.id.localizedCaseInsensitiveContains("samantha")
                } ?? appleVoices.first {
                    $0.language.lowercased().hasPrefix("en")
                } ?? TTSVoice.appleDefault
                fallbackLabel = speakVoice.pickerLabel
                do {
                    // Keep UI preference on Ava/Edge; only playback uses Apple.
                    snapshot.statusMessage = "Edge unavailable — using \(speakVoice.displayName)"
                    try await speakWithProvider(kind: .appleSpeech, text: text, voice: speakVoice, rate: rate)
                } catch {
                    snapshot.status = .idle
                    snapshot.statusMessage = error.localizedDescription
                    return
                }
            } else {
                snapshot.status = .idle
                snapshot.statusMessage = error.localizedDescription
                return
            }
        }

        if Task.isCancelled {
            snapshot.status = .idle
            return
        }

        snapshot.status = .idle
        snapshot.usedFallback = usedFallback
        // Restore the user's chosen voice label (don't stick on Karen/etc.)
        snapshot.voiceID = preferences.voiceID
        snapshot.voiceLabel = preferences.selectedVoice.pickerLabel
        snapshot.providerLabel = preferences.provider.displayName
        if usedFallback {
            snapshot.statusMessage = "Fell back to \(fallbackLabel ?? "macOS voice"). Ava stays selected."
        }
    }

    private func speakWithProvider(kind: TTSProviderKind, text: String, voice: TTSVoice, rate: Double) async throws {
        let provider = provider(for: kind)
        activeProvider = provider
        snapshot.status = .playing
        // During Edge playback show Edge voice; during emergency Apple playback keep preferred name
        // unless this is explicitly the Apple provider.
        if kind == preferences.provider {
            snapshot.providerLabel = kind.displayName
            snapshot.voiceLabel = voice.pickerLabel
            snapshot.voiceID = voice.id
        }
        try await provider.speak(text, voice: voice, rate: rate)
    }
}
