import AVFoundation
import Foundation

@MainActor
final class AppleSpeechProvider: NSObject, TTSProvider, AVSpeechSynthesizerDelegate {
    let kind: TTSProviderKind = .appleSpeech

    private let synthesizer = AVSpeechSynthesizer()
    private var speakContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func availableVoices() async throws -> [TTSVoice] {
        let noveltyKeywords = ["bad news", "good news", "zarvox", "trinoids", "whisper", "bubbles", "boing", "jester", "organ", "cellos", "deranged"]
        return AVSpeechSynthesisVoice.speechVoices()
            .compactMap { voice -> TTSVoice? in
                let name = voice.name
                if noveltyKeywords.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                    return nil
                }
                let gender: String
                switch voice.gender {
                case .female: gender = "Female"
                case .male: gender = "Male"
                default: gender = ""
                }
                return TTSVoice(
                    id: voice.identifier,
                    name: voice.name,
                    displayName: voice.name,
                    language: voice.language,
                    gender: gender,
                    provider: .appleSpeech
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func availableLanguages(from voices: [TTSVoice]) -> [TTSLanguage] {
        var seen = Set<String>()
        var result: [TTSLanguage] = []
        for voice in voices {
            guard seen.insert(voice.language).inserted else { continue }
            result.append(
                TTSLanguage(
                    code: voice.language,
                    name: LanguageFlag.displayName(for: voice.language),
                    flag: LanguageFlag.flag(for: voice.language)
                )
            )
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func speak(_ text: String, voice: TTSVoice, rate: Double) async throws {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TTSError.emptyText }

        let utterance = AVSpeechUtterance(string: trimmed)
        if let systemVoice = AVSpeechSynthesisVoice(identifier: voice.id)
            ?? AVSpeechSynthesisVoice(language: voice.language) {
            utterance.voice = systemVoice
        }
        // Map 1x → system default; keep pitch natural.
        let base = AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = min(
            max(base * Float(rate), AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.speakContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        if let continuation = speakContinuation {
            speakContinuation = nil
            continuation.resume(throwing: TTSError.cancelled)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let continuation = self.speakContinuation else { return }
            self.speakContinuation = nil
            continuation.resume()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let continuation = self.speakContinuation else { return }
            self.speakContinuation = nil
            continuation.resume(throwing: TTSError.cancelled)
        }
    }
}
