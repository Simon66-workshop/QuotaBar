#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Only the official read-only Antigravity /usage command supplies GO.
/// No credential discovery, login, HTTP requests, credits, or request counters.
enum GoogleUsage {
    static let executable = "/Volumes/2T扩展盘/Agent文件/gemini-cli/antigravity/bin/agy"
    static let arguments = ["-p", "/usage", "--output-format", "json", "--print-timeout", "60s"]

    static func fetch() async -> Lane {
        await Task.detached(priority: .utility) {
            lane(from: run())
        }.value
    }

    enum CommandResult {
        case success(Data)
        case unavailable(String)
    }

    static func lane(from result: CommandResult) -> Lane {
        switch result {
        case .success(let data): return parse(data)
        case .unavailable(let reason): return .error(.google, message: "Unavailable · \(reason)")
        }
    }

    /// Bounded stdout, discarded stderr, closed stdin, hard wall-clock deadline.
    /// The wrapper execs agy and owns its process-level proxy; do not change it.
    /// Parameters permit local fake-process tests; production always uses the constants above.
    static func run(
        executablePath: String = executable,
        commandArguments: [String] = arguments,
        timeout: TimeInterval = 65,
        outputLimit: Int = 1_048_576
    ) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return .unavailable("Antigravity CLI not found; Refresh after it is restored")
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = commandArguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // A pre-existing CLI subscription session, never API-key billing.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GEMINI_API_KEY")
        environment.removeValue(forKey: "GOOGLE_API_KEY")
        process.environment = environment

        let reader = pipe.fileHandleForReading
        let writer = pipe.fileHandleForWriting
        defer {
            try? reader.close()
            try? writer.close()
        }
        let fd = reader.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else {
            return .unavailable("could not read Antigravity output")
        }
        do { try process.run() }
        catch { return .unavailable("Antigravity CLI could not start") }
        try? writer.close()

        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            let grace = Date().addingTimeInterval(0.3)
            while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            // Check even while output flows, so a noisy child cannot defeat the deadline.
            if ProcessInfo.processInfo.systemUptime >= deadline {
                stop()
                return .unavailable("Antigravity /usage timed out; try Refresh")
            }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard count <= outputLimit - data.count else {
                    stop()
                    return .unavailable("Antigravity output exceeded the size limit")
                }
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno != EAGAIN, errno != EINTR {
                stop()
                return .unavailable("could not read Antigravity output")
            }
            if !process.isRunning {
                // One final drain after exit handles output written between read and isRunning.
                let finalCount = read(fd, &buffer, buffer.count)
                if finalCount > 0 {
                    guard finalCount <= outputLimit - data.count else {
                        return .unavailable("Antigravity output exceeded the size limit")
                    }
                    data.append(contentsOf: buffer.prefix(finalCount))
                    continue
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return .unavailable("Antigravity /usage failed; check the existing CLI session, then Refresh")
        }
        return .success(data)
    }

    /// Decode command.data only. Unknown/malformed data never becomes a zero quota.
    static func parse(_ data: Data) -> Lane {
        let unavailable = Lane.error(.google, message: "Unavailable · official /usage quota missing or invalid; try Refresh")
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.status == "SUCCESS", response.command.name == "usage",
              !response.command.data.groups.isEmpty else { return unavailable }

        var groups: [GoogleQuotaGroup] = []
        var groupNames = Set<String>()
        var bucketIDs = Set<String>()
        for group in response.command.data.groups {
            guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  groupNames.insert(group.name).inserted, !group.buckets.isEmpty else { return unavailable }
            var buckets: [GoogleQuotaBucket] = []
            for bucket in group.buckets {
                guard !bucket.id.isEmpty, !bucket.name.isEmpty, !bucket.window.isEmpty,
                      bucketIDs.insert(bucket.id).inserted,
                      bucket.remaining_fraction.isFinite, (0...1).contains(bucket.remaining_fraction),
                      let reset = resetDate(bucket.reset_time) else { return unavailable }
                buckets.append(GoogleQuotaBucket(
                    id: bucket.id, name: bucket.name, window: bucket.window,
                    remainingFraction: bucket.remaining_fraction, resetTime: reset
                ))
            }
            groups.append(GoogleQuotaGroup(name: group.name, description: group.description ?? "", buckets: buckets))
        }

        // GO has no scalar percentage. Each displayed figure comes from its own bucket.
        var lane = Lane.error(.google, message: "Unavailable · no unambiguous Gemini Models 5h or weekly window")
        lane.googleGroups = groups
        if let group = lane.googleMenuGroup,
           GoogleQuotaPeriod.allCases.contains(where: { group.bucket(for: $0) != nil }) {
            lane.tone = .ok
            lane.sub = "Gemini Models · 5h and weekly usage shown separately"
        }
        return lane
    }

    private static func resetDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private struct Response: Decodable {
        var status: String
        var command: Command
    }
    private struct Command: Decodable {
        var name: String
        var data: Quotas
    }
    private struct Quotas: Decodable {
        var groups: [Group]
    }
    private struct Group: Decodable {
        var name: String
        var description: String?
        var buckets: [Bucket]
    }
    private struct Bucket: Decodable {
        var id: String
        var name: String
        var window: String
        var remaining_fraction: Double
        var reset_time: String
    }
}
