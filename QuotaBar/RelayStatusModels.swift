import Foundation

enum RelayLinkState: String, CaseIterable {
    case ok, degraded, down, unknown

    var label: String {
        switch self {
        case .ok: return "正常"
        case .degraded: return "降级"
        case .down: return "断开"
        case .unknown: return "未知"
        }
    }

    static func summary(_ first: Self, _ second: Self) -> Self {
        let states = [first, second]
        return [.down, .degraded, .unknown].first(where: states.contains) ?? .ok
    }
}

enum RelayReason: String {
    case ready, unitDown = "unit_down", pausedByLease = "paused_by_lease", transitioning
    case sourceUnavailable = "source_unavailable", heartbeatStale = "heartbeat_stale"
    case pongStale = "pong_stale", heartbeatLate = "heartbeat_late", reconnecting
    case pongLate = "pong_late", leaseConflict = "lease_conflict"

    var label: String {
        switch self {
        case .ready: return ""
        case .unitDown: return "服务已停止"
        case .pausedByLease: return "接管期间已暂停"
        case .transitioning: return "服务切换中"
        case .sourceUnavailable: return "缺少可信状态"
        case .heartbeatStale: return "心跳超时"
        case .pongStale: return "应答超时"
        case .heartbeatLate: return "心跳延迟"
        case .reconnecting: return "正在重连"
        case .pongLate: return "应答延迟"
        case .leaseConflict: return "接管状态冲突"
        }
    }

    var state: RelayLinkState {
        switch self {
        case .ready: return .ok
        case .unitDown, .pausedByLease, .heartbeatStale, .pongStale: return .down
        case .transitioning, .heartbeatLate, .reconnecting, .pongLate, .leaseConflict: return .degraded
        case .sourceUnavailable: return .unknown
        }
    }

    static let heartbeatOK: Int64 = 90 * RelayTimestamp.microsecondsPerSecond
    static let pongOK: Int64 = 60 * RelayTimestamp.microsecondsPerSecond
    static let heartbeatDown: Int64 = 180 * RelayTimestamp.microsecondsPerSecond

    func matchesHeartbeatAge(_ collected: Int64?, snapshotAge: Int) -> Bool {
        let second = RelayTimestamp.microsecondsPerSecond
        switch self {
        case .ready:
            return collected.map { (-5 * second...Self.heartbeatOK).contains($0) } == true
        case .heartbeatLate, .heartbeatStale:
            guard let collected, collected >= -5 * second,
                  snapshotAge <= Int(RelaySnapshot.freshness) else { return false }
            // The server adds unrounded elapsed time to the collection age
            // (clamped at zero), then floors snapshot_age_s on the wire.
            let lower = max(0, collected) + Int64(snapshotAge) * second
            let upperExclusive = lower + second
            if self == .heartbeatLate {
                return upperExclusive > Self.heartbeatOK && lower <= Self.heartbeatDown
            }
            return upperExclusive > Self.heartbeatDown
        default: return true // Independent evidence (unit state, pong, lease, etc.).
        }
    }
}

struct RelayLink: Equatable {
    enum Channel { case feishu, wecom }

    var state: RelayLinkState { reason.state }
    private(set) var reason: RelayReason
    private let receivedReason: RelayReason
    var wasReady: Bool { receivedReason == .ready }
    private let channel: Channel
    private let heartbeat: RelayTimestamp?
    var lastHeartbeat: Date? { heartbeat?.date }

    private enum Keys: String, CodingKey, CaseIterable {
        case state, reason, lastHeartbeat = "last_heartbeat_at"
    }

    init(from decoder: Decoder, observedAt: RelayTimestamp, snapshotAge: Int, channel: Channel) throws {
        self.channel = channel
        let values = try decoder.relayFields(Keys.self)
        let wireState = RelayLinkState(rawValue: try values.decode(String.self, forKey: .state))
        let wireReason = RelayReason(rawValue: try values.decode(String.self, forKey: .reason))
        heartbeat = try values.decode(RelayTimestamp?.self, forKey: .lastHeartbeat)
        let collectedHeartbeatAge = heartbeat.map { observedAt.microsecondsSince1970 - $0.microsecondsSince1970 }
        if let wireState, let wireReason, wireReason.state == wireState,
           channel == .wecom || (wireReason != .pongStale && wireReason != .pongLate),
           wireReason.matchesHeartbeatAge(collectedHeartbeatAge, snapshotAge: snapshotAge) {
            reason = wireReason
        } else {
            reason = .sourceUnavailable
        }
        receivedReason = reason
    }

    mutating func project(at time: TimeInterval, observedAt: RelayTimestamp,
                          observationTime: TimeInterval) -> TimeInterval? {
        // A transitioning or unknown row can contain a historical heartbeat.
        guard receivedReason == .ready || (receivedReason.state == .degraded && receivedReason != .transitioning),
              let heartbeat else { return nil }
        let collectedAge = max(0, observedAt.microsecondsSince1970 - heartbeat.microsecondsSince1970)
        func cutoff(_ limit: Int64) -> TimeInterval {
            // Server thresholds are strict (>), not inclusive.
            (observationTime + Double(limit - collectedAge) / Double(RelayTimestamp.microsecondsPerSecond)).nextUp
        }

        // Keep the response reason as the baseline: a locally inferred yellow
        // does not prevent a higher-priority heartbeat reason later.
        var cutoffs: [(RelayReason, TimeInterval)] = [(.heartbeatStale, cutoff(RelayReason.heartbeatDown))]
        if receivedReason == .ready {
            cutoffs.append((.heartbeatLate, cutoff(RelayReason.heartbeatOK)))
            if channel == .wecom {
                // The public sample age bounds pong age from below. The
                // aggregate green window may end sooner, without a reason.
                cutoffs.append((.pongLate, cutoff(RelayReason.pongOK)))
            }
        }
        reason = receivedReason
        var next: TimeInterval?
        for (candidate, deadline) in cutoffs {
            if time >= deadline {
                reason = candidate
                break
            }
            next = min(next ?? deadline, deadline)
        }
        return next
    }

    mutating func revokeGreen() {
        if state == .ok { reason = .sourceUnavailable }
    }
}

struct RelayCertificate: Equatable {
    enum State: String { case ok, expiring, expired, unknown }
    let state: State
    let expiresAt: Date?
    let daysRemaining: Int?

    private enum Keys: String, CodingKey, CaseIterable {
        case state, expiresAt = "expires_at", daysRemaining = "days_remaining"
    }

    init(from decoder: Decoder, observedAt: Date) throws {
        let values = try decoder.relayFields(Keys.self)
        let wireState = State(rawValue: try values.decode(String.self, forKey: .state)) ?? .unknown
        let expiry = try values.decode(RelayTimestamp?.self, forKey: .expiresAt)?.date
        let days = try values.decode(Int?.self, forKey: .daysRemaining)
        if let expiry, let days, Self.matchesLifetime(wireState, days: days, seconds: expiry.timeIntervalSince(observedAt)) {
            state = wireState
            expiresAt = expiry
            daysRemaining = days
        } else {
            state = .unknown
            expiresAt = nil
            daysRemaining = nil
        }
    }

    private static func matchesLifetime(_ state: State, days: Int, seconds: TimeInterval) -> Bool {
        let day: TimeInterval = 86_400
        let expected: State = seconds <= 0 ? .expired : (seconds <= 14 * day ? .expiring : .ok)
        return state == expected && Double(days) == floor(seconds / day)
    }

    var label: String {
        switch state {
        case .unknown: return "未知"
        case .expired: return "已过期"
        case .ok, .expiring:
            guard let daysRemaining else { return "未知" }
            return daysRemaining == 0 ? "不足 1 天" : "剩余 \(daysRemaining) 天"
        }
    }
}

struct RelaySnapshot: Decodable, Equatable {
    static let freshness: TimeInterval = 75
    static let maxGreenForMilliseconds = Int(freshness * 1_000)
    let observation: RelayTimestamp
    var observedAt: Date { observation.date }
    let age: Int
    private(set) var feishu: RelayLink
    private(set) var wecom: RelayLink
    let certificate: RelayCertificate
    private(set) var greenForMilliseconds = 0

    private enum Keys: String, CodingKey, CaseIterable {
        case version = "schema_version", observedAt = "observed_at", age = "snapshot_age_s"
        case feishu, wecom, certificate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.relayFields(Keys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else {
            throw RelayIssue.unsupportedSchema
        }
        observation = try values.decode(RelayTimestamp.self, forKey: .observedAt)
        age = try values.decode(Int.self, forKey: .age)
        guard age >= 0 else { throw RelayIssue.badResponse }
        feishu = try RelayLink(from: values.superDecoder(forKey: .feishu), observedAt: observation,
                              snapshotAge: age, channel: .feishu)
        wecom = try RelayLink(from: values.superDecoder(forKey: .wecom), observedAt: observation,
                              snapshotAge: age, channel: .wecom)
        certificate = try RelayCertificate(from: values.superDecoder(forKey: .certificate), observedAt: observation.date)
    }

    var summary: RelayLinkState { .summary(feishu.state, wecom.state) }

    func expiresAt(requestStartedAt: TimeInterval) -> TimeInterval {
        requestStartedAt + (Self.freshness - Double(age))
    }

    func greenExpiresAt(requestStartedAt: TimeInterval) -> TimeInterval {
        let duration = feishu.wasReady && wecom.wasReady ? Double(greenForMilliseconds) / 1_000 : 0
        // Charge the full request/helper duration, not just time since receipt.
        return requestStartedAt + duration
    }

    func projected(at time: TimeInterval, snapshotDeadline: TimeInterval,
                   greenDeadline: TimeInterval) -> (snapshot: Self, nextDeadline: TimeInterval) {
        let observationTime = snapshotDeadline - Self.freshness
        var aged = self
        let feishuDeadline = aged.feishu.project(at: time, observedAt: observation, observationTime: observationTime)
        let wecomDeadline = aged.wecom.project(at: time, observedAt: observation, observationTime: observationTime)
        var next = min(snapshotDeadline, feishuDeadline ?? .infinity, wecomDeadline ?? .infinity)
        if feishu.wasReady && wecom.wasReady {
            if time < greenDeadline {
                next = min(next, greenDeadline)
            } else {
                // The duration says when the pair stops being provably green,
                // not which link changed or why. Preserve independently known
                // red/yellow; do not invent a failure for the remaining rows.
                aged.feishu.revokeGreen()
                aged.wecom.revokeGreen()
            }
        }
        return (aged, next)
    }

    func withGreenWindow(milliseconds: Int) throws -> Self {
        guard (0...Self.maxGreenForMilliseconds).contains(milliseconds) else { throw RelayIssue.badResponse }
        var snapshot = self
        snapshot.greenForMilliseconds = milliseconds
        return snapshot
    }

    static func parse(_ data: Data, greenForMilliseconds: Int) throws -> Self {
        let decoder = JSONDecoder()
        var syntax = RelayV1JSON(bytes: Array(data))
        try syntax.check(decoder: decoder)
        do { return try decoder.decode(Self.self, from: data).withGreenWindow(milliseconds: greenForMilliseconds) }
        catch let issue as RelayIssue { throw issue }
        catch { throw RelayIssue.badResponse }
    }

    static func shanghaiTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct RelayTimestamp: Decodable, Equatable {
    static let microsecondsPerSecond: Int64 = 1_000_000
    let microsecondsSince1970: Int64

    var date: Date {
        Date(timeIntervalSince1970: Double(microsecondsSince1970) / Double(Self.microsecondsPerSecond))
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        // Whole seconds plus up to six decimal digits; reject excess precision
        // instead of rounding a timestamp across a heartbeat boundary.
        guard value.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|\+00:00)\z"#,
                          options: .regularExpression) != nil else { throw RelayIssue.badResponse }
        // ISO8601DateFormatter normalizes some invalid dates. Check the
        // proleptic Gregorian fields before asking Foundation to parse.
        let bytes = Array(value.utf8)
        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
        }
        let year = number(0..<4), month = number(5..<7), day = number(8..<10)
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard year > 0, (1...12).contains(month), (1...days[month - 1]).contains(day),
              number(11..<13) < 24, number(14..<16) < 60, number(17..<19) < 60 else {
            throw RelayIssue.badResponse
        }
        let whole = String(value.prefix(19)) + "Z"
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: whole),
              formatter.string(from: date) == whole else { throw RelayIssue.badResponse }
        let fraction = bytes[19] == 46 ? bytes.dropFirst(20).prefix(while: { (48...57).contains($0) }) : []
        var micros = fraction.reduce(Int64(0)) { $0 * 10 + Int64($1 - 48) }
        for _ in fraction.count..<6 { micros *= 10 }
        microsecondsSince1970 = Int64(date.timeIntervalSince1970) * Self.microsecondsPerSecond + micros
    }
}

// v1 has only objects (root + one child level), strings, null, and integers.
// Check delimiters and integer lexemes before JSONDecoder can accept trailing
// commas, round a fractional number, or collapse duplicate member names.
private struct RelayV1JSON {
    let bytes: [UInt8]
    private var i = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    private var next: UInt8? { i < bytes.count ? bytes[i] : nil }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard next == byte else { return false }
        i += 1
        return true
    }

    private mutating func space() {
        while let next, [0x20, 0x09, 0x0a, 0x0d].contains(next) { i += 1 }
    }

    mutating func check(decoder: JSONDecoder) throws {
        space()
        try object(allowsChild: true, decoder: decoder)
        space()
        guard i == bytes.count else { throw RelayIssue.badResponse }
    }

    private mutating func object(allowsChild: Bool, decoder: JSONDecoder) throws {
        guard take(0x7b) else { throw RelayIssue.badResponse } // {
        space()
        if take(0x7d) { return } // }
        var seen = Set<String>()
        repeat {
            space()
            let name = try string(decoder: decoder)
            guard seen.insert(name).inserted else { throw RelayIssue.badResponse }
            space()
            guard take(0x3a) else { throw RelayIssue.badResponse } // :
            space()
            switch next {
            case 0x7b where allowsChild: try object(allowsChild: false, decoder: decoder)
            case 0x22: _ = try string(decoder: decoder)
            case 0x6e: // null
                for byte: UInt8 in [0x6e, 0x75, 0x6c, 0x6c] {
                    guard take(byte) else { throw RelayIssue.badResponse }
                }
            default: try integer()
            }
            space()
        } while take(0x2c) // A comma must be followed by another member.
        guard take(0x7d) else { throw RelayIssue.badResponse }
    }

    private mutating func string(decoder: JSONDecoder) throws -> String {
        let start = i
        guard take(0x22) else { throw RelayIssue.badResponse } // "
        while let next {
            i += 1
            if next == 0x22 {
                // Foundation validates UTF-8, controls and the complete escape
                // syntax; decoded names also catch duplicates using escapes.
                guard let value = try? decoder.decode(String.self, from: Data(bytes[start..<i])) else {
                    throw RelayIssue.badResponse
                }
                return value
            }
            if next == 0x5c, i < bytes.count { i += 1 } // skip escaped byte
        }
        throw RelayIssue.badResponse
    }

    private mutating func integer() throws {
        let start = i
        _ = take(0x2d) // -
        if !take(0x30) { // A leading zero cannot be followed by another digit.
            guard let next, (0x31...0x39).contains(next) else { throw RelayIssue.badResponse }
            repeat { i += 1 } while nextIsDigit
        }
        // The enclosing object requires a delimiter after this token, so a
        // decimal point, exponent or second digit after zero fails the check.
        guard Int(String(decoding: bytes[start..<i], as: UTF8.self)) != nil else {
            throw RelayIssue.badResponse
        }
    }

    private var nextIsDigit: Bool {
        next.map { (0x30...0x39).contains($0) } == true
    }
}

private struct RelayField: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

private extension Decoder {
    func relayFields<Key: CodingKey & CaseIterable>(_ key: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let fields = try container(keyedBy: RelayField.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(Key.allCases.map(\.stringValue)) else {
            throw RelayIssue.badResponse
        }
        return try container(keyedBy: key)
    }
}

enum RelayIssue: Error, Equatable, Codable {
    case waiting, notConfigured, keychainUnavailable, invalidCredential
    case offline, timeout, tls, network, unauthorized, rateLimited(TimeInterval)
    case unavailable, httpError, badResponse, unsupportedSchema, expired

    var label: String {
        switch self {
        case .waiting: return "等待状态数据"
        case .notConfigured: return "未配置"
        case .keychainUnavailable: return "登录钥匙串暂不可读"
        case .invalidCredential: return "钥匙串凭据格式错误"
        case .offline: return "网络未连接"
        case .timeout: return "状态请求超时"
        case .tls: return "TLS 验证失败"
        case .network: return "状态接口连接失败"
        case .unauthorized: return "鉴权失败 · 更新凭据后手动刷新"
        case .rateLimited: return "请求限速 · 稍后自动重试"
        case .unavailable: return "状态服务暂不可用"
        case .httpError: return "状态接口返回异常"
        case .badResponse: return "状态响应格式错误"
        case .unsupportedSchema: return "不支持的状态协议版本"
        case .expired: return "状态快照已过期"
        }
    }
}

enum RelayDisplay: Equatable {
    case live(RelaySnapshot)
    case unavailable(RelayIssue)

    var summary: RelayLinkState {
        if case .live(let snapshot) = self { return snapshot.summary }
        return .unknown
    }

    var statusText: String {
        if case .unavailable(let issue) = self { return issue.label }
        return summary.label
    }
}
