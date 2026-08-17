import Foundation

enum LaneKey: String, CaseIterable, Identifiable {
    case grok, cursor, bot
    var id: String { rawValue }

    var title: String {
        switch self {
        case .grok: "Grok"
        case .cursor: "Cursor"
        case .bot: "Grok Bot"
        }
    }

    var letter: String {
        switch self {
        case .grok: "G"
        case .cursor: "C"
        case .bot: "B"
        }
    }
}

enum Tone: String {
    case ok, warn, crit, empty, error
}

struct LaneDetail: Identifiable {
    var id: String { label }
    var label: String
    var usedPct: Double
}

struct Lane: Identifiable {
    var id: LaneKey { key }
    var key: LaneKey
    var usedPct: Double?
    var remainingPct: Double?
    var label: String
    var sub: String
    var tone: Tone
    var details: [LaneDetail]

    static func empty(_ key: LaneKey, sub: String) -> Lane {
        Lane(key: key, usedPct: nil, remainingPct: nil, label: "—", sub: sub, tone: .empty, details: [])
    }

    static func error(_ key: LaneKey, message: String) -> Lane {
        Lane(key: key, usedPct: nil, remainingPct: nil, label: "—", sub: message, tone: .error, details: [])
    }

    static func used(_ key: LaneKey, percent: Double, sub: String, details: [LaneDetail] = []) -> Lane {
        let used = min(100, max(0, percent.rounded()))
        let tone: Tone = used >= 90 ? .crit : used >= 80 ? .warn : .ok
        return Lane(
            key: key,
            usedPct: used,
            remainingPct: 100 - used,
            label: "\(Int(used))%",
            sub: sub,
            tone: tone,
            details: details
        )
    }
}

struct Snapshot {
    var grok: Lane
    var cursor: Lane
    var bot: Lane
    var fetchedAt: Date
    var grokLinked: Bool
    var cursorLinked: Bool

    var lanes: [Lane] { [grok, cursor, bot] }

    static var vacant: Snapshot {
        Snapshot(
            grok: .empty(.grok, sub: "Weekly SuperGrok Heavy  ·  not connected"),
            cursor: .empty(.cursor, sub: "Ultra monthly  ·  not connected"),
            bot: .empty(.bot, sub: "Sand weekly  ·  not connected"),
            fetchedAt: .distantPast,
            grokLinked: false,
            cursorLinked: false
        )
    }

    var menuTitle: String {
        func part(_ lane: Lane) -> String {
            if let n = lane.usedPct { return "\(lane.key.letter) \(Int(n))" }
            return "\(lane.key.letter) —"
        }
        return "\(part(grok)) · \(part(cursor)) · \(part(bot))"
    }
}

struct GrokAuth: Codable, Equatable {
    var access: String
    var refresh: String
    var clientId: String
    var expiresAt: Date

    var isStale: Bool {
        expiresAt.timeIntervalSinceNow < 90
    }

    var canRefresh: Bool {
        !refresh.isEmpty && !clientId.isEmpty
    }
}
