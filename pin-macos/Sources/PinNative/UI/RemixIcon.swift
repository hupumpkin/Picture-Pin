import CoreText
import SwiftUI

/// Remix Icon v4.9.1, bundled locally for the canvas toolbar.
struct RemixIcon: View {
    enum Symbol {
        case cursor, hand, imageAdd, focusAll, focusSelection
        case zoomIn, zoomOut, grid, sidebar

        var scalar: UInt32 {
            switch self {
            case .cursor: 0xec0a
            case .hand: 0xf687
            case .imageAdd: 0xee47
            case .focusAll: 0xed4e
            case .focusSelection: 0xed4a
            case .zoomIn: 0xf2db
            case .zoomOut: 0xf2dd
            case .grid: 0xeddf
            case .sidebar: 0xf128
            }
        }
    }

    let symbol: Symbol
    var size: CGFloat = 16

    private static let registered: Bool = {
        guard let url = Bundle.main.url(
            forResource: "remixicon", withExtension: "ttf", subdirectory: "RemixIcon"
        ) else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    var body: some View {
        let _ = Self.registered
        Text(String(UnicodeScalar(symbol.scalar)!))
            .font(.custom("remixicon", fixedSize: size))
            .frame(width: size + 2, height: size + 2)
            .accessibilityHidden(true)
    }
}
