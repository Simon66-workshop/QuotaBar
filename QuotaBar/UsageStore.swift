import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
    @Published var snap = Snapshot.vacant
    @Published var busy = false
    @Published var launchAtLogin: Bool
    @Published var notifyEnabled: Bool

    private var timer: AnyCancellable?
    private var lastAlert: [LaneKey: Int] = [:]

    init() {
        launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        notifyEnabled = UserDefaults.standard.object(forKey: "notifyEnabled") as? Bool ?? true
        Task { await refresh() }
        timer = Timer.publish(every: 120, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
    }

    var menuTitle: String { snap.menuTitle }

    func refresh() async {
        busy = true
        defer { busy = false }
        let grokTok = TokenReader.grokCLIAccessToken() ?? ""
        let cursorTok = TokenReader.cursorTokenFromLocalApp() ?? ""
        async let grok = UsageClient.fetchGrok(token: grokTok)
        async let cursor = UsageClient.fetchCursor(token: cursorTok)
        async let bot = UsageClient.fetchSand(token: cursorTok)
        let next = Snapshot(
            grok: await grok,
            cursor: await cursor,
            bot: await bot,
            fetchedAt: Date(),
            grokLinked: !grokTok.isEmpty,
            cursorLinked: !cursorTok.isEmpty
        )
        snap = next
        notifyIfNeeded(next)
    }

    func toggleNotify() {
        notifyEnabled.toggle()
        UserDefaults.standard.set(notifyEnabled, forKey: "notifyEnabled")
        if notifyEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
        UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        do {
            if launchAtLogin {
                try LaunchAgent.install()
            } else {
                try LaunchAgent.remove()
            }
        } catch {
            launchAtLogin.toggle()
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func notifyIfNeeded(_ snap: Snapshot) {
        guard notifyEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        for lane in snap.lanes {
            guard let used = lane.usedPct, used >= 80 else { continue }
            let bucket = Int(used)
            if lastAlert[lane.key] == bucket { continue }
            lastAlert[lane.key] = bucket
            let content = UNMutableNotificationContent()
            content.title = "\(lane.key.title) usage is high"
            content.body = "\(Int(used))% used this period. \(lane.sub)"
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "quotabar.\(lane.key.rawValue).\(bucket)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req)
        }
    }
}

enum LaunchAgent {
    static var label: String { "app.quotabar.mac" }
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func programPath() -> String {
        if let exec = Bundle.main.executablePath, !exec.isEmpty { return exec }
        return CommandLine.arguments[0]
    }

    static func install() throws {
        let program = programPath()
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(program)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: plistURL, atomically: true, encoding: .utf8)
        _ = try? shell("/bin/launchctl", "unload", plistURL.path)
        _ = try? shell("/bin/launchctl", "load", plistURL.path)
    }

    static func remove() throws {
        _ = try? shell("/bin/launchctl", "unload", plistURL.path)
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    @discardableResult
    private static func shell(_ args: String...) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: args[0])
        task.arguments = Array(args.dropFirst())
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }
}
