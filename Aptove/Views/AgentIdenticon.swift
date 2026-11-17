import SwiftUI

/// GitHub-style identicon: a 4×4 left-right mirrored grid, deterministically generated from the agent name.
/// Fixed colors: blue background, yellow dots.
/// The status-color ring is provided by the parent ZStack (via .padding(3) on this view).
struct AgentIdenticon: View {
    let name: String

    private static let background = Color(hue: 0.625, saturation: 0.90, brightness: 0.75)
    private static let dots       = Color.white

    private var cells: [[Bool]] {
        // djb2 — stable across app launches (Swift's hashValue is randomised per process)
        let seed = name.utf8.reduce(UInt64(5381)) { ($0 &<< 5) &+ $0 &+ UInt64($1) }

        var grid = Array(repeating: Array(repeating: false, count: 4), count: 4)
        var index = 0
        // 4×4 has no center column — unique cols are 0 and 1, mirrored to 3 and 2
        for col in [1, 0] {
            for row in 0..<4 {
                // MurmurHash3 finalizer: each cell gets fully independent randomness
                var h = seed ^ (UInt64(index + 1) &* 0x9e3779b97f4a7c15)
                h ^= h >> 33
                h = h &* 0xff51afd7ed558ccd
                h ^= h >> 33
                let filled = h & 1 == 0
                grid[row][col] = filled
                grid[row][3 - col] = filled  // mirror: 1→2, 0→3
                index += 1
            }
        }
        return grid
    }

    var body: some View {
        Canvas { context, size in
            // 12% padding ensures a clear gap from the circle boundary so dots
            // don't appear to collide with the status ring behind them.
            let pad  = size.width * 0.12
            let cell = (size.width - pad * 2) / 4
            let gap: CGFloat = 1.5

            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Self.background)
            )
            for (row, rowCells) in cells.enumerated() {
                for (col, filled) in rowCells.enumerated() where filled {
                    let rect = CGRect(
                        x: pad + CGFloat(col) * cell + gap,
                        y: pad + CGFloat(row) * cell + gap,
                        width: cell - gap * 2,
                        height: cell - gap * 2
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: cell * 0.18),
                        with: .color(Self.dots)
                    )
                }
            }
        }
        .clipShape(Circle())
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            ForEach([("aptove", Color.green), ("tmp2", Color.gray), ("data-pipeline", Color.orange)], id: \.0) { name, ring in
                VStack(spacing: 4) {
                    ZStack {
                        Circle().fill(ring)
                        AgentIdenticon(name: name).padding(3)
                    }
                    .frame(width: 48, height: 48)
                    Text(name).font(.caption2)
                }
            }
        }
    }
    .padding()
}
