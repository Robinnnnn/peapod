import AppKit
@preconcurrency import AVFoundation
import AVKit
@preconcurrency import FirebaseStorage
import Foundation
import Observation
import SwiftUI

/// Owns one explicit video presentation. Encrypted metadata stays pinned from the
/// synchronous tap through loading/playback; dismissal or invalidation revokes it.
@MainActor @Observable
final class MacVideoPreviewModel {
    private(set) var isPresented = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var player: AVPlayer?
    @ObservationIgnored private(set) var loadingTask: Task<Void, Never>?
    @ObservationIgnored private let metadataLease = EncryptedMediaPresentationLease()
    @ObservationIgnored private var invalidation: ServiceObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var attachment: AttachmentContent?
    @ObservationIgnored private var resolver: EncryptedAttachmentResolver?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let legacyURL: @MainActor (String) async throws -> URL

    init(legacyURL: @escaping @MainActor (String) async throws -> URL = { path in

        return try await Storage.storage().reference(withPath: path).downloadURL()
    }) { self.legacyURL = legacyURL }

    func present(attachment: AttachmentContent, resolver: EncryptedAttachmentResolver?) {
        close()
        guard attachment.type == .video, attachment.storagePath != nil else {
            errorMessage = "Video unavailable. Try again."
            return
        }
        do {
            try EncryptedMediaLoading.validate(attachment, resolver: resolver)
            try metadataLease.acquire([attachment], resolver: resolver)
            self.attachment = attachment
            self.resolver = resolver
            if EncryptedMediaLoading.isEncrypted(attachment) {
                guard let resolver else { throw EncryptedMediaError.unavailable }
                invalidation = resolver.observeInvalidation { [weak self] in self?.close() }
                try resolver.validateActive()
            }
            isPresented = true
            startLoading()
        } catch {
            close()
            errorMessage = "Video unavailable. Try again."
        }
    }

    func retry() {
        guard isPresented else { return }
        startLoading()
    }

    func close() {
        generation = UUID()
        loadingTask?.cancel(); loadingTask = nil
        stopPlayer()
        invalidation?.cancel(); invalidation = nil
        metadataLease.release()
        attachment = nil; resolver = nil
        isLoading = false; isPresented = false; errorMessage = nil
    }

    private func stopPlayer() {
        itemObservation?.invalidate(); itemObservation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
    }

    private func startLoading() {
        generation = UUID()
        let operation = generation
        loadingTask?.cancel()
        stopPlayer()
        errorMessage = nil
        guard isPresented, let attachment, let path = attachment.storagePath else { return }
        let resolver = resolver
        do {
            try EncryptedMediaLoading.validate(attachment, resolver: resolver)
            try metadataLease.acquire([attachment], resolver: resolver)
        } catch { fail(operation); return }
        isLoading = true
        loadingTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == operation { self.loadingTask = nil } }
            do {
                let url = try await EncryptedMediaLoading.url(attachment, resolver: resolver) {
                    try await self.legacyURL(path)
                }
                try self.requireCurrent(operation, attachment: attachment, resolver: resolver)
                let asset = AVURLAsset(url: url)
                guard try await asset.load(.isPlayable) else { throw EncryptedMediaError.unavailable }
                try self.requireCurrent(operation, attachment: attachment, resolver: resolver)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard !tracks.isEmpty else { throw EncryptedMediaError.unavailable }
                try self.requireCurrent(operation, attachment: attachment, resolver: resolver)
                let item = AVPlayerItem(asset: asset)
                let prepared = AVPlayer(playerItem: item)
                // Playback begins only through the visible native player controls.
                self.player = prepared
                self.itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == operation,
                              self.player?.currentItem === item, item.status == .failed else { return }
                        self.fail(operation)
                    }
                }
                // Keep loading visible until AVFoundation has actually prepared the item.
                // A stalled item offers retry rather than leaving an endless loading sheet.
                for _ in 0..<300 {
                    try self.requireCurrent(operation, attachment: attachment, resolver: resolver)
                    switch item.status {
                    case .readyToPlay:
                        self.isLoading = false
                        return
                    case .failed: throw EncryptedMediaError.unavailable
                    case .unknown: try await Task.sleep(for: .milliseconds(100))
                    @unknown default: throw EncryptedMediaError.unavailable
                    }
                }
                throw EncryptedMediaError.unavailable
            } catch {
                guard self.generation == operation, self.isPresented else { return }
                self.fail(operation)
            }
        }
    }

    private func requireCurrent(_ operation: UUID, attachment: AttachmentContent,
                                resolver: EncryptedAttachmentResolver?) throws {
        guard isPresented, generation == operation else { throw CancellationError() }
        try EncryptedMediaLoading.validate(attachment, resolver: resolver)
    }

    private func fail(_ operation: UUID) {
        guard generation == operation, isPresented else { return }
        stopPlayer()
        isLoading = false
        errorMessage = "Video unavailable. Try again."
    }
}

/// Uses explicit inline native transport controls, including keyboard/accessibility
/// support, while the presentation model owns loading and session invalidation.
private struct MacNativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

struct MacVideoPreview: View {
    @Environment(\.dismiss) private var dismiss
    let model: MacVideoPreviewModel
    let fileName: String
    let save: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let player = model.player {
                    MacNativeVideoPlayer(player: player)
                        .accessibilityIdentifier("video-player")
                }
                if model.isLoading {
                    ProgressView("Loading video…")
                        .padding(20)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                        .accessibilityIdentifier("video-loading")
                } else if let errorMessage = model.errorMessage {
                    VStack(spacing: 10) {
                        Text(errorMessage)
                        Button("Try Again") { model.retry() }
                            .accessibilityIdentifier("video-retry")
                    }.padding(20)
                }
            }
            .frame(minWidth: 560, minHeight: 320)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(fileName).lineLimit(1)
                Spacer()
                Button("Save…", action: save)
                Button("Done") { model.close(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("close-video-preview")
            }.padding(14)
        }
        .frame(idealWidth: 720, idealHeight: 460)
        .accessibilityIdentifier("video-preview")
        .onDisappear { model.close() }
    }
}
