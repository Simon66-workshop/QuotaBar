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
    @Published var loginInProgress = false
    @Published var copiedNote: String = ""
    @Published var disks: [DiskVolume] = []

    var onWillOpenBrowser: (() -> Void)?
    var onLoginFinished: (() -> Void)?

    private var timer: AnyCancellable?
    private var diskTimer: AnyCancellable?
    private var lastAlert: [LaneKey: Int] = [:]
    private var lastDiskAlert: [String: Int] = [:]
    private var authWatchers: [DispatchSourceFileSystemObject] = []
    private var watchFds: [Int32] = []
    private var deviceTask: Task<Void, Never>?
    private var watchDebounce: DispatchWorkItem?
    private var disksPrimed = false
    private var refreshRunning = false
    private var liveIO = false
    private var lastCapacityTick = Date.distantPast
    private var forceDiskTick = false
    private var mountedAt: [String: Date] = [:]

    init() {
        launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        notifyEnabled = UserDefaults.standard.object(forKey: "notifyEnabled") as? Bool ?? true
        if notifyEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        watchAuthDirs()
        DiskMonitor.start { [weak self] in
            self?.forceDiskTick = true
            self?.tickDisks()
        }
        tickDisks()
        Task { await refresh() }
        timer = Timer.publish(every: 90, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
        diskTimer = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tickDisks()
            }
    }

    func connectGrok(_ raw: String) async {
        TokenReader.clearDeadRefresh()
        guard TokenReader.savePasted(raw) else { return }
        await refresh()
    }

    func disconnectGrok() async {
        // Mark disk/keychain refresh dead so loadGrokAuth will not revive it.
        if let disk = TokenReader.loadGrokAuthFromDisk(), !disk.refresh.isEmpty {
            TokenReader.markRefreshDead(disk.refresh)
        }
        if let saved = KeychainStore.loadAuth(), !saved.refresh.isEmpty {
            TokenReader.markRefreshDead(saved.refresh)
        }
        KeychainStore.clearGrok()
        await refresh()
    }

    func openGrokLogin() {
        startDeviceLogin()
    }

    func startDeviceLogin() {
        deviceTask?.cancel()
        deviceUserCode = ""
        loginInProgress = true
        deviceNote = "Starting Grok device login…"
        deviceTask = Task { [weak self] in
            guard let self else { return }
            var openedBrowser = false
            defer {
                Task { @MainActor in
                    self.loginInProgress = false
                    if openedBrowser {
                        self.onLoginFinished?()
                    }
                }
            }
            do {
                let pending = try await GrokDeviceAuth.begin()
                await MainActor.run {
                    self.deviceUserCode = pending.userCode
                    self.deviceNote = "Authorize in the browser, then come back and click the bar."
                    self.onWillOpenBrowser?()
                }
                openedBrowser = true
                NSWorkspace.shared.open(pending.verifyURL)
                let auth = try await GrokDeviceAuth.poll(pending)
                if Task.isCancelled { return }
                TokenReader.clearDeadRefresh()
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

    func cancelDeviceLogin() {
        deviceTask?.cancel()
        deviceTask = nil
        loginInProgress = false
        deviceNote = "Login cancelled"
        deviceUserCode = ""
        onLoginFinished?()
    }

    func copyUserCode() {
        guard !deviceUserCode.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deviceUserCode, forType: .string)
        flashCopied("User code copied")
    }

    func connectChatGPT(_ raw: String) async {
        guard TokenReader.saveCodexPasted(raw) else { return }
        await refresh()
    }

    func copySummary() {
        var lines = snap.lanes.map { lane in
            "\(lane.key.title): \(lane.label) — \(lane.sub)"
        }
        for disk in disks {
            lines.append("\(disk.name): \(Int(disk.usedPct.rounded()))% — \(disk.sizeLabel) · \(disk.statusLabel) · \(disk.rateLabel)")
        }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopied("Summary copied")
    }

    private func flashCopied(_ note: String) {
        copiedNote = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.copiedNote == note { self?.copiedNote = "" }
        }
    }

    func setLiveIO(_ on: Bool) {
        liveIO = on
        if on {
            forceDiskTick = true
            tickDisks()
        }
    }

    func refresh() async {
        if refreshRunning { return }
        refreshRunning = true
        busy = true
        defer {
            busy = false
            refreshRunning = false
        }
        let cursorTok = TokenReader.cursorTokenFromLocalApp() ?? ""
        async let grok = UsageClient.fetchGrok()
        async let cursor = UsageClient.fetchCursor(token: cursorTok)
        async let bot = UsageClient.fetchSand(token: cursorTok)
        async let gpt = UsageClient.fetchChatGPT()
        let grokLane = await grok
        let gptLane = await gpt
        let next = Snapshot(
            grok: grokLane,
            cursor: await cursor,
            bot: await bot,
            gpt: gptLane,
            fetchedAt: Date(),
            grokLinked: grokLane.tone != .empty && grokLane.tone != .error,
            cursorLinked: !cursorTok.isEmpty,
            gptLinked: gptLane.tone != .empty && gptLane.tone != .error
        )
        snap = next
        forceDiskTick = true
        tickDisks()
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
        timer?.cancel()
        diskTimer?.cancel()
        DiskMonitor.stop()
        deviceTask?.cancel()
        NSApplication.shared.terminate(nil)
    }

    private func watchAuthDirs() {
        let dirs = [
            TokenReader.grokDir().path,
            TokenReader.home().appendingPathComponent(".codex").path,
        ]
        for dir in dirs {
            if dir.hasSuffix(".codex") {
                if !FileManager.default.fileExists(atPath: dir) { continue }
            } else {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }
            watchFds.append(fd)
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .extend, .delete],
                queue: .main
            )
            src.setEventHandler { [weak self] in
                guard let self else { return }
                self.watchDebounce?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.refreshRunning else { return }
                    Task { await self.refresh() }
                }
                self.watchDebounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
            }
            src.setCancelHandler { [fd] in
                close(fd)
            }
            authWatchers.append(src)
            src.resume()
        }
    }

    private func stopWatch() {
        watchDebounce?.cancel()
        for src in authWatchers { src.cancel() }
        authWatchers.removeAll()
        watchFds.removeAll()
    }

    private func notifyIfNeeded(_ snap: Snapshot) {
        guard notifyEnabled else { return }
        for lane in snap.lanes {
            guard let used = lane.usedPct, used >= 80 else { continue }
            let bucket = used >= 95 ? 95 : used >= 90 ? 90 : 80
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
        for disk in disks {
            guard disk.usedPct >= 80 else { continue }
            let bucket = disk.usedPct >= 95 ? 95 : disk.usedPct >= 90 ? 90 : 80
            if lastDiskAlert[disk.id] == bucket { continue }
            lastDiskAlert[disk.id] = bucket
            let content = UNMutableNotificationContent()
            content.title = "\(disk.name) is \(Int(disk.usedPct.rounded()))% full"
            content.body = "\(disk.sizeLabel) · \(disk.kindLabel)"
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "quotabar.disk.\(disk.id).\(bucket)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req)
        }
    }

    private func tickDisks() {
        let wantIO = liveIO
        if !forceDiskTick, !wantIO, Date().timeIntervalSince(lastCapacityTick) < 12 {
            return
        }
        forceDiskTick = false
        lastCapacityTick = Date()

        let previous = disks
        var next = DiskMonitor.snapshot(includeIO: wantIO)
        if !wantIO {
            let rates = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, ($0.readBps, $0.writeBps)) })
            next = next.map { disk in
                var copy = disk
                if let rate = rates[disk.id] {
                    copy.readBps = rate.0
                    copy.writeBps = rate.1
                }
                return copy
            }
        }

        let now = Date()
        if disksPrimed {
            let oldIds = Set(previous.map(\.id))
            let newIds = Set(next.map(\.id))
            let added = next.filter { !oldIds.contains($0.id) }
            let removed = previous.filter { !newIds.contains($0.id) }
            if !added.isEmpty || !removed.isEmpty {
                announceDisks(added: added, removed: removed)
            }
            for disk in added { mountedAt[disk.id] = now }
            for disk in removed { mountedAt[disk.id] = nil }
        }
        disksPrimed = true
        mountedAt = mountedAt.filter { key, _ in next.contains(where: { $0.id == key }) }
        next = next.map { disk in
            var copy = disk
            if let at = mountedAt[disk.id], now.timeIntervalSince(at) < 8 {
                copy.justChanged = "just mounted"
            }
            return copy
        }
        lastDiskAlert = lastDiskAlert.filter { key, _ in next.contains(where: { $0.id == key }) }

        if sameDisks(previous, next) { return }
        disks = next
        notifyIfNeeded(snap)
    }

    private func sameDisks(_ a: [DiskVolume], _ b: [DiskVolume]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.id != y.id { return false }
            if Int(x.usedPct.rounded()) != Int(y.usedPct.rounded()) { return false }
            if x.statusLabel != y.statusLabel { return false }
            if x.justChanged != y.justChanged { return false }
            if Int(x.readBps / 200_000) != Int(y.readBps / 200_000) { return false }
            if Int(x.writeBps / 200_000) != Int(y.writeBps / 200_000) { return false }
        }
        return true
    }

    private func announceDisks(added: [DiskVolume], removed: [DiskVolume]) {
        let bits = added.map { "\($0.name) mounted · \($0.sizeLabel)" }
            + removed.map { "\($0.name) ejected" }
        if !bits.isEmpty { flashCopied(bits.joined(separator: "  ·  ")) }
        guard notifyEnabled else { return }
        for disk in added {
            let content = UNMutableNotificationContent()
            content.title = "\(disk.name) mounted"
            content.body = "\(disk.kindLabel) · \(disk.sizeLabel)"
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "quotabar.disk.add.\(disk.id).\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
            )
        }
        for disk in removed {
            let content = UNMutableNotificationContent()
            content.title = "\(disk.name) ejected"
            content.body = disk.kindLabel
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "quotabar.disk.remove.\(disk.id).\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
            )
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
