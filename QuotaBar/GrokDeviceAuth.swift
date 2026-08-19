import Foundation

/// Clash on 127.0.0.1:7897 is the *system* proxy. URLSession
/// connectionProxyDictionary still inherited it (v1.8.9: CFNetwork
/// HTTP 500 via 7897). Grok uses /usr/bin/curl --noproxy '*' so
/// CFNetwork never sees the request. Token goes on curl stdin, not argv.
enum GrokNet {
    enum TransportError: LocalizedError {
        case curl(String)
        var errorDescription: String? {
            switch self {
            case .curl(let s): s
            }
        }
    }

    private static let lock = NSLock()
    private static var ipCache: [String: (ip: String, at: Date)] = [:]

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await Task.detached(priority: .userInitiated) {
            try runCurl(request)
        }.value
    }

    private static func runCurl(_ request: URLRequest) throws -> (Data, URLResponse) {
        guard let url = request.url, let host = url.host else {
            throw TransportError.curl("missing url")
        }
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
        ipv4
        noproxy = "*"
        max-time = "15"
        connect-timeout = "8"
        url = "\(escape(url.absoluteString))"

        """
        if let ip = pinnedIPv4(host) {
            let port = url.port ?? 443
            cfg += "resolve = \"\(host):\(port):\(ip)\"\n"
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

    /// Clash fake-ip makes --noproxy still hit 198.18.x. Pin a public A record
    /// via DoH to 1.1.1.1 (literal IP, no system DNS).
    private static func pinnedIPv4(_ host: String) -> String? {
        lock.lock()
        if let hit = ipCache[host], Date().timeIntervalSince(hit.at) < 300 {
            let ip = hit.ip
            lock.unlock()
            return ip
        }
        lock.unlock()
        let ip = dohA(host) ?? dohAGoogle(host)
        guard let ip else { return nil }
        lock.lock()
        ipCache[host] = (ip, Date())
        lock.unlock()
        return ip
    }

    private static func dohA(_ host: String) -> String? {
        rawCurlJSON(
            url: "https://1.1.1.1/dns-query?name=\(host)&type=A",
            extra: ["header = \"accept: application/dns-json\""]
        ).flatMap(firstA)
    }

    private static func dohAGoogle(_ host: String) -> String? {
        rawCurlJSON(url: "https://8.8.8.8/resolve?name=\(host)&type=A", extra: []).flatMap(firstA)
    }

    private static func firstA(_ obj: [String: Any]) -> String? {
        guard let answers = obj["Answer"] as? [[String: Any]] else { return nil }
        for item in answers {
            let type = (item["type"] as? NSNumber)?.intValue ?? 0
            guard type == 1, let data = item["data"] as? String else { continue }
            if data.split(separator: ".").count == 4, !data.hasPrefix("198.18.") { return data }
        }
        return nil
    }

    private static func rawCurlJSON(url: String, extra: [String]) -> [String: Any]? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-doh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var cfg = """
        silent
        show-error
        ipv4
        noproxy = "*"
        max-time = "5"
        connect-timeout = "4"
        url = "\(escape(url))"

        """
        for line in extra { cfg += line + "\n" }
        guard (try? cfg.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["--config", tmp.path]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
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
