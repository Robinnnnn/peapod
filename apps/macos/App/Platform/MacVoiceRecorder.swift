@preconcurrency import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class MacVoiceRecorder: NSObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case ready
        case permissionDenied
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var meterLevel: Double = 0
    private(set) var waveformSamples: [Double] = []
    private(set) var draft: VoiceMessageDraft?
    private(set) var isPreviewPlaying = false
    private(set) var previewTime: TimeInterval = 0
    private(set) var previewErrorMessage: String?

    private let draftStore: MacVoiceMessageDraftStore
    private(set) var scope: MacVoiceMessageDraftStore.Scope?
    private var recordingID = UUID()
    private var recordingCreatedAt = Date.now
    private var operationGeneration = UUID()
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var recordingURL: URL?
    private var previewPlayer: AVAudioPlayer?
    private var previewTimer: Timer?

    init(draftStore: MacVoiceMessageDraftStore = MacVoiceMessageDraftStore()) {
        self.draftStore = draftStore
        super.init()
    }

    func configure(scope: MacVoiceMessageDraftStore.Scope, acceptedDraftIDs: Set<UUID> = []) {
        if self.scope != scope { detach(); self.scope = scope }
        guard draft == nil, state != .recording, state != .requestingPermission else { return }
        do {
            let recovered = try draftStore.load(in: scope) { url in
                try AVAudioPlayer(contentsOf: url).duration
            }
            for item in recovered where acceptedDraftIDs.contains(item.id) {
                draftStore.remove(item, in: scope)
            }
            if let ready = recovered.first(where: { !acceptedDraftIDs.contains($0.id) }) {
                draft = ready
                recordingURL = ready.fileURL
                elapsedTime = ready.duration
                state = .ready
            }
        } catch { state = .failed(error.localizedDescription) }
    }

    /// Navigation may stop capture/playback, but does not discard the composer draft.
    func suspend() {
        operationGeneration = UUID()
        if state == .recording { finish() }
        if state == .requestingPermission { state = .idle }
        stopPreview()
    }

    /// Session/assignment boundaries revoke in-memory access; scoped files stay recoverable.
    func detach() {
        suspend()
        scope = nil
        clearDraftState()
    }

    func discardAccount(_ accountID: String) throws {
        if scope?.accountID == accountID { detach() }
        try draftStore.removeAccount(accountID)
    }

    var previewProgress: Double {
        guard let draft, draft.duration > 0 else { return 0 }
        return min(max(previewTime / draft.duration, 0), 1)
    }

    func togglePreview() {
        guard state == .ready, let draft else { return }
        if isPreviewPlaying {
            previewPlayer?.pause()
            stopPreviewTimer()
            isPreviewPlaying = false
            return
        }

        do {
            let player = try preparePreviewPlayer(for: draft)
            if player.currentTime >= player.duration {
                player.currentTime = 0
                previewTime = 0
            }
            guard player.play() else {
                previewErrorMessage = "Couldn't play this recording. Try again."
                return
            }
            previewErrorMessage = nil
            isPreviewPlaying = true
            startPreviewTimer()
        } catch {
            previewErrorMessage = "Couldn't play this recording. Try again."
        }
    }

    func seekPreview(to progress: Double) {
        guard state == .ready, progress.isFinite, let draft else { return }
        do {
            let player = try preparePreviewPlayer(for: draft)
            previewTime = player.duration * min(max(progress, 0), 1)
            player.currentTime = previewTime
            previewErrorMessage = nil
        } catch {
            previewErrorMessage = "Couldn't play this recording. Try again."
        }
    }

    private func preparePreviewPlayer(
        for draft: VoiceMessageDraft
    ) throws -> AVAudioPlayer {
        if let previewPlayer { return previewPlayer }
        let player = try AVAudioPlayer(contentsOf: draft.fileURL)
        player.prepareToPlay()
        previewPlayer = player
        return player
    }

    func start() async {
        guard state != .recording, state != .requestingPermission else {
            return
        }

        // A ready draft is replaced only by explicit Discard.
        guard draft == nil, let scope else { return }
        operationGeneration = UUID()
        let operation = operationGeneration
        state = .requestingPermission
        let permitted = await requestMicrophoneAccess()
        guard operationGeneration == operation, self.scope == scope else { return }
        guard permitted else {
            state = .permissionDenied
            return
        }

        do {
            recordingID = UUID()
            recordingCreatedAt = .now
            let url = try draftStore.recordingURL(id: recordingID, createdAt: recordingCreatedAt, in: scope)
            recordingURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey:
                    AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(
                url: url,
                settings: settings
            )
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard
                recorder.prepareToRecord(),
                recorder.record(
                    forDuration: VoiceMessagePolicy.maximumDuration
                )
            else {
                throw VoiceMessageError.couldNotStartRecording
            }

            self.recorder = recorder
            recordingURL = url
            elapsedTime = 0
            meterLevel = 0
            waveformSamples = []
            state = .recording
            startMetering()
        } catch {
            cleanupRecording()
            state = .failed(error.localizedDescription)
        }
    }

    func finish() {
        guard state == .recording else { return }
        let duration = max(elapsedTime, recorder?.currentTime ?? 0)
        recorder?.stop()
        recorder = nil
        stopMetering()

        guard let recordingURL else {
            state = .failed(
                VoiceMessageError.missingRecording.localizedDescription
            )
            return
        }
        guard duration >= VoiceMessagePolicy.minimumDuration else {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
            state = .failed(
                VoiceMessageError.recordingTooShort.localizedDescription
            )
            return
        }

        do {
            let size = Int64(
                try recordingURL.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize ?? 0
            )
            guard size > 0 else {
                throw VoiceMessageError.emptyRecording
            }
            let finished = VoiceMessageDraft(id: recordingID, fileURL: recordingURL,
                duration: duration, byteSize: size, createdAt: recordingCreatedAt)
            draft = finished
            elapsedTime = duration
            state = .ready
            if let scope {
                do {
                    let saved = try draftStore.persist(finished, in: scope)
                    draft = saved
                    self.recordingURL = saved.fileURL
                } catch {
                    // Keep the playable source and retryable draft if finalization fails.
                    previewErrorMessage = "This recording is still on this device. Try sending it again."
                }
            }
        } catch {
            cleanupRecording()
            state = .failed(error.localizedDescription)
        }
    }

    /// Explicit user discard is the only navigation-independent deletion action.
    func cancel() {
        operationGeneration = UUID()
        recorder?.stop()
        recorder = nil
        stopMetering()
        if let draft, let scope { draftStore.remove(draft, in: scope) }
        else if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        clearDraftState()
        if let scope { configure(scope: scope) }
    }

    /// Call only after the existing durable outbox accepted this exact draft.
    func markDraftConsumed() {
        let consumedID = draft?.id
        if let draft, let scope { draftStore.remove(draft, in: scope) }
        clearDraftState()
        if let scope { configure(scope: scope, acceptedDraftIDs: Set([consumedID].compactMap { $0 })) }
    }

    private func clearDraftState() {
        stopPreview()
        recordingURL = nil
        draft = nil
        elapsedTime = 0
        meterLevel = 0
        waveformSamples = []
        state = .idle
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func startMetering() {
        stopMetering()
        let timer = Timer(
            timeInterval: VoiceMessagePolicy.meterSamplingInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateMeter()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func updateMeter() {
        guard let recorder, state == .recording else { return }
        recorder.updateMeters()
        elapsedTime = min(
            recorder.currentTime,
            VoiceMessagePolicy.maximumDuration
        )
        meterLevel = VoiceMessagePolicy.normalizedMeterLevel(
            decibels: recorder.averagePower(forChannel: 0)
        )
        waveformSamples.append(meterLevel)
        if waveformSamples.count > 48 { waveformSamples.removeFirst(waveformSamples.count - 48) }
        if elapsedTime >= VoiceMessagePolicy.maximumDuration {
            finish()
        }
    }

    private func cleanupRecording() {
        stopPreview()
        recorder?.stop()
        recorder = nil
        stopMetering()
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        draft = nil
        elapsedTime = 0
        meterLevel = 0
        waveformSamples = []
    }

    private func startPreviewTimer() {
        stopPreviewTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.previewPlayer else { return }
                if player.isPlaying {
                    self.previewTime = player.currentTime
                } else {
                    self.stopPreviewTimer()
                    self.isPreviewPlaying = false
                    self.previewTime = 0
                    player.currentTime = 0
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func stopPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    private func stopPreview() {
        stopPreviewTimer()
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewPlaying = false
        previewTime = 0
        previewErrorMessage = nil
    }
}

extension MacVoiceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        guard !flag else { return }
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.cancel()
            self.state = .failed(
                VoiceMessageError.couldNotStartRecording.localizedDescription
            )
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.cancel()
            self.state = .failed(
                error?.localizedDescription
                    ?? VoiceMessageError.couldNotStartRecording
                        .localizedDescription
            )
        }
    }
}
