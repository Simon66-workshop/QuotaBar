import AppKit
import Darwin
import Foundation
import IOKit

enum DiskMonitor {
    private static var lastBytes: [String: (r: UInt64, w: UInt64, t: Date)] = [:]
    private static var observers: [NSObjectProtocol] = []

    static func start(onChange: @escaping () -> Void) {
        stop()
        let nc = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                onChange()
            }
            observers.append(token)
        }
    }

    static func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for token in observers { nc.removeObserver(token) }
        observers.removeAll()
    }

    static func snapshot() -> [DiskVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeIsRootFileSystemKey,
            .volumeUUIDStringKey,
            .volumeIsAutomountedKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        let io = blockIO()
        let now = Date()
        var seen = Set<String>()
        var out: [DiskVolume] = []

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.volumeIsLocal == false { continue }
            let name = (values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !shouldSkip(name: name, path: url.path) else { continue }

            let total = Int64(values.volumeTotalCapacity ?? 0)
            guard total >= 1_000_000_000 else { continue }

            let free = Int64(
                values.volumeAvailableCapacityForImportantUsage
                    ?? Int64(values.volumeAvailableCapacity ?? 0)
            )
            let usedPct = total > 0 ? min(100, max(0, Double(total - max(0, free)) / Double(total) * 100)) : 0

            let uuid = values.volumeUUIDString ?? url.path
            if seen.contains(uuid) { continue }
            seen.insert(uuid)

            let internalDrive = values.volumeIsInternal == true
            let ejectable = values.volumeIsEjectable == true || values.volumeIsRemovable == true
            let kind: DiskKind
            if isDiskImage(url) {
                kind = .image
            } else if ejectable && !internalDrive {
                kind = .external
            } else if internalDrive {
                kind = .internalDrive
            } else if ejectable {
                kind = .external
            } else {
                kind = .internalDrive
            }

            let bsd = bsdParent(for: url.path)
            let counters = bsd.flatMap { io[$0] }
            var readBps = 0.0
            var writeBps = 0.0
            if let counters {
                if let prev = lastBytes[uuid] {
                    let dt = now.timeIntervalSince(prev.t)
                    if dt > 0.2 {
                        let dr = counters.r >= prev.r ? counters.r - prev.r : 0
                        let dw = counters.w >= prev.w ? counters.w - prev.w : 0
                        readBps = Double(dr) / dt
                        writeBps = Double(dw) / dt
                    }
                }
                lastBytes[uuid] = (counters.r, counters.w, now)
            }

            out.append(DiskVolume(
                id: uuid,
                name: name,
                path: url.path,
                kind: kind,
                totalBytes: total,
                freeBytes: max(0, free),
                usedPct: usedPct,
                readBps: readBps,
                writeBps: writeBps,
                isReadOnly: values.volumeIsReadOnly == true,
                isRoot: values.volumeIsRootFileSystem == true,
                justChanged: nil
            ))
        }

        lastBytes = lastBytes.filter { key, _ in seen.contains(key) }
        return out.sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            if a.kind != b.kind { return a.kind == .internalDrive }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private static func shouldSkip(name: String, path: String) -> Bool {
        let banned = [
            "Preboot", "Recovery", "VM", "Update", "iSCPreboot", "xarts",
            "Hardware", "Cryptexes", "iOS", "watchOS", "tvOS",
        ]
        if banned.contains(name) { return true }
        let lower = path.lowercased()
        if lower.contains("com.apple.timemachine") { return true }
        if lower.contains("mobilebackups") { return true }
        if lower.contains("/system/volumes/preboot") { return true }
        if lower.contains("/system/volumes/vm") { return true }
        if lower.contains("/system/volumes/update") { return true }
        if name.hasPrefix(".") { return true }
        return false
    }

    private static func isDiskImage(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.contains(".dmg") || path.contains("/diskimages/") { return true }
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return false }
        let from = withUnsafePointer(to: &s.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_DARWIN_MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return from.contains("diskimage") || from.hasPrefix("/dev/diskimage")
    }

    private static func bsdParent(for path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let raw = withUnsafePointer(to: &s.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_DARWIN_MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        var name = raw.split(separator: "/").last.map(String.init) ?? raw
        if name.hasPrefix("disk"), let slice = name.range(of: "s", options: .backwards) {
            let after = name[slice.upperBound...]
            if !after.isEmpty, after.allSatisfy(\.isNumber) {
                name = String(name[..<slice.lowerBound])
            }
        }
        return name.isEmpty ? nil : name
    }

    private static func blockIO() -> [String: (r: UInt64, w: UInt64)] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return [:] }
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var out: [String: (r: UInt64, w: UInt64)] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any]
            else { continue }
            let stats = props["Statistics"] as? [String: Any] ?? [:]
            let read = uint64(stats["Bytes (Read)"]) ?? uint64(stats["BytesRead"]) ?? 0
            let write = uint64(stats["Bytes (Written)"]) ?? uint64(stats["BytesWritten"]) ?? 0
            for bsd in mediaNames(parent: service, depth: 0) {
                out[bsd] = (read, write)
            }
        }
        return out
    }

    private static func mediaNames(parent: io_object_t, depth: Int) -> [String] {
        guard depth < 6 else { return [] }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(parent, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        var child = IOIteratorNext(iterator)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(iterator)
            }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(child, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any]
            else { continue }
            if let bsd = props["BSD Name"] as? String, bsd.hasPrefix("disk") {
                let parentDisk: String
                if let slice = bsd.range(of: "s", options: .backwards),
                   bsd[slice.upperBound...].allSatisfy(\.isNumber)
                {
                    parentDisk = String(bsd[..<slice.lowerBound])
                } else {
                    parentDisk = bsd
                }
                names.append(parentDisk)
                names.append(bsd)
            }
            names.append(contentsOf: mediaNames(parent: child, depth: depth + 1))
        }
        return names
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber { return n.uint64Value }
        if let n = value as? UInt64 { return n }
        return nil
    }
}
