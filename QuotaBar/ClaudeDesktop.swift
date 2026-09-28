import CommonCrypto
import Foundation
import SQLite3

/// Claude Desktop (Claude.app) session, read locally.
///
/// Settings → Usage is the claude.ai web session, not Claude Code oauth.
/// The app stores Chromium cookies under Application Support/Claude and the
/// AES key in the login keychain item "Claude Safe Storage". A second desktop
/// store, `config.json` `oauth:tokenCacheV2`, uses the same key. That token is
/// read-only: refreshing it would rotate the app's refresh token.
///
/// The keychain secret and cookie values stay in memory. Nothing here writes
/// them to a log, a status file, or the Claude Code credential store.
enum ClaudeDesktop {
    struct WebSession {
        var cookieHeader: String
        var orgHint: String?
    }

    enum Read {
        case missing
        case blocked(String)
        case web(WebSession)
        case oauth(ClaudeAuth)
    }

    private struct CookieRow {
        var host: String
        var name: String
        var value: String
        var encryptedHex: String
        var modified: Date
    }

    private static let lock = NSLock()
    private static var rowCache: (at: Date, rows: [CookieRow])?
    /// Derived AES key, kept for the process lifetime. Re-reading it every few
    /// minutes would re-prompt on "Allow" and push users toward "Always Allow",
    /// which trusts `/usr/bin/security` for every process.
    private static var keyCache: Data?
    /// A denied or timed-out prompt is not retried by the timer. Only a
    /// user Refresh clears it, so a Deny cannot turn into a prompt loop.
    private static var keychainBackoff: String?

    private static var support: URL {
        TokenReader.home().appendingPathComponent("Library/Application Support/Claude")
    }

    /// File-only. Does not touch the keychain, so a refresh cannot raise a prompt
    /// just to decide whether Claude is connected.
    static func hasLocalMaterial() -> Bool {
        if !tokenCacheBlobs().isEmpty { return true }
        return cachedRows().contains { row in
            (row.name == "sessionKey" || row.name == "sessionKeyV3")
                && (!row.value.isEmpty || row.encryptedHex.count > 6)
        }
    }

    static func read() -> Read {
        let rows = cachedRows()
        let blobs = tokenCacheBlobs()
        let sessionRows = rows.filter { $0.name == "sessionKey" || $0.name == "sessionKeyV3" }
        if sessionRows.isEmpty && blobs.isEmpty { return .missing }

        let hasPlain = sessionRows.contains { looksLikeSession($0.value) }
        let hasEncrypted = sessionRows.contains { $0.encryptedHex.count > 6 && !looksLikeSession($0.value) }
        if hasPlain && !hasEncrypted && blobs.isEmpty {
            if let web = webSession(rows: rows, key: nil) { return .web(web) }
        }

        let key: Data
        switch encryptionKey() {
        case .key(let found):
            key = found
        case .blocked(let message):
            if let web = webSession(rows: rows, key: nil) { return .web(web) }
            return .blocked(message)
        }

        if let web = webSession(rows: rows, key: key) { return .web(web) }
        if let auth = oauthAuth(key: key) { return .oauth(auth) }
        if !sessionRows.isEmpty {
            return .blocked("Claude Desktop cookies did not contain a session. Open Claude while signed in, then Refresh.")
        }
        return .blocked("Claude Desktop token cache could not be read. Open Claude, then Refresh.")
    }

    /// Inference token from the desktop config cache, using the key already
    /// derived for the cookie read when that is still fresh. Refresh stays blank.
    static func loadOAuth() -> ClaudeAuth? {
        guard !tokenCacheBlobs().isEmpty else { return nil }
        switch encryptionKey() {
        case .key(let key):
            return oauthAuth(key: key)
        case .blocked:
            return nil
        }
    }

    static func prettyPlan(subscription: String, tier: String) -> String {
        let blob = (tier + " " + subscription).lowercased()
        if blob.contains("20x") { return "Max 20x" }
        if blob.contains("5x") { return "Max 5x" }
        if blob.contains("max") { return "Max" }
        if blob.contains("pro") { return "Pro" }
        let cleaned = subscription
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Claude" : cleaned
    }

    static func isOrganizationID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    // MARK: - Cookies

    private static func cachedRows() -> [CookieRow] {
        lock.lock()
        if let rowCache, Date().timeIntervalSince(rowCache.at) < 5 {
            let rows = rowCache.rows
            lock.unlock()
            return rows
        }
        lock.unlock()
        var rows: [CookieRow] = []
        for url in cookieDatabaseURLs() {
            rows.append(contentsOf: rowsFromDatabase(url))
        }
        lock.lock()
        rowCache = (Date(), rows)
        lock.unlock()
        return rows
    }

    private static func cookieDatabaseURLs() -> [URL] {
        var urls = [
            support.appendingPathComponent("Network/Cookies"),
            support.appendingPathComponent("Cookies"),
        ]
        let parts = support.appendingPathComponent("Partitions")
        if let children = try? FileManager.default.contentsOfDirectory(
            at: parts,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for child in children {
                urls.append(child.appendingPathComponent("Network/Cookies"))
                urls.append(child.appendingPathComponent("Cookies"))
            }
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func rowsFromDatabase(_ db: URL) -> [CookieRow] {
        if let rows = queryCookies(db) { return rows }
        guard let copy = copyDatabase(db) else { return [] }
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        return queryCookies(copy) ?? []
    }

    private static func queryCookies(_ db: URL) -> [CookieRow]? {
        guard FileManager.default.fileExists(atPath: db.path) else { return [] }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(db.path, &handle, flags, nil) == SQLITE_OK, let handle else { return nil }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 1500)
        let sql = """
        SELECT host_key, name, IFNULL(value, ''), IFNULL(hex(encrypted_value), '')
        FROM cookies
        WHERE name IN ('sessionKey', 'sessionKeyV3', 'lastActiveOrg')
        AND (host_key = 'claude.ai' OR host_key = '.claude.ai' OR host_key LIKE '%.claude.ai')
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        let modified = (try? db.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        var rows: [CookieRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(CookieRow(
                host: columnText(stmt, 0),
                name: columnText(stmt, 1),
                value: columnText(stmt, 2),
                encryptedHex: columnText(stmt, 3),
                modified: modified
            ))
        }
        return rows
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }

    private static func copyDatabase(_ db: URL) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-claude-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("Cookies")
            try FileManager.default.copyItem(at: db, to: dest)
            let folder = db.deletingLastPathComponent()
            let base = db.lastPathComponent
            for suffix in ["-wal", "-shm"] {
                let src = folder.appendingPathComponent(base + suffix)
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.copyItem(at: src, to: dir.appendingPathComponent("Cookies" + suffix))
                }
            }
            return dest
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    private static func webSession(rows: [CookieRow], key: Data?) -> WebSession? {
        func best(_ name: String) -> String? {
            let matches = rows.filter { $0.name == name }.sorted { lhs, rhs in
                let left = hostRank(lhs.host)
                let right = hostRank(rhs.host)
                if left != right { return left < right }
                return lhs.modified > rhs.modified
            }
            for row in matches {
                guard let text = reveal(row, key: key), headerSafe(text) else { continue }
                return text
            }
            return nil
        }
        var parts: [String] = []
        if let session = best("sessionKey") { parts.append("sessionKey=\(session)") }
        if let session = best("sessionKeyV3") { parts.append("sessionKeyV3=\(session)") }
        guard !parts.isEmpty else { return nil }
        let org = best("lastActiveOrg").map(cleanOrg).flatMap { isOrganizationID($0) ? $0 : nil }
        return WebSession(cookieHeader: parts.joined(separator: "; "), orgHint: org)
    }

    private static func reveal(_ row: CookieRow, key: Data?) -> String? {
        let plain = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if accepts(row.name, plain) { return plain }
        guard let key, !row.encryptedHex.isEmpty else { return nil }
        guard let text = decryptCookie(row.encryptedHex, key: key) else { return nil }
        return accepts(row.name, text) ? text : nil
    }

    private static func accepts(_ name: String, _ value: String) -> Bool {
        switch name {
        case "sessionKey", "sessionKeyV3":
            return looksLikeSession(value)
        case "lastActiveOrg":
            return isOrganizationID(cleanOrg(value))
        default:
            return false
        }
    }

    private static func looksLikeSession(_ value: String) -> Bool {
        value.hasPrefix("sk-ant-") && headerSafe(value)
    }

    private static func headerSafe(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return v >= 0x20 && v < 0x7f && scalar != ";" && scalar != ","
        }
    }

    private static func cleanOrg(_ raw: String) -> String {
        let decoded = raw.removingPercentEncoding ?? raw
        return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    private static func hostRank(_ host: String) -> Int {
        switch host {
        case "claude.ai": 0
        case ".claude.ai": 1
        default: 2
        }
    }

    // MARK: - Desktop oauth cache (read-only)

    private static func tokenCacheBlobs() -> [(slot: String, blob: String)] {
        let url = support.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return ["oauth:tokenCacheV2", "oauth:tokenCache"].compactMap { key in
            guard let value = obj[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (key, trimmed)
        }
    }

    private static func oauthAuth(key: Data) -> ClaudeAuth? {
        for (_, blob) in tokenCacheBlobs() {
            guard let plain = decryptSafeStorage(blob, key: key),
                  let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
            else { continue }
            var best: (exp: Date, auth: ClaudeAuth)?
            for (entryKey, raw) in obj {
                guard entryKey.contains("user:inference"), let entry = raw as? [String: Any] else { continue }
                let token = (entry["token"] as? String)
                    ?? (entry["accessToken"] as? String)
                    ?? (entry["access_token"] as? String)
                    ?? ""
                guard token.count >= 20, headerSafe(token) else { continue }
                let sub = (entry["subscriptionType"] as? String) ?? ""
                let tier = (entry["rateLimitTier"] as? String) ?? ""
                let exp = parseExpiry(entry["expiresAt"]) ?? .distantFuture
                let auth = ClaudeAuth(
                    access: token,
                    refresh: "",
                    expiresAt: exp,
                    subscription: prettyPlan(subscription: sub, tier: tier),
                    tier: ""
                )
                if best == nil || exp > best!.exp { best = (exp, auth) }
            }
            if let best { return best.auth }
        }
        return nil
    }

    private static func parseExpiry(_ value: Any?) -> Date? {
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

    // MARK: - Chromium safe storage

    private enum KeyMaterial {
        case key(Data)
        case blocked(String)
    }

    /// Called for a user-initiated Refresh so the next read may prompt again.
    static func allowKeychainRetry() {
        lock.lock()
        keychainBackoff = nil
        lock.unlock()
    }

    private static func encryptionKey() -> KeyMaterial {
        lock.lock()
        if let keyCache {
            lock.unlock()
            return .key(keyCache)
        }
        if let keychainBackoff {
            lock.unlock()
            return .blocked(keychainBackoff)
        }
        lock.unlock()
        let secret: Data
        switch keychainSecret() {
        case .secret(let found):
            secret = found
        case .timedOut:
            return backOff("Keychain prompt for Claude Safe Storage timed out. Click Refresh, then Allow.")
        case .denied:
            return backOff("QuotaBar was not allowed to read Claude Safe Storage. Click Refresh, then Allow.")
        case .missing:
            return .blocked("Claude Safe Storage is not in the login keychain. Open Claude once, then Refresh.")
        }
        guard let key = deriveKey(secret) else {
            return .blocked("Claude Desktop storage key could not be derived. Open Claude, then Refresh.")
        }
        lock.lock()
        keyCache = key
        lock.unlock()
        return .key(key)
    }

    private static func backOff(_ message: String) -> KeyMaterial {
        lock.lock()
        keychainBackoff = message
        lock.unlock()
        return .blocked(message)
    }

    private enum SecretRead {
        case secret(Data)
        case missing
        case denied
        case timedOut
    }

    /// `security -w` stdout is the Safe Storage password. It is not logged.
    /// One query only: a service match already covers every account, and a
    /// second query on the same item would raise a second prompt after Deny.
    private static func keychainSecret() -> SecretRead {
        runSecurity(["find-generic-password", "-s", "Claude Safe Storage", "-w"], timeout: 20)
    }

    private static func runSecurity(_ args: [String], timeout: TimeInterval) -> SecretRead {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = args
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do {
            try proc.run()
        } catch {
            return .missing
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return .timedOut
        }
        // 44 is errSecItemNotFound. Anything else (Deny, locked keychain) prompted or failed.
        if proc.terminationStatus == 44 { return .missing }
        guard proc.terminationStatus == 0 else { return .denied }
        var bytes = [UInt8](stdout.fileHandleForReading.readDataToEndOfFile())
        while let last = bytes.last, last == 10 || last == 13 { bytes.removeLast() }
        guard !bytes.isEmpty else { return .missing }
        return .secret(Data(bytes))
    }

    /// PBKDF2-HMAC-SHA1, salt "saltysalt", 1003 rounds, 16-byte AES key.
    /// The password is the keychain bytes themselves, including when they are not text.
    private static func deriveKey(_ password: Data) -> Data? {
        guard !password.isEmpty else { return nil }
        let passwordBytes = [UInt8](password)
        let saltBytes = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: 16)
        // Reading derived.count in the same call as &derived overlaps on Swift 6.3.
        let derivedCount = derived.count
        let status: Int32 = passwordBytes.withUnsafeBufferPointer { passwordBuf in
            saltBytes.withUnsafeBufferPointer { saltBuf in
                guard let passwordBase = passwordBuf.baseAddress, let saltBase = saltBuf.baseAddress else {
                    return Int32(-1)
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafePointer<Int8>(OpaquePointer(passwordBase)),
                    passwordBytes.count,
                    saltBase,
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    UInt32(1003),
                    &derived,
                    derivedCount
                )
            }
        }
        guard status == 0 else { return nil }
        return Data(derived)
    }

    private static func decryptCookie(_ hex: String, key: Data) -> String? {
        guard let raw = hexData(hex), raw.count > 3 else { return nil }
        guard String(data: raw.prefix(3), encoding: .utf8) == "v10" else { return nil }
        guard let plain = aesDecrypt(raw.dropFirst(3), key: key) else { return nil }
        return unwrapCookie(plain)
    }

    /// safeStorage blobs are base64("v10" + AES-128-CBC). No 32-byte cookie prefix.
    private static func decryptSafeStorage(_ b64: String, key: Data) -> Data? {
        let trimmed = b64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: trimmed), raw.count > 3 else { return nil }
        guard String(data: raw.prefix(3), encoding: .utf8) == "v10" else { return nil }
        return aesDecrypt(raw.dropFirst(3), key: key)
    }

    private static func aesDecrypt(_ ciphertext: Data.SubSequence, key: Data) -> Data? {
        let data = Data(ciphertext)
        guard key.count == kCCKeySizeAES128, !data.isEmpty, data.count % kCCBlockSizeAES128 == 0 else { return nil }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        // Reading out.count inside withUnsafeMutableBytes is an exclusivity error on Swift 6.3.
        let outCount = out.count
        var moved = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outRaw in
            data.withUnsafeBytes { dataRaw in
                key.withUnsafeBytes { keyRaw in
                    iv.withUnsafeBytes { ivRaw in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyRaw.baseAddress,
                            key.count,
                            ivRaw.baseAddress,
                            dataRaw.baseAddress,
                            data.count,
                            outRaw.baseAddress,
                            outCount,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, moved > 0, moved <= out.count else { return nil }
        return out.prefix(moved)
    }

    /// Chrome 130+ prepends 32 bytes to cookie plaintext. Older stores do not.
    /// A candidate that is a session key or an org id wins over a truncated tail.
    private static func unwrapCookie(_ plain: Data) -> String? {
        var candidates: [String] = []
        func add(_ slice: Data.SubSequence) {
            guard let text = String(data: Data(slice), encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
            guard !trimmed.isEmpty else { return }
            guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f }) else { return }
            if !candidates.contains(trimmed) { candidates.append(trimmed) }
        }
        if plain.count > 32 { add(plain.dropFirst(32)) }
        add(plain[...])
        if let start = plain.firstIndex(where: { $0 >= 0x20 && $0 <= 0x7e }) {
            add(plain[start...])
        }
        if let hit = candidates.first(where: { looksLikeSession($0) || isOrganizationID(cleanOrg($0)) }) {
            return hit
        }
        return candidates.first
    }

    private static func hexData(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count % 2 == 0, !bytes.isEmpty else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48 ... 57: c - 48
            case 65 ... 70: c - 55
            case 97 ... 102: c - 87
            default: nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i < bytes.count {
            guard let hi = nibble(bytes[i]), let lo = nibble(bytes[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return Data(out)
    }
}
