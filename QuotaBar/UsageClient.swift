import Foundation

enum UsageClient {
    private static let timeout: TimeInterval = 12

    static func fetchCursor(token: String) async -> Lane {
        let t = TokenReader.scrub(token)
        if t.isEmpty { return .empty(.cursor, sub: "Ultra monthly  ·  not connected") }
        do {
            let json = try await post(
                "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
                token: t
            )
            return parseCursor(json) ?? .error(.cursor, message: "Cursor usage payload was incomplete")
        } catch AuthError.http(let code) where code == 401 || code == 403 {
            return .error(.cursor, message: "Session expired — sign in to Cursor again")
        } catch {
            return .error(.cursor, message: "Cursor did not return period usage")
        }
    }

    static func fetchSand(token: String) async -> Lane {
        let t = TokenReader.scrub(token)
        if t.isEmpty { return .empty(.bot, sub: "Sand weekly  ·  needs Cursor") }
        do {
            let json = try await post(
                "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus",
                token: t
            )
            return parseSand(json) ?? .error(.bot, message: "Sand weekly payload was incomplete")
        } catch AuthError.http(let code) where code == 401 || code == 403 {
            return .error(.bot, message: "Session expired — same Cursor token")
        } catch {
            return .error(.bot, message: "Sand weekly quota not returned")
        }
    }

    private static func grokStatus(_ line: String) {
        let url = TokenReader.home().appendingPathComponent(".grok/quotabar-status.txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let next = "\(stamp)  \(line)\n"
        let prev = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let keep = prev.split(whereSeparator: \.isNewline).suffix(18).joined(separator: "\n")
        let out = keep.isEmpty ? next : keep + "\n" + next
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    static func fetchGrok(token ignored: String = "") async -> Lane {
        guard var auth = TokenReader.loadGrokAuth() else {
            grokStatus("no-token")
            return .empty(.grok, sub: "Weekly SuperGrok Heavy  ·  not connected")
        }

        var persistNote: String?
        // Refresh only when near expiry. Always-refresh burned tokens.
        if auth.canRefresh, auth.isStale || auth.access.isEmpty {
            switch await refreshGrokOIDC(auth) {
            case .ok(let next):
                persistNote = TokenReader.persist(next)
                auth = next
            case .failed(let detail) where detail.localizedCaseInsensitiveContains("invalid_grant"):
                TokenReader.markRefreshDead(auth.refresh)
                if let live = TokenReader.discoverAlternateAuth(), !TokenReader.isDeadRefresh(live.refresh) {
                    if live.canRefresh, live.isStale || live.access.isEmpty {
                        switch await refreshGrokOIDC(live) {
                        case .ok(let next):
                            persistNote = TokenReader.persist(next)
                            auth = next
                        case .failed(let second):
                            grokStatus("refresh invalid_grant alt \(second)")
                            return .error(.grok, message: "Grok refresh invalid_grant; alternate also failed: \(second)")
                        }
                    } else {
                        persistNote = TokenReader.persist(live)
                        auth = live
                    }
                } else {
                    TokenReader.clearStaleAuthLock()
                    grokStatus("refresh invalid_grant no-alt")
                    return .error(
                        .grok,
                        message: "CLI 没落盘。点 Sign in with Grok，由 QuotaBar 写回 key + expires_at。"
                    )
                }
            case .failed(let detail):
                persistNote = "refresh soft-fail: \(detail)"
            }
        } else if auth.access.isEmpty {
            grokStatus("access empty")
            return .empty(.grok, sub: "auth.json has no access or refresh_token")
        }

        do {
            let json = try await pullGrokBilling(token: auth.access)
            if var lane = parseGrok(json) {
                if let persistNote, persistNote.contains("write failed") {
                    lane.sub += "  ·  auth.json write failed"
                }
                grokStatus("ok used=\(Int(lane.usedPct ?? 0)) keys=\(json.keys.sorted().joined(separator: ","))")
                return lane
            }
            let keys = json.keys.sorted().joined(separator: ",")
            grokStatus("parse-nil keys=\(keys)")
            return .error(.grok, message: "billing keys \(keys)")
        } catch AuthError.http(let code) where code == 401 || code == 403 {
            if auth.canRefresh, !TokenReader.isDeadRefresh(auth.refresh) {
                switch await refreshGrokOIDC(auth) {
                case .ok(let next):
                    _ = TokenReader.persist(next)
                    if let json = try? await pullGrokBilling(token: next.access),
                       let lane = parseGrok(json)
                    {
                        grokStatus("ok after-401 used=\(Int(lane.usedPct ?? 0))")
                        return lane
                    }
                case .failed(let detail) where detail.localizedCaseInsensitiveContains("invalid_grant"):
                    TokenReader.markRefreshDead(auth.refresh)
                    grokStatus("billing \(code) invalid_grant")
                    return .error(.grok, message: "billing \(code) · sign in again")
                case .failed(let detail):
                    grokStatus("billing \(code) refresh \(detail)")
                }
            }
            grokStatus("billing \(code)")
            return .error(.grok, message: "billing \(code)")
        } catch AuthError.http(let code) {
            grokStatus("billing HTTP \(code)")
            return .error(.grok, message: "billing HTTP \(code)")
        } catch let err as GrokNet.TransportError {
            grokStatus("curl \(err.localizedDescription)")
            return .error(.grok, message: "curl \(err.localizedDescription)")
        } catch AuthError.bad {
            grokStatus("billing JSON")
            return .error(.grok, message: "billing JSON")
        } catch {
            grokStatus("billing \(error.localizedDescription)")
            return .error(.grok, message: "billing \(error.localizedDescription)")
        }
    }

    static func fetchChatGPT() async -> Lane {
        guard var auth = TokenReader.loadCodexAuth() else {
            return .empty(.gpt, sub: "ChatGPT / Codex  ·  run `codex login` once")
        }
        if auth.canRefresh, auth.isStale || auth.access.isEmpty {
            switch await refreshCodex(auth) {
            case .ok(let next):
                TokenReader.persistCodex(next)
                auth = next
            case .failed(let detail) where detail.localizedCaseInsensitiveContains("invalid"):
                return .error(.gpt, message: "ChatGPT session expired — run `codex login`")
            case .failed:
                break
            }
        }
        do {
            let json = try await getChatGPTUsage(auth)
            if let lane = parseChatGPT(json) { return lane }
            return .error(.gpt, message: "ChatGPT usage 200 but no rate_limit window")
        } catch AuthError.http(let code) where code == 401 || code == 403 {
            if auth.canRefresh {
                switch await refreshCodex(auth) {
                case .ok(let next):
                    TokenReader.persistCodex(next)
                    if let json = try? await getChatGPTUsage(next), let lane = parseChatGPT(json) {
                        return lane
                    }
                case .failed:
                    break
                }
            }
            return .error(.gpt, message: "ChatGPT usage \(code) — run `codex login`")
        } catch AuthError.http(let code) {
            return .error(.gpt, message: "ChatGPT usage HTTP \(code)")
        } catch {
            return .error(.gpt, message: "ChatGPT usage request failed")
        }
    }

    static func fetchClaude() async -> Lane {
        guard var auth = TokenReader.loadClaudeAuth() else {
            return .empty(.claude, sub: "Claude Code 5h + 7d  ·  run `claude` once")
        }
        if auth.canRefresh, auth.isStale || auth.access.isEmpty {
            if ProcessProbe.claudeLive() {
                if auth.access.isEmpty {
                    return .error(.claude, message: "Claude Code is running — waiting for its token")
                }
            } else {
                switch await refreshClaude(auth) {
                case .ok(let next):
                    TokenReader.persistClaude(next)
                    auth = next
                case .failed(let detail) where detail.localizedCaseInsensitiveContains("invalid"):
                    return .error(.claude, message: "Claude session expired — run `claude` once")
                case .failed:
                    break
                }
            }
        }
        do {
            let json = try await getClaudeUsage(auth)
            if let lane = parseClaude(json, auth: auth) { return lane }
            return .error(.claude, message: "Claude usage 200 but no 5h / 7d window")
        } catch AuthError.http(let code) where code == 401 || code == 403 {
            if ProcessProbe.claudeLive() {
                return .error(.claude, message: "Claude Code is running — token is stale, wait for it to refresh")
            }
            if auth.canRefresh {
                switch await refreshClaude(auth) {
                case .ok(let next):
                    TokenReader.persistClaude(next)
                    if let json = try? await getClaudeUsage(next), let lane = parseClaude(json, auth: next) {
                        return lane
                    }
                case .failed:
                    break
                }
            }
            return .error(.claude, message: "Claude usage \(code) — run `claude` once")
        } catch AuthError.http(let code) {
            return .error(.claude, message: "Claude usage HTTP \(code)")
        } catch {
            return .error(.claude, message: "Claude usage request failed")
        }
    }

    private enum AuthError: Error { case http(Int), bad }

    private enum RefreshResult {
        case ok(GrokAuth)
        case failed(String)
    }

    private enum CodexRefresh {
        case ok(CodexAuth)
        case failed(String)
    }

    private enum ClaudeRefresh {
        case ok(ClaudeAuth)
        case failed(String)
    }

    private static func post(_ url: String, token: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("QuotaBar/1.8", forHTTPHeaderField: "User-Agent")
        req.httpBody = Data("{}".utf8)
        let (data, res) = try await URLSession.shared.data(for: req)
        return try decode(data, res)
    }

    private static func pullGrokBilling(token: String) async throws -> [String: Any] {
        var last: Error = AuthError.bad
        var best: (json: [String: Any], score: Int)?
        let urls = [
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
            "https://cli-chat-proxy.grok.com/v1/billing",
            "https://grok.com/rest/subscriptions",
            "https://grok.com/rest/billing/usage",
            "https://grok.com/rest/usage",
        ]
        for url in urls {
            do {
                let json = try await getGrokJSON(url: url, token: token)
                let score = grokScore(json)
                grokStatus("try \(url.replacingOccurrences(of: "https://", with: "")) score=\(score) \(grokShape(json))")
                if best == nil || score > best!.score {
                    best = (json, score)
                }
            } catch {
                last = error
                grokStatus("fail \(url.replacingOccurrences(of: "https://", with: "")) \(error.localizedDescription)")
            }
        }
        do {
            if let json = try await getGrokCreditsGRPC(token: token) {
                let score = grokScore(json) + 3
                grokStatus("try grpc GetGrokCreditsConfig score=\(score) \(grokShape(json))")
                if best == nil || score > best!.score {
                    best = (json, score)
                }
            }
        } catch {
            last = error
            grokStatus("fail grpc \(error.localizedDescription)")
        }
        if let best { return best.json }
        throw last
    }

    /// Website weekly pool (Chat / Builder / Imagine) lives on grok.com, not
    /// the credits-only `config.creditUsagePercent` which is often 0.
    private static func grokScore(_ json: [String: Any]) -> Int {
        let root = json["config"] as? [String: Any] ?? json
        let period = (root["currentPeriod"] as? [String: Any])
            ?? (json["currentPeriod"] as? [String: Any])
        let products = (period?["productUsage"] ?? root["productUsage"] ?? json["productUsage"]) as? [[String: Any]]
        let n = products?.count ?? 0
        let periodPct = num(period?["creditUsagePercent"]) ?? num(period?["usagePercent"])
        let configPct = num(root["creditUsagePercent"])
        var score = 0
        if n > 0 { score += 8 + min(n, 4) }
        if let periodPct, periodPct > 0 { score += 12 }
        else if period != nil { score += 4 }
        if let configPct, configPct > 0 { score += 3 }
        if period?["end"] != nil || root["billingPeriodEnd"] != nil { score += 1 }
        return score
    }

    private static func grokShape(_ json: [String: Any]) -> String {
        let root = json["config"] as? [String: Any] ?? json
        let period = (root["currentPeriod"] as? [String: Any]) ?? (json["currentPeriod"] as? [String: Any])
        let ck = root.keys.sorted().joined(separator: ",")
        let pk = period?.keys.sorted().joined(separator: ",") ?? "-"
        let pct = num(period?["creditUsagePercent"]) ?? num(root["creditUsagePercent"])
        return "cfg=\(ck) period=\(pk) pct=\(pct.map { String(Int($0)) } ?? "-")"
    }

    private static func getGrokJSON(url: String, token: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        applyGrokHeaders(&req, token: token)
        let (data, res) = try await GrokNet.data(for: req)
        return try decode(data, res)
    }

    private static func applyGrokHeaders(_ req: inout URLRequest, token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "User-Agent")
        req.setValue("grok-shell", forHTTPHeaderField: "x-grok-client-identifier")
        req.setValue("0.2.120", forHTTPHeaderField: "x-grok-client-version")
    }

    private static func getGrokCreditsGRPC(token: String) async throws -> [String: Any]? {
        var req = URLRequest(url: URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        applyGrokHeaders(&req, token: token)
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "x-grpc-web")
        req.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        req.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        req.httpBody = Data([0, 0, 0, 0, 0])
        let (data, res) = try await GrokNet.data(for: req)
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        if !(200 ..< 300).contains(code) { throw AuthError.http(code) }
        return parseGrokCreditsProto(data)
    }

    /// grpc-web frame + proto. Field 1 = used%, 5 = reset, 7 = products (enum + %).
    private static func parseGrokCreditsProto(_ raw: Data) -> [String: Any]? {
        let proto: Data
        if raw.count >= 5, raw[0] == 0 {
            let len = Int(raw[1]) << 24 | Int(raw[2]) << 16 | Int(raw[3]) << 8 | Int(raw[4])
            if 5 + len <= raw.count {
                proto = raw.subdata(in: 5 ..< (5 + len))
            } else {
                proto = raw
            }
        } else if let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            return obj
        } else {
            proto = raw
        }
        let root = protoFields(proto)
        let innerData = root[1].compactMap { $0 as? Data }.first ?? proto
        let inner = protoFields(innerData)
        var used = protoFloat(inner[1]) ?? protoFloat(root[1])
        var products: [[String: Any]] = []
        let names = [1: "GrokAPI", 2: "GrokBuild", 4: "GrokChat", 5: "GrokImagine", 6: "GrokVoice"]
        for blob in inner[7] {
            guard let data = blob as? Data else { continue }
            let item = protoFields(data)
            let kind = protoInt(item[1]) ?? 0
            let pct = protoFloat(item[2]) ?? 0
            products.append(["product": names[kind] ?? "P\(kind)", "usagePercent": pct])
        }
        if used == nil, !products.isEmpty {
            used = products.reduce(0) { $0 + (( $1["usagePercent"] as? Double) ?? 0) }
        }
        guard used != nil || !products.isEmpty else { return nil }
        var period: [String: Any] = [:]
        if let used { period["creditUsagePercent"] = used }
        if let end = protoInt(inner[5]) ?? protoInt(root[5]), end > 1_000_000 {
            period["end"] = end
        }
        if !products.isEmpty { period["productUsage"] = products }
        period["type"] = "WEEKLY"
        return ["config": ["currentPeriod": period, "creditUsagePercent": used ?? 0]]
    }

    private static func protoFields(_ data: Data) -> [Int: [Any]] {
        var out: [Int: [Any]] = [:]
        var i = data.startIndex
        while i < data.endIndex {
            let (key, n1) = protoVarint(data, i)
            guard let key, n1 > 0 else { break }
            i += n1
            let field = Int(key >> 3)
            let wire = Int(key & 7)
            switch wire {
            case 0:
                let (v, n) = protoVarint(data, i)
                guard let v, n > 0 else { return out }
                out[field, default: []].append(v)
                i += n
            case 1:
                guard i + 8 <= data.endIndex else { return out }
                var bits: UInt64 = 0
                for b in 0 ..< 8 { bits |= UInt64(data[i + b]) << (8 * b) }
                out[field, default: []].append(Double(bitPattern: bits))
                i += 8
            case 2:
                let (len64, n) = protoVarint(data, i)
                guard let len64, n > 0 else { return out }
                i += n
                let len = Int(len64)
                guard i + len <= data.endIndex else { return out }
                out[field, default: []].append(data.subdata(in: i ..< (i + len)))
                i += len
            case 5:
                guard i + 4 <= data.endIndex else { return out }
                var bits: UInt32 = 0
                for b in 0 ..< 4 { bits |= UInt32(data[i + b]) << (8 * b) }
                out[field, default: []].append(Double(Float(bitPattern: bits)))
                i += 4
            default:
                return out
            }
        }
        return out
    }

    private static func protoVarint(_ data: Data, _ start: Data.Index) -> (UInt64?, Int) {
        var value: UInt64 = 0
        var shift = 0
        var i = start
        while i < data.endIndex, shift < 64 {
            let byte = data[i]
            value |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 { return (value, i - start) }
            shift += 7
        }
        return (nil, 0)
    }

    private static func protoFloat(_ values: [Any]?) -> Double? {
        guard let first = values?.first else { return nil }
        if let d = first as? Double { return d }
        if let u = first as? UInt64 { return Double(u) }
        return nil
    }

    private static func protoInt(_ values: [Any]?) -> Int? {
        guard let first = values?.first else { return nil }
        if let u = first as? UInt64 { return Int(u) }
        if let d = first as? Double { return Int(d) }
        return nil
    }

    private static func get(_ url: String, token: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("QuotaBar/1.8", forHTTPHeaderField: "User-Agent")
        let (data, res) = try await URLSession.shared.data(for: req)
        return try decode(data, res)
    }

    private static func getChatGPTUsage(_ auth: CodexAuth) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(auth.access)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("QuotaBar/1.8", forHTTPHeaderField: "User-Agent")
        if !auth.accountId.isEmpty {
            req.setValue(auth.accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        let (data, res) = try await URLSession.shared.data(for: req)
        do {
            return try decode(data, res)
        } catch AuthError.http(let code) where code == 404 || code == 400 {
            var alt = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/usage")!)
            alt.httpMethod = "GET"
            alt.timeoutInterval = timeout
            alt.setValue("Bearer \(auth.access)", forHTTPHeaderField: "Authorization")
            alt.setValue("application/json", forHTTPHeaderField: "Accept")
            alt.setValue("QuotaBar/1.8", forHTTPHeaderField: "User-Agent")
            if !auth.accountId.isEmpty {
                alt.setValue(auth.accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
            }
            let (data2, res2) = try await URLSession.shared.data(for: alt)
            return try decode(data2, res2)
        }
    }

    private static func refreshCodex(_ auth: CodexAuth) async -> CodexRefresh {
        guard auth.canRefresh else { return .failed("missing refresh_token") }
        var req = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: String] = [
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "grant_type": "refresh_token",
            "refresh_token": auth.refresh,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, res) = try await URLSession.shared.data(for: req)
            let code = (res as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            if code != 200 {
                let snippet = text.replacingOccurrences(of: "\n", with: " ")
                let clipped = snippet.count > 140 ? String(snippet.prefix(140)) : snippet
                return .failed("token HTTP \(code)\(clipped.isEmpty ? "" : " \(clipped)")")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String, !access.isEmpty
            else { return .failed("token 200 but no access_token") }
            let refresh = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? auth.refresh
            let expires = TokenReader.jwtExpiry(access)
                ?? Date().addingTimeInterval(((obj["expires_in"] as? NSNumber)?.doubleValue) ?? 3600)
            return .ok(CodexAuth(access: access, refresh: refresh, accountId: auth.accountId, expiresAt: expires))
        } catch {
            return .failed("token request \(error.localizedDescription)")
        }
    }

    private static func getClaudeUsage(_ auth: ClaudeAuth) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(auth.access)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("QuotaBar/1.8", forHTTPHeaderField: "User-Agent")
        let (data, res) = try await URLSession.shared.data(for: req)
        return try decode(data, res)
    }

    private static func refreshClaude(_ auth: ClaudeAuth) async -> ClaudeRefresh {
        guard auth.canRefresh else { return .failed("missing refresh_token") }
        var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("anthropic", forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": auth.refresh,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, res) = try await URLSession.shared.data(for: req)
            let code = (res as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            if code != 200 {
                // Fallback older path used by some CLI builds.
                if code == 404 || code == 405 {
                    return await refreshClaudeAlt(auth)
                }
                let snippet = text.replacingOccurrences(of: "\n", with: " ")
                let clipped = snippet.count > 140 ? String(snippet.prefix(140)) : snippet
                return .failed("token HTTP \(code)\(clipped.isEmpty ? "" : " \(clipped)")")
            }
            return parseClaudeToken(data, fallback: auth)
        } catch {
            return .failed("token request \(error.localizedDescription)")
        }
    }

    private static func refreshClaudeAlt(_ auth: ClaudeAuth) async -> ClaudeRefresh {
        var req = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": auth.refresh,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, res) = try await URLSession.shared.data(for: req)
            let code = (res as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                let text = String(data: data, encoding: .utf8) ?? ""
                let snippet = text.replacingOccurrences(of: "\n", with: " ")
                let clipped = snippet.count > 140 ? String(snippet.prefix(140)) : snippet
                return .failed("token HTTP \(code)\(clipped.isEmpty ? "" : " \(clipped)")")
            }
            return parseClaudeToken(data, fallback: auth)
        } catch {
            return .failed("token request \(error.localizedDescription)")
        }
    }

    private static func parseClaudeToken(_ data: Data, fallback: ClaudeAuth) -> ClaudeRefresh {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, !access.isEmpty
        else { return .failed("token 200 but no access_token") }
        let refresh = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback.refresh
        let expires = Date().addingTimeInterval(((obj["expires_in"] as? NSNumber)?.doubleValue) ?? 3600)
        return .ok(ClaudeAuth(
            access: access,
            refresh: refresh,
            expiresAt: expires,
            subscription: fallback.subscription,
            tier: fallback.tier
        ))
    }

    private static func decode(_ data: Data, _ res: URLResponse) throws -> [String: Any] {
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        if !(200 ..< 300).contains(code) { throw AuthError.http(code) }
        let obj = try JSONSerialization.jsonObject(with: data)
        if let dict = obj as? [String: Any] {
            if dict["config"] != nil || dict["creditUsagePercent"] != nil || dict["currentPeriod"] != nil {
                return dict
            }
            if let inner = dict["data"] as? [String: Any] { return inner }
            if let inner = dict["result"] as? [String: Any] { return inner }
            return dict
        }
        if let list = obj as? [Any], let first = list.first as? [String: Any] { return first }
        throw AuthError.bad
    }

    private static func formBody(_ pairs: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/")
        return pairs
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func refreshGrokOIDC(_ rec: GrokAuth) async -> RefreshResult {
        guard rec.canRefresh else { return .failed("missing refresh_token or oidc_client_id") }
        var req = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/token")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": rec.refresh,
            "client_id": rec.clientId,
        ])
        do {
            let (data, res) = try await GrokNet.data(for: req)
            let code = (res as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            if code != 200 {
                let snippet = text.replacingOccurrences(of: "\n", with: " ")
                let clipped = snippet.count > 140 ? String(snippet.prefix(140)) : snippet
                return .failed("token HTTP \(code)\(clipped.isEmpty ? "" : " \(clipped)")")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String, !access.isEmpty
            else { return .failed("token 200 but no access_token") }
            let refresh = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? rec.refresh
            let expires: Date
            if let seconds = obj["expires_in"] as? NSNumber {
                expires = Date().addingTimeInterval(seconds.doubleValue)
            } else {
                expires = Date().addingTimeInterval(50 * 60)
            }
            return .ok(GrokAuth(access: access, refresh: refresh, clientId: rec.clientId, expiresAt: expires))
        } catch {
            return .failed("token request \(error.localizedDescription)")
        }
    }

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let n = Double(s) { return n }
        return nil
    }

    private static func resetLabel(_ value: Any?) -> String? {
        let date: Date?
        if let n = value as? NSNumber {
            let v = n.doubleValue
            date = v > 1e12 ? Date(timeIntervalSince1970: v / 1000) : v > 1e9 ? Date(timeIntervalSince1970: v) : nil
        } else if let s = value as? String {
            if let n = Double(s), s.count >= 10, s.allSatisfy(\.isNumber) {
                date = s.count >= 13 ? Date(timeIntervalSince1970: n / 1000) : Date(timeIntervalSince1970: n)
            } else {
                date = ISO8601DateFormatter().date(from: s)
                    ?? {
                        let f = ISO8601DateFormatter()
                        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        return f.date(from: s)
                    }()
            }
        } else {
            date = nil
        }
        guard let date else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return "resets \(f.string(from: date))"
    }

    private static func parseCursor(_ json: [String: Any]) -> Lane? {
        guard let plan = json["planUsage"] as? [String: Any] else { return nil }
        let used: Double?
        if let t = num(plan["totalPercentUsed"]) {
            used = t
        } else if let remaining = num(plan["remaining"]), let limit = num(plan["limit"]), limit > 0 {
            used = ((limit - remaining) / limit) * 100
        } else {
            used = nil
        }
        guard let used else { return nil }
        let details = [
            LaneDetail(label: "Cursor Models", usedPct: num(plan["autoPercentUsed"]) ?? 0),
            LaneDetail(label: "Other Models", usedPct: num(plan["apiPercentUsed"]) ?? 0),
        ]
        var bits: [String] = []
        if let msg = json["displayMessage"] as? String { bits.append(msg.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
        if let r = resetLabel(json["billingCycleEnd"]) { bits.append(r) }
        return .used(.cursor, percent: used, sub: bits.joined(separator: "  ·  "), details: details)
    }

    private static func parseGrok(_ json: [String: Any]) -> Lane? {
        let root = json["config"] as? [String: Any] ?? json
        let period = root["currentPeriod"] as? [String: Any]
        let names: [String: String] = [
            "GrokChat": "Chat",
            "GrokAppBuilder": "Builder",
            "GrokBuild": "Builder",
            "GrokImagine": "Imagine",
            "GrokVoice": "Voice",
            "GrokAPI": "API",
        ]
        var details: [LaneDetail] = []
        if let products = (period?["productUsage"] ?? root["productUsage"] ?? json["productUsage"]) as? [[String: Any]] {
            for item in products {
                guard let product = item["product"] as? String else { continue }
                details.append(LaneDetail(label: names[product] ?? product, usedPct: num(item["usagePercent"]) ?? 0))
            }
        }
        guard let used = pickGrokUsed(config: root, period: period, root: json, details: details) else {
            if period != nil || root["config"] != nil || json["config"] != nil {
                return .used(.grok, percent: 0, sub: bitsJoined(json, period, root, extra: details), details: details)
            }
            return nil
        }
        return .used(.grok, percent: used, sub: bitsJoined(json, period, root, extra: details), details: details)
    }

    private static func bitsJoined(_ json: [String: Any], _ period: [String: Any]?, _ root: [String: Any], extra: [LaneDetail]) -> String {
        var bits = ["Weekly SuperGrok Heavy Limit"]
        if let r = resetLabel(
            period?["end"]
                ?? root["end"]
                ?? json["end"]
                ?? root["billingPeriodEnd"]
                ?? json["billingPeriodEnd"]
        ) { bits.append(r) }
        return bits.joined(separator: "  ·  ")
    }

    /// config.creditUsagePercent == 0 must not hide currentPeriod / productUsage.
    /// Newer payloads use { val: cents } money objects instead of a percent.
    private static func pickGrokUsed(
        config: [String: Any],
        period: [String: Any]?,
        root: [String: Any],
        details: [LaneDetail]
    ) -> Double? {
        let periodUsed = num(period?["creditUsagePercent"]) ?? num(period?["usagePercent"])
        let configUsed = num(config["creditUsagePercent"])
        let rootUsed = num(root["creditUsagePercent"])
        let productSum = details.map(\.usedPct).reduce(0, +)
        let productMax = details.map(\.usedPct).max() ?? 0
        let moneyPct = moneyPercent(config) ?? moneyPercent(root) ?? moneyPercent(period ?? [:])
        let onDemandPct = onDemandPercent(config) ?? onDemandPercent(root)

        // Weekly pool (Settings → Usage) lives on currentPeriod / product mix.
        // Bare config.creditUsagePercent is often the API-credit meter (0).
        if let periodUsed { return periodUsed }
        if productSum > 0, productSum <= 100 { return productSum }
        if productMax > 0 { return productMax }
        if let configUsed, configUsed > 0 { return configUsed }
        if let rootUsed, rootUsed > 0 { return rootUsed }
        if let moneyPct, moneyPct > 0 { return moneyPct }
        if let onDemandPct, onDemandPct > 0 { return onDemandPct }
        if period != nil || !details.isEmpty {
            return periodUsed ?? 0
        }
        return nil
    }

    private static func moneyVal(_ value: Any?) -> Double? {
        if let n = num(value) { return n }
        if let dict = value as? [String: Any] {
            return num(dict["val"]) ?? num(dict["value"]) ?? num(dict["amount"])
        }
        return nil
    }

    private static func moneyPercent(_ bag: [String: Any]) -> Double? {
        let used = moneyVal(bag["used"]) ?? moneyVal(bag["creditUsed"])
        let cap = moneyVal(bag["monthlyLimit"]) ?? moneyVal(bag["limit"]) ?? moneyVal(bag["creditLimit"])
        guard let used, let cap, cap > 0 else { return nil }
        return min(100, max(0, used / cap * 100))
    }

    private static func onDemandPercent(_ bag: [String: Any]) -> Double? {
        let used = moneyVal(bag["onDemandUsed"])
        let cap = moneyVal(bag["onDemandCap"])
        guard let used, let cap, cap > 0 else { return nil }
        return min(100, max(0, used / cap * 100))
    }

    private static func parseSand(_ json: [String: Any]) -> Lane? {
        guard let used = num(json["usagePercent"]) else { return nil }
        var bits = ["Sand weekly usage"]
        if let r = resetLabel(json["nextResetTimestampUtc"]) { bits.append(r) }
        return .used(.bot, percent: used, sub: bits.joined(separator: "  ·  "))
    }

    private static func parseChatGPT(_ json: [String: Any]) -> Lane? {
        let rate = json["rate_limit"] as? [String: Any]
            ?? json["rate_limits"] as? [String: Any]
            ?? json
        let primary = windowDict(rate["primary_window"] ?? rate["primary"])
        let secondary = windowDict(rate["secondary_window"] ?? rate["secondary"])
        let primaryUsed = num(primary?["used_percent"]) ?? num(json["used_percent"])
        let weeklyUsed = num(secondary?["used_percent"])
        guard primaryUsed != nil || weeklyUsed != nil else { return nil }

        let used = max(primaryUsed ?? 0, weeklyUsed ?? 0)
        let plan = (json["plan_type"] as? String)
            ?? (json["plan"] as? String)
            ?? (rate["plan_type"] as? String)
            ?? "ChatGPT"
        var credits: Double?
        if let bag = json["credits"] as? [String: Any] {
            credits = num(bag["balance"]) ?? num(bag["available_count"])
        } else {
            credits = num(json["credits"])
        }

        var details: [LaneDetail] = []
        if let primaryUsed {
            details.append(LaneDetail(label: windowName(primary, fallback: "5h"), usedPct: primaryUsed))
        }
        if let weeklyUsed {
            details.append(LaneDetail(label: windowName(secondary, fallback: "Weekly"), usedPct: weeklyUsed))
        }

        var bits: [String] = [plan.replacingOccurrences(of: "_", with: " ")]
        if let credits { bits.append("\(Int(credits)) credits") }
        if let r = resetLabel(primary?["reset_at"] ?? secondary?["reset_at"] ?? primary?["resets_at"]) {
            bits.append(r)
        }
        return .used(.gpt, percent: used, sub: bits.joined(separator: "  ·  "), details: details)
    }

    private static func windowDict(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func windowName(_ window: [String: Any]?, fallback: String) -> String {
        guard let secs = num(window?["limit_window_seconds"]) ?? num(window?["window_minutes"]).map({ $0 * 60 }) else {
            return fallback
        }
        if secs <= 6 * 3600 { return "5h" }
        if secs <= 2 * 24 * 3600 { return "Daily" }
        return "Weekly"
    }

    private static func parseClaude(_ json: [String: Any], auth: ClaudeAuth) -> Lane? {
        let fiveUsed = utilizationValue(json["five_hour"] ?? json["fiveHour"] ?? json["five_hour_utilization"])
        let sevenUsed = utilizationValue(json["seven_day"] ?? json["sevenDay"] ?? json["seven_day_utilization"])
        let sonnetUsed = utilizationValue(json["seven_day_sonnet"] ?? json["sevenDaySonnet"])
        let five = windowDict(json["five_hour"] ?? json["fiveHour"])
        let seven = windowDict(json["seven_day"] ?? json["sevenDay"])
        guard fiveUsed != nil || sevenUsed != nil else { return nil }

        let used = max(fiveUsed ?? 0, sevenUsed ?? 0)
        var details: [LaneDetail] = []
        if let fiveUsed { details.append(LaneDetail(label: "5h", usedPct: fiveUsed)) }
        if let sevenUsed { details.append(LaneDetail(label: "7d", usedPct: sevenUsed)) }
        if let sonnetUsed { details.append(LaneDetail(label: "Sonnet 7d", usedPct: sonnetUsed)) }

        var plan = auth.subscription
        if plan.isEmpty { plan = (json["subscription_type"] as? String) ?? (json["plan"] as? String) ?? "Claude Code" }
        if !auth.tier.isEmpty, !plan.lowercased().contains(auth.tier.lowercased()) {
            plan = "\(plan) \(auth.tier)".trimmingCharacters(in: .whitespaces)
        }
        plan = plan.replacingOccurrences(of: "_", with: " ")

        var bits: [String] = [plan]
        if let r = resetLabel(five?["resets_at"] ?? five?["reset_at"] ?? seven?["resets_at"] ?? seven?["reset_at"]) {
            bits.append(r)
        }
        return .used(.claude, percent: used, sub: bits.joined(separator: "  ·  "), details: details)
    }

    /// Claude returns 0–1. Some builds send 0–100. Treat ≤1.5 as a fraction.
    private static func utilizationValue(_ value: Any?) -> Double? {
        if let dict = value as? [String: Any] {
            if let n = num(dict["utilization"]) ?? num(dict["used_percent"]) ?? num(dict["usedPercent"]) {
                return n <= 1.5 ? n * 100 : n
            }
        }
        if let n = num(value) {
            return n <= 1.5 ? n * 100 : n
        }
        return nil
    }
}
