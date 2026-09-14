import Foundation

enum TTSProviderKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case edgeTTS = "edge"
    case appleSpeech = "apple"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .edgeTTS: return "Edge TTS"
        case .appleSpeech: return "macOS Voice"
        }
    }
}

struct TTSVoice: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let displayName: String
    let language: String
    let gender: String
    let provider: TTSProviderKind

    var pickerLabel: String {
        if gender.isEmpty {
            return displayName
        }
        return "\(displayName) · \(gender.capitalized)"
    }

    static let edgeAva = TTSVoice(
        id: "en-US-AvaNeural",
        name: "en-US-AvaNeural",
        displayName: "Ava",
        language: "en-US",
        gender: "Female",
        provider: .edgeTTS
    )

    static let appleDefault = TTSVoice(
        id: "com.apple.speech.synthesis.voice.Samantha",
        name: "Samantha",
        displayName: "Samantha",
        language: "en-US",
        gender: "Female",
        provider: .appleSpeech
    )
}

struct TTSLanguage: Identifiable, Hashable, Codable, Sendable {
    let code: String
    let name: String
    let flag: String

    var id: String { code }

    var pickerLabel: String {
        flag.isEmpty ? name : "\(flag) \(name)"
    }

    static let englishUS = TTSLanguage(
        code: "en-US",
        name: "English (United States)",
        flag: "🇺🇸"
    )
}

enum PlaybackStatus: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
}

struct PlaybackSnapshot: Equatable, Sendable {
    var status: PlaybackStatus = .idle
    var text: String = ""
    var rate: Double = 1.0
    var voiceID: String = ""
    var voiceLabel: String = ""
    var providerLabel: String = ""
    var usedFallback: Bool = false
    var statusMessage: String?
}
