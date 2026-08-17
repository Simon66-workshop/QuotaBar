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
        let disk = loadGrokAuthFromDisk()
        let saved = KeychainStore.loadAuth()
        if let d = disk, d.canRefresh { return d }
        if let s = saved, s.canRefresh { return s }
        return disk ?? saved
    }

    static func grokCLIAccessToken() -> String? {
        loadGrokAuth()?.access
    }

    static func grokCLIAvailable() -> Bool {
        loadGrokAuth() != nil
    }

    static func persist(_ auth: GrokAuth) -> String? {
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

    static func loadGrokAuthFromDisk() -> GrokAuth? {
        var found: [GrokAuth] = []
        for url in grokCandidateFiles() + grokDeepFiles() {
            if let auth = extractRecord(from: url) { found.append(auth) }
        }
        return found.first(where: \.canRefresh) ?? found.first
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
        let support = home().appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")
        if let fromDB = readCursorDB(support.appendingPathComponent("state.vscdb")) { return scrub(fromDB) }
        if let fromJSON = readCursorJSON(support.appendingPathComponent("storage.json")) { return scrub(fromJSON) }
        return nil
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
        let sql = "SELECT value FROM ItemTable WHERE key IN ('cursorAuth/accessToken','cursorAuth/cachedAccessToken') LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return nil
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
