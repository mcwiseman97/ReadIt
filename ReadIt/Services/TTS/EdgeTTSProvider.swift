import AVFoundation
import CryptoKit
import Foundation

/// Microsoft Edge online neural TTS (same public endpoint used by open-source edge-tts clients).
@MainActor
final class EdgeTTSProvider: NSObject, TTSProvider, AVAudioPlayerDelegate {
    let kind: TTSProviderKind = .edgeTTS

    /// Must match edge-tts TRUSTED_CLIENT_TOKEN (note trailing F4).
    private let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private let chromiumFullVersion = "143.0.3650.75"
    private let voiceListURL = URL(string: "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list")!
    private let websocketBase = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"

    private var player: AVAudioPlayer?
    private var speakContinuation: CheckedContinuation<Void, Error>?
    private var cachedVoices: [TTSVoice]?
    private var isPaused = false
    private var clockSkewSeconds: Double = 0

    /// Popular Edge voices always available even if the remote catalog fails.
    static let curatedVoices: [TTSVoice] = [
        TTSVoice(id: "en-US-AvaNeural", name: "en-US-AvaNeural", displayName: "Ava", language: "en-US", gender: "Female", provider: .edgeTTS),
        TTSVoice(id: "en-US-AndrewNeural", name: "en-US-AndrewNeural", displayName: "Andrew", language: "en-US", gender: "Male", provider: .edgeTTS),
        TTSVoice(id: "en-US-EmmaNeural", name: "en-US-EmmaNeural", displayName: "Emma", language: "en-US", gender: "Female", provider: .edgeTTS),
        TTSVoice(id: "en-US-BrianNeural", name: "en-US-BrianNeural", displayName: "Brian", language: "en-US", gender: "Male", provider: .edgeTTS),
        TTSVoice(id: "en-US-JennyNeural", name: "en-US-JennyNeural", displayName: "Jenny", language: "en-US", gender: "Female", provider: .edgeTTS),
        TTSVoice(id: "en-US-GuyNeural", name: "en-US-GuyNeural", displayName: "Guy", language: "en-US", gender: "Male", provider: .edgeTTS),
        TTSVoice(id: "en-GB-SoniaNeural", name: "en-GB-SoniaNeural", displayName: "Sonia", language: "en-GB", gender: "Female", provider: .edgeTTS),
        TTSVoice(id: "en-GB-RyanNeural", name: "en-GB-RyanNeural", displayName: "Ryan", language: "en-GB", gender: "Male", provider: .edgeTTS)
    ]

    func availableVoices() async throws -> [TTSVoice] {
        if let cachedVoices { return cachedVoices }

        do {
            let remote = try await fetchRemoteVoices()
            cachedVoices = remote
            return remote
        } catch {
            // Keep curated Edge voices (incl. Ava) instead of dumping the user into Apple novelty voices.
            cachedVoices = Self.curatedVoices
            return Self.curatedVoices
        }
    }

    func invalidateCache() {
        cachedVoices = nil
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

        let audio = try await synthesize(text: trimmed, voice: voice.name, rate: rate)
        // Sanity-check: real MPEG frames start with 0xFF Ex sync word somewhere near the start.
        guard audio.count > 64, audio.contains(where: { $0 == 0xFF }) else {
            throw TTSError.synthesisFailed("Received invalid audio from Edge TTS.")
        }

        let player = try AVAudioPlayer(data: audio)
        player.delegate = self
        player.enableRate = true
        player.rate = 1.0 // speed is already applied in SSML prosody
        player.prepareToPlay()
        player.volume = 1.0
        self.player = player
        isPaused = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.speakContinuation = continuation
            if !player.play() {
                self.speakContinuation = nil
                continuation.resume(throwing: TTSError.synthesisFailed("Unable to start audio playback."))
            }
        }
    }

    func pause() {
        guard let player, player.isPlaying else { return }
        player.pause()
        isPaused = true
    }

    func resume() {
        guard let player, isPaused else { return }
        player.play()
        isPaused = false
    }

    func stop() {
        player?.stop()
        player = nil
        isPaused = false
        if let continuation = speakContinuation {
            speakContinuation = nil
            continuation.resume(throwing: TTSError.cancelled)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard let continuation = self.speakContinuation else { return }
            self.speakContinuation = nil
            self.player = nil
            if flag {
                continuation.resume()
            } else {
                continuation.resume(throwing: TTSError.synthesisFailed("Playback failed."))
            }
        }
    }

    // MARK: - Remote catalog

    private func fetchRemoteVoices() async throws -> [TTSVoice] {
        var components = URLComponents(url: voiceListURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "trustedclienttoken", value: trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: generateSecMSGEC()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "1-\(chromiumFullVersion)")
        ]

        var request = URLRequest(url: components.url!)
        for (key, value) in voiceHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 403,
           let date = http.value(forHTTPHeaderField: "Date") {
            adjustClockSkew(serverDateHeader: date)
            // Retry once after skew correction.
            return try await fetchRemoteVoicesRetry()
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TTSError.networkUnavailable
        }

        return try decodeVoices(from: data)
    }

    private func fetchRemoteVoicesRetry() async throws -> [TTSVoice] {
        var components = URLComponents(url: voiceListURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "trustedclienttoken", value: trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: generateSecMSGEC()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "1-\(chromiumFullVersion)")
        ]
        var request = URLRequest(url: components.url!)
        for (key, value) in voiceHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TTSError.networkUnavailable
        }
        return try decodeVoices(from: data)
    }

    private func decodeVoices(from data: Data) throws -> [TTSVoice] {
        let decoded = try JSONDecoder().decode([EdgeVoiceDTO].self, from: data)
        let voices = decoded.map { dto in
            let shortName = dto.ShortName
            let friendly = dto.FriendlyName
                .replacingOccurrences(of: "Microsoft ", with: "")
                .replacingOccurrences(of: " Online", with: "")
                .components(separatedBy: " - ").first
                ?? shortName
            let display = friendly
                .replacingOccurrences(of: " Neural", with: "")
                .components(separatedBy: " ")
                .first ?? friendly
            return TTSVoice(
                id: shortName,
                name: shortName,
                displayName: display,
                language: dto.Locale,
                gender: dto.Gender,
                provider: .edgeTTS
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        // Ensure curated favorites always appear.
        var byID = Dictionary(uniqueKeysWithValues: voices.map { ($0.id, $0) })
        for curated in Self.curatedVoices where byID[curated.id] == nil {
            byID[curated.id] = curated
        }
        return byID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Synthesis

    private func synthesize(text: String, voice: String, rate: Double) async throws -> Data {
        let connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        var components = URLComponents(string: websocketBase)!
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "ConnectionId", value: connectionID),
            URLQueryItem(name: "Sec-MS-GEC", value: generateSecMSGEC()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "1-\(chromiumFullVersion)")
        ]

        guard let url = components.url else { throw TTSError.networkUnavailable }

        var request = URLRequest(url: url)
        for (key, value) in websocketHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()

        defer { task.cancel(with: .goingAway, reason: nil) }

        let timestamp = Self.jsStyleTimestamp()
        let configMessage =
            "X-Timestamp:\(timestamp)\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#
        try await task.send(.string(configMessage))

        let cleaned = Self.removeIncompatibleCharacters(text)
        let escaped = Self.escapeXML(cleaned)
        let ratePercent = Int(((rate - 1.0) * 100).rounded())
        let rateString = ratePercent >= 0 ? "+\(ratePercent)%" : "\(ratePercent)%"
        let ssml =
            "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
            + "<voice name='\(voice)'>"
            + "<prosody pitch='+0Hz' rate='\(rateString)' volume='+0%'>\(escaped)</prosody>"
            + "</voice></speak>"

        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let ssmlMessage =
            "X-RequestId:\(requestID)\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "X-Timestamp:\(timestamp)Z\r\n"
            + "Path:ssml\r\n\r\n"
            + ssml
        try await task.send(.string(ssmlMessage))

        var audio = Data()
        while true {
            let message = try await task.receive()
            switch message {
            case .data(let data):
                if let chunk = Self.extractAudioChunk(from: data) {
                    audio.append(chunk)
                }
            case .string(let textMessage):
                if textMessage.contains("Path:turn.end") {
                    guard !audio.isEmpty else {
                        throw TTSError.synthesisFailed("Edge TTS returned no audio.")
                    }
                    return audio
                }
            @unknown default:
                break
            }
        }
    }

    /// Edge binary frames: [uint16 BE headerLength][header bytes][mp3 payload]
    private static func extractAudioChunk(from data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let headerLength = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        let audioStart = 2 + headerLength
        guard headerLength >= 0, audioStart <= data.count else { return nil }

        let headerRange = data.index(data.startIndex, offsetBy: 2)..<data.index(data.startIndex, offsetBy: audioStart)
        let headerString = String(data: data[headerRange], encoding: .utf8) ?? ""

        // Terminal empty audio frames are normal — skip non-audio paths.
        guard headerString.contains("Path:audio") else { return nil }
        if headerString.contains("Content-Type:") && !headerString.contains("audio/mpeg") {
            return nil
        }

        let chunk = data.subdata(in: audioStart..<data.count)
        return chunk.isEmpty ? nil : chunk
    }

    private static func jsStyleTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    private static func removeIncompatibleCharacters(_ text: String) -> String {
        String(text.map { ch in
            let v = ch.unicodeScalars.first?.value ?? 0
            if (0...8).contains(v) || (11...12).contains(v) || (14...31).contains(v) {
                return Character(" ")
            }
            return ch
        })
    }

    // MARK: - Headers / DRM

    private func voiceHeaders() -> [String: String] {
        let major = chromiumFullVersion.split(separator: ".").first.map(String.init) ?? "143"
        return [
            "Authority": "speech.platform.bing.com",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36 Edg/\(major).0.0.0",
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Sec-CH-UA": "\"Not;A Brand\";v=\"99\", \"Microsoft Edge\";v=\"\(major)\", \"Chromium\";v=\"\(major)\"",
            "Sec-CH-UA-Mobile": "?0",
            "Sec-Fetch-Site": "none",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
            "Cookie": "muid=\(UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased());"
        ]
    }

    private func websocketHeaders() -> [String: String] {
        let major = chromiumFullVersion.split(separator: ".").first.map(String.init) ?? "143"
        return [
            "Pragma": "no-cache",
            "Cache-Control": "no-cache",
            "Origin": "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36 Edg/\(major).0.0.0",
            "Accept-Language": "en-US,en;q=0.9"
        ]
    }

    private func generateSecMSGEC() -> String {
        let winEpoch: Double = 11_644_473_600
        var ticks = Date().timeIntervalSince1970 + clockSkewSeconds + winEpoch
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        ticks *= 10_000_000 // 100-nanosecond intervals
        let payload = "\(Int64(ticks.rounded(.down)))\(trustedClientToken)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private func adjustClockSkew(serverDateHeader: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let serverDate = formatter.date(from: serverDateHeader) else { return }
        clockSkewSeconds += serverDate.timeIntervalSince1970 - Date().timeIntervalSince1970
    }

    private static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private struct EdgeVoiceDTO: Decodable {
    let Name: String
    let ShortName: String
    let Gender: String
    let Locale: String
    let FriendlyName: String
}
