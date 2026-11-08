@preconcurrency import AVFoundation
import Foundation

@MainActor
protocol VoicePlaybackBackend: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var didFinish: ((Bool) -> Void)? { get set }

    func load(url: URL) throws
    func play() throws
    func pause()
    func stop()
}

@MainActor
final class SystemVoicePlaybackBackend: NSObject, VoicePlaybackBackend {
    var didFinish: ((Bool) -> Void)?

    private let session: AVAudioSession
    private var player: AVAudioPlayer?

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        super.init()
    }

    var isPlaying: Bool {
        player?.isPlaying == true
    }

    var currentTime: TimeInterval {
        get { player?.currentTime ?? 0 }
        set { player?.currentTime = max(0, min(newValue, duration)) }
    }

    var duration: TimeInterval {
        player?.duration ?? 0
    }

    func load(url: URL) throws {
        stop()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.prepareToPlay() else {
                throw VoiceMessageError.missingRecording
            }
            self.player = player
        } catch {
            deactivateSession()
            throw error
        }
    }

    func play() throws {
        guard let player else {
            throw VoiceMessageError.missingRecording
        }
        try session.setActive(true)
        guard player.play() else {
            throw VoiceMessageError.missingRecording
        }
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        player?.stop()
        player = nil
        deactivateSession()
    }

    private func deactivateSession() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension SystemVoicePlaybackBackend: @preconcurrency AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.didFinish?(flag)
        }
    }

    func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            self?.didFinish?(false)
        }
    }
}

actor VoiceMessageAudioResolver {
    private let fileManager: FileManager
    private let session: URLSession

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.session = session
    }

    func resolve(_ sourceURL: URL) async throws -> ResolvedVoiceMessageAudio {
        guard !sourceURL.isFileURL else {
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw VoiceMessageError.missingRecording
            }
            return ResolvedVoiceMessageAudio(
                localURL: sourceURL,
                shouldDelete: false
            )
        }

        let (temporaryURL, response) = try await session.download(from: sourceURL)
        guard
            let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
        else {
            throw VoiceMessageError.invalidDownloadResponse
        }

        let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
        let byteSize = Int64(values.fileSize ?? 0)
        guard byteSize <= VoiceMessagePolicy.maximumDownloadByteSize else {
            throw VoiceMessageError.downloadTooLarge
        }
        guard byteSize > 0 else {
            throw VoiceMessageError.emptyRecording
        }

        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "mines-voice-playback",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let destination = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(
                VoiceMessageDraft.preferredFilenameExtension
            )
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return ResolvedVoiceMessageAudio(
            localURL: destination,
            shouldDelete: true
        )
    }
}

struct ResolvedVoiceMessageAudio: Sendable {
    let localURL: URL
    let shouldDelete: Bool
}

@MainActor
final class VoiceMessagePlayer: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private let backend: any VoicePlaybackBackend
    private let resolver: @Sendable (URL) async throws
        -> ResolvedVoiceMessageAudio
    private let fileManager: FileManager
    private var sourceURL: URL?
    private var resolvedAudio: ResolvedVoiceMessageAudio?
    private var progressTimer: Timer?
    private var loadGeneration = UUID()
    private var interruptionObserver: NSObjectProtocol?

    init(
        backend: any VoicePlaybackBackend =
            SystemVoicePlaybackBackend(),
        resolver: @escaping @Sendable (URL) async throws
            -> ResolvedVoiceMessageAudio = {
                try await VoiceMessageAudioResolver().resolve($0)
            },
        fileManager: FileManager = .default
    ) {
        self.backend = backend
        self.resolver = resolver
        self.fileManager = fileManager
        backend.didFinish = { [weak self] successfully in
            self?.playbackDidFinish(successfully: successfully)
        }
        observeInterruptions()
    }

    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
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
            Task { @MainActor [weak self] in
                self?.pause()
            }
        }
    }

    var isPlaying: Bool {
        state == .playing
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    func toggle(sourceURL: URL) async {
        observeInterruptions()
        if self.sourceURL == sourceURL {
            switch state {
            case .playing:
                pause()
                return
            case .paused:
                resume()
                return
            case .loading:
                return
            default:
                break
            }
        }
        await loadAndPlay(sourceURL: sourceURL)
    }

    func seek(to progress: Double) {
        guard duration > 0 else { return }
        let clamped = min(1, max(0, progress))
        backend.currentTime = duration * clamped
        currentTime = backend.currentTime
    }

    func pause() {
        guard state == .playing else { return }
        backend.pause()
        stopProgressTimer()
        currentTime = backend.currentTime
        state = .paused
    }

    func stop() {
        loadGeneration = UUID()
        stopProgressTimer()
        backend.stop()
        cleanupResolvedAudio()
        sourceURL = nil
        currentTime = 0
        duration = 0
        state = .idle
    }

    func shutdown() {
        stop()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    private func loadAndPlay(sourceURL: URL) async {
        stop()
        let generation = UUID()
        loadGeneration = generation
        self.sourceURL = sourceURL
        state = .loading

        do {
            let resolved = try await resolver(sourceURL)
            try Task.checkCancellation()
            guard loadGeneration == generation else {
                if resolved.shouldDelete {
                    try? fileManager.removeItem(at: resolved.localURL)
                }
                return
            }
            resolvedAudio = resolved
            try backend.load(url: resolved.localURL)
            duration = backend.duration
            currentTime = 0
            try backend.play()
            state = .playing
            startProgressTimer()
        } catch is CancellationError {
            guard loadGeneration == generation else { return }
            if self.sourceURL == sourceURL {
                state = .idle
            }
        } catch {
            guard loadGeneration == generation else { return }
            cleanupResolvedAudio()
            state = .failed(error.localizedDescription)
        }
    }

    private func resume() {
        do {
            if duration > 0, backend.currentTime >= duration {
                backend.currentTime = 0
            }
            try backend.play()
            state = .playing
            startProgressTimer()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func playbackDidFinish(successfully: Bool) {
        guard state == .playing || state == .paused else { return }
        stopProgressTimer()
        if successfully {
            currentTime = duration
            state = .paused
        } else {
            currentTime = backend.currentTime
            backend.stop()
            cleanupResolvedAudio()
            state = .failed("Couldn't play this recording. Try again.")
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .playing else { return }
                self.currentTime = self.backend.currentTime
                self.duration = self.backend.duration
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func cleanupResolvedAudio() {
        guard let resolvedAudio else { return }
        if resolvedAudio.shouldDelete {
            try? fileManager.removeItem(at: resolvedAudio.localURL)
        }
        self.resolvedAudio = nil
    }
}
