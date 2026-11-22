import AppKit
import Security
import SwiftUI

@main
struct RelayStatusCheck {
    private static let good = """
    {
      "schema_version": 1, "observed_at": "2026-11-22T17:15:00Z", "snapshot_age_s": 2,
      "feishu": {"state":"ok","reason":"ready","last_heartbeat_at":"2026-11-22T17:14:51Z"},
      "wecom": {"state":"ok","reason":"ready","last_heartbeat_at":"2026-11-22T17:14:47Z"},
      "certificate":{"state":"ok","expires_at":"2027-02-20T17:15:00Z","days_remaining":90}
    }
    """

    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        if args.dropFirst().elementsEqual([RelayStatusHelper.argument]) {
            RelayStatusHelper.runAndExit(readToken: {
                // Exercise the actual child's Security policy, never SecItemCopyMatching.
                precondition(!interactionAllowed())
                return String(repeating: "A", count: 43)
            }, fetch: { token in
                precondition(token == String(repeating: "A", count: 43))
                return Data(good.utf8)
            })
        }
        let snapshot = try parse(good)
        if args[1] == "time" {
            let first = RelaySnapshot.shanghaiTime(snapshot.feishu.lastHeartbeat!)
            let second = RelaySnapshot.shanghaiTime(snapshot.wecom.lastHeartbeat!)
            precondition(first == "11-23 01:14:51" && second == "11-23 01:14:47")
            print("Feishu=\(first); WeCom=\(second)")
            return
        }
        try models(snapshot)
        try client(snapshot)
        try await store(snapshot)
        try await replay(snapshot)
        await duplicates(snapshot)
        try await helper(snapshot)
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let version = try Data(contentsOf: root.appendingPathComponent("QuotaBar/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: version, format: nil) as? [String: Any]
        precondition(plist?["CFBundleShortVersionString"] as? String == "1.8.28")
        precondition(plist?["CFBundleVersion"] as? String == "41")
        print("VERSION=PASS · 1.8.28/41")
        try render(URL(fileURLWithPath: args[3], isDirectory: true), green: snapshot)
    }

    private static func parse(_ text: String) throws -> RelaySnapshot {
        try RelaySnapshot.parse(Data(text.utf8))
    }

    private static func reject(_ issue: RelayIssue, _ work: () throws -> RelaySnapshot) {
        do {
            _ = try work()
            preconditionFailure("unexpected relay response success")
        } catch {
            precondition((error as? RelayIssue) == issue, "wrong relay error mapping")
        }
    }

    private static func variant(_ state: String, _ reason: String) throws -> RelaySnapshot {
        try parse(good.replacingOccurrences(of: #""state":"ok","reason":"ready","last_heartbeat_at":"2026-11-22T17:14:51Z""#,
            with: #""state":"\#(state)","reason":"\#(reason)","last_heartbeat_at":"2026-11-22T17:14:51Z""#))
    }

    private static func models(_ snapshot: RelaySnapshot) throws {
        precondition(snapshot.age == 2 && snapshot.summary == .ok && snapshot.certificate.label == "剩余 90 天")
        reject(.unsupportedSchema) { try parse(good.replacingOccurrences(of: #""schema_version": 1"#, with: #""schema_version": 2"#)) }
        reject(.badResponse) { try parse("{") }
        reject(.badResponse) { try parse(good.replacingOccurrences(of: #""schema_version": 1"#, with: #""extra": 0, "schema_version": 1"#)) }
        reject(.badResponse) { try parse(good.replacingOccurrences(of: #""reason":"ready""#, with: #""reason":"ready","extra":true"#)) }
        reject(.badResponse) { try parse(good.replacingOccurrences(of: #""days_remaining":90"#, with: #""days_remaining":90,"extra":{}"#)) }
        reject(.badResponse) { try parse(good.replacingOccurrences(of: #","last_heartbeat_at":"2026-11-22T17:14:51Z""#, with: "")) }
        reject(.badResponse) { try parse(good.replacingOccurrences(of: #""snapshot_age_s": 2"#, with: #""snapshot_age_s": -2"#)) }
        let cases: [(String, String, RelayLinkState)] = [
            ("ok", "ready", .ok), ("down", "unit_down", .down), ("down", "paused_by_lease", .down),
            ("down", "heartbeat_stale", .down), ("down", "pong_stale", .down),
            ("degraded", "transitioning", .degraded), ("degraded", "heartbeat_late", .degraded),
            ("degraded", "reconnecting", .degraded), ("degraded", "pong_late", .degraded),
            ("degraded", "lease_conflict", .degraded), ("unknown", "source_unavailable", .unknown),
            ("future", "ready", .unknown), ("ok", "future", .unknown), ("ok", "pong_late", .unknown),
        ]
        for (state, reason, expected) in cases {
            let link = try variant(state, reason).feishu
            precondition(link.state == expected && (expected == .ok || !link.reason.label.isEmpty))
        }
        let noHeartbeat = try parse(good.replacingOccurrences(of: #""2026-11-22T17:14:51Z""#, with: "null"))
        precondition(noHeartbeat.feishu.lastHeartbeat == nil && noHeartbeat.summary == .unknown)
        try heartbeatBoundaries(snapshot)
        let ordered: [RelayLinkState] = [.ok, .unknown, .degraded, .down]
        for (i, a) in ordered.enumerated() {
            for (j, b) in ordered.enumerated() {
                precondition(RelayLinkState.summary(a, b) == ordered[max(i, j)])
            }
        }
        try certificateLifetime(snapshot)
        try dates()
        print("V1_PARSE=PASS · schema, strict keys, malformed data, enum mapping, all 16 priority pairs, certificate independence")
    }

    private static func heartbeatBoundaries(_ snapshot: RelaySnapshot) throws {
        let cases: [(String, RelayLinkState)] = [
            ("2026-11-22T17:13:29Z", .unknown), // 91s before observation
            ("2026-11-22T17:13:30Z", .ok),      // 90s
            ("2026-11-22T17:13:31Z", .ok),      // 89s
            ("2026-11-22T17:15:04Z", .ok),      // 4s after observation
            ("2026-11-22T17:15:05Z", .ok),      // 5s
            ("2026-11-22T17:15:06Z", .unknown), // 6s
        ]
        let links: [(String, KeyPath<RelaySnapshot, RelayLink>, KeyPath<RelaySnapshot, RelayLink>)] = [
            ("2026-11-22T17:14:51Z", \.feishu, \.wecom),
            ("2026-11-22T17:14:47Z", \.wecom, \.feishu),
        ]
        for (original, changedLink, otherLink) in links {
            for (timestamp, expected) in cases {
                let parsed = try parse(good.replacingOccurrences(of: original, with: timestamp))
                let link = parsed[keyPath: changedLink]
                precondition(link.state == expected && link.reason == (expected == .ok ? .ready : .sourceUnavailable),
                             "heartbeat boundary: \(timestamp)")
                precondition(parsed[keyPath: otherLink] == snapshot[keyPath: otherLink] && parsed.summary == expected)
                precondition(parsed.certificate == snapshot.certificate)
            }
        }
        let auditCase = try parse(good.replacingOccurrences(of: "2026-11-22T17:14:51Z", with: "2026-11-22T16:15:00Z")
            .replacingOccurrences(of: "2026-11-22T17:14:47Z", with: "2026-11-23T17:15:00Z"))
        precondition(auditCase.age == 2 && auditCase.feishu.state == .unknown &&
                     auditCase.wecom.state == .unknown && auditCase.summary == .unknown)
        print("HEARTBEAT_BOUNDARIES=PASS · both paths: 89/90/91s old, +4/+5/+6s future")
    }

    private static func certificateLifetime(_ snapshot: RelaySnapshot) throws {
        let cases: [(String, String?, Int?, RelayCertificate.State, String)] = [
            ("ok", "2026-12-06T17:15:01Z", 14, .ok, "剩余 14 天"),
            ("expiring", "2026-12-06T17:15:00Z", 14, .expiring, "剩余 14 天"),
            ("expiring", "2026-12-06T17:14:59Z", 13, .expiring, "剩余 13 天"),
            ("expiring", "2026-11-23T17:15:00Z", 1, .expiring, "剩余 1 天"),
            ("expiring", "2026-11-23T17:14:59Z", 0, .expiring, "不足 1 天"),
            ("expiring", "2026-11-22T17:15:01Z", 0, .expiring, "不足 1 天"),
            ("expired", "2026-11-22T17:15:00Z", 0, .expired, "已过期"),
            ("expired", "2026-11-22T17:14:59Z", -1, .expired, "已过期"),
            ("ok", "2025-11-22T17:15:00Z", 90, .unknown, "未知"), // Audit repro
            ("ok", "2027-02-20T17:15:00Z", 89, .unknown, "未知"),
            ("ok", "2026-12-06T17:15:00Z", 14, .unknown, "未知"),
            ("expired", "2026-11-22T17:15:01Z", 0, .unknown, "未知"),
            ("expired", "2026-11-22T17:14:59Z", 0, .unknown, "未知"),
            ("ok", nil, 90, .unknown, "未知"),
            ("ok", "2027-02-20T17:15:00Z", nil, .unknown, "未知"),
            ("unknown", nil, nil, .unknown, "未知"),
        ]
        for (state, expiry, days, expected, label) in cases {
            let expiryJSON = expiry.map { "\"\($0)\"" } ?? "null"
            let daysJSON = days.map { String($0) } ?? "null"
            let parsed = try parse(good.replacingOccurrences(
                of: #"{"state":"ok","expires_at":"2027-02-20T17:15:00Z","days_remaining":90}"#,
                with: #"{"state":"\#(state)","expires_at":\#(expiryJSON),"days_remaining":\#(daysJSON)}"#))
            let cert = parsed.certificate
            precondition(cert.state == expected && cert.label == label, "certificate lifetime: \(state) \(expiryJSON) \(daysJSON)")
            precondition(cert.daysRemaining == (expected == .unknown ? nil : days))
            precondition((cert.expiresAt == nil) == (expected == .unknown))
            precondition(parsed.feishu == snapshot.feishu && parsed.wecom == snapshot.wecom && parsed.summary == snapshot.summary)
        }
        print("CERTIFICATE_BOUNDARIES=PASS · \(cases.count) cases: 14-day/expiry boundaries, full days and unchanged links")
    }

    private static func dates() throws {
        let originals = ["2026-11-22T17:15:00Z", "2026-11-22T17:14:51Z",
                         "2026-11-22T17:14:47Z", "2027-02-20T17:15:00Z"]
        for bad in ["2026-02-30T17:15:00Z", "2026-02-29T17:15:00Z",
                    "1900-02-29T17:15:00Z", "2026-04-31T17:15:00Z",
                    "2026-11-22T24:00:00Z", "2026-11-22T17:15:00Z\n"] {
            let wire = bad.replacingOccurrences(of: "\n", with: #"\n"#)
            for original in originals {
                reject(.badResponse) { try parse(good.replacingOccurrences(of: original, with: wire)) }
            }
            let allInvalid = originals.reduce(good) { $0.replacingOccurrences(of: $1, with: wire) }
            reject(.badResponse) { try parse(allInvalid) }
        }
        let leap = try parse(good.replacingOccurrences(of: "2026-11-22T17:15:00Z", with: "2028-02-29T17:15:00.5+00:00")
            .replacingOccurrences(of: "2026-11-22", with: "2028-02-29")
            .replacingOccurrences(of: "2027-02-20T17:15:00Z", with: "2028-02-29T17:15:01Z")
            .replacingOccurrences(of: #""state":"ok","expires_at""#, with: #""state":"expiring","expires_at""#)
            .replacingOccurrences(of: #""days_remaining":90"#, with: #""days_remaining":0"#))
        precondition(leap.summary == .ok && leap.certificate.state == .expiring)
        precondition(leap.observedAt.timeIntervalSince(leap.feishu.lastHeartbeat!) == 9.5)
        print("APP-03=PASS · invalid calendar/time values rejected in all four fields; valid leap day, fraction and +00:00 accepted")
    }

    private static func client(_ snapshot: RelaySnapshot) throws {
        let config = RelayStatusClient.configuration()
        precondition(config.timeoutIntervalForRequest == 5 && config.timeoutIntervalForResource == 5)
        precondition(config.urlCache == nil && config.requestCachePolicy == .reloadIgnoringLocalCacheData)
        precondition(config.httpCookieStorage == nil && !config.httpShouldSetCookies && config.httpCookieAcceptPolicy == .never)
        precondition(config.urlCredentialStorage == nil && !config.waitsForConnectivity)
        precondition(RelayStatusClient.endpoint.absoluteString == "https://66workshop.cn/api/relay-status/v1")
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: RelayStatusClient.endpoint) // Intentionally never resumed.
        let target = URLRequest(url: URL(string: "https://example.invalid/")!)
        let redirect = HTTPURLResponse(url: RelayStatusClient.endpoint, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": target.url!.absoluteString])!
        var refused = false
        RelayNoRedirect().urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                                     newRequest: target) { refused = $0 == nil }
        precondition(refused && task.state == .suspended)
        let data = Data(good.utf8)
        let fixtureNow = Date(timeIntervalSince1970: 0)
        func send(_ status: Int, _ headers: [String: String] = ["Content-Type": "application/json"]) throws -> RelaySnapshot {
            let response = HTTPURLResponse(url: RelayStatusClient.endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return try RelayStatusClient.decode(data, response: response, now: fixtureNow)
        }
        let valid = try send(200)
        precondition(valid == snapshot)
        reject(.badResponse) { try send(200, ["Content-Type": "text/html"]) }
        reject(.unauthorized) { try send(401) }
        reject(.httpError) { try send(302) }
        reject(.httpError) { try send(404) }
        reject(.unavailable) { try send(503) }
        reject(.rateLimited(60)) { try send(429) }
        reject(.rateLimited(60)) { try send(429, ["Retry-After": "bad"]) }
        reject(.rateLimited(95)) { try send(429, ["Retry-After": "95"]) }
        reject(.rateLimited(90)) { try send(429, ["Retry-After": "Thu, 01 Jan 1970 00:01:30 GMT"]) }
        precondition(RelayIssue.notConfigured.label == "未配置" && RelayIssue.unauthorized.label.contains("手动刷新") &&
                     RelayIssue.rateLimited(60).label.contains("限速") && RelayIssue.unavailable.label == "状态服务暂不可用")
        precondition(RelayStatusClient.issue(for: .notConnectedToInternet) == .offline)
        precondition(RelayStatusClient.issue(for: .timedOut) == .timeout)
        precondition(RelayStatusClient.issue(for: .serverCertificateUntrusted) == .tls)
        print("HTTP_POLICY=PASS · no I/O; cache/cookies/credential storage disabled, 5s, refused redirect, error labels and Retry-After")
    }

    @MainActor
    private static func store(_ snapshot: RelaySnapshot) async throws {
        precondition((0...5).map { RelayPollTiming.delay(failures: $0, jitter: 0) } == [30, 30, 60, 120, 300, 300])
        precondition(RelayPollTiming.delay(failures: 2, jitter: -3) == 57)
        precondition(RelayPollTiming.delay(failures: 2, jitter: 3) == 63)
        var now: TimeInterval = 0
        var calls = 0
        var keyReads = 0
        var missing = true
        var response: Result<RelaySnapshot, RelayIssue> = .success(snapshot)
        var stall = false
        var resume: CheckedContinuation<Void, Never>?
        let status = RelayStatusStore(loadSnapshot: {
            keyReads += 1
            if missing { throw RelayIssue.notConfigured }
            calls += 1
            if stall { await withCheckedContinuation { resume = $0 } }
            return try response.get()
        }, now: { now }, jitter: { 0 })
        status.start(monitorNetwork: false)
        defer { status.stop() }
        await status.waitForAttempt()
        precondition(calls == 0 && keyReads == 1 && status.display == .unavailable(.notConfigured))
        missing = false
        stall = true
        status.manualRefresh()
        while resume == nil { await Task.yield() }
        status.woke()
        status.manualRefresh()
        status.panelOpened()
        precondition(calls == 1 && keyReads == 2, "single flight")
        now = 4
        resume?.resume()
        await status.waitForAttempt()
        precondition(status.display == .live(snapshot))
        now = 14
        status.panelOpened()
        await status.waitForAttempt()
        precondition(calls == 1, "panel-open minimum interval")
        now = 34
        stall = false
        response = .failure(.unauthorized)
        status.clockAdvanced()
        await status.waitForAttempt()
        precondition(calls == 2 && status.display == .unavailable(.unauthorized) && status.display.summary == .unknown)
        now = 1000
        status.woke()
        status.panelOpened()
        await status.waitForAttempt()
        precondition(calls == 2, "401 must not auto-resume")
        response = .failure(.rateLimited(95))
        status.manualRefresh()
        await status.waitForAttempt()
        precondition(calls == 3 && status.display == .unavailable(.rateLimited(95)))
        status.networkChanged(false)
        now = 1094
        status.networkChanged(true)
        status.manualRefresh()
        await status.waitForAttempt()
        precondition(calls == 3 && status.display == .unavailable(.rateLimited(95)),
                     "Retry-After survives wake, manual refresh, and restore")
        response = .success(try parse(good.replacingOccurrences(of: "T17:15:00Z", with: "T17:15:30Z")))
        now = 1095
        status.clockAdvanced()
        await status.waitForAttempt()
        precondition(calls == 4 && status.display.summary == .ok)

        now = 1111
        status.panelOpened()
        await status.waitForAttempt()
        precondition(calls == 5, "panel-open refresh after 15s")
        status.networkChanged(false)
        precondition(status.display == .unavailable(.offline))
        now = 1200
        status.woke()
        await status.waitForAttempt()
        precondition(calls == 5)
        let nearlyOld = try parse(good.replacingOccurrences(of: "T17:15:00Z", with: "T17:16:00Z")
            .replacingOccurrences(of: #""snapshot_age_s": 2"#, with: #""snapshot_age_s": 70"#))
        response = .success(nearlyOld)
        stall = true
        resume = nil
        status.networkChanged(true)
        while resume == nil { await Task.yield() }
        now = 1204
        resume?.resume()
        await status.waitForAttempt()
        precondition(status.display.summary == .ok)
        now = 1205
        status.clockAdvanced()
        precondition(status.display == .unavailable(.expired) && calls == 6, "expiry uses server age + request time")
        now = 1234
        stall = false
        response = .failure(.timeout)
        status.clockAdvanced()
        await status.waitForAttempt()
        precondition(status.display == .unavailable(.timeout) && calls == 7)
        now = 1263
        status.woke()
        await status.waitForAttempt()
        precondition(calls == 7, "wake must respect failure backoff")
        now = 1264
        status.clockAdvanced()
        await status.waitForAttempt()
        precondition(calls == 8)
        now = 1323
        status.clockAdvanced()
        await status.waitForAttempt()
        precondition(calls == 8)
        now = 1324
        status.clockAdvanced()
        await status.waitForAttempt()
        precondition(calls == 9)
        print("POLLING=PASS · injected clock/credentials/transport; single flight, panel gate, wake, offline, 401, 429, expiry, backoff")
    }

    @MainActor
    private static func replay(_ snapshot: RelaySnapshot) async throws {
        var now: TimeInterval = 0
        var calls = 0
        var response = snapshot
        let status = RelayStatusStore(loadSnapshot: {
            calls += 1
            return response
        }, now: { now }, jitter: { 0 })
        status.start(monitorNetwork: false)
        defer { status.stop() }
        await status.waitForAttempt()
        for time in [30.0, 60, 72.999, 73, 90, 120] {
            now = time
            status.clockAdvanced()
            await status.waitForAttempt()
            if time < 73 { precondition(status.display == .live(snapshot)) }
            else { precondition(status.display == .unavailable(.expired) && status.display.summary == .unknown) }
        }
        precondition(calls == 5, "the identical observation was actually replayed at 90 and 120s")
        let newerWire = good.replacingOccurrences(of: "T17:15:00Z", with: "T17:15:30Z")
        let newer = try parse(newerWire)
        response = newer
        now = 180
        status.clockAdvanced()
        await status.waitForAttempt()
        precondition(status.display == .live(newer))
        // Same timestamp shrinks to 200, then a smaller advertised age and a
        // connectivity bounce must not extend it.
        response = try parse(newerWire.replacingOccurrences(of: #""snapshot_age_s": 2"#, with: #""snapshot_age_s": 70"#))
        now = 195
        status.manualRefresh()
        await status.waitForAttempt()
        precondition(status.display.summary == .ok)
        response = newer
        now = 198
        status.networkChanged(false)
        status.networkChanged(true)
        await status.waitForAttempt()
        precondition(status.display.summary == .ok)
        now = 200
        status.clockAdvanced()
        precondition(status.display == .unavailable(.expired))
        response = snapshot
        now = 201
        status.manualRefresh()
        await status.waitForAttempt()
        precondition(status.display == .unavailable(.expired), "older observation cannot bypass the high-water mark")
        print("APP-01=PASS · replay at 30/60/90/120s, exact deadline, recovery with newer data, shortening, reconnect and rollback")
    }

    @MainActor
    private static func duplicates(_ snapshot: RelaySnapshot) async {
        let fixtures = [
            (#""snapshot_age_s": 2"#, #""snapshot_age_s": 200"#),
            (#""snapshot_age_s": 2"#, #""snapshot_age_\u0073": 200"#),
            (#""feishu": {"state":"ok""#, #""state":"down""#),
            (#""wecom": {"state":"ok""#, #""st\u0061te":"down""#),
            (#""certificate":{"state":"ok""#, #""state":"expired""#),
            (#""days_remaining":90"#, #""days_remaining":90"#),
        ]
        let http = HTTPURLResponse(url: RelayStatusClient.endpoint, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        for (target, duplicate) in fixtures {
            let split = target.lastIndex(of: "{").map { target.index(after: $0) } ?? target.startIndex
            let key = target[split...]
            for pair in ["\(key),\(duplicate)", "\(duplicate),\(key)"] {
                let wire = good.replacingOccurrences(of: target, with: target[..<split] + pair)
                let body = Data(wire.utf8)
                reject(.badResponse) { try RelayStatusClient.decode(body, response: http) }
                var first = true
                let store = RelayStatusStore(loadSnapshot: {
                    if first { first = false; return snapshot }
                    return try RelayStatusClient.decode(body, response: http)
                }, now: { 0 }, jitter: { 0 })
                store.start(monitorNetwork: false)
                await store.waitForAttempt()
                precondition(store.display.summary == .ok)
                store.manualRefresh()
                await store.waitForAttempt()
                precondition(store.display == .unavailable(.badResponse) && store.display.summary == .unknown)
                store.stop()
            }
        }
        print("APP-02=PASS · 12 order/level cases including escaped and identical keys; HTTP badResponse clears green")
    }

    private static func interactionAllowed() -> Bool {
        var allowed = DarwinBoolean(false)
        precondition(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess)
        return allowed.boolValue
    }

    private static func helper(_ snapshot: RelaySnapshot) async throws {
        let before = interactionAllowed()
        let result = try await RelayStatusHelper.load()
        precondition(result == snapshot && interactionAllowed() == before)
        print("APP-04=PASS · actual child/pipe with synthetic providers; child interaction disabled, parent policy unchanged")
    }

    @MainActor
    private static func render(_ output: URL, green: RelaySnapshot) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let displays: [(String, RelayDisplay)] = [
            ("green", .live(green)), ("yellow", .live(try variant("degraded", "heartbeat_late"))),
            ("red", .live(try variant("down", "paused_by_lease"))), ("gray", .unavailable(.unauthorized))
        ]
        var sectionHeight: CGFloat?
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for (name, display) in displays {
                let section = RelayStatusSection(display: display).padding(16)
                let size = try capture(section, name: "relay-\(theme)-\(name)", dark: dark, output: output)
                if let sectionHeight { precondition(abs(sectionHeight - size.height) < 0.5, "unstable section height") }
                else { sectionHeight = size.height }
                _ = try capture(panelFragment(display), name: "relay-panel-\(theme)-\(name)", dark: dark, output: output)
            }
        }

        let cap: Double = 110
        let plan = fitPanel(measured: nil, header: 37, usage: 56, bottom: Double(sectionHeight ?? 110) + 54,
            verticalPadding: PanelFitMetrics.verticalPadding, sectionSpacing: PanelFitMetrics.sectionSpacing,
            cap: cap, epsilon: PanelFitMetrics.heightEpsilon, currentlyScrolling: false,
            hysteresis: PanelFitMetrics.scrollHysteresis)
        precondition(plan.scroll == .body && plan.height == cap, "relay in bottom band needs short-panel body scroll")
        let short = PanelBodyScroll(height: plan.height) {
            panelFragment(.unavailable(.unauthorized))
        }
        _ = try capture(short, name: "relay-panel-dark-short-scrolled", dark: true, output: output, scroll: true)
        print("RENDER=PASS · 17 offscreen PNGs; stable section height, drawable foreground and short native scroll")
    }

    private static func panelFragment(_ display: RelayDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("QuotaBar").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("v1.8.28").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            UsageTable(lanes: [.used(.grok, percent: 21, sub: "Shared weekly pool")])
            RelayStatusSection(display: display)
            MemoryRow(usage: MemoryUsage(usedBytes: 10_737_418_240, totalBytes: 17_179_869_184))
        }
        .padding(CGFloat(PanelFitMetrics.outerPadding))
    }

    @MainActor
    private static func capture<V: View>(_ view: V, name: String, dark: Bool, output: URL, scroll: Bool = false) throws -> NSSize {
        let width = CGFloat(PanelFitMetrics.panelWidth)
        let backgrounds: (dark: UInt32, light: UInt32) = (0x222427, 0xF3F4F6)
        let rgb = dark ? backgrounds.dark : backgrounds.light
        let bg = Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        let content = view.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .background(bg).environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        precondition(abs(size.width - width) < 1 && (80..<800).contains(size.height), "unexpected preview geometry")
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = frame
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        host.layoutSubtreeIfNeeded()
        if scroll {
            guard let scroller = scrollView(in: host), let doc = scroller.documentView else {
                throw NSError(domain: "native panel scroll view missing", code: 1)
            }
            let clip = scroller.contentView
            let distance = doc.bounds.height - clip.bounds.height
            precondition(distance > 0 && size.height == 110)
            clip.scroll(to: NSPoint(x: 0, y: distance))
            scroller.reflectScrolledClipView(clip)
            precondition(clip.bounds.origin.y > 0)
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "preview bitmap unavailable", code: 1)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // A solid backdrop (or transparent bitmap) alone must not pass.
        let bgSample = bitmap.colorAt(x: 3, y: 3)!.usingColorSpace(.deviceRGB)!
        var foreground = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.alphaComponent > 0.9 else { continue }
                if abs(pixel.redComponent - bgSample.redComponent) + abs(pixel.greenComponent - bgSample.greenComponent)
                   + abs(pixel.blueComponent - bgSample.blueComponent) > 0.25 { foreground += 1 }
            }
        }
        precondition(bgSample.alphaComponent > 0.9 && foreground > 40, "preview lacks foreground pixels")
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "preview encoding failed", code: 1)
        }
        try png.write(to: output.appendingPathComponent("\(name).png"))
        print("\(name).png · \(Int(size.width))×\(Int(size.height)) pt · \(foreground) contrasting samples")
        return size
    }

    @MainActor
    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
}
