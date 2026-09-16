import Foundation

enum Duration {
    /// Parses "30m", "2h", "1h30m" or a bare number of minutes. Returns seconds.
    static func parse(_ text: String) -> TimeInterval? {
        let s = text.lowercased().replacingOccurrences(of: " ", with: "")
        if let minutes = Int(s), minutes > 0 { return TimeInterval(minutes * 60) }
        guard let regex = try? NSRegularExpression(pattern: #"^(?:(\d+)h)?(?:(\d+)m)?$"#),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func group(_ i: Int) -> Int {
            guard let r = Range(m.range(at: i), in: s) else { return 0 }
            return Int(s[r]) ?? 0
        }
        let total = group(1) * 3600 + group(2) * 60
        return total > 0 ? TimeInterval(total) : nil
    }

    /// "45 s", "30 min", "2 h", "1 h 30 min". Minutes are rounded to nearest so a session
    /// started a moment ago still reads as the length that was asked for.
    static func describe(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(Int(seconds.rounded(.up)), 0)) s" }
        let minutes = Int((seconds / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }
}
