import Foundation

/// Single photos retain their proportions; only extreme panoramas need a
/// small letterboxed hit area. Loading keeps the existing stable placeholder.
enum ChatPhotoLayout {
    static func size(for imageSize: CGSize?, maximum: CGSize, placeholder: CGSize) -> CGSize {
        guard let imageSize,
              imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return placeholder }
        let ratio = imageSize.width / imageSize.height
        guard ratio.isFinite, ratio > 0 else { return placeholder }

        let fitted: CGSize
        if ratio >= maximum.width / maximum.height {
            fitted = CGSize(width: maximum.width, height: maximum.width / ratio)
        } else {
            fitted = CGSize(width: maximum.height * ratio, height: maximum.height)
        }
        return CGSize(width: min(maximum.width, max(44, fitted.width)),
                      height: min(maximum.height, max(44, fitted.height)))
    }
}
