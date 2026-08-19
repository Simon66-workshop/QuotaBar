import CryptoKit
import Foundation
import Security
import SQLite3

enum TokenReader {
    static func home() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func grokDir() -> URL {
        home().appendingPathComponent(".grok")
    }

    static func grokAuthURL() -> URL {
        grokDir().appendingPathComponent("auth.json")
    }

    static func grokCandidateFiles() -> [URL] {
        let h = home()
        return [
            grokAuthURL(),
            h.appendingPathComponent(".grok/user-settings.json"),
            h.appendingPathComponent(".config/grok/auth.json"),
            h.appendingPathComponent("Library/Application Support/Grok/auth.json"),
            h.appendingPathComponent("Library/Application Support/xAI/auth.json"),
        ]
    }

    static func loadGrokAuth() -> GrokAuth? {
        if UserDefaults.standard.bool(forKey: disconnectedKey) { return nil }
        clearStaleAuthLock()
        let disk = loadGrokAuthFromDisk()
        let saved = KeychainStore.loadAuth()

        if let d = disk, d.canRefresh, !isDeadRefresh(d.refresh) { return d }
        if let s = saved, s.canRefresh, !isDeadRefresh(s.refresh) { return s }
        if let alt = discoverAlternateAuth() { return alt }

        // Fall back to any still-usable access token (paste-only / no refresh).
        if let d = disk, !d.access.isEmpty, (d.refresh.isEmpty || !isDeadRefresh(d.refresh)) {
            return d
        }
        if let s = saved, !s.access.isEmpty, (s.refresh.isEmpty || !isDeadRefresh(s.refresh)) {
            return s
        }
        return nil
    }

    static func markRefreshDead(_ refresh: String) {
        invalidateGrokCache()
        guard !refresh.isEmpty else { return }
        UserDefaults.standard.set(fingerprint(refresh), forKey: deadKey)
    }

    static func clearDeadRefresh() {
        UserDefaults.standard.removeObject(forKey: deadKey)
    }

    static func isDeadRefresh(_ refresh: String) -> Bool {
        guard !refresh.isEmpty,
              let dead = UserDefaults.standard.string(forKey: deadKey)
        else { return false }
        return dead == fingerprint(refresh)
    }

    static func discoverAlternateAuth() -> GrokAuth? {
        clearStaleAuthLock()
        let disk = loadGrokAuthFromDisk()
        let dead = disk.map(\.refresh)
        var found: [GrokAuth] = []
        for url in alternateAuthFiles() {
            if let auth = extractRecord(from: url), auth.canRefresh {
                if let dead, fingerprint(auth.refresh) == fingerprint(dead) { continue }
                if isDeadRefresh(auth.refresh) { continue }
                found.append(auth)
            }
        }
        if let fromLogs = newestAuthFromLogs() {
            if !isDeadRefresh(fromLogs.refresh) { found.append(fromLogs) }
        }
        if let fromKey = newestAuthFromKeychain() {
            if !isDeadRefresh(fromKey.refresh) { found.append(fromKey) }
        }
        return found.max(by: { $0.expiresAt < $1.expiresAt })
    }

    static func grokCLIAccessToken() -> String? {
        loadGrokAuth()?.access
    }

    static func grokCLIAvailable() -> Bool {
        loadGrokAuth() != nil
    }

    static func persist(_ auth: GrokAuth) -> String? {
        invalidateGrokCache()
        UserDefaults.standard.set(false, forKey: disconnectedKey)
        KeychainStore.saveAuth(auth)
        do {
            try writeBackAuthFile(auth)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func savePasted(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let auth = firstRecord(in: obj)
        {
            persist(auth)
            return true
        }
        let token = scrub(trimmed)
        guard !token.isEmpty else { return false }
        persist(GrokAuth(access: token, refresh: "", clientId: "", expiresAt: .distantPast))
        return true
    }

    private static var grokDiskCache: (at: Date, value: GrokAuth?)?
    private static var codexCache: (at: Date, value: CodexAuth?)?
    private static var claudeCache: (at: Date, value: ClaudeAuth?)?
    private static var cursorTokCache: (at: Date, value: String?)?
    private static let cacheLock = NSLock()

    static func invalidateDiskCache() {
        cacheLock.lock()
        grokDiskCache = nil
        codexCache = nil
        claudeCache = nil
        cursorTokCache = nil
        cacheLock.unlock()
    }

    private static func invalidateGrokCache() {
        cacheLock.lock()
        grokDiskCache = nil
        cacheLock.unlock()
    }

    static func loadGrokAuthFromDisk() -> GrokAuth? {
        cacheLock.lock()
        if let cached = grokDiskCache, Date().timeIntervalSince(cached.at) < 20 {
            let value = cached.value
            cacheLock.unlock()
            return value
        }
        cacheLock.unlock()
        var found: [GrokAuth] = []
        for url in grokCandidateFiles() + grokDeepFiles() {
            if let auth = extractRecord(from: url) { found.append(auth) }
        }
        let value = found.first(where: { $0.canRefresh && !isDeadRefresh($0.refresh) }) ?? found.first
        cacheLock.lock()
        grokDiskCache = (Date(), value)
        cacheLock.unlock()
        return value
    }

    private static let deadKey = "qb.deadGrokRefresh.sha"
    private static let disconnectedKey = "qb.grokDisconnected"

    /// Explicit disconnect: drop our slot + keychain, ignore logs/alternates
    /// until the next persist / Sign in. Does not delete the rest of auth.json.
    static func disconnectGrokSession() {
        invalidateGrokCache()
        if let disk = loadGrokAuthFromDisk(), !disk.refresh.isEmpty {
            markRefreshDead(disk.refresh)
        }
        if let saved = KeychainStore.loadAuth(), !saved.refresh.isEmpty {
            markRefreshDead(saved.refresh)
        }
        removeWrittenSlot()
        KeychainStore.clearGrok()
        UserDefaults.standard.set(true, forKey: disconnectedKey)
        invalidateGrokCache()
    }

    private static func removeWrittenSlot() {
        let url = grokAuthURL()
        guard let data = try? Data(contentsOf: url),
              var bag = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let client = GrokDeviceAuth.clientId
        let drop = bag.keys.filter { key in
            if key.hasSuffix("::\(client)") { return true }
            guard let rec = bag[key] as? [String: Any] else { return false }
            return (rec["oidc_client_id"] as? String) == client
        }
        if drop.isEmpty { return }
        for key in drop { bag.removeValue(forKey: key) }
        guard let out = try? JSONSerialization.data(withJSONObject: bag, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? out.write(to: url, options: .atomic)
    }

    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func clearStaleAuthLock() {
        let url = grokDir().appendingPathComponent("auth.json.lock")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date
        else { return }
        if Date().timeIntervalSince(mtime) > 60 {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func alternateAuthFiles() -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        let roots = [
            grokDir().appendingPathComponent("auth"),
            grokDir().appendingPathComponent("credentials"),
            grokDir(),
        ]
        let names: Set<String> = [
            "auth.json", "credentials.json", "mcp_credentials.json",
            "session.json", "tokens.json", "oauth.json",
        ]
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            var hops = 0
            while let url = en.nextObject() as? URL {
                hops += 1
                if hops > 300 { break }
                let ext = url.pathExtension.lowercased()
                if names.contains(url.lastPathComponent) || ext == "json" {
                    if url.lastPathComponent == "auth.json" { continue }
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private static func newestAuthFromLogs() -> GrokAuth? {
        let fm = FileManager.default
        let roots = [
            grokDir().appendingPathComponent("logs"),
            grokDir().appendingPathComponent("debug"),
        ]
        var best: GrokAuth?
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            var hops = 0
            while let url = en.nextObject() as? URL {
                hops += 1
                if hops > 80 { break }
                guard let auth = extractAuthFromLog(url) else { continue }
                if best == nil || auth.expiresAt > best!.expiresAt { best = auth }
            }
        }
        return best
    }

    private static func extractAuthFromLog(_ url: URL) -> GrokAuth? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window = min(size, 1_500_000)
        try? handle.seek(toOffset: size - window)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        var best: GrokAuth?
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let raw = String(line)
            guard raw.contains("refresh_token"),
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let auth = firstRecord(in: obj), auth.canRefresh
            else { continue }
            best = auth
            break
        }
        return best
    }

    private static func newestAuthFromKeychain() -> GrokAuth? {
        let services = [
            "xai-grok-cli", "grok-cli", "xai-grok-shell", "xai.grok",
            "grok", "com.xai.grok", "xai-grok-auth",
        ]
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
            ]
            var out: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
                  let items = out as? [[String: Any]]
            else { continue }
            for item in items {
                guard let data = item[kSecValueData as String] as? Data else { continue }
                if let auth = try? JSONDecoder().decode(GrokAuth.self, from: data), auth.canRefresh {
                    return auth
                }
                if let obj = try? JSONSerialization.jsonObject(with: data),
                   let auth = firstRecord(in: obj), auth.canRefresh
                {
                    return auth
                }
            }
        }
        return nil
    }

    private static func grokDeepFiles() -> [URL] {
        let fm = FileManager.default
        let h = home()
        var found: [URL] = []
        let roots = [
            grokDir(),
            h.appendingPathComponent("Library/Application Support/Grok"),
            h.appendingPathComponent("Library/Application Support/xAI"),
        ]
        let names: Set<String> = ["auth.json", "credentials.json"]
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            var hops = 0
            while let url = en.nextObject() as? URL {
                hops += 1
                if hops > 200 { break }
                if names.contains(url.lastPathComponent) { found.append(url) }
            }
        }
        return found
    }

    private static func extractRecord(from url: URL) -> GrokAuth? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return firstRecord(in: obj)
    }

    static func firstRecord(in obj: Any, parentKey: String? = nil) -> GrokAuth? {
        var bag: [GrokAuth] = []
        collect(obj, parentKey: parentKey, into: &bag)
        return bag.first(where: \.canRefresh) ?? bag.first
    }

    private static func collect(_ obj: Any, parentKey: String?, into bag: inout [GrokAuth]) {
        if let rec = record(from: obj, parentKey: parentKey) { bag.append(rec) }
        if let dict = obj as? [String: Any] {
            for (key, value) in dict { collect(value, parentKey: key, into: &bag) }
        } else if let list = obj as? [Any] {
            for value in list { collect(value, parentKey: parentKey, into: &bag) }
        }
    }

    private static func record(from obj: Any, parentKey: String?) -> GrokAuth? {
        guard let dict = obj as? [String: Any] else { return nil }
        let accessKeys = ["key", "access_token", "accessToken"]
        var access: String?
        for k in accessKeys {
            if let s = dict[k] as? String, s.count >= 20 { access = s; break }
        }
        guard let access else { return nil }
        let refresh = (dict["refresh_token"] as? String) ?? (dict["refreshToken"] as? String) ?? ""
        var clientId = (dict["oidc_client_id"] as? String) ?? (dict["client_id"] as? String) ?? ""
        if clientId.isEmpty, let parentKey, parentKey.contains("::") {
            clientId = parentKey.split(separator: ":").last.map(String.init) ?? ""
        }
        let expiresAt = parseExpiry(dict["expires_at"] ?? dict["expiresAt"])
        return GrokAuth(access: access, refresh: refresh, clientId: clientId, expiresAt: expiresAt)
    }

    private static func parseExpiry(_ value: Any?) -> Date {
        if let n = value as? NSNumber {
            let v = n.doubleValue
            if v > 1e12 { return Date(timeIntervalSince1970: v / 1000) }
            if v > 1e9 { return Date(timeIntervalSince1970: v) }
        }
        if let s = value as? String {
            if let n = Double(s), s.count >= 10, s.allSatisfy({ $0.isNumber || $0 == "." }) {
                return s.count >= 13
                    ? Date(timeIntervalSince1970: n / 1000)
                    : Date(timeIntervalSince1970: n)
            }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? .distantPast
        }
        return .distantPast
    }

    private static func isoExpiry(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }

    private static func writeBackAuthFile(_ auth: GrokAuth) throws {
        let url = grokAuthURL()
        let fm = FileManager.default
        try fm.createDirectory(at: grokDir(), withIntermediateDirectories: true)

        var bag: [String: Any]
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "QuotaBar", code: 2, userInfo: [NSLocalizedDescriptionKey: "auth.json is not an object"])
            }
            bag = parsed
        } else {
            bag = [:]
        }

        let slot = bag.keys.first(where: { $0.hasSuffix("::\(auth.clientId)") })
            ?? bag.first(where: { _, value in
                guard let rec = value as? [String: Any] else { return false }
                return (rec["oidc_client_id"] as? String) == auth.clientId
            })?.key
            ?? bag.first(where: { _, value in
                (value as? [String: Any])?["refresh_token"] != nil
            })?.key
            ?? (auth.clientId.isEmpty ? "https://auth.x.ai" : "https://auth.x.ai::\(auth.clientId)")

        var rec = bag[slot] as? [String: Any] ?? [:]
        rec["key"] = auth.access
        if !auth.refresh.isEmpty { rec["refresh_token"] = auth.refresh }
        if !auth.clientId.isEmpty { rec["oidc_client_id"] = auth.clientId }
        rec["expires_at"] = isoExpiry(auth.expiresAt)
        bag[slot] = rec

        let out = try JSONSerialization.data(withJSONObject: bag, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)

        let check = try Data(contentsOf: url)
        guard let again = try JSONSerialization.jsonObject(with: check) as? [String: Any],
              let saved = again[slot] as? [String: Any],
              let writtenKey = saved["key"] as? String, writtenKey == auth.access,
              saved["expires_at"] != nil
        else {
            throw NSError(domain: "QuotaBar", code: 3, userInfo: [NSLocalizedDescriptionKey: "auth.json write verify failed"])
        }
    }

    static func cursorTokenFromLocalApp() -> String? {
        cacheLock.lock()
        if let cached = cursorTokCache, Date().timeIntervalSince(cached.at) < 20 {
            let value = cached.value
            cacheLock.unlock()
            return value
        }
        cacheLock.unlock()
        let support = home().appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")
        let value = readCursorDB(support.appendingPathComponent("state.vscdb")).map(scrub)
            ?? readCursorJSON(support.appendingPathComponent("storage.json")).map(scrub)
        cacheLock.lock()
        cursorTokCache = (Date(), value)
        cacheLock.unlock()
        return value
    }

    static func cursorAppPresent() -> Bool {
        FileManager.default.fileExists(
            atPath: home().appendingPathComponent("Library/Application Support/Cursor").path
        )
    }

    private static func readCursorDB(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        let sql = "SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken','cursorAuth/cachedAccessToken');"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        var access: String?
        var cached: String?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let val = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            if key.hasSuffix("accessToken") { access = val }
            if key.hasSuffix("cachedAccessToken") { cached = val }
        }
        return access ?? cached
    }

    private static func readCursorJSON(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let keys = ["cursorAuth/accessToken", "cursorAuth/cachedAccessToken"]
        for key in keys {
            if let s = obj[key] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    static func scrub(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let auth = firstRecord(in: obj) { return auth.access }
            for key in ["cursorToken", "access_token", "token", "accessToken", "key"] {
                if let inner = obj[key] as? String, !inner.isEmpty { return scrub(inner) }
            }
        }
        trimmed = trimmed.removingPercentEncoding ?? trimmed
        let prefixes = ["WorkosCursorSessionToken=", "WorkosCursorSessionToken", "Bearer ", "sso=", "sso-rw="]
        for p in prefixes where trimmed.lowercased().hasPrefix(p.lowercased()) {
            trimmed = String(trimmed.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        if let last = trimmed.split(separator: ":").last, trimmed.contains("::") {
            return String(last)
        }
        return trimmed
    }

    static func loadCodexAuth() -> CodexAuth? {
        cacheLock.lock()
        if let cached = codexCache, Date().timeIntervalSince(cached.at) < 20 {
            let value = cached.value
            cacheLock.unlock()
            return value
        }
        cacheLock.unlock()
        var found: CodexAuth?
        for url in codexCandidateFiles() {
            if let auth = extractCodex(from: url) { found = auth; break }
        }
        cacheLock.lock()
        codexCache = (Date(), found)
        cacheLock.unlock()
        return found
    }

    static func hasCodexSession() -> Bool {
        cacheLock.lock()
        if let cached = codexCache {
            let yes = cached.value != nil
            cacheLock.unlock()
            return yes
        }
        cacheLock.unlock()
        return codexCandidateFiles().contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func hasGrokSession() -> Bool {
        if FileManager.default.fileExists(atPath: grokAuthURL().path) { return true }
        if KeychainStore.loadAuth() != nil { return true }
        return false
    }

    static func hasClaudeSession() -> Bool {
        cacheLock.lock()
        if let cached = claudeCache {
            let yes = cached.value != nil
            cacheLock.unlock()
            return yes
        }
        cacheLock.unlock()
        if loadClaudeKeychainData() != nil { return true }
        return claudeCandidateFiles().contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func persistCodex(_ auth: CodexAuth) {
        cacheLock.lock()
        if let current = codexCache?.value, current.access == auth.access, current.refresh == auth.refresh {
            cacheLock.unlock()
            return
        }
        cacheLock.unlock()
        if let current = loadCodexAuth(), current.access == auth.access, current.refresh == auth.refresh {
            return
        }
        let url = home().appendingPathComponent(".codex/auth.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bag: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            bag = obj
        }
        var tokens = bag["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = auth.access
        if !auth.refresh.isEmpty { tokens["refresh_token"] = auth.refresh }
        if !auth.accountId.isEmpty { tokens["account_id"] = auth.accountId }
        bag["tokens"] = tokens
        bag["auth_mode"] = bag["auth_mode"] ?? "chatgpt"
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        bag["last_refresh"] = fmt.string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: bag, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        cacheLock.lock()
        codexCache = (Date(), auth)
        cacheLock.unlock()
    }

    static func saveCodexPasted(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let auth = extractCodex(from: obj)
        {
            persistCodex(auth)
            return true
        }
        let token = scrub(trimmed)
        guard token.count >= 20 else { return false }
        persistCodex(CodexAuth(access: token, refresh: "", accountId: "", expiresAt: jwtExpiry(token) ?? .distantPast))
        return true
    }

    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = 4 - b64.count % 4
        if pad < 4 { b64 += String(repeating: "=", count: pad) }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let n = obj["exp"] as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue)
        }
        if let s = obj["exp"] as? String, let n = Double(s) {
            return Date(timeIntervalSince1970: n)
        }
        return nil
    }

    private static func codexCandidateFiles() -> [URL] {
        let h = home()
        return [
            h.appendingPathComponent(".codex/auth.json"),
            h.appendingPathComponent(".config/codex/auth.json"),
            h.appendingPathComponent("Library/Application Support/Codex/auth.json"),
            h.appendingPathComponent("Library/Application Support/com.openai.codex/auth.json"),
        ]
    }

    private static func extractCodex(from url: URL) -> CodexAuth? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return extractCodex(from: obj)
    }

    private static func extractCodex(from obj: Any) -> CodexAuth? {
        guard let dict = obj as? [String: Any] else { return nil }
        let tokens = dict["tokens"] as? [String: Any] ?? dict
        let access = (tokens["access_token"] as? String)
            ?? (dict["access_token"] as? String)
            ?? (dict["OPENAI_API_KEY"] as? String)
            ?? ""
        guard !access.isEmpty, access.count >= 20 else { return nil }
        let refresh = (tokens["refresh_token"] as? String) ?? (dict["refresh_token"] as? String) ?? ""
        let account = (tokens["account_id"] as? String)
            ?? (dict["account_id"] as? String)
            ?? (dict["last_active_account_id"] as? String)
            ?? ((dict["account"] as? [String: Any])?["id"] as? String)
            ?? ""
        let exp = jwtExpiry(access) ?? .distantPast
        return CodexAuth(access: access, refresh: refresh, accountId: account, expiresAt: exp)
    }

    static func claudeDir() -> URL {
        home().appendingPathComponent(".claude")
    }

    static func loadClaudeAuth() -> ClaudeAuth? {
        cacheLock.lock()
        if let cached = claudeCache, Date().timeIntervalSince(cached.at) < 20 {
            let value = cached.value
            cacheLock.unlock()
            return value
        }
        cacheLock.unlock()
        var found: [ClaudeAuth] = []
        if let key = loadClaudeFromKeychain() { found.append(key) }
        for url in claudeCandidateFiles() {
            if let auth = extractClaude(from: url) { found.append(auth) }
        }
        let value = found.max(by: { $0.expiresAt < $1.expiresAt })
        cacheLock.lock()
        claudeCache = (Date(), value)
        cacheLock.unlock()
        return value
    }

    static func persistClaude(_ auth: ClaudeAuth) {
        cacheLock.lock()
        if let current = claudeCache?.value,
           current.access == auth.access,
           current.refresh == auth.refresh
        {
            cacheLock.unlock()
            return
        }
        cacheLock.unlock()
        if let current = loadClaudeAuth(),
           current.access == auth.access,
           current.refresh == auth.refresh
        {
            return
        }
        var bag = loadClaudeBag() ?? [:]
        var oauth = bag["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = auth.access
        if !auth.refresh.isEmpty { oauth["refreshToken"] = auth.refresh }
        oauth["expiresAt"] = Int64(auth.expiresAt.timeIntervalSince1970 * 1000)
        if !auth.subscription.isEmpty { oauth["subscriptionType"] = auth.subscription }
        if !auth.tier.isEmpty { oauth["rateLimitTier"] = auth.tier }
        bag["claudeAiOauth"] = oauth
        guard let data = try? JSONSerialization.data(withJSONObject: bag, options: [.prettyPrinted, .sortedKeys]) else { return }

        // Never invent ~/.claude/.credentials.json — Claude Code on macOS
        // treats the keychain as source of truth. Creating a stale file desyncs it.
        let url = claudeDir().appendingPathComponent(".credentials.json")
        if FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        }
        writeClaudeKeychain(data)
        cacheLock.lock()
        claudeCache = (Date(), auth)
        cacheLock.unlock()
    }

    static func saveClaudePasted(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let auth = extractClaude(from: obj)
        {
            persistClaude(auth)
            return true
        }
        let token = scrub(trimmed)
        guard token.count >= 20 else { return false }
        persistClaude(ClaudeAuth(
            access: token,
            refresh: "",
            expiresAt: jwtExpiry(token) ?? .distantPast,
            subscription: "",
            tier: ""
        ))
        return true
    }

    private static func claudeCandidateFiles() -> [URL] {
        let h = home()
        return [
            h.appendingPathComponent(".claude/.credentials.json"),
            h.appendingPathComponent(".config/claude/.credentials.json"),
            h.appendingPathComponent(".claude.json"),
            h.appendingPathComponent("Library/Application Support/Claude/.credentials.json"),
        ]
    }

    private static func loadClaudeBag() -> [String: Any]? {
        if let data = loadClaudeKeychainData(),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return obj
        }
        for url in claudeCandidateFiles() {
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                return obj
            }
        }
        return nil
    }

    private static func extractClaude(from url: URL) -> ClaudeAuth? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return extractClaude(from: obj)
    }

    private static func extractClaude(from obj: Any) -> ClaudeAuth? {
        guard let dict = obj as? [String: Any] else { return nil }
        let oauth = dict["claudeAiOauth"] as? [String: Any] ?? dict
        let access = (oauth["accessToken"] as? String)
            ?? (oauth["access_token"] as? String)
            ?? (dict["accessToken"] as? String)
            ?? ""
        guard !access.isEmpty, access.count >= 20 else { return nil }
        let refresh = (oauth["refreshToken"] as? String)
            ?? (oauth["refresh_token"] as? String)
            ?? (dict["refreshToken"] as? String)
            ?? ""
        let sub = (oauth["subscriptionType"] as? String) ?? (dict["subscriptionType"] as? String) ?? ""
        let tier = (oauth["rateLimitTier"] as? String) ?? (dict["rateLimitTier"] as? String) ?? ""
        let exp = parseClaudeExpiry(oauth["expiresAt"] ?? oauth["expires_at"] ?? dict["expiresAt"])
            ?? jwtExpiry(access)
            ?? .distantPast
        return ClaudeAuth(access: access, refresh: refresh, expiresAt: exp, subscription: sub, tier: tier)
    }

    private static func parseClaudeExpiry(_ value: Any?) -> Date? {
        if let n = value as? NSNumber {
            let v = n.doubleValue
            if v > 1e12 { return Date(timeIntervalSince1970: v / 1000) }
            if v > 1e9 { return Date(timeIntervalSince1970: v) }
        }
        if let s = value as? String, let n = Double(s) {
            if n > 1e12 { return Date(timeIntervalSince1970: n / 1000) }
            if n > 1e9 { return Date(timeIntervalSince1970: n) }
        }
        return nil
    }

    private static let claudeKeychainService = "Claude Code-credentials"

    private static func loadClaudeFromKeychain() -> ClaudeAuth? {
        guard let data = loadClaudeKeychainData(),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return extractClaude(from: obj)
    }

    private static func loadClaudeKeychainData() -> Data? {
        let accounts = [NSUserName(), NSUserName().lowercased(), ""]
        for account in accounts {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: claudeKeychainService,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if !account.isEmpty {
                query[kSecAttrAccount as String] = account
            }
            var out: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
               let data = out as? Data, !data.isEmpty
            {
                return data
            }
        }
        let all: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: AnyObject?
        if SecItemCopyMatching(all as CFDictionary, &out) == errSecSuccess,
           let items = out as? [Data]
        {
            return items.first
        }
        return nil
    }

    private static func writeClaudeKeychain(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeKeychainService,
            kSecAttrAccount as String: NSUserName(),
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

enum KeychainStore {
    private static let service = "app.quotabar.mac"
    private static let account = "grok-auth"

    static func saveAuth(_ auth: GrokAuth) {
        guard let data = try? JSONEncoder().encode(auth) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadAuth() -> GrokAuth? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return nil }
        if let auth = try? JSONDecoder().decode(GrokAuth.self, from: data) { return auth }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return GrokAuth(access: TokenReader.scrub(text), refresh: "", clientId: "", expiresAt: .distantPast)
        }
        return nil
    }

    static func saveGrok(_ value: String) {
        _ = TokenReader.savePasted(value)
    }

    static func loadGrok() -> String? {
        loadAuth()?.access
    }

    static func clearGrok() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
