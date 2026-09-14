import Foundation

@MainActor
protocol TTSProvider: AnyObject {
    var kind: TTSProviderKind { get }
    func availableVoices() async throws -> [TTSVoice]
    func availableLanguages(from voices: [TTSVoice]) -> [TTSLanguage]
    func speak(_ text: String, voice: TTSVoice, rate: Double) async throws
    func pause()
    func resume()
    func stop()
}

enum TTSError: LocalizedError {
    case emptyText
    case networkUnavailable
    case synthesisFailed(String)
    case unsupportedVoice
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text selected."
        case .networkUnavailable:
            return "Network unavailable for Edge TTS."
        case .synthesisFailed(let message):
            return message
        case .unsupportedVoice:
            return "Selected voice is not available."
        case .cancelled:
            return "Cancelled."
        }
    }
}

enum LanguageFlag {
    static func flag(for languageCode: String) -> String {
        let region: String
        if let dash = languageCode.split(separator: "-").last, dash.count == 2 {
            region = String(dash)
        } else if languageCode.count == 2 {
            region = languageCode.uppercased()
        } else {
            return ""
        }
        let base = UnicodeScalar("A").value
        var scalars: [UnicodeScalar] = []
        for ch in region.uppercased().unicodeScalars {
            guard let regional = UnicodeScalar(0x1F1E6 + (ch.value - base)) else { continue }
            scalars.append(regional)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func displayName(for languageCode: String) -> String {
        Locale.current.localizedString(forIdentifier: languageCode)
            ?? Locale.current.localizedString(forLanguageCode: String(languageCode.prefix(2)))
            ?? languageCode
    }
}
