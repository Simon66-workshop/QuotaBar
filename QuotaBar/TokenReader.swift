import Foundation
import Security
import SQLite3

enum TokenReader {
    static func home() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func grokAuthURL() -> URL {
        grokCandidateFiles().first ?? home().appendingPathComponent(".grok/auth.json")
    }

    static func grokCandidateFiles() -> [URL] {
        let h = home()
        return [
            h.appendingPathComponent(".grok/auth.json"),
            h.appendingPathComponent(".grok/user-settings.json"),
            h.appendingPathComponent(".config/grok/auth.json"),
            h.appendingPathComponent("Library/Application Support/Grok/auth.json"),
            h.appendingPathComponent("Library/Application Support/xAI/auth.json"),
        ]
    }

    static func grokCLIAvailable() -> Bool {
        grokCLIAccessToken() != nil
    }

    static func grokCLIAccessToken() -> String? {
        if let fromFiles = grokTokenFromDisk() { return fromFiles }
        return KeychainStore.loadGrok()
    }

    static func grokTokenFromDisk() -> String? {
        for url in grokCandidateFiles() {
            if let token = extractAccess(from: url) { return token }
        }
        return nil
    }

    static func grokCLIRecord() -> (access: String, refresh: String, clientId: String, expiresAt: Date)? {
        for url in grokCandidateFiles() {
            if let rec = extractRecord(from: url) { return rec }
        }
        if let pasted = KeychainStore.loadGrok() {
            return (pasted, "", "", .distantPast)
        }
        return nil
    }

    private static func extractAccess(from url: URL) -> String? {
        extractRecord(from: url)?.access
    }

    private static func extractRecord(from url: URL) -> (access: String, refresh: String, clientId: String, expiresAt: Date)? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return firstRecord(in: obj)
    }

    private static func firstRecord(in obj: Any) -> (access: String, refresh: String, clientId: String, expiresAt: Date)? {
        if let rec = record(from: obj) { return rec }
        if let dict = obj as? [String: Any] {
            for value in dict.values {
                if let rec = firstRecord(in: value) { return rec }
            }
        }
        if let list = obj as? [Any] {
            for value in list {
                if let rec = firstRecord(in: value) { return rec }
            }
        }
        return nil
    }

    private static func record(from obj: Any) -> (access: String, refresh: String, clientId: String, expiresAt: Date)? {
        guard let dict = obj as? [String: Any] else { return nil }
        let accessKeys = ["key", "access_token", "accessToken", "apiKey", "api_key", "token"]
        var access: String?
        for k in accessKeys {
            if let s = dict[k] as? String, !s.isEmpty { access = s; break }
        }
        guard let access else { return nil }
        let refresh = (dict["refresh_token"] as? String) ?? (dict["refreshToken"] as? String) ?? ""
        let clientId = (dict["oidc_client_id"] as? String) ?? (dict["client_id"] as? String) ?? ""
        var expires = Date.distantPast
        if let s = dict["expires_at"] as? String ?? dict["expiresAt"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expires = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? .distantPast
        }
        return (access, refresh, clientId, expires)
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
    private static let account = "grok-access"

    static func saveGrok(_ value: String) {
        let data = Data(value.utf8)
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

    static func loadGrok() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return TokenReader.scrub(text)
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
