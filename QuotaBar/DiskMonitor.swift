import AppKit
import Darwin
import Foundation
import IOKit

/// Mount list comes from FileManager / NSWorkspace.
/// Per-disk I/O comes from IOBlockStorageDriver Statistics — only while the panel is open.
/// Topology is rebuilt on IOKit match/terminate + mount/wake, never on a 90s poll.
final class DiskMonitor {
    static let shared = DiskMonitor()

    static func start(onChange: @escaping () -> Void) {
        shared.start(onChange: onChange)
    }

    static func stop() {
        shared.stop()
    }

    static func snapshot(includeIO: Bool) -> [DiskVolume] {
        shared.snapshot(includeIO: includeIO)
    }

    private var lastBytes: [String: (r: UInt64, w: UInt64, t: Date)] = [:]
    private var observers: [NSObjectProtocol] = []
    private var drivers: [io_object_t] = []
    private var driverNames: [[String]] = []
    private var onChange: (() -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0

    /// uuid -> (path, candidate BSD names including physical parents)
    private var bsdCache: [String: (path: String, names: [String])] = [:]

    private init() {}

    func start(onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange
        rebuildTopology()
        armIOKitNotifications()

        let nc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
            NSWorkspace.didWakeNotification,
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.rebuildTopology()
                self?.onChange?()
            }
            observers.append(token)
        }
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for token in observers { nc.removeObserver(token) }
        observers.removeAll()
        disarmIOKitNotifications()
        releaseTopology()
        onChange = nil
        bsdCache.removeAll()
        lastBytes.removeAll()
    }

    func topologyDidChange() {
        rebuildTopology()
        onChange?()
    }

    func snapshot(includeIO: Bool) -> [DiskVolume] {
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
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        // Panel closed: never touch IOKit handles.
        if includeIO, drivers.isEmpty {
            rebuildTopology()
        }
        let io = includeIO ? readIO() : [:]
        let now = Date()
        var seen = Set<String>()
        var out: [DiskVolume] = []

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.volumeIsLocal == false { continue }
            let name = (values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !shouldSkip(name: name, path: url.path) else { continue }
            if isDiskImage(url) { continue }

            let total = Int64(values.volumeTotalCapacity ?? 0)
            guard total >= 1_000_000_000 else { continue }

            let freeAvail = Int64(values.volumeAvailableCapacity ?? 0)
            let free = freeAvail > 0 ? freeAvail : Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            let usedPct = total > 0 ? min(100, max(0, Double(total - max(0, free)) / Double(total) * 100)) : 0

            let uuid = values.volumeUUIDString ?? url.path
            if seen.contains(uuid) { continue }
            seen.insert(uuid)

            let internalDrive = values.volumeIsInternal == true
            let ejectable = values.volumeIsEjectable == true || values.volumeIsRemovable == true
            let kind: DiskKind = (!internalDrive && ejectable) ? .external : .internalDrive
            let hint = ignoreHint(name: name, url: url)

            var readBps = 0.0
            var writeBps = 0.0
            if includeIO, let counters = counters(for: url.path, uuid: uuid, io: io) {
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
                justChanged: nil,
                suggestedIgnore: hint != nil,
                ignoreHint: hint
            ))
        }

        lastBytes = lastBytes.filter { key, _ in seen.contains(key) }
        bsdCache = bsdCache.filter { key, _ in seen.contains(key) }
        return out
    }

    private func shouldSkip(name: String, path: String) -> Bool {
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

    private func ignoreHint(name: String, url: URL) -> String? {
        let n = name.lowercased()
        let p = url.path.lowercased()
        if n.contains("time machine") || n.contains("timemachine") { return "Time Machine" }
        let backup = url.appendingPathComponent("Backups.backupdb")
        if FileManager.default.fileExists(atPath: backup.path) { return "Time Machine" }
        let tm = url.appendingPathComponent(".com.apple.timemachine")
        if FileManager.default.fileExists(atPath: tm.path) { return "Time Machine" }
        let vmHints = ["parallels", "vmware", "virtualbox", "utm disk", "docker", "colima", "rancher", "lima"]
        if vmHints.contains(where: { n.contains($0) || p.contains($0) }) { return "virtual machine" }
        if p.contains("/library/containers/") { return "virtual machine" }
        return nil
    }

    private func isDiskImage(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.contains(".dmg") || path.contains("/diskimages/") { return true }
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return false }
        let from = mntfrom(&s)
        return from.contains("diskimage") || from.hasPrefix("/dev/diskimage")
    }

    private func mntfrom(_ s: inout statfs) -> String {
        withUnsafePointer(to: &s.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_DARWIN_MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    private func counters(
        for path: String,
        uuid: String,
        io: [String: (r: UInt64, w: UInt64)]
    ) -> (r: UInt64, w: UInt64)? {
        let names = bsdNames(for: path, uuid: uuid)
        for name in names {
            if let c = io[name] { return c }
        }
        for name in names {
            if let key = io.keys.first(where: { name.hasPrefix($0) || $0.hasPrefix(name) }) {
                return io[key]
            }
        }
        return nil
    }

    private func bsdNames(for path: String, uuid: String) -> [String] {
        if let cached = bsdCache[uuid], cached.path == path {
            return cached.names
        }
        var s = statfs()
        guard statfs(path, &s) == 0 else { return [] }
        let raw = mntfrom(&s)
        var slice = raw.split(separator: "/").last.map(String.init) ?? raw
        if slice.hasPrefix("/dev/") {
            slice = String(slice.dropFirst(5))
        }
        var names: [String] = []
        if !slice.isEmpty { names.append(slice) }
        if let parent = wholeDisk(slice) { names.append(parent) }
        names.append(contentsOf: physicalNames(from: slice))
        var seen = Set<String>()
        names = names.filter { seen.insert($0).inserted && !$0.isEmpty }
        bsdCache[uuid] = (path, names)
        return names
    }

    private func wholeDisk(_ bsd: String) -> String? {
        guard bsd.hasPrefix("disk"), let slice = bsd.range(of: "s", options: .backwards) else { return nil }
        let after = bsd[slice.upperBound...]
        guard !after.isEmpty, after.allSatisfy(\.isNumber) else { return nil }
        return String(bsd[..<slice.lowerBound])
    }

    /// Walk IOMedia parents so APFS container slices (disk3s5) map to the
    /// physical IOBlockStorageDriver (often disk0), not just the container.
    private func physicalNames(from slice: String) -> [String] {
        guard !slice.isEmpty else { return [] }
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, slice) else { return [] }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { return [] }
        defer { IOObjectRelease(media) }

        var names: [String] = []
        var current = media
        IOObjectRetain(current)
        var depth = 0
        while depth < 12 {
            if let bsd = cfString(current, "BSD Name"), bsd.hasPrefix("disk") {
                names.append(bsd)
                if let parent = wholeDisk(bsd) { names.append(parent) }
            }
            var cls = [CChar](repeating: 0, count: 128)
            if IOObjectGetClass(current, &cls) == KERN_SUCCESS {
                let name = String(cString: cls)
                if name.contains("IOBlockStorageDriver") { break }
            }
            var parent: io_object_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if current != media { IOObjectRelease(current) }
            guard kr == KERN_SUCCESS, parent != 0 else { break }
            current = parent
            depth += 1
        }
        if current != media { IOObjectRelease(current) }
        return names
    }

    private func armIOKitNotifications() {
        disarmIOKitNotifications()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let callback: IOServiceMatchingCallback = { _, iterator in
            var service = IOIteratorNext(iterator)
            while service != 0 {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            DispatchQueue.main.async {
                DiskMonitor.shared.topologyDidChange()
            }
        }

        if let matching = IOServiceMatching("IOBlockStorageDriver") {
            if IOServiceAddMatchingNotification(
                port,
                kIOFirstMatchNotification,
                matching,
                callback,
                nil,
                &addedIter
            ) == KERN_SUCCESS {
                drain(addedIter)
            }
        }
        if let matching = IOServiceMatching("IOBlockStorageDriver") {
            if IOServiceAddMatchingNotification(
                port,
                kIOTerminatedNotification,
                matching,
                callback,
                nil,
                &removedIter
            ) == KERN_SUCCESS {
                drain(removedIter)
            }
        }
    }

    private func disarmIOKitNotifications() {
        if let port = notifyPort {
            IONotificationPortSetDispatchQueue(port, nil)
        }
        if addedIter != 0 {
            IOObjectRelease(addedIter)
            addedIter = 0
        }
        if removedIter != 0 {
            IOObjectRelease(removedIter)
            removedIter = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func rebuildTopology() {
        releaseTopology()
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            drivers.append(service)
            driverNames.append(mediaNames(parent: service, depth: 0))
            service = IOIteratorNext(iterator)
        }
        bsdCache.removeAll()
    }

    private func releaseTopology() {
        for service in drivers { IOObjectRelease(service) }
        drivers.removeAll()
        driverNames.removeAll()
    }

    /// Single-key Statistics — never dump the whole registry entry.
    private func readIO() -> [String: (r: UInt64, w: UInt64)] {
        var out: [String: (r: UInt64, w: UInt64)] = [:]
        for (index, service) in drivers.enumerated() {
            guard let raw = IORegistryEntryCreateCFProperty(
                service,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any]
            else { continue }
            let read = uint64(raw["Bytes (Read)"]) ?? uint64(raw["BytesRead"]) ?? 0
            let write = uint64(raw["Bytes (Written)"]) ?? uint64(raw["BytesWritten"]) ?? 0
            let names = index < driverNames.count ? driverNames[index] : []
            for bsd in names {
                out[bsd] = (read, write)
            }
        }
        return out
    }

    private func mediaNames(parent: io_object_t, depth: Int) -> [String] {
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
            if let bsd = cfString(child, "BSD Name"), bsd.hasPrefix("disk") {
                names.append(bsd)
                if let parentDisk = wholeDisk(bsd) { names.append(parentDisk) }
            }
            names.append(contentsOf: mediaNames(parent: child, depth: depth + 1))
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private func cfString(_ service: io_object_t, _ key: String) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        else { return nil }
        return raw as? String
    }

    private func uint64(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber { return n.uint64Value }
        if let n = value as? UInt64 { return n }
        return nil
    }
}
