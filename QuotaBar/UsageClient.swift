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

    static func fetchGrok(token ignored: String = "") async -> Lane {
        guard var auth = TokenReader.loadGrokAuth() else {
            if FileManager.default.fileExists(atPath: TokenReader.grokAuthURL().path) {
                return .error(.grok, message: "CLI 没落盘。auth.json 还是死会话。点 Sign in with Grok，由本 App 写回。")
            }
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
                            return .error(.grok, message: "Grok refresh invalid_grant; alternate also failed: \(second)")
                        }
                    } else {
                        persistNote = TokenReader.persist(live)
                        auth = live
                    }
                } else {
                    TokenReader.clearStaleAuthLock()
                    return .error(
                        .grok,
                        message: "CLI 没落盘。点 Sign in with Grok，由 QuotaBar 写回 key + expires_at。"
                    )
                }
            case .failed(let detail):
                persistNote = "refresh soft-fail: \(detail)"
            }
        } else if auth.access.isEmpty {
            return .empty(.grok, sub: "auth.json has no access or refresh_token")
        }

        do {
            let json = try await getGrokBilling(token: auth.access)
            if var lane = parseGrok(json) {
                if let persistNote, persistNote.contains("write failed") {
                    lane.sub += "  ·  auth.json write failed"
                }
                return lane
            }
            if let alt = try? await getGrokBilling(token: auth.access, credits: false),
               let lane = parseGrok(alt)
            {
                return lane
            }
            return .error(.grok, message: "billing 200 empty")
        } catch AuthError.http(let code) where code == 401 || code == 403 {
            if auth.canRefresh, !TokenReader.isDeadRefresh(auth.refresh) {
                switch await refreshGrokOIDC(auth) {
                case .ok(let next):
                    _ = TokenReader.persist(next)
                    if let json = try? await getGrokBilling(token: next.access),
                       let lane = parseGrok(json)
                    {
                        return lane
                    }
                case .failed(let detail) where detail.localizedCaseInsensitiveContains("invalid_grant"):
                    TokenReader.markRefreshDead(auth.refresh)
                    return .error(.grok, message: "billing \(code) · sign in again")
                case .failed:
                    break
                }
            }
            return .error(.grok, message: "billing \(code)")
        } catch AuthError.http(let code) {
            return .error(.grok, message: "billing HTTP \(code)")
        } catch {
            return .error(.grok, message: "billing request failed")
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

    private static func getGrokBilling(token: String, credits: Bool = true) async throws -> [String: Any] {
        let url = credits
            ? "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
            : "https://cli-chat-proxy.grok.com/v1/billing"
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("QuotaBar/1.8.6", forHTTPHeaderField: "User-Agent")
        let (data, res) = try await URLSession.shared.data(for: req)
        return try decode(data, res)
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
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AuthError.bad }
        if let inner = obj["data"] as? [String: Any] { return inner }
        if let inner = obj["result"] as? [String: Any] { return inner }
        return obj
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
            "GrokImagine": "Imagine",
            "GrokVoice": "Voice",
        ]
        var details: [LaneDetail] = []
        if let products = (period?["productUsage"] ?? root["productUsage"] ?? json["productUsage"]) as? [[String: Any]] {
            for item in products {
                guard let product = item["product"] as? String else { continue }
                details.append(LaneDetail(label: names[product] ?? product, usedPct: num(item["usagePercent"]) ?? 0))
            }
        }
        guard let used = pickGrokUsed(config: root, period: period, root: json, details: details) else {
            return nil
        }
        var bits = ["Weekly SuperGrok Heavy Limit"]
        if let r = resetLabel(
            period?["end"]
                ?? root["end"]
                ?? json["end"]
                ?? root["billingPeriodEnd"]
                ?? json["billingPeriodEnd"]
        ) { bits.append(r) }
        return .used(.grok, percent: used, sub: bits.joined(separator: "  ·  "), details: details)
    }

    /// config.creditUsagePercent == 0 must not hide currentPeriod / productUsage.
    /// Newer payloads use { val: cents } money objects instead of a percent.
    private static func pickGrokUsed(
        config: [String: Any],
        period: [String: Any]?,
        root: [String: Any],
        details: [LaneDetail]
    ) -> Double? {
        let periodUsed = num(period?["creditUsagePercent"])
        let configUsed = num(config["creditUsagePercent"])
        let rootUsed = num(root["creditUsagePercent"])
        let productSum = details.map(\.usedPct).reduce(0, +)
        let productMax = details.map(\.usedPct).max() ?? 0
        let moneyPct = moneyPercent(config) ?? moneyPercent(root) ?? moneyPercent(period ?? [:])
        let onDemandPct = onDemandPercent(config) ?? onDemandPercent(root)

        if let periodUsed, periodUsed > 0 { return periodUsed }
        if let configUsed, configUsed > 0 { return configUsed }
        if let rootUsed, rootUsed > 0 { return rootUsed }
        if let moneyPct, moneyPct > 0 { return moneyPct }
        if let onDemandPct, onDemandPct > 0 { return onDemandPct }
        if productSum > 0, productSum <= 100 { return productSum }
        if productMax > 0 { return productMax }
        if period != nil, let periodUsed { return periodUsed }
        if period != nil || !details.isEmpty || moneyPct != nil || onDemandPct != nil {
            return periodUsed ?? configUsed ?? rootUsed ?? moneyPct ?? onDemandPct ?? 0
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
