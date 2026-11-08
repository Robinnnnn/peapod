import AppKit
import SwiftUI

/// Native pinch zoom and scrolling, keeping the fitted image's geometry stable when
/// original detail replaces a display copy of the same photo.
struct MacPhotoCanvas: NSViewRepresentable {
    let image: NSImage
    var onZoom: () -> Void

    func makeNSView(context: Context) -> PhotoScrollView {
        let scroll = PhotoScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 5
        scroll.imageView.imageScaling = .scaleProportionallyUpOrDown
        scroll.imageView.imageAlignment = .alignCenter
        scroll.documentView = scroll.imageView
        scroll.onZoom = onZoom
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main
        ) { [weak scroll] _ in
            MainActor.assumeIsolated {
                guard let scroll, scroll.magnification > 1 else { return }
                scroll.onZoom?()
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: PhotoScrollView, context: Context) {
        scroll.onZoom = onZoom
        scroll.imageView.image = image
        scroll.needsLayout = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    final class PhotoScrollView: NSScrollView {
        let imageView = NSImageView()
        var onZoom: (() -> Void)?
        override func layout() {
            super.layout()
            // contentSize is the unscaled viewport; don't resize the document as zoom changes.
            imageView.frame.size = contentSize
        }
    }
}
