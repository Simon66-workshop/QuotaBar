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
}

struct RelayLink: Equatable {
    let state: RelayLinkState
    let reason: RelayReason
    let lastHeartbeat: Date?

    private enum Keys: String, CodingKey, CaseIterable {
        case state, reason, lastHeartbeat = "last_heartbeat_at"
    }

    init(from decoder: Decoder, observedAt: Date) throws {
        let values = try decoder.relayFields(Keys.self)
        let wireState = RelayLinkState(rawValue: try values.decode(String.self, forKey: .state))
        let wireReason = RelayReason(rawValue: try values.decode(String.self, forKey: .reason))
        lastHeartbeat = try values.decode(Date?.self, forKey: .lastHeartbeat)
        // Check evidence at collection time; snapshot freshness is a separate gate.
        let heartbeatAge = lastHeartbeat.map { observedAt.timeIntervalSince($0) }
        if let wireState, let wireReason, wireReason.state == wireState,
           wireState != .ok || heartbeatAge.map({ (-5...90).contains($0) }) == true {
            state = wireState
            reason = wireReason
        } else {
            state = .unknown
            reason = .sourceUnavailable
        }
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
        let expiry = try values.decode(Date?.self, forKey: .expiresAt)
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
    let observedAt: Date
    let age: Int
    let feishu: RelayLink
    let wecom: RelayLink
    let certificate: RelayCertificate

    private enum Keys: String, CodingKey, CaseIterable {
        case version = "schema_version", observedAt = "observed_at", age = "snapshot_age_s"
        case feishu, wecom, certificate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.relayFields(Keys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else {
            throw RelayIssue.unsupportedSchema
        }
        observedAt = try values.decode(Date.self, forKey: .observedAt)
        age = try values.decode(Int.self, forKey: .age)
        guard age >= 0 else { throw RelayIssue.badResponse }
        feishu = try RelayLink(from: values.superDecoder(forKey: .feishu), observedAt: observedAt)
        wecom = try RelayLink(from: values.superDecoder(forKey: .wecom), observedAt: observedAt)
        certificate = try RelayCertificate(from: values.superDecoder(forKey: .certificate), observedAt: observedAt)
    }

    var summary: RelayLinkState { .summary(feishu.state, wecom.state) }

    func expiresAt(requestStartedAt: TimeInterval) -> TimeInterval {
        requestStartedAt + (Self.freshness - Double(age))
    }

    static func parse(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|\+00:00)$"#,
                              options: .regularExpression) != nil else { throw RelayIssue.badResponse }
            let formatter = ISO8601DateFormatter()
            if value.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
            guard let date = formatter.date(from: value) else { throw RelayIssue.badResponse }
            return date
        }
        do { return try decoder.decode(Self.self, from: data) }
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

enum RelayIssue: Error, Equatable {
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
