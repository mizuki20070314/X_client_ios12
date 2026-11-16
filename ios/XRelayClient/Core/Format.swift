import Foundation

/// Japanese display strings, as the official app shows them. The wording is fixed to ja_JP; the calendar is
/// Gregorian on purpose (a ja_JP calendar would show Japanese eras). The time zone is the device's and can be
/// pinned by tests.
enum Format {
    static var timeZone = TimeZone.current

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(max(1, seconds))秒" }
        if seconds < 3_600 { return "\(seconds / 60)分" }
        if seconds < 86_400 { return "\(seconds / 3_600)時間" }
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let today = calendar.dateComponents([.year], from: now)
        let year = day.year ?? 0
        let month = day.month ?? 0
        let dayOfMonth = day.day ?? 0
        if year == today.year { return "\(month)月\(dayOfMonth)日" }
        return "\(year)年\(month)月\(dayOfMonth)日"
    }

    static func count(_ n: Int) -> String {
        let value = max(0, n)
        if value < 10_000 { return grouped(value) }
        if value < 1_000_000 {
            // tenths of 万, truncated (not rounded): 12345 -> 1.2万
            return decimal(value / 1_000, unit: "万")
        }
        if value < 100_000_000 {
            return grouped(value / 10_000) + "万"
        }
        // tenths of 億: 123456789 -> 1.2億
        return decimal(value / 10_000_000, unit: "億")
    }

    static func fullTimestamp(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let period = hour < 12 ? "午前" : "午後"
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let minute = parts.minute ?? 0
        let minuteText = minute < 10 ? "0\(minute)" : "\(minute)"
        let dateText = "\(parts.year ?? 0)年\(parts.month ?? 0)月\(parts.day ?? 0)日"
        return "\(period)\(hour12):\(minuteText) · \(dateText)"
    }

    static func joined(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return "\(parts.year ?? 0)年\(parts.month ?? 0)月からXを利用しています"
    }

    static func duration(ms: Int) -> String {
        let total = max(0, ms) / 1_000
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        let secondText = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        if hours > 0 {
            let minuteText = minutes < 10 ? "0\(minutes)" : "\(minutes)"
            return "\(hours):\(minuteText):\(secondText)"
        }
        return "\(minutes):\(secondText)"
    }

    /// `tenths` is ten times the shown value: 12 -> "1.2", 10 -> "1".
    private static func decimal(_ tenths: Int, unit: String) -> String {
        let whole = grouped(tenths / 10)
        let fraction = tenths % 10
        if fraction == 0 { return "\(whole)\(unit)" }
        return "\(whole).\(fraction)\(unit)"
    }

    /// 1234567 -> "1,234,567"
    private static func grouped(_ value: Int) -> String {
        let digits = Array(String(value))
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return result
    }
}
