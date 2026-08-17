import Foundation
import SQLite3

enum TokenReader {
    static func home() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func grokAuthURL() -> URL {
        home().appendingPathComponent(".grok/auth.json")
    }

    static func grokCLIAvailable() -> Bool {
        grokCLIAccessToken() != nil
    }

    static func grokCLIAccessToken() -> String? {
        guard let data = try? Data(contentsOf: grokAuthURL()),
              let bag = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for value in bag.values {
            guard let rec = value as? [String: Any], let key = rec["key"] as? String, !key.isEmpty else { continue }
            return key
        }
        return nil
    }

    static func grokCLIRecord() -> (access: String, refresh: String, clientId: String, expiresAt: Date)? {
        guard let data = try? Data(contentsOf: grokAuthURL()),
              let bag = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for value in bag.values {
            guard let rec = value as? [String: Any], let key = rec["key"] as? String, !key.isEmpty else { continue }
            let refresh = rec["refresh_token"] as? String ?? ""
            let clientId = rec["oidc_client_id"] as? String ?? ""
            var expires = Date.distantPast
            if let s = rec["expires_at"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                expires = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? .distantPast
            }
            return (key, refresh, clientId, expires)
        }
        return nil
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
