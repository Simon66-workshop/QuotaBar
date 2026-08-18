import Foundation

enum LaneKey: String, CaseIterable, Identifiable {
    case grok, cursor, bot, gpt, claude
    var id: String { rawValue }

    var title: String {
        switch self {
        case .grok: "Grok"
        case .cursor: "Cursor"
        case .bot: "Grok Bot"
        case .gpt: "ChatGPT"
        case .claude: "Claude"
        }
    }

    var letter: String {
        switch self {
        case .grok: "G"
        case .cursor: "C"
        case .bot: "B"
        case .gpt: "O"
        case .claude: "A"
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

    var showsOnBar: Bool { tone != .empty }

    static func empty(_ key: LaneKey, sub: String) -> Lane {
        Lane(key: key, usedPct: nil, remainingPct: nil, label: "—", sub: sub, tone: .empty, details: [])
    }

    static func error(_ key: LaneKey, message: String) -> Lane {
        Lane(key: key, usedPct: nil, remainingPct: nil, label: "—", sub: message, tone: .error, details: [])
    }

    static func used(_ key: LaneKey, percent: Double, sub: String, details: [LaneDetail] = []) -> Lane {
        let used = min(100, max(0, percent.rounded()))
        // 85 / 95 so a typical 60–80% day stays neutral on the bar.
        let tone: Tone = used >= 95 ? .crit : used >= 85 ? .warn : .ok
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

struct DiskHealth: Equatable {
    var smart: String
    var bus: String
    var temperature: String?
    var note: String

    var line: String {
        var parts = [smart]
        if !bus.isEmpty { parts.append(bus) }
        if let temperature { parts.append(temperature) }
        if !note.isEmpty { parts.append(note) }
        return parts.joined(separator: "  ·  ")
    }
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
    var suggestedIgnore: Bool
    var ignoreHint: String?

    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    var tone: Tone {
        // Disks often sit at 70–85%. Only shout when actually tight.
        if usedPct >= 96 { return .crit }
        if usedPct >= 90 || isReadOnly { return .warn }
        return .ok
    }

    var statusLabel: String {
        if isReadOnly { return "Read-only" }
        if usedPct >= 96 { return "Full" }
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
    private var byKey: [LaneKey: Lane]
    var fetchedAt: Date

    subscript(_ key: LaneKey) -> Lane {
        byKey[key] ?? UsageSources.emptyLane(key)
    }

    var lanes: [Lane] { LaneKey.allCases.map { self[$0] } }
    var barLanes: [Lane] { lanes.filter(\.showsOnBar) }

    func isLinked(_ key: LaneKey) -> Bool {
        let tone = self[key].tone
        return tone != .empty && tone != .error
    }

    static func assemble(_ lanes: [Lane], fetchedAt: Date = Date()) -> Snapshot {
        var dict: [LaneKey: Lane] = [:]
        for lane in lanes { dict[lane.key] = lane }
        return Snapshot(byKey: dict, fetchedAt: fetchedAt)
    }

    static var vacant: Snapshot {
        assemble([], fetchedAt: .distantPast)
    }

    var menuTitle: String {
        let parts = barLanes.map { lane -> String in
            if let n = lane.usedPct { return "\(lane.key.letter) \(Int(n))" }
            return "\(lane.key.letter) —"
        }
        return parts.isEmpty ? "QuotaBar" : parts.joined(separator: " · ")
    }

    func barTitle(disks: [DiskVolume]) -> String {
        var parts = barLanes.map { lane -> String in
            if let n = lane.usedPct { return "\(lane.key.letter) \(Int(n))" }
            return "\(lane.key.letter) —"
        }
        for bit in Self.barDiskBits(disks) {
            parts.append("\(bit.letter) \(bit.pct)")
        }
        return parts.isEmpty ? "QuotaBar" : parts.joined(separator: " · ")
    }

    /// D = hottest internal / system volume. Each external is its own E.
    /// Fixed PCI-E / USB SSDs must not be folded into D.
    static func barDiskBits(_ disks: [DiskVolume]) -> [(letter: String, pct: Int, tone: Tone)] {
        var bits: [(letter: String, pct: Int, tone: Tone)] = []
        if let sys = disks.filter({ $0.kind != .external }).max(by: { $0.usedPct < $1.usedPct }) {
            bits.append(("D", Int(sys.usedPct.rounded()), sys.tone))
        }
        let ext = disks.filter { $0.kind == .external }.sorted { $0.usedPct > $1.usedPct }
        for disk in ext.prefix(4) {
            bits.append(("E", Int(disk.usedPct.rounded()), disk.tone))
        }
        return bits
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

struct ClaudeAuth: Equatable {
    var access: String
    var refresh: String
    var expiresAt: Date
    var subscription: String
    var tier: String

    var isStale: Bool {
        expiresAt.timeIntervalSinceNow < 90
    }

    var canRefresh: Bool {
        !refresh.isEmpty
    }
}
