import Foundation

/// Claude Settings → Usage, split into menu-bar figures.
///
/// Keys read from the Desktop / oauth payload (whichever is present):
/// - AC Current session ← `five_hour`, `fiveHour`, `five_hour_utilization`,
///   or `limits[]` kind `session`
/// - AT This week ← `seven_day`, `sevenDay`, `seven_day_utilization`,
///   or `limits[]` kind `weekly` / `weekly_all` / `seven_day`
/// - AF Fable this week ← `seven_day_fable`, `sevenDayFable`, or a
///   `models[]` / `limits[]` `weekly_scoped` entry whose name contains Fable
///
/// `seven_day_sonnet` and `seven_day_opus` stay unlabeled detail rows.
/// A missing window is left out. Utilization is already 0–100 and is not rescaled.
/// `Lane.usedPct` stays the tighter of session and week so other Claude
/// behavior keeps using that account window. Fable does not replace it.
enum ClaudeUsage {
    static func parse(
        _ json: [String: Any],
        auth: ClaudeAuth,
        resetTimeZone: TimeZone = .current,
        now: Date = Date()
    ) -> Lane? {
        var windows: [ClaudeWindow] = []

        let fiveRaw = jsonValue(json["five_hour"]) ?? jsonValue(json["fiveHour"])
        if let five = windowDict(fiveRaw), let used = rawUtilization(five) {
            append(&windows, role: .session, label: "Current session", used: used, resets: five["resets_at"] ?? five["reset_at"])
        } else if let used = rawUtilization(fiveRaw ?? jsonValue(json["five_hour_utilization"])) {
            append(&windows, role: .session, label: "Current session", used: used, resets: nil)
        }

        let sevenRaw = jsonValue(json["seven_day"]) ?? jsonValue(json["sevenDay"])
        if let seven = windowDict(sevenRaw), let used = rawUtilization(seven) {
            append(&windows, role: .week, label: "This week", used: used, resets: seven["resets_at"] ?? seven["reset_at"])
        } else if let used = rawUtilization(sevenRaw ?? jsonValue(json["seven_day_utilization"])) {
            append(&windows, role: .week, label: "This week", used: used, resets: nil)
        }

        appendNamedModels(json, &windows)
        if let models = json["models"] as? [[String: Any]] {
            for item in models {
                let name = ((item["display_name"] as? String) ?? (item["name"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty,
                      let used = rawUtilization(
                        jsonValue(item["percent"])
                            ?? jsonValue(item["utilization"])
                            ?? jsonValue(item["used_percentage"])
                            ?? jsonValue(item["used_percent"])
                      )
                else { continue }
                append(&windows, role: .model, label: modelWeekLabel(name), used: used, resets: item["resets_at"] ?? item["reset_at"])
            }
        }

        if let limits = json["limits"] as? [[String: Any]] {
            for entry in limits {
                guard let used = rawUtilization(
                    jsonValue(entry["percent"])
                        ?? jsonValue(entry["utilization"])
                        ?? jsonValue(entry["used_percentage"])
                        ?? jsonValue(entry["used_percent"])
                ) else { continue }
                let resets = entry["resets_at"] ?? entry["reset_at"]
                switch limitKind(entry) {
                case .session:
                    append(&windows, role: .session, label: "Current session", used: used, resets: resets)
                case .week:
                    append(&windows, role: .week, label: "This week", used: used, resets: resets)
                case .model(let name):
                    append(&windows, role: .model, label: modelWeekLabel(name), used: used, resets: resets)
                case .ignore:
                    break
                }
            }
        }

        guard let primary = primaryWindow(windows) else { return nil }
        windows = windows.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element.role)
            let right = rank(rhs.element.role)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let details = windows.map { window in
            LaneDetail(
                label: window.label,
                usedPct: window.usedPct,
                reset: resetLabel(window.resetsAt, role: window.role, timeZone: resetTimeZone, now: now),
                mark: mark(for: window.role, label: window.label),
                window: windowShort(window.role)
            )
        }

        var plan = auth.subscription
        if plan.isEmpty {
            plan = (json["subscription_type"] as? String) ?? (json["plan"] as? String) ?? "Claude Code"
        }
        if !auth.tier.isEmpty, !plan.lowercased().contains(auth.tier.lowercased()) {
            plan = "\(plan) \(auth.tier)".trimmingCharacters(in: .whitespaces)
        }
        plan = plan.replacingOccurrences(of: "_", with: " ")

        return .used(
            .claude,
            percent: primary.usedPct,
            sub: plan,
            details: details,
            window: windowShort(primary.role)
        )
    }

    private enum WindowRole {
        case session
        case week
        case model
    }

    private struct ClaudeWindow {
        var role: WindowRole
        var label: String
        var usedPct: Double
        var resetsAt: Any?
    }

    private enum LimitKind {
        case session
        case week
        case model(String)
        case ignore
    }

    private static func appendNamedModels(_ json: [String: Any], _ windows: inout [ClaudeWindow]) {
        let named = [
            ("seven_day_fable", "Fable this week"),
            ("sevenDayFable", "Fable this week"),
            ("seven_day_sonnet", "Sonnet this week"),
            ("sevenDaySonnet", "Sonnet this week"),
            ("seven_day_opus", "Opus this week"),
            ("sevenDayOpus", "Opus this week"),
        ]
        for (key, label) in named {
            guard let used = rawUtilization(jsonValue(json[key])) else { continue }
            let bag = json[key] as? [String: Any]
            append(&windows, role: .model, label: label, used: used, resets: bag?["resets_at"] ?? bag?["reset_at"])
        }
    }

    private static func append(
        _ windows: inout [ClaudeWindow],
        role: WindowRole,
        label: String,
        used: Double,
        resets: Any?
    ) {
        switch role {
        case .session, .week:
            if windows.contains(where: { $0.role == role }) { return }
        case .model:
            if windows.contains(where: { $0.label == label }) { return }
            // Fable is one pool however the payload names it; a second AF would double the bar.
            if isFable(label), windows.contains(where: { $0.role == .model && isFable($0.label) }) { return }
        }
        windows.append(ClaudeWindow(role: role, label: label, usedPct: used, resetsAt: jsonValue(resets)))
    }

    private static func limitKind(_ entry: [String: Any]) -> LimitKind {
        let kind = (entry["kind"] as? String) ?? ""
        switch kind {
        case "session":
            return .session
        case "weekly", "weekly_all", "seven_day":
            return .week
        case "weekly_scoped":
            return .model(modelName(entry))
        default:
            return .ignore
        }
    }

    private static func modelName(_ entry: [String: Any]) -> String {
        let scope = entry["scope"] as? [String: Any]
        let model = scope?["model"] as? [String: Any]
        return (model?["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func modelWeekLabel(_ name: String) -> String {
        if name.isEmpty { return "Model this week" }
        return "\(name) this week"
    }

    /// Higher used % is the tighter account window. Equal session and week
    /// keep the session, which is the shorter window.
    private static func primaryWindow(_ windows: [ClaudeWindow]) -> ClaudeWindow? {
        let account = windows.filter { $0.role == .session || $0.role == .week }
        let pool = account.isEmpty ? windows : account
        return pool.max { lhs, rhs in
            if lhs.usedPct != rhs.usedPct { return lhs.usedPct < rhs.usedPct }
            return lhs.role != .session && rhs.role == .session
        }
    }

    private static func rank(_ role: WindowRole) -> Int {
        switch role {
        case .session: 0
        case .week: 1
        case .model: 2
        }
    }

    private static func windowShort(_ role: WindowRole) -> String {
        switch role {
        case .session: "5h"
        case .week, .model: "week"
        }
    }

    private static func mark(for role: WindowRole, label: String) -> String? {
        switch role {
        case .session:
            return "AC"
        case .week:
            return "AT"
        case .model:
            return isFable(label) ? "AF" : nil
        }
    }

    private static func isFable(_ label: String) -> Bool {
        label.range(of: "fable", options: .caseInsensitive) != nil
    }

    /// A weekly reset more than a day out keeps its weekday so `8:00 PM` is not read as today.
    private static func resetLabel(_ value: Any?, role: WindowRole, timeZone: TimeZone, now: Date) -> String? {
        guard let date = resetDate(value) else { return nil }
        let includeWeekday: Bool
        switch role {
        case .session:
            includeWeekday = true
        case .week, .model:
            includeWeekday = date.timeIntervalSince(now) > 24 * 3600
        }
        return "resets \(clock(date, timeZone: timeZone, includeWeekday: includeWeekday))"
    }

    /// Local clock, `Thu 12:10 AM` for the session and `8:00 PM` (or `Mon 8:00 PM`) for a weekly window.
    private static func clock(_ date: Date, timeZone: TimeZone, includeWeekday: Bool) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let hour24 = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let suffix = hour24 >= 12 ? "PM" : "AM"
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let time = "\(hour12):\(String(format: "%02d", minute)) \(suffix)"
        if !includeWeekday { return time }
        let symbols = calendar.shortWeekdaySymbols
        let index = (parts.weekday ?? 1) - 1
        let weekday = symbols.indices.contains(index) ? symbols[index] : ""
        return weekday.isEmpty ? time : "\(weekday) \(time)"
    }

    private static func resetDate(_ value: Any?) -> Date? {
        let value = jsonValue(value)
        if let n = value as? NSNumber {
            let v = n.doubleValue
            if v > 1e12 { return Date(timeIntervalSince1970: v / 1000) }
            if v > 1e9 { return Date(timeIntervalSince1970: v) }
            return nil
        }
        guard let s = value as? String else { return nil }
        if let n = Double(s), s.count >= 10, s.allSatisfy(\.isNumber) {
            return s.count >= 13 ? Date(timeIntervalSince1970: n / 1000) : Date(timeIntervalSince1970: n)
        }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: s) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }

    private static func windowDict(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func jsonValue(_ value: Any?) -> Any? {
        if value == nil || value is NSNull { return nil }
        return value
    }

    /// Oauth usage is 0–100. Never rescale: a fresh week (session 0, week 1)
    /// is indistinguishable from a 0–1 fraction and would read as 100%.
    private static func rawUtilization(_ value: Any?) -> Double? {
        let raw = jsonValue(value)
        if let dict = raw as? [String: Any] {
            return num(dict["utilization"])
                ?? num(dict["percent"])
                ?? num(dict["used_percentage"])
                ?? num(dict["used_percent"])
                ?? num(dict["usedPercent"])
        }
        return num(raw)
    }

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let n = Double(s) { return n }
        return nil
    }
}
