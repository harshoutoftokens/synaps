import Foundation

/// Tolerant, thread-safe parser for the timestamps the NAS returns. Accepts "2026-10-13",
/// "2026-10-13T14:59:00", "2026-10-13 14:59:00.123456", "...Z", "...+05:30", "...+0530".
enum NASDateParser {
    private static let pattern = try? NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?)?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?$"#
    )
    
    static func parse(_ string: String?) -> Date? {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let regex = pattern else { return nil }
        let ns = raw as NSString
        guard let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        func number(_ index: Int) -> Int? {
            return group(index).flatMap { Int($0) }
        }
        
        guard let year = number(1), let month = number(2), let day = number(3),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = number(4) ?? 0
        components.minute = number(5) ?? 0
        components.second = number(6) ?? 0
        if let fraction = group(7) {
            components.nanosecond = Int(String((fraction + "000000000").prefix(9)))
        }
        
        let timeZone: TimeZone
        if let zone = group(8) {
            if zone == "Z" || zone == "z" {
                timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            } else {
                let sign = zone.hasPrefix("-") ? -1 : 1
                let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
                let hours = Int(digits.prefix(2)) ?? 0
                let minutes = digits.count >= 4 ? (Int(digits.dropFirst(2).prefix(2)) ?? 0) : 0
                timeZone = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60)) ?? .current
            }
        } else {
            // Naive timestamps are NAS local time; the NAS and this Mac share a time zone.
            timeZone = .current
        }
        
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }
}
