import Foundation
import Security

enum RelayStatusHelper {
    static let argument = "--relay-status-helper"

    private enum Reply: Codable {
        case snapshot(RelayStatusClient.Payload)
        case failure(RelayIssue)
    }

    static func load() async throws -> RelaySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try requestFromChild() })
            }
        }
    }

    private static func requestFromChild() throws -> RelaySnapshot {
        guard let executable = Bundle.main.executableURL else { throw RelayIssue.keychainUnavailable }
        let output = Pipe()
        let child = Process()
        child.executableURL = executable
        child.arguments = [argument]
        child.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        child.environment = [:]
        child.standardInput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.standardOutput = output
        do { try child.run() }
        catch { throw RelayIssue.keychainUnavailable }
        // The child has its own 5s HTTP budget. Bound its total lifetime as well,
        // including startup and potentially stalled native Keychain calls.
        let watchdog = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        let data = try? output.fileHandleForReading.readToEnd()
        child.waitUntilExit()
        guard child.terminationReason == .exit else { throw RelayIssue.timeout }
        guard child.terminationStatus == 0, let data,
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw RelayIssue.keychainUnavailable
        }
        switch reply {
        case .snapshot(let payload): return try payload.snapshot()
        case .failure(let issue): throw issue
        }
    }

    // Called only in the dedicated process, before AppKit or any quota provider.
    // An ACL granted to this executable must never turn it into a token exporter:
    // the child makes the fixed request and returns only v1 status or a typed error.
    static func runAndExit(
        readToken: @escaping () throws -> String = readLoginItem,
        fetch: @escaping (String) async throws -> RelayStatusClient.Payload = RelayStatusClient.fetchPayload
    ) -> Never {
        Task.detached(priority: .utility) {
            let reply: Reply
            do {
                guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                    throw RelayIssue.keychainUnavailable
                }
                let token = try readToken()
                reply = .snapshot(try await fetch(token))
            } catch {
                reply = .failure((error as? RelayIssue) ?? .network)
            }
            do {
                try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(reply))
                exit(EXIT_SUCCESS)
            } catch {
                exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
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

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

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
