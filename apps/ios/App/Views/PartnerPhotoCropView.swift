import SwiftUI
import UIKit

struct PartnerPhotoSelection: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// The library picker only selects; saving happens after an explicit crop confirmation.
struct PartnerPhotoCropView: UIViewControllerRepresentable {
    let image: UIImage
    let onCancel: () -> Void
    let onSave: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: PartnerPhotoCropController(
            image: image, onCancel: onCancel, onSave: onSave
        ))
        navigation.overrideUserInterfaceStyle = .dark
        return navigation
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

enum PartnerPhotoCrop {
    /// Scroll geometry is in image points before zooming. Clamp bounce offsets so
    /// confirming during deceleration can never introduce empty edges.
    static func render(image: UIImage, viewportSize: CGSize, contentOffset: CGPoint,
                       zoomScale: CGFloat) -> UIImage? {
        guard zoomScale.isFinite, zoomScale > 0,
              viewportSize.width > 0, viewportSize.height > 0,
              contentOffset.x.isFinite, contentOffset.y.isFinite else { return nil }
        let side = min(viewportSize.width / zoomScale, image.size.width, image.size.height)
        guard side.isFinite, side > 0 else { return nil }
        let origin = CGPoint(
            x: min(max(0, contentOffset.x / zoomScale), image.size.width - side),
            y: min(max(0, contentOffset.y / zoomScale), image.size.height - side)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            let scale = 512 / side
            image.draw(in: CGRect(x: -origin.x * scale, y: -origin.y * scale,
                                  width: image.size.width * scale, height: image.size.height * scale))
        }
    }
}

final class PartnerPhotoCropController: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let onCancel: () -> Void
    private let onSave: (UIImage) -> Void
    private let scrollView = UIScrollView()
    private let imageView: UIImageView
    private let cropOutline = CAShapeLayer()
    private let cropShade = CAShapeLayer()
    private var viewportSize = CGSize.zero

    init(image: UIImage, onCancel: @escaping () -> Void, onSave: @escaping (UIImage) -> Void) {
        self.image = image
        self.onCancel = onCancel
        self.onSave = onSave
        imageView = UIImageView(image: image)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = "Move and Scale"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.onCancel() }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Use Photo", primaryAction: UIAction { [weak self] _ in self?.confirmCrop() }
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "partner-photo-crop-save"
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.clipsToBounds = true
        scrollView.accessibilityIdentifier = "partner-photo-crop-canvas"
        scrollView.isAccessibilityElement = true
        scrollView.accessibilityLabel = "Photo crop"
        scrollView.accessibilityHint = "Drag to move the photo. Pinch to zoom."
        scrollView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Zoom in") { [weak self] _ in self?.zoom(by: 1.25); return true },
            UIAccessibilityCustomAction(name: "Zoom out") { [weak self] _ in self?.zoom(by: 0.8); return true },
        ]
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.contentSize = image.size
        scrollView.addSubview(imageView)
        view.addSubview(scrollView)
        cropShade.fillRule = .evenOdd
        cropShade.fillColor = UIColor.black.withAlphaComponent(0.6).cgColor
        cropOutline.fillColor = UIColor.clear.cgColor
        cropOutline.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
        cropOutline.lineWidth = 1
        view.layer.addSublayer(cropShade)
        view.layer.addSublayer(cropOutline)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let available = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 16, dy: 16)
        let side = max(1, min(available.width, available.height))
        let frame = CGRect(x: available.midX - side / 2, y: available.midY - side / 2,
                           width: side, height: side)
        scrollView.frame = frame
        let circle = UIBezierPath(ovalIn: frame)
        let shade = UIBezierPath(rect: frame)
        shade.append(circle)
        cropShade.path = shade.cgPath
        cropOutline.path = circle.cgPath
        guard viewportSize != frame.size else { return }
        viewportSize = frame.size
        scrollView.minimumZoomScale = max(side / image.size.width, side / image.size.height)
        scrollView.maximumZoomScale = scrollView.minimumZoomScale * 6
        scrollView.zoomScale = scrollView.minimumZoomScale
        scrollView.contentOffset = CGPoint(
            x: max(0, (image.size.width * scrollView.zoomScale - side) / 2),
            y: max(0, (image.size.height * scrollView.zoomScale - side) / 2)
        )
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    private func zoom(by factor: CGFloat) {
        let scale = min(max(scrollView.zoomScale * factor, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        let center = CGPoint(x: scrollView.contentOffset.x + scrollView.bounds.width / 2,
                             y: scrollView.contentOffset.y + scrollView.bounds.height / 2)
        let ratio = scale / scrollView.zoomScale
        scrollView.setZoomScale(scale, animated: false)
        scrollView.contentOffset = CGPoint(
            x: min(max(0, center.x * ratio - scrollView.bounds.width / 2), max(0, scrollView.contentSize.width - scrollView.bounds.width)),
            y: min(max(0, center.y * ratio - scrollView.bounds.height / 2), max(0, scrollView.contentSize.height - scrollView.bounds.height))
        )
    }

    func confirmCrop() {
        guard let cropped = PartnerPhotoCrop.render(image: image, viewportSize: scrollView.bounds.size,
                                                    contentOffset: scrollView.contentOffset,
                                                    zoomScale: scrollView.zoomScale) else { return }
        onSave(cropped)
    }
}
