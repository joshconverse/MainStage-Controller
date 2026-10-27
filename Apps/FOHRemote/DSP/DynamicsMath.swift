import SwiftUI

/// Static transfer curves for the Dynamics page (input dBFS → output dBFS).
enum DynamicsMath {
    static let minDB = -60.0, maxDB = 0.0

    static func compressor(_ input: Double, threshold: Double, ratio: Double, knee: Double = 2) -> Double {
        let r = ratio.isFinite ? max(ratio, 1) : 1000
        let over = input - threshold
        if knee > 0, abs(over) <= knee / 2 {
            let x = over + knee / 2
            return input + (1 / r - 1) * x * x / (2 * knee)
        }
        return over <= 0 ? input : threshold + over / r
    }

    /// Expander (2:1 downward) or gate below threshold, never reducing more than `range`.
    static func expander(_ input: Double, threshold: Double, range: Double, gate: Bool) -> Double {
        guard input < threshold else { return input }
        if gate { return input - range }
        return max(input - range, threshold + (input - threshold) * 2)
    }

    static func path(size: CGSize, _ transfer: (Double) -> Double) -> Path {
        var p = Path()
        let n = 120
        for i in 0...n {
            let input = minDB + (maxDB - minDB) * Double(i) / Double(n)
            let out = max(minDB, min(maxDB, transfer(input)))
            let pt = point(input, out, size)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    static func point(_ input: Double, _ output: Double, _ size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat((input - minDB) / (maxDB - minDB)) * size.width,
                y: size.height - CGFloat((output - minDB) / (maxDB - minDB)) * size.height)
    }
}
