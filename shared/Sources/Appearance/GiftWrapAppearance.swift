import SwiftUI

// Shared production identity; preview controls remain on iPhone.
enum GiftWrapAppearance {
    static func outgoing(_ dark: Bool) -> Color { dark ? pineDark : pine }

    static func accent(_ dark: Bool) -> Color { dark ? mint : pine }

    /// Read receipts use System Blue in light appearance and Teal in dark appearance.
    static func receipt(_ dark: Bool, isRead: Bool) -> Color {
        if isRead {
            return dark ? Color(.sRGB, red: 46/255, green: 196/255, blue: 174/255, opacity: 1)
                : Color(.sRGB, red: 0, green: 122/255, blue: 1, opacity: 1)
        }
        return dark ? Color(red: 228/255, green: 236/255, blue: 232/255)
            : Color(red: 52/255, green: 76/255, blue: 96/255)
    }

    static let pine = Color(red: 43/255, green: 98/255, blue: 72/255)
    static let pineDark = Color(red: 34/255, green: 83/255, blue: 59/255)
    static let mint = Color(red: 143/255, green: 204/255, blue: 169/255)
    static func incoming(_ dark: Bool) -> Color {
        dark ? Color(red: 35/255, green: 43/255, blue: 39/255) : Color(red: 1, green: 253/255, blue: 249/255)
    }
    static func bar(_ dark: Bool) -> Color {
        dark ? Color(red: 21/255, green: 27/255, blue: 24/255) : Color(red: 242/255, green: 239/255, blue: 233/255)
    }
    static func field(_ dark: Bool) -> Color {
        dark ? Color(red: 34/255, green: 42/255, blue: 38/255) : .white
    }
}

struct GiftWrapWallpaper: View {
    enum Composition {
        case portrait
        case tiled
    }

    var composition: Composition = .portrait

    var body: some View {
        GeometryReader { bounds in
            switch composition {
            case .portrait:
                Image("OriginalGiftWrap")
                    .resizable()
                    .scaledToFill()
                    .frame(width: bounds.size.width, height: bounds.size.height)
                    .clipped()
                    .accessibilityHidden(true)
            case .tiled:
                // Stable motif scale across freely resizable desktop windows.
                Canvas { context, size in
                    let tile = context.resolve(Image("GiftWrapTile"))
                    let edge: CGFloat = 512
                    for row in 0..<max(1, Int(ceil(size.height / edge))) {
                        for column in 0..<max(1, Int(ceil(size.width / edge))) {
                            context.draw(tile, in: CGRect(
                                x: CGFloat(column) * edge, y: CGFloat(row) * edge,
                                width: edge, height: edge
                            ))
                        }
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

extension EnvironmentValues {
    @Entry var usesGiftWrap = false
}
