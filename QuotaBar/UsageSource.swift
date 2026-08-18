import Darwin
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

    static func source(for key: LaneKey) -> (any UsageSource)? {
        all.first(where: { $0.key == key })
    }

    static func emptyLane(_ key: LaneKey) -> Lane {
        .empty(key, sub: source(for: key)?.emptySub ?? "not connected")
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

/// Process probe via path + argv. `pgrep -x claude` misses `node …/claude`.
enum ProcessProbe {
    private static var cache: [String: (at: Date, yes: Bool)] = [:]
    private static let lock = NSLock()

    static func claudeLive() -> Bool {
        lock.lock()
        if let hit = cache["claude-path"], Date().timeIntervalSince(hit.at) < 4 {
            let yes = hit.yes
            lock.unlock()
            return yes
        }
        lock.unlock()
        let yes = scanClaude()
        lock.lock()
        cache["claude-path"] = (Date(), yes)
        lock.unlock()
        return yes
    }

    private static func scanClaude() -> Bool {
        let raw = proc_listpids(PROC_ALL_PIDS, 0, nil, 0)
        guard raw > 0 else { return false }
        let count = Int(raw) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: count)
        let filled = proc_listpids(PROC_ALL_PIDS, 0, &pids, raw)
        guard filled > 0 else { return false }
        let n = Int(filled) / MemoryLayout<pid_t>.stride
        for pid in pids.prefix(n) where pid > 0 {
            if looksLikeClaudeCLI(pid) { return true }
        }
        return false
    }

    private static func looksLikeClaudeCLI(_ pid: pid_t) -> Bool {
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN))
        let path = n > 0 ? String(cString: pathBuf) : ""
        let lower = path.lowercased()
        if lower.contains("claude.app/") { return false }

        var nameBuf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        let comm = String(cString: nameBuf)
        if comm == "claude" { return true }
        if lower.hasSuffix("/claude") || lower.hasSuffix("/claude-code") { return true }

        let runtime = lower.hasSuffix("/node") || lower.hasSuffix("/nodejs")
            || lower.hasSuffix("/bun") || lower.hasSuffix("/deno")
            || comm == "node" || comm == "bun" || comm == "deno"
        guard runtime, let args = argv(pid) else { return false }
        return args.contains { arg in
            let a = arg.lowercased()
            if a.contains("claude.app/") { return false }
            let base = (a as NSString).lastPathComponent
            guard base == "claude" else {
                return a.contains("@anthropic-ai/claude") || a.hasSuffix("/claude.js")
            }
            // Require a CLI-shaped path so `node ./claude` project folders do not match.
            return !a.contains("/")
                || a.hasSuffix("/.bin/claude")
                || a.contains("node_modules")
                || a.contains("@anthropic")
        }
    }

    private static func argv(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 8 else { return nil }
        var argc: Int32 = 0
        _ = withUnsafeMutableBytes(of: &argc) { dest in
            buf.withUnsafeBytes { src in
                memcpy(dest.baseAddress, src.baseAddress, min(4, src.count))
            }
        }
        argc = Int32(littleEndian: argc)
        guard argc > 0, argc < 64 else { return nil }
        var idx = 4
        while idx < size && buf[idx] != 0 { idx += 1 }
        idx += 1
        while idx < size && buf[idx] == 0 { idx += 1 }
        var args: [String] = []
        for _ in 0..<Int(argc) {
            if idx >= size { break }
            let start = idx
            while idx < size && buf[idx] != 0 { idx += 1 }
            if start < idx, let s = String(bytes: buf[start..<idx], encoding: .utf8) {
                args.append(s)
            }
            idx += 1
        }
        return args
    }
}
