@preconcurrency import AVFoundation
import Foundation
import UIKit

enum MicrophoneAuthorization: Equatable {
    case undetermined
    case denied
    case granted
}

@MainActor
protocol MicrophonePermissionProviding {
    var authorization: MicrophoneAuthorization { get }
    func requestAuthorization() async -> Bool
}

@MainActor
struct SystemMicrophonePermissionProvider: MicrophonePermissionProviding {
    var authorization: MicrophoneAuthorization {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            return .undetermined
        case .denied:
            return .denied
        case .granted:
            return .granted
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

@MainActor
protocol VoiceRecordingBackend: AnyObject {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    var averagePower: Float { get }
    var didStop: ((Bool) -> Void)? { get set }

    func startRecording(
        to url: URL,
        maximumDuration: TimeInterval
    ) throws
    func updateMeters()
    func stopRecording() -> TimeInterval
    func cancelRecording()
}

@MainActor
final class SystemVoiceRecordingBackend: NSObject, VoiceRecordingBackend {
    var didStop: ((Bool) -> Void)?

    private let session: AVAudioSession
    private var recorder: AVAudioRecorder?

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        super.init()
    }

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    var currentTime: TimeInterval {
        recorder?.currentTime ?? 0
    }

    var averagePower: Float {
        recorder?.averagePower(forChannel: 0) ?? -160
    }

    func startRecording(
        to url: URL,
        maximumDuration: TimeInterval
    ) throws {
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record(forDuration: maximumDuration) else {
                throw VoiceMessageError.couldNotStartRecording
            }
            self.recorder = recorder
        } catch {
            try? session.setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            throw error
        }
    }

    func updateMeters() {
        recorder?.updateMeters()
    }

    func stopRecording() -> TimeInterval {
        let duration = currentTime
        recorder?.stop()
        recorder = nil
        deactivateSession()
        return duration
    }

    func cancelRecording() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        deactivateSession()
    }

    private func deactivateSession() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension SystemVoiceRecordingBackend: @preconcurrency AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.didStop?(flag)
        }
    }

    func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            self?.didStop?(false)
        }
    }
}

@MainActor
final class VoiceMessageRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case ready
        case permissionDenied
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var meterSamples: [Double] = []
    @Published private(set) var draft: VoiceMessageDraft?

    private let permissionProvider: any MicrophonePermissionProviding
    private let backend: any VoiceRecordingBackend
    private let fileManager: FileManager
    private let draftStore: VoiceMessageDraftStore
    private let recordingsDirectory: URL
    private var recordingURL: URL?
    private var meterTimer: Timer?
    private var isFinalizing = false
    private var notificationObservers: [NSObjectProtocol] = []

    init(
        permissionProvider: any MicrophonePermissionProviding =
            SystemMicrophonePermissionProvider(),
        backend: any VoiceRecordingBackend =
            SystemVoiceRecordingBackend(),
        fileManager: FileManager = .default,
        recordingsDirectory: URL? = nil,
        draftStore: VoiceMessageDraftStore? = nil
    ) {
        self.permissionProvider = permissionProvider
        self.backend = backend
        self.fileManager = fileManager
        let resolvedDraftStore = draftStore
            ?? VoiceMessageDraftStore(
                fileManager: fileManager,
                rootDirectory: recordingsDirectory?.appendingPathComponent(
                    "Persisted",
                    isDirectory: true
                )
            )
        self.draftStore = resolvedDraftStore
        self.recordingsDirectory = recordingsDirectory
            ?? resolvedDraftStore.recordingsDirectory

        backend.didStop = { [weak self] successfully in
            self?.recordingBackendDidStop(successfully: successfully)
        }
        observeInterruptions()
    }

    var isRecording: Bool {
        state == .recording
    }

    func start() async {
        guard state != .requestingPermission, state != .recording else {
            return
        }

        observeInterruptions()
        discardCurrentDraft()
        state = .requestingPermission

        let granted: Bool
        switch permissionProvider.authorization {
        case .granted:
            granted = true
        case .denied:
            granted = false
        case .undetermined:
            granted = await permissionProvider.requestAuthorization()
        }

        guard granted else {
            state = .permissionDenied
            return
        }

        do {
            try fileManager.createDirectory(
                at: recordingsDirectory,
                withIntermediateDirectories: true,
                attributes: [
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication,
                ]
            )
            removeAbandonedRecordings()

            let url = recordingsDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(
                    VoiceMessageDraft.preferredFilenameExtension
                )
            recordingURL = url
            elapsedTime = 0
            meterSamples = []
            try backend.startRecording(
                to: url,
                maximumDuration: VoiceMessagePolicy.maximumDuration
            )
            state = .recording
            startMeterTimer()
        } catch {
            cleanupFailedRecording()
            state = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func finish() -> VoiceMessageDraft? {
        guard state == .recording, !isFinalizing else {
            return draft
        }

        isFinalizing = true
        let duration = max(elapsedTime, backend.stopRecording())
        stopMeterTimer()
        completeRecording(duration: duration)
        isFinalizing = false
        return draft
    }

    func cancel() {
        stopMeterTimer()
        if backend.isRecording {
            backend.cancelRecording()
        }
        discardDraftFiles()
        elapsedTime = 0
        meterSamples = []
        isFinalizing = false
        state = .idle
    }

    /// Call after the draft has been copied into the durable outbox.
    func markDraftStaged() {
        if let draft {
            draftStore.remove(draft)
        }
        recordingURL = nil
        draft = nil
        elapsedTime = 0
        meterSamples = []
        state = .idle
    }

    func discardCurrentDraft() {
        discardDraftFiles()
        elapsedTime = 0
        meterSamples = []
        if !isRecording {
            state = .idle
        }
    }

    func stopForViewDisappearance() {
        if isRecording {
            cancel()
        } else {
            stopMeterTimer()
        }
    }

    func shutdown() {
        stopForViewDisappearance()
        let center = NotificationCenter.default
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func completeRecording(duration: TimeInterval) {
        guard let url = recordingURL else {
            state = .failed(VoiceMessageError.missingRecording.localizedDescription)
            return
        }
        guard duration >= VoiceMessagePolicy.minimumDuration else {
            try? fileManager.removeItem(at: url)
            recordingURL = nil
            elapsedTime = 0
            meterSamples = []
            state = .failed(VoiceMessageError.recordingTooShort.localizedDescription)
            return
        }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let byteSize = Int64(values.fileSize ?? 0)
            guard byteSize > 0 else {
                throw VoiceMessageError.emptyRecording
            }

            elapsedTime = duration
            let completedDraft = VoiceMessageDraft(
                fileURL: url,
                duration: duration,
                byteSize: byteSize
            )
            draft = try draftStore.persist(completedDraft)
            recordingURL = nil
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func recordingBackendDidStop(successfully: Bool) {
        guard state == .recording, !isFinalizing else { return }

        isFinalizing = true
        let duration = max(elapsedTime, backend.stopRecording())
        stopMeterTimer()
        if successfully {
            completeRecording(duration: duration)
        } else {
            cleanupFailedRecording()
            state = .failed(VoiceMessageError.couldNotStartRecording.localizedDescription)
        }
        isFinalizing = false
    }

    private func startMeterTimer() {
        stopMeterTimer()
        let timer = Timer(
            timeInterval: VoiceMessagePolicy.meterSamplingInterval,
            repeats: true
        ) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateMeter()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func updateMeter() {
        guard state == .recording else { return }
        backend.updateMeters()
        elapsedTime = min(
            backend.currentTime,
            VoiceMessagePolicy.maximumDuration
        )
        let meterLevel = VoiceMessagePolicy.normalizedMeterLevel(
            decibels: backend.averagePower
        )
        VoiceMessagePolicy.appendMeterLevel(
            meterLevel,
            to: &meterSamples
        )
        if elapsedTime >= VoiceMessagePolicy.maximumDuration {
            _ = finish()
        }
    }

    private func cleanupFailedRecording() {
        stopMeterTimer()
        backend.cancelRecording()
        if let recordingURL {
            try? fileManager.removeItem(at: recordingURL)
        }
        recordingURL = nil
        draft = nil
        elapsedTime = 0
        meterSamples = []
    }

    private func observeInterruptions() {
        guard notificationObservers.isEmpty else { return }

        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let interruptionBegan =
                    (notification.userInfo?[
                        AVAudioSessionInterruptionTypeKey
                    ] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                    == .began
                guard interruptionBegan else { return }
                MainActor.assumeIsolated {
                    _ = self?.finish()
                }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    _ = self?.finish()
                }
            }
        )
    }

    private func removeAbandonedRecordings() {
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: recordingsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)
        for url in urls {
            let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if modified.map({ $0 < cutoff }) == true {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func discardDraftFiles() {
        if let draft {
            draftStore.remove(draft)
        } else if let recordingURL {
            try? fileManager.removeItem(at: recordingURL)
        }
        recordingURL = nil
        draft = nil
    }
}
