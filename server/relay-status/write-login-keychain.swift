import Darwin
import Foundation
import Security

// The provisioner sends exactly 43 bytes through an anonymous stdin pipe.
// Refuse terminals and files before reading anything; never emit the input.
var stdinInfo = stat()
guard CommandLine.arguments.count == 1,
      fstat(STDIN_FILENO, &stdinInfo) == 0,
      (stdinInfo.st_mode & S_IFMT) == S_IFIFO,
      let token = try? FileHandle.standardInput.read(upToCount: 44),
      token.count == 43,
      token.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                         (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
    exit(EXIT_FAILURE)
}

let path = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Keychains/login.keychain-db").path
var login: SecKeychain?
guard SecKeychainOpen(path, &login) == errSecSuccess, let login else {
    exit(EXIT_FAILURE)
}

let item: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "app.quotabar.mac.relay-status",
    kSecAttrAccount as String: "66workshop.cn/relay-status-v1",
    kSecUseDataProtectionKeychain as String: false
]
let password = [kSecValueData as String: token]
let added = SecItemAdd(item.merging(password) { _, new in new }
    .merging([kSecUseKeychain as String: login]) { _, new in new } as CFDictionary, nil)
if added == errSecDuplicateItem {
    let query = item.merging([kSecMatchSearchList as String: [login]]) { _, new in new }
    let updated = SecItemUpdate(query as CFDictionary, password as CFDictionary)
    exit(updated == errSecSuccess ? EXIT_SUCCESS : EXIT_FAILURE)
}
exit(added == errSecSuccess ? EXIT_SUCCESS : EXIT_FAILURE)
