import Foundation

/// 0.2.111 device-auth prints "Signed in" but often never writes disk
/// (`loginmint persist failed; using unpersisted token`). There is no
/// macOS Keychain write in that binary. QuotaBar runs the same OIDC
/// device grant and writes ~/.grok/auth.json itself.
enum GrokDeviceAuth {
    static let clientId = "b1a00492-073a-47ea-816f-4c329264a828"
    static let issuer = "https://auth.x.ai"
    static let scope = "openid profile email offline_access grok-cli:access api:access"

    struct Pending: Sendable {
        var deviceCode: String
        var userCode: String
        var verifyURL: URL
        var interval: TimeInterval
        var expiresAt: Date
    }

    enum AuthError: LocalizedError {
        case start(String)
        case denied
        case expired
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .start(let s): s
            case .denied: "Device login was denied"
            case .expired: "Device login timed out"
            case .failed(let s): s
            }
        }
    }

    static func begin() async throws -> Pending {
        var req = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/device/code")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody([
            "client_id": clientId,
            "scope": scope,
        ])
        let (data, res) = try await URLSession.shared.data(for: req)
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = obj["device_code"] as? String,
              let user = obj["user_code"] as? String
        else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.start("device code HTTP \(code) \(text.prefix(120))")
        }
        let uri = (obj["verification_uri_complete"] as? String)
            ?? (obj["verification_uri"] as? String)
            ?? "https://auth.x.ai/device"
        let interval = (obj["interval"] as? NSNumber)?.doubleValue ?? 5
        let expires = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 600
        guard let url = URL(string: uri) else { throw AuthError.start("bad verification URL") }
        return Pending(
            deviceCode: device,
            userCode: user,
            verifyURL: url,
            interval: max(3, interval),
            expiresAt: Date().addingTimeInterval(expires)
        )
    }

    static func poll(_ pending: Pending) async throws -> GrokAuth {
        var wait = pending.interval
        while Date() < pending.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { throw AuthError.failed("cancelled") }
            var req = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/token")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = formBody([
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": pending.deviceCode,
                "client_id": clientId,
            ])
            let (data, res) = try await URLSession.shared.data(for: req)
            let status = (res as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if status == 200, let access = obj["access_token"] as? String, !access.isEmpty {
                let refresh = (obj["refresh_token"] as? String) ?? ""
                let ttl = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600
                return GrokAuth(
                    access: access,
                    refresh: refresh,
                    clientId: clientId,
                    expiresAt: Date().addingTimeInterval(ttl)
                )
            }
            let err = (obj["error"] as? String) ?? ""
            if err == "authorization_pending" { continue }
            if err == "slow_down" { wait += 5; continue }
            if err == "access_denied" { throw AuthError.denied }
            if err == "expired_token" { throw AuthError.expired }
            if !err.isEmpty { throw AuthError.failed(err) }
            throw AuthError.failed("token HTTP \(status)")
        }
        throw AuthError.expired
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
}
