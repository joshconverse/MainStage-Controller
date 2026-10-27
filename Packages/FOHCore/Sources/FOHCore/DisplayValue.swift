import Foundation

/// Parses plugin display text ("320 Hz", "3.2 kHz", "-3.5 dB", "3:1", "0.3 s") into numbers
/// the iPad can draw curves with.
public struct DisplayValue: Hashable, Sendable {
    public enum Unit: String, Codable, Sendable {
        case hz, db, ratio, ms, s, percent, none
    }

    public var value: Double
    public var unit: Unit

    public init(value: Double, unit: Unit) {
        self.value = value
        self.unit = unit
    }

    /// Seconds for time units, Hz for frequency, otherwise the raw value.
    public var normalized: Double {
        switch unit {
        case .ms: return value / 1000
        default: return value
        }
    }

    public static func parse(_ text: String, unitHint: String? = nil) -> DisplayValue? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: ".")
        let lower = t.lowercased()
        if lower.contains("inf") || lower.contains("∞") {
            return DisplayValue(value: lower.hasPrefix("+") ? .infinity : -.infinity, unit: unitFrom(lower, hint: unitHint) ?? .db)
        }
        if let colon = t.firstIndex(of: ":") {
            if let v = Double(t[..<colon].trimmingCharacters(in: .whitespaces)) {
                return DisplayValue(value: v, unit: .ratio)
            }
        }
        // Leading number (with optional sign / decimal).
        var numberEnd = t.startIndex
        var seenDigit = false
        for idx in t.indices {
            let ch = t[idx]
            if ch.isNumber { seenDigit = true; numberEnd = t.index(after: idx); continue }
            if (ch == "-" || ch == "+") && idx == t.startIndex { numberEnd = t.index(after: idx); continue }
            if ch == "." { numberEnd = t.index(after: idx); continue }
            break
        }
        guard seenDigit, var v = Double(t[..<numberEnd]) else { return nil }
        t = String(t[numberEnd...]).trimmingCharacters(in: .whitespaces)
        let suffix = t.lowercased()
        // "3.2k" / "3.2 kHz", or a bare "1.01" whose unit name is "KHz" (Waves SSL Channel).
        if suffix.hasPrefix("k") || (suffix.isEmpty && (unitHint?.lowercased().hasPrefix("k") ?? false)) { v *= 1000 }
        let unit = unitFrom(suffix, hint: unitHint) ?? .none
        return DisplayValue(value: v, unit: unit)
    }

    private static func unitFrom(_ suffix: String, hint: String?) -> Unit? {
        let s = suffix.lowercased()
        if s.contains("hz") || s == "k" { return .hz }
        if s.contains("db") { return .db }
        if s.hasPrefix("ms") { return .ms }
        if s == "s" || s.hasPrefix("sec") { return .s }
        if s.contains("%") { return .percent }
        if let hint, !hint.isEmpty, hint.lowercased() != s { return unitFrom(hint, hint: nil) }
        return nil
    }
}
