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
        guard let auth = TokenReader.loadGrokAuth() else {
            if FileManager.default.fileExists(atPath: TokenReader.grokAuthURL().path) {
                return .error(.grok, message: "CLI 没落盘。auth.json 还是死会话。点 Sign in with Grok，由本 App 写回。")
            }
            return .error(.grok, message: "没有可用 Grok 会话。点 Sign in with Grok，不用跑 grok login。")
        }
        var access = auth.access
        var persistNote: String?
        if auth.canRefresh {
            switch await refreshGrokOIDC(auth) {
            case .ok(let next):
                persistNote = TokenReader.persist(next)
                access = next.access
            case .failed(let detail) where detail.contains("invalid_grant"):
                TokenReader.markRefreshDead(auth.refresh)
                if let live = TokenReader.discoverAlternateAuth(), !TokenReader.isDeadRefresh(live.refresh) {
                    if live.canRefresh {
                        switch await refreshGrokOIDC(live) {
                        case .ok(let next):
                            persistNote = TokenReader.persist(next)
                            access = next.access
                        case .failed(let second):
                            return .error(.grok, message: "Grok refresh invalid_grant; newer CLI session also failed: \(second)")
                        }
                    } else {
                        persistNote = TokenReader.persist(live)
                        access = live.access
                    }
                } else {
                    TokenReader.clearStaleAuthLock()
                    return .error(
                        .grok,
                        message: "CLI 没落盘。0.2.111 登录成功也不写 auth.json / Keychain（loginmint persist failed）。点 Sign in with Grok，由 QuotaBar 写回 key + expires_at。"
                    )
                }
            case .failed(let detail):
                return .error(.grok, message: "Grok refresh failed: \(detail)")
            }
        } else if access.isEmpty {
            return .empty(.grok, sub: "auth.json has no access or refresh_token")
        }

        do {
            let json = try await get("https://cli-chat-proxy.grok.com/v1/billing?format=credits", token: access)
            guard var lane = parseGrok(json) else {
                return .error(.grok, message: "Grok billing 200 but no weekly usage in currentPeriod/productUsage")
            }
            if let persistNote {
                lane.sub += "  ·  auth.json write failed: \(persistNote)"
            }
            return lane
        } catch AuthError.http(let code) where code == 401 || code == 403 {
            return .error(.grok, message: "Grok billing \(code) after \(auth.canRefresh ? "refresh" : "no refresh")")
        } catch AuthError.http(let code) {
            return .error(.grok, message: "Grok billing HTTP \(code)")
        } catch {
            return .error(.grok, message: "Grok billing request failed")
        }
    }

    private enum AuthError: Error { case http(Int), bad }

    private enum RefreshResult {
        case ok(GrokAuth)
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
        req.setValue("QuotaBar/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = Data("{}".utf8)
        let (data, res) = try await URLSession.shared.data(for: req)
        return try decode(data, res)
    }

    private static func get(_ url: String, token: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("QuotaBar/1.0", forHTTPHeaderField: "User-Agent")
        let (data, res) = try await URLSession.shared.data(for: req)
        return try decode(data, res)
    }

    private static func decode(_ data: Data, _ res: URLResponse) throws -> [String: Any] {
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        if !(200 ..< 300).contains(code) { throw AuthError.http(code) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AuthError.bad }
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
        let config = json["config"] as? [String: Any] ?? json
        let period = config["currentPeriod"] as? [String: Any]
        let names: [String: String] = [
            "GrokChat": "Chat",
            "GrokAppBuilder": "Builder",
            "GrokImagine": "Imagine",
            "GrokVoice": "Voice",
        ]
        var details: [LaneDetail] = []
        if let products = (period?["productUsage"] ?? config["productUsage"] ?? json["productUsage"]) as? [[String: Any]] {
            for item in products {
                guard let product = item["product"] as? String else { continue }
                details.append(LaneDetail(label: names[product] ?? product, usedPct: num(item["usagePercent"]) ?? 0))
            }
        }
        guard let used = pickGrokUsed(config: config, period: period, root: json, details: details) else {
            return nil
        }
        var bits = ["Weekly SuperGrok Heavy Limit"]
        if let r = resetLabel(
            period?["end"]
                ?? config["end"]
                ?? json["end"]
                ?? json["billingPeriodEnd"]
        ) { bits.append(r) }
        return .used(.grok, percent: used, sub: bits.joined(separator: "  ·  "), details: details)
    }

    /// config.creditUsagePercent == 0 must not hide currentPeriod / productUsage.
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

        if let periodUsed, periodUsed > 0 { return periodUsed }
        if let configUsed, configUsed > 0 { return configUsed }
        if let rootUsed, rootUsed > 0 { return rootUsed }
        if productSum > 0, productSum <= 100 { return productSum }
        if productMax > 0 { return productMax }
        if period != nil, let periodUsed { return periodUsed }
        if period != nil || !details.isEmpty {
            return periodUsed ?? configUsed ?? rootUsed ?? 0
        }
        return nil
    }

    private static func parseSand(_ json: [String: Any]) -> Lane? {
        guard let used = num(json["usagePercent"]) else { return nil }
        var bits = ["Sand weekly usage"]
        if let r = resetLabel(json["nextResetTimestampUtc"]) { bits.append(r) }
        return .used(.bot, percent: used, sub: bits.joined(separator: "  ·  "))
    }
}
