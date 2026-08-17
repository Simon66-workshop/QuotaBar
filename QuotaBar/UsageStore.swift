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
    @Published var deviceUserCode: String = ""
    @Published var deviceNote: String = ""

    private var timer: AnyCancellable?
    private var lastAlert: [LaneKey: Int] = [:]
    private var authWatcher: DispatchSourceFileSystemObject?
    private var watchFd: Int32 = -1
    private var deviceTask: Task<Void, Never>?

    init() {
        launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        notifyEnabled = UserDefaults.standard.object(forKey: "notifyEnabled") as? Bool ?? true
        watchGrokAuthFile()
        Task { await refresh() }
        timer = Timer.publish(every: 90, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
    }

    func connectGrok(_ raw: String) async {
        guard TokenReader.savePasted(raw) else { return }
        await refresh()
    }

    func disconnectGrok() async {
        KeychainStore.clearGrok()
        await refresh()
    }

    func openGrokLogin() {
        startDeviceLogin()
    }

    func startDeviceLogin() {
        deviceTask?.cancel()
        deviceUserCode = ""
        deviceNote = "Starting Grok device login…"
        deviceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pending = try await GrokDeviceAuth.begin()
                await MainActor.run {
                    self.deviceUserCode = pending.userCode
                    self.deviceNote = "Authorize this device, then wait — QuotaBar writes auth.json itself."
                }
                NSWorkspace.shared.open(pending.verifyURL)
                let auth = try await GrokDeviceAuth.poll(pending)
                if Task.isCancelled { return }
                let writeErr = TokenReader.persist(auth)
                await MainActor.run {
                    if let writeErr {
                        self.deviceNote = "CLI 没落盘；QuotaBar 也写失败：\(writeErr)"
                    } else {
                        self.deviceNote = "Signed in. Wrote key + expires_at to ~/.grok/auth.json"
                        self.deviceUserCode = ""
                    }
                }
                await refresh()
            } catch {
                await MainActor.run {
                    self.deviceNote = "CLI 没落盘。QuotaBar device login failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func refresh() async {
        busy = true
        defer { busy = false }
        let grokAuth = TokenReader.loadGrokAuth()
        let cursorTok = TokenReader.cursorTokenFromLocalApp() ?? ""
        async let grok = UsageClient.fetchGrok()
        async let cursor = UsageClient.fetchCursor(token: cursorTok)
        async let bot = UsageClient.fetchSand(token: cursorTok)
        let next = Snapshot(
            grok: await grok,
            cursor: await cursor,
            bot: await bot,
            fetchedAt: Date(),
            grokLinked: grokAuth != nil,
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
        stopWatch()
        NSApplication.shared.terminate(nil)
    }

    private func watchGrokAuthFile() {
        let dir = TokenReader.grokDir().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        watchFd = open(dir, O_EVTONLY)
        guard watchFd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFd,
            eventMask: [.write, .rename, .extend, .delete, .attrib],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            Task { await self?.refresh() }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.watchFd, fd >= 0 { close(fd) }
            self?.watchFd = -1
        }
        authWatcher = src
        src.resume()
    }

    private func stopWatch() {
        authWatcher?.cancel()
        authWatcher = nil
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
