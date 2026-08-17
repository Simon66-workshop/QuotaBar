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
        } catch AuthError.expired {
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
        } catch AuthError.expired {
            return .error(.bot, message: "Session expired — same Cursor token")
        } catch {
            return .error(.bot, message: "Sand weekly quota not returned")
        }
    }

    static func fetchGrok(token: String) async -> Lane {
        if token.isEmpty { return .empty(.grok, sub: "Run  grok login  in Terminal, then Refresh") }
        do {
            var used = token
            var rec = TokenReader.grokCLIRecord()
            if let rec, rec.expiresAt < Date().addingTimeInterval(60), !rec.refresh.isEmpty {
                if let next = await refreshGrokOIDC(rec) { used = next }
            }
            let json = try await get("https://cli-chat-proxy.grok.com/v1/billing?format=credits", token: used)
            return parseGrok(json) ?? .error(.grok, message: "Weekly Heavy payload was incomplete")
        } catch AuthError.expired {
            if let rec = TokenReader.grokCLIRecord(), let next = await refreshGrokOIDC(rec) {
                if let json = try? await get("https://cli-chat-proxy.grok.com/v1/billing?format=credits", token: next) {
                    return parseGrok(json) ?? .error(.grok, message: "Weekly Heavy payload was incomplete")
                }
            }
            return .error(.grok, message: "Grok CLI session expired — sign in again")
        } catch {
            return .error(.grok, message: "Weekly Heavy quota not returned")
        }
    }

    private enum AuthError: Error { case expired, bad }

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
        if code == 401 || code == 403 { throw AuthError.expired }
        guard (200 ..< 300).contains(code),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AuthError.bad }
        return obj
    }

    private static func refreshGrokOIDC(_ rec: (access: String, refresh: String, clientId: String, expiresAt: Date)) async -> String? {
        guard !rec.refresh.isEmpty, !rec.clientId.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "grant_type=refresh_token&refresh_token=\(rec.refresh)&client_id=\(rec.clientId)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            .flatMap { Data($0.utf8) }
        guard let (data, res) = try? await URLSession.shared.data(for: req),
              (res as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String
        else { return nil }
        return access
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
        guard let used = num(config["creditUsagePercent"]) else { return nil }
        let names: [String: String] = [
            "GrokChat": "Chat",
            "GrokAppBuilder": "Builder",
            "GrokImagine": "Imagine",
            "GrokVoice": "Voice",
        ]
        var details: [LaneDetail] = []
        if let products = config["productUsage"] as? [[String: Any]] {
            for item in products {
                guard let product = item["product"] as? String else { continue }
                details.append(LaneDetail(label: names[product] ?? product, usedPct: num(item["usagePercent"]) ?? 0))
            }
        }
        var bits = ["Weekly SuperGrok Heavy Limit"]
        if let r = resetLabel(config["end"] ?? json["end"] ?? json["billingPeriodEnd"]) { bits.append(r) }
        return .used(.grok, percent: used, sub: bits.joined(separator: "  ·  "), details: details)
    }

    private static func parseSand(_ json: [String: Any]) -> Lane? {
        guard let used = num(json["usagePercent"]) else { return nil }
        var bits = ["Sand weekly usage"]
        if let r = resetLabel(json["nextResetTimestampUtc"]) { bits.append(r) }
        return .used(.bot, percent: used, sub: bits.joined(separator: "  ·  "))
    }
}
