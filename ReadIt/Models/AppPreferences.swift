import Foundation
import Combine
import Carbon

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }

    @Published var provider: TTSProviderKind {
        didSet {
            defaults.set(provider.rawValue, forKey: Keys.provider)
            objectWillChange.send()
        }
    }

    @Published var languageCode: String {
        didSet { defaults.set(languageCode, forKey: Keys.language) }
    }

    @Published var voiceID: String {
        didSet { defaults.set(voiceID, forKey: Keys.voiceID) }
    }

    @Published var voiceDisplayName: String {
        didSet { defaults.set(voiceDisplayName, forKey: Keys.voiceName) }
    }

    @Published var voiceGender: String {
        didSet { defaults.set(voiceGender, forKey: Keys.voiceGender) }
    }

    @Published var rate: Double {
        didSet { defaults.set(rate, forKey: Keys.rate) }
    }

    /// Carbon-style key code for the global hotkey.
    @Published var hotkeyKeyCode: UInt32 {
        didSet { defaults.set(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode) }
    }

    /// Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
    @Published var hotkeyModifiers: UInt32 {
        didSet { defaults.set(Int(hotkeyModifiers), forKey: Keys.hotkeyModifiers) }
    }

    @Published var hasHotkey: Bool {
        didSet { defaults.set(hasHotkey, forKey: Keys.hasHotkey) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let enabled = "readit.enabled"
        static let provider = "readit.provider"
        static let language = "readit.language"
        static let voiceID = "readit.voiceID"
        static let voiceName = "readit.voiceName"
        static let voiceGender = "readit.voiceGender"
        static let rate = "readit.rate"
        static let hotkeyKeyCode = "readit.hotkeyKeyCode"
        static let hotkeyModifiers = "readit.hotkeyModifiers"
        static let hasHotkey = "readit.hasHotkey"
    }

    static let rateOptions: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var selectedVoice: TTSVoice {
        TTSVoice(
            id: voiceID,
            name: voiceID,
            displayName: voiceDisplayName,
            language: languageCode,
            gender: voiceGender,
            provider: provider
        )
    }

    var hotkeyDisplay: String {
        guard hasHotkey else { return "None" }
        return HotkeyFormatter.displayString(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }

    private init() {
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        let providerRaw = defaults.string(forKey: Keys.provider) ?? TTSProviderKind.edgeTTS.rawValue
        provider = TTSProviderKind(rawValue: providerRaw) ?? .edgeTTS
        languageCode = defaults.string(forKey: Keys.language) ?? TTSLanguage.englishUS.code
        voiceID = defaults.string(forKey: Keys.voiceID) ?? TTSVoice.edgeAva.id
        voiceDisplayName = defaults.string(forKey: Keys.voiceName) ?? TTSVoice.edgeAva.displayName
        voiceGender = defaults.string(forKey: Keys.voiceGender) ?? TTSVoice.edgeAva.gender
        rate = defaults.object(forKey: Keys.rate) as? Double ?? 1.0

        // Default: Control + Option + Command + S
        let defaultMods = UInt32(controlKey | optionKey | cmdKey)
        hotkeyKeyCode = UInt32(defaults.object(forKey: Keys.hotkeyKeyCode) as? Int ?? Int(kVK_ANSI_S))
        hotkeyModifiers = UInt32(defaults.object(forKey: Keys.hotkeyModifiers) as? Int ?? Int(defaultMods))
        hasHotkey = defaults.object(forKey: Keys.hasHotkey) as? Bool ?? true
    }

    func applyVoice(_ voice: TTSVoice) {
        voiceID = voice.id
        voiceDisplayName = voice.displayName
        voiceGender = voice.gender
        languageCode = voice.language
        provider = voice.provider
    }

    func clearHotkey() {
        hasHotkey = false
    }

    func setHotkey(keyCode: UInt32, modifiers: UInt32) {
        hotkeyKeyCode = keyCode
        hotkeyModifiers = modifiers
        hasHotkey = true
    }

    func bumpRate(_ delta: Double) {
        let options = Self.rateOptions
        guard let idx = options.firstIndex(of: rate) else {
            rate = 1.0
            return
        }
        let next = min(max(idx + (delta > 0 ? 1 : -1), 0), options.count - 1)
        rate = options[next]
    }
}

enum HotkeyFormatter {
    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyCodeGlyph(keyCode))
        return parts.joined()
    }

    static func keyCodeGlyph(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "?"
        }
    }
}
