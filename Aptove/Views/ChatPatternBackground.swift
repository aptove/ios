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
        let size = CGSize(width: 280, height: 280)

        // Background colour — slightly tinted so it reads as "tech"
        let bgColor: UIColor = dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1.0)
            : UIColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1.0)

        let iconAlpha: CGFloat = dark ? 0.14 : 0.13
        let iconColor = (dark ? UIColor.white : UIColor.black).withAlphaComponent(iconAlpha)

        // 12×12 grid = 144 icons
        let cols = 12, rows = 12
        let cellW = size.width / CGFloat(cols)
        let cellH = size.height / CGFloat(rows)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            bgColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let cgCtx = ctx.cgContext

            for row in 0..<rows {
                for col in 0..<cols {
                    let idx = row * cols + col

                    // Deterministic pseudo-random offsets (no stdlib random needed)
                    let jx = CGFloat((idx * 37 + col * 11 + 7) % 100) / 100.0 * cellW * 0.8 - cellW * 0.4
                    let jy = CGFloat((idx * 53 + row * 17 + 3) % 100) / 100.0 * cellH * 0.8 - cellH * 0.4
                    let cx = min(size.width - 4, max(4, cellW * (CGFloat(col) + 0.5) + jx))
                    let cy = min(size.height - 4, max(4, cellH * (CGFloat(row) + 0.5) + jy))
                    let deg = CGFloat((idx * 29 + col * 7 + 13) % 72) - 36
                    let ptSize = CGFloat(11 + (idx * 7 + col * 3) % 7)   // 11–17 pt

                    cgCtx.saveGState()
                    cgCtx.translateBy(x: cx, y: cy)

                    // Every 10th icon → robot emoji 🤖
                    if idx % 10 == 7 {
                        cgCtx.rotate(by: deg * 0.3 * .pi / 180)   // gentle tilt only
                        cgCtx.setAlpha(iconAlpha)
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: UIFont.systemFont(ofSize: ptSize + 3)
                        ]
                        let str = NSAttributedString(string: "🤖", attributes: attrs)
                        let sz = str.size()
                        str.draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2))
                    } else {
                        cgCtx.rotate(by: deg * .pi / 180)
                        let name = symbolNames[idx % symbolNames.count]
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
