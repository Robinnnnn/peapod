import AppKit
import ImageIO
import Testing
@testable import PeapodMac

struct MacPartnerPhotoCropTests {
    @Test func panAndZoomSelectTheVisibleRegionWithoutBlankEdges() throws {
        let image = try stripedImage()
        let centered = try #require(MacPartnerPhotoCrop.cropRect(
            image: image, viewportSide: 300, zoom: 1, offset: .zero
        ))
        #expect(centered == CGRect(x: 300, y: 0, width: 300, height: 300))

        let right = try #require(MacPartnerPhotoCrop.cropRect(
            image: image, viewportSide: 300, zoom: 1,
            offset: CGSize(width: -1_000, height: 100)
        ))
        #expect(right == CGRect(x: 600, y: 0, width: 300, height: 300))

        let zoomed = try #require(MacPartnerPhotoCrop.cropRect(
            image: image, viewportSide: 300, zoom: 2,
            offset: CGSize(width: -450, height: 0)
        ))
        #expect(zoomed == CGRect(x: 600, y: 75, width: 150, height: 150))
        #expect(MacPartnerPhotoCrop.cropRect(image: image, viewportSide: 0, zoom: 1, offset: .zero) == nil)
        #expect(MacPartnerPhotoCrop.cropRect(image: image, viewportSide: 300, zoom: 0, offset: .zero) == nil)
    }

    @Test func confirmedCropExportsABoundedJPEGFromTheSelectedPixels() throws {
        let image = try stripedImage()
        let centeredData = try #require(MacPartnerPhotoCrop.render(
            image: image, viewportSide: 300, zoom: 1, offset: .zero
        ))
        let rightData = try #require(MacPartnerPhotoCrop.render(
            image: image, viewportSide: 300, zoom: 1, offset: CGSize(width: -300, height: 0)
        ))
        let centered = try decoded(centeredData)
        let right = try decoded(rightData)
        #expect(centered.width == 512 && centered.height == 512)
        #expect(right.width == 512 && right.height == 512)
        let center = centerPixel(centered)
        let rightCenter = centerPixel(right)
        #expect(center[1] > 240 && center[0] < 20 && center[2] < 20)
        #expect(rightCenter[2] > 240 && rightCenter[0] < 20 && rightCenter[1] < 20)
    }

    @Test func verticalPanSelectsTheSameEndOfTheImageShownInTheEditor() throws {
        let context = try #require(CGContext(
            data: nil, width: 300, height: 900, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for (index, color) in [NSColor.red, .green, .blue].enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: index * 300, width: 300, height: 300))
        }
        let image = try #require(context.makeImage())
        let top = try decoded(#require(MacPartnerPhotoCrop.render(
            image: image, viewportSide: 300, zoom: 1,
            offset: CGSize(width: 0, height: 300)
        )))
        let bottom = try decoded(#require(MacPartnerPhotoCrop.render(
            image: image, viewportSide: 300, zoom: 1,
            offset: CGSize(width: 0, height: -300)
        )))
        let topCenter = centerPixel(top), bottomCenter = centerPixel(bottom)
        #expect(topCenter[2] > 240 && topCenter[0] < 20 && topCenter[1] < 20)
        #expect(bottomCenter[0] > 240 && bottomCenter[1] < 20 && bottomCenter[2] < 20)
    }

    private func stripedImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 900, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for (index, color) in [NSColor.red, .green, .blue].enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: index * 300, y: 0, width: 300, height: 300))
        }
        return try #require(context.makeImage())
    }

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func centerPixel(_ image: CGImage) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -255, y: -255, width: 512, height: 512))
        return bytes.prefix(3).map(Int.init)
    }
}
