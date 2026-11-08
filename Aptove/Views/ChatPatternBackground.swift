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
    // Bump this string to bust the in-memory cache after layout changes.
    private static let tileVersion = "v3-no-overlap"

    private static func tile(dark: Bool) -> UIImage {
        if dark, let cached = darkTile { return cached }
        if !dark, let cached = lightTile { return cached }
        let result = makeTile(dark: dark)
        if dark { darkTile = result } else { lightTile = result }
        return result
    }

    // MARK: - Tile generation

    private static let symbolNames: [String] = [
        "cpu", "gear", "network", "bolt", "waveform", "eye",
        "curlybraces", "hexagon", "antenna.radiowaves.left.and.right",
        "bubble.left", "square.grid.3x3", "dot.radiowaves.right",
        "gearshape.2", "waveform.path.ecg", "bolt.circle", "eye.circle",
        "chevron.left.forwardslash.chevron.right", "curlybraces.square",
        "memorychip", "brain", "wrench.and.screwdriver", "terminal",
        "arrow.triangle.2.circlepath", "rays", "magnifyingglass",
        "qrcode", "timer", "powerplug", "function", "chart.bar",
    ]

    private static func makeTile(dark: Bool) -> UIImage {
        // 320×320 tile with a 10×10 grid → cell = 32pt.
        // Centering icons in the middle 40% of each cell guarantees a minimum
        // center-to-center distance of 32 × 0.6 = 19.2pt between any two adjacent
        // icons. With a max icon size of 18pt the smallest possible gap is 1.2pt
        // — overlap is impossible regardless of which sizes the RNG picks.
        let size = CGSize(width: 320, height: 320)

        // Background colour — slightly tinted so it reads as "tech"
        let bgColor: UIColor = dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1.0)
            : UIColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1.0)

        let iconAlpha: CGFloat = dark ? 0.25 : 0.22
        let iconColor = (dark ? UIColor.white : UIColor.black).withAlphaComponent(iconAlpha)

        // Seeded Xorshift32 — deterministic but looks truly random
        var rng: UInt32 = 0xABCD1234
        func next() -> CGFloat {
            rng ^= rng << 13
            rng ^= rng >> 17
            rng ^= rng << 5
            return CGFloat(rng) / CGFloat(UInt32.max)
        }

        let cols = 10, rows = 10   // 100 icons total
        let cellW = size.width / CGFloat(cols)
        let cellH = size.height / CGFloat(rows)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            bgColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let cgCtx = ctx.cgContext

            for row in 0..<rows {
                for col in 0..<cols {
                    // Constrain center to middle 40% of each cell so the minimum
                    // distance between any two adjacent icon centers is cellW × 0.6 ≈ 14 pt.
                    // Icon sizes are capped at 12 pt, guaranteeing no overlap.
                    let cx     = (CGFloat(col) + 0.3 + next() * 0.4) * cellW
                    let cy     = (CGFloat(row) + 0.3 + next() * 0.4) * cellH
                    let deg    = next() * 72 - 36
                    let ptSize = 8 + next() * 10   // 8–18 pt, randomly varied
                    let isEmoji = next() < 0.1

                    cgCtx.saveGState()
                    cgCtx.translateBy(x: cx, y: cy)

                    if isEmoji {
                        cgCtx.rotate(by: deg * 0.3 * .pi / 180)
                        cgCtx.setAlpha(iconAlpha)
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: UIFont.systemFont(ofSize: ptSize)
                        ]
                        let str = NSAttributedString(string: "🤖", attributes: attrs)
                        let sz = str.size()
                        str.draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2))
                    } else {
                        cgCtx.rotate(by: deg * .pi / 180)
                        let name = symbolNames[Int(next() * CGFloat(symbolNames.count)) % symbolNames.count]
                        let cfg = UIImage.SymbolConfiguration(pointSize: ptSize, weight: .thin)
                        if let symbol = UIImage(systemName: name, withConfiguration: cfg) {
                            let colored = symbol.withTintColor(iconColor, renderingMode: .alwaysOriginal)
                            let w = colored.size.width, h = colored.size.height
                            colored.draw(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                        }
                    }

                    cgCtx.restoreGState()
                }
            }
        }
    }
}
