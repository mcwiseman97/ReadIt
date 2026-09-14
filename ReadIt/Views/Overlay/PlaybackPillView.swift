import SwiftUI

struct PlaybackPillView: View {
    @EnvironmentObject private var engine: TTSEngine
    @EnvironmentObject private var preferences: AppPreferences
    @State private var appeared = false

    var onDismiss: () -> Void = {
        OverlayHoverBridge.shared.dismiss?()
    }

    private var snapshot: PlaybackSnapshot { engine.snapshot }

    var body: some View {
        HStack(spacing: 14) {
            statusGlyph
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.text.isEmpty ? "Ready to read" : snapshot.text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(snapshot.voiceLabel.isEmpty ? preferences.selectedVoice.pickerLabel : snapshot.voiceLabel)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                    if let message = snapshot.statusMessage, !message.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(message)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            controlCluster
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background { glassBackground }
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .compositingGroup()
        .scaleEffect(appeared ? 1 : 0.96)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                appeared = true
            }
        }
        .onHover { hovering in
            if hovering {
                OverlayHoverBridge.shared.cancelHide?()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        ZStack {
            if snapshot.status == .loading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: snapshot.status == .paused ? "pause.fill" : "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .symbolEffect(.variableColor.iterative, isActive: snapshot.status == .playing)
            }
        }
    }

    private var controlCluster: some View {
        HStack(spacing: 4) {
            pillButton(systemName: "tortoise.fill") {
                engine.bumpRate(-0.25)
            }
            .help("Slower")

            pillButton(systemName: snapshot.status == .paused ? "play.fill" : "pause.fill") {
                if snapshot.status == .paused {
                    engine.resume()
                } else if snapshot.status == .playing {
                    engine.pause()
                }
            }
            .help(snapshot.status == .paused ? "Resume" : "Pause")

            pillButton(systemName: "hare.fill") {
                engine.bumpRate(0.25)
            }
            .help("Faster")

            Menu {
                let voices: [TTSVoice] = {
                    var list = engine.voicesForCurrentLanguage()
                    if list.isEmpty {
                        list = EdgeTTSProvider.curatedVoices.filter { $0.language == preferences.languageCode }
                    }
                    if !list.contains(where: { $0.id == preferences.voiceID }) {
                        list.insert(preferences.selectedVoice, at: 0)
                    }
                    return list
                }()
                ForEach(voices) { voice in
                    Button {
                        engine.selectVoice(voice)
                    } label: {
                        HStack {
                            Text(voice.pickerLabel)
                            if voice.id == preferences.voiceID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28, height: 28)
            .help("Change voice")

            pillButton(systemName: "xmark") {
                onDismiss()
            }
            .help("Dismiss")
        }
    }

    private func pillButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            Circle()
                .fill(.primary.opacity(0.08))
        }
    }

    @ViewBuilder
    private var glassBackground: some View {
        if #available(macOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .glassEffect(in: Capsule(style: .continuous))
        } else {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }
}
