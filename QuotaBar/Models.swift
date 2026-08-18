import Foundation

enum LaneKey: String, CaseIterable, Identifiable {
    case grok, cursor, bot, gpt
    var id: String { rawValue }

    var title: String {
        switch self {
        case .grok: "Grok"
        case .cursor: "Cursor"
        case .bot: "Grok Bot"
        case .gpt: "ChatGPT"
        }
    }

    var letter: String {
        switch self {
        case .grok: "G"
        case .cursor: "C"
        case .bot: "B"
        case .gpt: "O"
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

enum DiskKind: String {
    case internalDrive = "Internal"
    case external = "External"
    case image = "Image"
}

struct DiskVolume: Identifiable, Equatable {
    var id: String
    var name: String
    var path: String
    var kind: DiskKind
    var totalBytes: Int64
    var freeBytes: Int64
    var usedPct: Double
    var readBps: Double
    var writeBps: Double
    var isReadOnly: Bool
    var isRoot: Bool
    var justChanged: String?

    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    var tone: Tone {
        if usedPct >= 95 { return .crit }
        if usedPct >= 80 || isReadOnly { return .warn }
        return .ok
    }

    var statusLabel: String {
        if isReadOnly { return "Read-only" }
        if usedPct >= 95 { return "Full" }
        if usedPct >= 90 { return "Almost full" }
        if readBps + writeBps >= 20_000_000 { return "Busy" }
        if readBps + writeBps < 50_000 { return "Idle" }
        return "OK"
    }

    var sizeLabel: String {
        "\(Self.bytes(freeBytes)) free of \(Self.bytes(totalBytes))"
    }

    var rateLabel: String {
        if readBps + writeBps < 50_000 { return "idle" }
        return "↓ \(Self.rate(readBps))  ↑ \(Self.rate(writeBps))"
    }

    var kindLabel: String { kind.rawValue }

    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB, .useTB]
        f.countStyle = .file
        f.includesUnit = true
        return f.string(fromByteCount: n)
    }

    static func rate(_ bps: Double) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .binary
        f.includesUnit = true
        return f.string(fromByteCount: Int64(max(0, bps))) + "/s"
    }
}

struct Snapshot {
    var grok: Lane
    var cursor: Lane
    var bot: Lane
    var gpt: Lane
    var fetchedAt: Date
    var grokLinked: Bool
    var cursorLinked: Bool
    var gptLinked: Bool

    var lanes: [Lane] { [grok, cursor, bot, gpt] }

    static var vacant: Snapshot {
        Snapshot(
            grok: .empty(.grok, sub: "Weekly SuperGrok Heavy  ·  not connected"),
            cursor: .empty(.cursor, sub: "Ultra monthly  ·  not connected"),
            bot: .empty(.bot, sub: "Sand weekly  ·  not connected"),
            gpt: .empty(.gpt, sub: "ChatGPT / Codex  ·  not connected"),
            fetchedAt: .distantPast,
            grokLinked: false,
            cursorLinked: false,
            gptLinked: false
        )
    }

    var menuTitle: String {
        func part(_ lane: Lane) -> String {
            if let n = lane.usedPct { return "\(lane.key.letter) \(Int(n))" }
            return "\(lane.key.letter) —"
        }
        return lanes.map(part).joined(separator: " · ")
    }

    func barTitle(disks: [DiskVolume]) -> String {
        guard let hot = disks.max(by: { $0.usedPct < $1.usedPct }) else { return menuTitle }
        return "\(menuTitle) · D \(Int(hot.usedPct.rounded()))"
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

struct CodexAuth: Equatable {
    var access: String
    var refresh: String
    var accountId: String
    var expiresAt: Date

    var isStale: Bool {
        expiresAt.timeIntervalSinceNow < 60
    }

    var canRefresh: Bool {
        !refresh.isEmpty
    }
}
