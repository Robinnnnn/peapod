import SwiftUI

struct VoiceMessageComposerControl: View {
    let onStaged: (StagedVoiceMessage) -> Void
    let onError: (String) -> Void

    @ObservedObject private var recorder: VoiceMessageRecorder
    @StateObject private var player: VoiceMessagePlayer
    @State private var isStaging = false
    private let controlSize: CGFloat
    private let stageDraft: (VoiceMessageDraft) throws -> StagedVoiceMessage

    init(
        recorder: VoiceMessageRecorder,
        player: VoiceMessagePlayer? = nil,
        controlSize: CGFloat = 44,
        stager: VoiceMessageStager = VoiceMessageStager(),
        stageDraft: ((VoiceMessageDraft) throws -> StagedVoiceMessage)? = nil,
        onError: @escaping (String) -> Void = { _ in },
        onStaged: @escaping (StagedVoiceMessage) -> Void
    ) {
        self.recorder = recorder
        _player = StateObject(
            wrappedValue: player ?? VoiceMessagePlayer()
        )
        self.controlSize = controlSize
        self.stageDraft = stageDraft ?? stager.stageAndEnqueue
        self.onError = onError
        self.onStaged = onStaged
    }

    var body: some View {
        Group {
            if recorder.state == .recording || recorder.state == .ready {
                VoiceComposerAudioRow(
                    recording: recorder.isRecording,
                    samples: recorder.meterSamples,
                    duration: recorder.draft?.duration ?? recorder.elapsedTime,
                    playback: player.state,
                    progress: player.duration > 0 ? player.progress : nil,
                    isStaging: isStaging,
                    controlSize: controlSize,
                    discard: {
                        player.shutdown()
                        recorder.cancel()
                    },
                    stopOrPlay: stopOrPlay,
                    send: send
                )
            }
        }
        .onDisappear {
            player.shutdown()
        }
        .onChange(of: recorder.draft?.id) {
            player.stop()
        }
        .onChange(of: player.state) { _, state in
            if case let .failed(message) = state {
                onError(message)
            }
        }
    }

    private func stopOrPlay() {
        if recorder.isRecording {
            recorder.finish()
        } else if let url = recorder.draft?.fileURL {
            Task { await player.toggle(sourceURL: url) }
        }
    }

    private func send() {
        guard !isStaging else { return }
        let draft = recorder.isRecording ? recorder.finish() : recorder.draft
        if let draft { stage(draft) }
    }

    private func stage(_ draft: VoiceMessageDraft) {
        guard !isStaging else { return }
        isStaging = true
        player.shutdown()
        defer { isStaging = false }

        do {
            let staged = try stageDraft(draft)
            recorder.markDraftStaged()
            onStaged(staged)
        } catch {
            onError(error.localizedDescription)
        }
    }
}

/// The outer material belongs to MessageComposer, so a state change preserves
/// the keyboard and the same continuous glass surface as the text field.
private struct VoiceComposerAudioRow: View {
    @Environment(\.usesGiftWrap) private var usesGiftWrap
    @Environment(\.colorScheme) private var colorScheme

    let recording: Bool
    let samples: [Double]
    let duration: TimeInterval
    let playback: VoiceMessagePlayer.State
    let progress: Double?
    let isStaging: Bool
    let controlSize: CGFloat
    let discard: () -> Void
    let stopOrPlay: () -> Void
    let send: () -> Void

    private var accent: Color {
        usesGiftWrap ? GiftWrapAppearance.accent(colorScheme == .dark) : .indigo
    }

    var body: some View {
        HStack(spacing: 1) {
            Button(action: discard) {
                symbol("xmark", weight: .medium)
            }
            .accessibilityLabel(recording ? "Cancel recording" : "Discard voice message")
            .accessibilityIdentifier(recording ? "cancel-voice-recording" : "discard-voice-message")

            if playback == .loading || isStaging {
                Text(isStaging ? "Preparing to send…" : "Loading audio…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                VoiceMessageWaveform(samples: samples, presentation: recording ? .live : .overview(progress: progress))
                    .frame(maxWidth: .infinity)
                if !recording {
                    Text(VoiceMessageDurationText.string(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

            Button(action: stopOrPlay) {
                if playback == .loading {
                    ActivitySpinner()
                        .frame(width: controlSize, height: controlSize)
                } else {
                    symbol(recording ? "stop.fill" : (playback == .playing ? "pause.fill" : "play.fill"))
                }
            }
            .disabled(playback == .loading || isStaging)
            .accessibilityLabel(recording ? "Stop recording" :
                (playback == .playing ? "Pause voice message preview" : "Play voice message preview"))
            .accessibilityHint(recording ? "Keeps the recording for review." : "")
            .accessibilityIdentifier(recording ? "stop-voice-recording" : "play-voice-message-preview")

            Button(action: send) {
                symbol("arrow.up", send: true)
            }
            .disabled(isStaging)
            .accessibilityLabel("Send voice message")
            .accessibilityIdentifier(recording ? "send-recording" : "send-voice-message-preview")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: controlSize)
        .disabled(isStaging)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recording ? "Recording" : "Voice message preview")
        .accessibilityValue(VoiceMessageDurationText.string(duration))
        .accessibilityIdentifier(recording ? "voice-recording-composer" : "voice-message-preview-composer")
    }

    private func symbol(_ name: String, weight: Font.Weight = .bold, send: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: name == "stop.fill" ? 13 : 17, weight: weight))
            .foregroundStyle(send ? (usesGiftWrap && colorScheme == .dark ? Color.black : .white) : .primary)
            .frame(width: 32, height: 32)
            .background(send ? accent : Color.primary.opacity(0.10), in: Circle())
            .frame(width: controlSize, height: controlSize)
            .contentShape(.rect)
    }
}

private enum VoiceMessageWaveformPresentation {
    case live
    case overview(progress: Double?)
}

private struct VoiceMessageWaveform: View {
    let samples: [Double]
    let presentation: VoiceMessageWaveformPresentation

    var body: some View {
        Canvas { context, size in
            let count = max(18, Int(size.width / 5))
            let levels: [Double] =
                switch presentation {
                case .live:
                    VoiceMessagePolicy.liveWaveformSamples(
                        from: samples,
                        count: count
                    )
                case .overview:
                    VoiceMessagePolicy.overviewWaveformSamples(
                        from: samples,
                        count: count
                    )
                }
            let spacing = size.width / CGFloat(count)

            for (index, level) in levels.enumerated() {
                let emphasizedLevel = pow(max(0, min(1, level)), 0.45)
                let normalizedHeight = 0.12 + emphasizedLevel * 0.88
                let height = max(
                    CGFloat(3),
                    size.height * CGFloat(normalizedHeight)
                )
                let rect = CGRect(
                    x: CGFloat(index) * spacing,
                    y: (size.height - height) / 2,
                    width: max(2, spacing * 0.48),
                    height: height
                )
                context.fill(
                    Path(
                        roundedRect: rect,
                        cornerRadius: rect.width / 2
                    ),
                    with: .color(color(for: index, count: levels.count))
                )
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }

    private func color(for index: Int, count: Int) -> Color {
        guard
            case let .overview(progress) = presentation,
            let progress
        else {
            return .secondary
        }
        let position = Double(index + 1) / Double(max(count, 1))
        return .primary.opacity(position <= progress ? 0.87 : 0.42)
    }
}

struct VoiceMessagePlaybackView: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @Environment(\.usesGiftWrap) private var usesGiftWrap
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color {
        usesGiftWrap ? GiftWrapAppearance.accent(colorScheme == .dark) : .indigo
    }

    let sourceURL: URL?
    let fallbackDuration: TimeInterval?
    let prepareSource: (() async -> URL?)?
    @State private var preparing = false
    @State private var preparationGeneration = UUID()

    @StateObject private var player = VoiceMessagePlayer()

    init(
        sourceURL: URL?,
        fallbackDuration: TimeInterval? = nil,
        prepareSource: (() async -> URL?)? = nil
    ) {
        self.sourceURL = sourceURL
        self.fallbackDuration = fallbackDuration
        self.prepareSource = prepareSource
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    Task { await togglePlayback() }
                } label: {
                    Group {
                        if player.state == .loading || preparing {
                            ActivitySpinner()
                        } else {
                            Image(
                                systemName: player.isPlaying
                                    ? "pause.fill"
                                    : "play.fill"
                            )
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(accent.opacity(0.16), in: .circle)
                }
                .disabled((sourceURL == nil && prepareSource == nil) || player.state == .loading || preparing)
                .accessibilityLabel(
                    player.isPlaying
                        ? "Pause voice message"
                        : "Play voice message"
                )

                VStack(alignment: .leading, spacing: 4) {
                    Slider(
                        value: progressBinding,
                        in: 0...1
                    )
                    .disabled(player.duration <= 0)
                    .tint(accent)
                    .accessibilityLabel("Voice message position")
                    .accessibilityValue(
                        VoiceMessageDurationText.string(player.currentTime)
                    )

                    HStack {
                        Text(VoiceMessageDurationText.string(player.currentTime))
                        Spacer()
                        Text(
                            VoiceMessageDurationText.string(
                                player.duration > 0
                                    ? player.duration
                                    : fallbackDuration ?? 0
                            )
                        )
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            if case let .failed(message) = player.state {
                HStack(spacing: 8) {
                    Text(message)
                        .lineLimit(1)
                    Spacer()
                    Button("Retry") {
                        Task { await togglePlayback() }
                    }
                    .font(.caption.weight(.semibold))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .frame(width: 250)
        .background(
            usesGiftWrap ? GiftWrapAppearance.incoming(colorScheme == .dark) : Color(.secondarySystemBackground),
            in: .rect(cornerRadius: 18)
        )
        .encryptedMediaLifetime(encryptedResolver) {
            if prepareSource != nil || sourceURL?.isFileURL == true { stopPlayback() }
        }
        .onDisappear { stopPlayback() }
    }

    private func stopPlayback() {
        preparationGeneration = UUID(); preparing = false; player.shutdown()
    }

    private var needsPreparation: Bool {
        switch player.state {
        case .idle, .failed: true
        default: false
        }
    }

    private func togglePlayback() async {
        guard !preparing else { return }
        let generation = preparationGeneration
        var url = sourceURL
        if let prepareSource, needsPreparation {
            preparing = true
            url = await prepareSource()
            guard generation == preparationGeneration, !Task.isCancelled else { return }
            preparing = false
        }
        guard generation == preparationGeneration, let url else { return }
        if prepareSource != nil {
            guard let encryptedResolver else { return }
            do { try encryptedResolver.validateActive() } catch { stopPlayback(); return }
        }
        await player.toggle(sourceURL: url)
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: { player.progress },
            set: { player.seek(to: $0) }
        )
    }
}
