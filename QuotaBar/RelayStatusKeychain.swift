import Foundation
import Security

enum RelayStatusKeychain {
    private static let queue = DispatchQueue(label: "app.quotabar.mac.relay-status.keychain", qos: .utility)

    static func read() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try readLoginItem() })
            }
        }
    }

    private static func readLoginItem() throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db").path
        var login: SecKeychain?
        guard SecKeychainOpen(path, &login) == errSecSuccess, let login else {
            throw RelayIssue.keychainUnavailable
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.quotabar.mac.relay-status",
            kSecAttrAccount as String: "66workshop.cn/relay-status-v1",
            kSecMatchSearchList as String: [login],
            kSecUseDataProtectionKeychain as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        // The file-based login keychain does not honor LAContext's no-UI flag.
        // Temporarily suppress optional UI, restoring the previous setting
        // immediately after this synchronous Security call. ACL enforcement stays on.
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw RelayIssue.keychainUnavailable
        }
        let status: OSStatus
        var item: CFTypeRef?
        do {
            defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }

        if status == errSecItemNotFound { throw RelayIssue.notConfigured }
        guard status == errSecSuccess else { throw RelayIssue.keychainUnavailable }
        // The v1 secret is 32 bytes encoded without Base64URL padding.
        guard let data = item as? Data, data.count == 43,
              data.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                                (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let token = String(data: data, encoding: .ascii) else { throw RelayIssue.invalidCredential }
        return token
    }
}
