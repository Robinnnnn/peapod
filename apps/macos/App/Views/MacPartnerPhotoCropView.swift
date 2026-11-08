import AppKit
import ImageIO
import SwiftUI

struct MacPartnerPhotoSelection: Identifiable {
    let id = UUID()
    let image: CGImage
    let target: SecureConversationResetTarget
}

/// The file panel only selects an image. The local profile photo changes after confirmation.
struct MacPartnerPhotoCropView: View {
    let image: CGImage
    let onCancel: () -> Void
    let onSave: (Data) -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var dragOrigin = CGSize.zero
    @State private var pinchStartZoom: CGFloat?

    private let side: CGFloat = 300

    private var imageScale: CGFloat {
        max(side / CGFloat(image.width), side / CGFloat(image.height)) * zoom
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Move and Scale").font(.title2.bold())

            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: CGFloat(image.width) * imageScale,
                       height: CGFloat(image.height) * imageScale)
                .offset(offset)
                .frame(width: side, height: side)
                .background(.black)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1) }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        offset = MacPartnerPhotoCrop.clamp(
                            CGSize(width: dragOrigin.width + value.translation.width,
                                   height: dragOrigin.height + value.translation.height),
                            image: image, viewportSide: side, zoom: zoom
                        )
                    }
                    .onEnded { _ in dragOrigin = offset })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStartZoom ?? zoom
                        if pinchStartZoom == nil { pinchStartZoom = start }
                        zoom = min(max(start * value.magnification, 1), 6)
                        offset = MacPartnerPhotoCrop.clamp(offset, image: image, viewportSide: side, zoom: zoom)
                        dragOrigin = offset
                    }
                    .onEnded { _ in pinchStartZoom = nil })
                .accessibilityLabel("Photo crop")
                .accessibilityHint("Drag to move the photo. Pinch or use the zoom slider to scale it.")
                .accessibilityIdentifier("partner-photo-crop-canvas")

            HStack(spacing: 12) {
                Image(systemName: "minus.magnifyingglass")
                    .accessibilityHidden(true)
                Slider(value: $zoom, in: 1...6)
                    .accessibilityLabel("Zoom")
                    .onChange(of: zoom) { _, newValue in
                        offset = MacPartnerPhotoCrop.clamp(offset, image: image, viewportSide: side, zoom: newValue)
                        dragOrigin = offset
                    }
                Image(systemName: "plus.magnifyingglass")
                    .accessibilityHidden(true)
            }
            .frame(width: side)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Photo") {
                    guard let data = MacPartnerPhotoCrop.render(
                        image: image, viewportSide: side, zoom: zoom, offset: offset
                    ) else { return }
                    onSave(data)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("partner-photo-crop-save")
            }
        }
        .padding(28)
        .frame(width: 380)
    }
}

enum MacPartnerPhotoCrop {
    static func decode(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    static func clamp(_ offset: CGSize, image: CGImage, viewportSide: CGFloat, zoom: CGFloat) -> CGSize {
        guard viewportSide.isFinite, viewportSide > 0, zoom.isFinite, zoom >= 1 else { return .zero }
        let scale = max(viewportSide / CGFloat(image.width), viewportSide / CGFloat(image.height)) * zoom
        let horizontal = max(0, (CGFloat(image.width) * scale - viewportSide) / 2)
        let vertical = max(0, (CGFloat(image.height) * scale - viewportSide) / 2)
        return CGSize(width: min(max(offset.width, -horizontal), horizontal),
                      height: min(max(offset.height, -vertical), vertical))
    }

    /// Offsets are in viewport points; cropping uses the same aspect-fill geometry as the editor.
    static func cropRect(image: CGImage, viewportSide: CGFloat, zoom: CGFloat, offset: CGSize) -> CGRect? {
        guard viewportSide.isFinite, viewportSide > 0, zoom.isFinite, zoom >= 1,
              offset.width.isFinite, offset.height.isFinite else { return nil }
        let scale = max(viewportSide / CGFloat(image.width), viewportSide / CGFloat(image.height)) * zoom
        let side = min(viewportSide / scale, CGFloat(image.width), CGFloat(image.height))
        guard side.isFinite, side > 0 else { return nil }
        let limited = clamp(offset, image: image, viewportSide: viewportSide, zoom: zoom)
        let x = min(max(0, (CGFloat(image.width) - side) / 2 - limited.width / scale), CGFloat(image.width) - side)
        let y = min(max(0, (CGFloat(image.height) - side) / 2 - limited.height / scale), CGFloat(image.height) - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    static func render(image: CGImage, viewportSide: CGFloat, zoom: CGFloat, offset: CGSize) -> Data? {
        guard let rect = cropRect(image: image, viewportSide: viewportSide, zoom: zoom, offset: offset),
              let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        let scale = 512 / rect.width
        // SwiftUI displays the image top-down; the bitmap context draws from the bottom.
        let bottomOriginY = CGFloat(image.height) - rect.maxY
        context.draw(image, in: CGRect(x: -rect.minX * scale, y: -bottomOriginY * scale,
                                       width: CGFloat(image.width) * scale,
                                       height: CGFloat(image.height) * scale))
        guard let cropped = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
