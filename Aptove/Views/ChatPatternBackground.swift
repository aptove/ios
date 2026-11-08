import SwiftUI
import UIKit

/// Tiled robotic/tech-themed background for the chat scroll area.
/// Renders a 280×280 pt tile of outline SF Symbols at low opacity,
/// then tiles it to fill the view — adapts automatically to dark/light mode.
struct ChatPatternBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(uiImage: Self.tile(dark: colorScheme == .dark))
            .resizable(resizingMode: .tile)
    }

    // MARK: - Tile cache

    private static var lightTile: UIImage?
    private static var darkTile: UIImage?

    private static func tile(dark: Bool) -> UIImage {
        if dark, let cached = darkTile { return cached }
        if !dark, let cached = lightTile { return cached }
        let result = makeTile(dark: dark)
        if dark { darkTile = result } else { lightTile = result }
        return result
    }

    // MARK: - Tile generation

    private static func makeTile(dark: Bool) -> UIImage {
        let size = CGSize(width: 280, height: 280)

        // Background colour — slightly tinted so it reads as "tech"
        let bgColor: UIColor = dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1.0)   // deep charcoal/navy
            : UIColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1.0)   // cool light gray

        // Icon tint — very low opacity so they read as a subtle watermark
        let iconAlpha: CGFloat = dark ? 0.09 : 0.08
        let iconColor = (dark ? UIColor.white : UIColor.black).withAlphaComponent(iconAlpha)

        // (name, cx, cy, pointSize, rotationDegrees)
        let icons: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            // --- original 12 ---
            ("cpu",                                   38,  48,  26, -12),
            ("gear",                                 215, 155,  28,  22),
            ("network",                              120, 235,  24,   0),
            ("bolt",                                 165,  58,  20,  10),
            ("waveform",                              55, 180,  18, -18),
            ("eye",                                  228,  72,  20,   6),
            ("curlybraces",                          102, 118,  16,  -8),
            ("hexagon",                              248, 228,  18,  32),
            ("antenna.radiowaves.left.and.right",     28, 248,  16, -24),
            ("bubble.left",                          178,   8,  22,  14),
            ("square.grid.3x3",                       68, 108,  14, -30),
            ("dot.radiowaves.right",                 185, 210,  14,   0),
            // --- additional 12 ---
            ("gearshape.2",                          145, 100,  22, -15),
            ("cpu",                                  268,  12,  18,  18),
            ("waveform.path.ecg",                     12, 130,  16,   0),
            ("bolt.circle",                          240, 130,  20, -10),
            ("eye.circle",                            88, 268,  18,  25),
            ("chevron.left.forwardslash.chevron.right", 200, 268, 15,  0),
            ("antenna.radiowaves.left.and.right",    155, 170,  16,  12),
            ("hexagon",                               12,  12,  18, -20),
            ("network",                              260,  88,  16,  -5),
            ("bubble.left",                           88, 200,  16, -15),
            ("curlybraces.square",                   140,  18,  14,  28),
            ("dot.radiowaves.right",                 268, 190,  16,  20),
        ]

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            bgColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let cgCtx = ctx.cgContext
            for (name, cx, cy, ptSize, deg) in icons {
                let cfg = UIImage.SymbolConfiguration(pointSize: ptSize, weight: .thin)
                guard let symbol = UIImage(systemName: name, withConfiguration: cfg) else { continue }
                let colored = symbol.withTintColor(iconColor, renderingMode: .alwaysOriginal)
                let w = colored.size.width
                let h = colored.size.height

                cgCtx.saveGState()
                cgCtx.translateBy(x: cx, y: cy)
                cgCtx.rotate(by: deg * .pi / 180)
                colored.draw(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                cgCtx.restoreGState()
            }
        }
    }
}
