import Foundation

/// Live, read-only evidence using the exact sampler shipped in the app.
@main
struct MemoryCheck {
    static func command(_ path: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: path, code: Int(process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func number(_ pattern: String, in text: String) throws -> UInt64 {
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let value = UInt64(text[range]) else {
            throw NSError(domain: "Missing counter: \(pattern)", code: 1)
        }
        return value
    }

    static func main() throws {
        guard let before = MemoryMonitor.snapshot() else {
            throw NSError(domain: "Mach RAM sample unavailable", code: 1)
        }
        print("RAM check at \(ISO8601DateFormatter().string(from: Date()))")
        print("Formula: (active + wired + compressor physical pages) * page size / physicalMemory * 100")
        print("Speculative/inactive/free excluded; no separate purgeable adjustment; GB = 2^30 bytes.")
        print(String(format: "App sampler: %.4f%%; %@; %@; usedBytes=%llu; totalBytes=%llu",
                     before.usedPct, before.barLabel, before.sizeLabel, before.usedBytes, before.totalBytes))

        var passed = true
        for path in ["/usr/bin/vm_stat", "/usr/bin/memory_pressure"] {
            let output = try command(path) // No pressure-generating flags or allocations.
            print("\n$ \(path)\n\(output)")
            let active = try number(#"Pages active:\s+(\d+)"#, in: output)
            let wired = try number(#"Pages wired down:\s+(\d+)"#, in: output)
            let compressed = try number(#"Pages (?:occupied|used) by compressor:\s+(\d+)"#, in: output)
            let pageSize = try number(#"page size (?:of )?(\d+)"#, in: output)
            let used = (active + wired + compressed) * pageSize
            let percent = Double(used) / Double(before.totalBytes) * 100
            let delta = abs(percent - before.usedPct)
            print(String(format: "Recomputed: active=%llu wired=%llu compressor=%llu pageSize=%llu usedBytes=%llu; %.4f%%; delta=%.4f percentage points",
                         active, wired, compressed, pageSize, used, percent, delta))
            passed = passed && delta < 1.0
            if path.hasSuffix("memory_pressure") {
                let total = try number(#"system has (\d+)"#, in: output)
                print("Physical total matches ProcessInfo: \(total == before.totalBytes)")
                passed = passed && total == before.totalBytes
                print("The tool's system-wide free percentage is memory-pressure availability, NOT 100 - M.")
            }
        }
        guard let after = MemoryMonitor.snapshot() else {
            throw NSError(domain: "Second Mach RAM sample unavailable", code: 1)
        }
        print(String(format: "App sampler after: %.4f%%; %@", after.usedPct, after.sizeLabel))
        print("Comparison tolerance: < 1 percentage point for sequential live samples.")
        print(passed ? "PASS: app sampler agrees with both tools' page counters." : "FAIL: samples differ; inspect timing and counters.")
        if !passed { throw NSError(domain: "RAM evidence comparison failed", code: 1) }
    }
}
