import Foundation

/// This Mini cannot reach grok.com direct (`--noproxy` timed out).
/// Clash on the system proxy (HTTP/SOCKS 127.0.0.1:7897) can — 401
/// without a token, 200 with one. Grok therefore uses curl *with*
/// the system proxy. Token stays in a 0600 config file, not argv.
enum GrokNet {
    enum TransportError: LocalizedError {
        case curl(String)
        var errorDescription: String? {
            switch self {
            case .curl(let s): s
            }
        }
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await Task.detached(priority: .userInitiated) {
            try runCurl(request)
        }.value
    }

    private static func systemProxyURL() -> String? {
        guard let raw = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as NSDictionary? else {
            return nil
        }
        func on(_ enableKey: String, _ hostKey: String, _ portKey: String, scheme: String) -> String? {
            let enabled: Bool
            if let b = raw[enableKey] as? Bool { enabled = b }
            else if let n = raw[enableKey] as? NSNumber { enabled = n.boolValue }
            else { enabled = false }
            guard enabled, let host = raw[hostKey] as? String, !host.isEmpty else { return nil }
            let port: Int
            if let n = raw[portKey] as? NSNumber { port = n.intValue }
            else if let i = raw[portKey] as? Int { port = i }
            else { return nil }
            guard port > 0 else { return nil }
            return "\(scheme)://\(host):\(port)"
        }
        return on("HTTPSEnable", "HTTPSProxy", "HTTPSPort", scheme: "http")
            ?? on("HTTPEnable", "HTTPProxy", "HTTPPort", scheme: "http")
            ?? on("SOCKSEnable", "SOCKSProxy", "SOCKSPort", scheme: "socks5h")
    }

    private static func runCurl(_ request: URLRequest) throws -> (Data, URLResponse) {
        guard let url = request.url else { throw TransportError.curl("missing url") }
        let curlPath = "/usr/bin/curl"
        guard FileManager.default.isExecutableFile(atPath: curlPath) else {
            throw TransportError.curl("curl missing")
        }

        var trash: [URL] = []
        defer {
            for item in trash { try? FileManager.default.removeItem(at: item) }
        }

        let tmp = FileManager.default.temporaryDirectory
        var cfg = """
        silent
        show-error
        compressed
        location
        http1.1
        max-time = "15"
        connect-timeout = "8"
        url = "\(escape(url.absoluteString))"

        """
        if let proxy = systemProxyURL() {
            cfg += "proxy = \"\(escape(proxy))\"\n"
        }
        if let method = request.httpMethod, method.uppercased() != "GET" {
            cfg += "request = \"\(escape(method))\"\n"
        }
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            cfg += "header = \"\(escape("\(key): \(value)"))\"\n"
        }
        if let body = request.httpBody, !body.isEmpty {
            let bodyURL = tmp.appendingPathComponent("qb-grok-body-\(UUID().uuidString)")
            try body.write(to: bodyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bodyURL.path)
            trash.append(bodyURL)
            cfg += "data-binary = \"@\(escape(bodyURL.path))\"\n"
        }
        cfg += "write-out = \"\\n__QBHTTP__%{http_code}\"\n"

        let cfgURL = tmp.appendingPathComponent("qb-grok-cfg-\(UUID().uuidString)")
        try cfg.write(to: cfgURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cfgURL.path)
        trash.append(cfgURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: curlPath)
        proc.arguments = ["--config", cfgURL.path]
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()

        let raw = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = (String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let blob = String(data: raw, encoding: .utf8) ?? ""
        guard let sep = blob.range(of: "\n__QBHTTP__", options: .backwards)
                ?? blob.range(of: "__QBHTTP__", options: .backwards)
        else {
            throw TransportError.curl(short(err.isEmpty ? "no status" : err))
        }
        let bodyText = String(blob[..<sep.lowerBound])
        let code = Int(blob[sep.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if proc.terminationStatus != 0, code == 0 {
            throw TransportError.curl(short(err.isEmpty ? "exit \(proc.terminationStatus)" : err))
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) ?? URLResponse(
            url: url,
            mimeType: "application/json",
            expectedContentLength: bodyText.utf8.count,
            textEncodingName: "utf-8"
        )
        return (Data(bodyText.utf8), response)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func short(_ value: String) -> String {
        let one = value.replacingOccurrences(of: "\n", with: " ")
        return one.count > 72 ? String(one.prefix(72)) : one
    }
}

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
        let (data, res) = try await GrokNet.data(for: req)
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
            let (data, res) = try await GrokNet.data(for: req)
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
