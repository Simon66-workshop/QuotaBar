import Foundation

/// One usage provider. To add the next service:
/// 1. Add a `LaneKey` case (letter + title).
/// 2. Add a `UsageSource` struct below and append it to `UsageSources.all`.
/// 3. If it has a paste / local-login form, set `connectTitle` and add a form
///    in `ConnectCell`. Cursor-style sources leave `connectTitle` nil.
///
/// `UsageStore.refresh()` walks `all` — do not add another ad-hoc fetch there.
protocol UsageSource: Sendable {
    var key: LaneKey { get }
    var emptySub: String { get }
    var connectTitle: String? { get }
    func hasSession() -> Bool
    func fetch() async -> Lane
}

extension UsageSource {
    func load() async -> Lane {
        if hasSession() { return await fetch() }
        return .empty(key, sub: emptySub)
    }
}

enum UsageSources {
    static let all: [any UsageSource] = [
        GrokUsageSource(),
        CursorUsageSource(),
        SandUsageSource(),
        ChatGPTUsageSource(),
        ClaudeUsageSource(),
    ]

    static func source(for key: LaneKey) -> any UsageSource {
        all.first(where: { $0.key == key }) ?? GrokUsageSource()
    }

    static func emptyLane(_ key: LaneKey) -> Lane {
        let src = source(for: key)
        return .empty(key, sub: src.emptySub)
    }

    static func loadAll() async -> [Lane] {
        await withTaskGroup(of: Lane.self) { group in
            for src in all {
                group.addTask { await src.load() }
            }
            var rows: [Lane] = []
            rows.reserveCapacity(all.count)
            for await lane in group { rows.append(lane) }
            return rows
        }
    }
}

struct GrokUsageSource: UsageSource {
    var key: LaneKey { .grok }
    var emptySub: String { "Weekly SuperGrok Heavy  ·  not connected" }
    var connectTitle: String? { "Grok" }
    func hasSession() -> Bool { TokenReader.hasGrokSession() }
    func fetch() async -> Lane { await UsageClient.fetchGrok() }
}

struct CursorUsageSource: UsageSource {
    var key: LaneKey { .cursor }
    var emptySub: String { "Ultra monthly  ·  not connected" }
    var connectTitle: String? { nil }
    func hasSession() -> Bool {
        !(TokenReader.cursorTokenFromLocalApp() ?? "").isEmpty
    }
    func fetch() async -> Lane {
        await UsageClient.fetchCursor(token: TokenReader.cursorTokenFromLocalApp() ?? "")
    }
}

struct SandUsageSource: UsageSource {
    var key: LaneKey { .bot }
    var emptySub: String { "Sand weekly  ·  needs Cursor" }
    var connectTitle: String? { nil }
    func hasSession() -> Bool {
        !(TokenReader.cursorTokenFromLocalApp() ?? "").isEmpty
    }
    func fetch() async -> Lane {
        await UsageClient.fetchSand(token: TokenReader.cursorTokenFromLocalApp() ?? "")
    }
}

struct ChatGPTUsageSource: UsageSource {
    var key: LaneKey { .gpt }
    var emptySub: String { "ChatGPT / Codex  ·  not connected" }
    var connectTitle: String? { "ChatGPT" }
    func hasSession() -> Bool { TokenReader.hasCodexSession() }
    func fetch() async -> Lane { await UsageClient.fetchChatGPT() }
}

struct ClaudeUsageSource: UsageSource {
    var key: LaneKey { .claude }
    var emptySub: String { "Claude Code 5h + 7d  ·  not connected" }
    var connectTitle: String? { "Claude" }
    func hasSession() -> Bool { TokenReader.hasClaudeSession() }
    func fetch() async -> Lane { await UsageClient.fetchClaude() }
}

/// Cheap process probe. Cached a few seconds so a 90s refresh does not spawn pgrep twice.
enum ProcessProbe {
    private static var cache: [String: (at: Date, yes: Bool)] = [:]
    private static let lock = NSLock()

    static func named(_ name: String) -> Bool {
        lock.lock()
        if let hit = cache[name], Date().timeIntervalSince(hit.at) < 4 {
            let yes = hit.yes
            lock.unlock()
            return yes
        }
        lock.unlock()
        let yes = pgrepExact(name)
        lock.lock()
        cache[name] = (Date(), yes)
        lock.unlock()
        return yes
    }

    /// Claude Code CLI (`claude`) or the desktop app (`Claude`).
    static func claudeLive() -> Bool {
        named("claude") || named("Claude")
    }

    private static func pgrepExact(_ name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", name]
        task.standardOutput = Pipe()
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
