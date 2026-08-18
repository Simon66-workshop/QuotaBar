import AppKit
import Darwin
import DiskArbitration
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

    static func health(uuid: String, path: String) -> DiskHealth {
        shared.health(uuid: uuid, path: path)
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
    private var hintCache: [String: String] = [:]
    private var rebuildWork: DispatchWorkItem?
    private var daSession: DASession?
    private var daReady = false

    private init() {}

    func start(onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange
        rebuildTopology()
        armIOKitNotifications()
        armDiskArbitration()

        let nc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
            NSWorkspace.didWakeNotification,
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRebuild()
            }
            observers.append(token)
        }
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for token in observers { nc.removeObserver(token) }
        observers.removeAll()
        rebuildWork?.cancel()
        rebuildWork = nil
        disarmIOKitNotifications()
        releaseTopology()
        onChange = nil
        bsdCache.removeAll()
        hintCache.removeAll()
        lastBytes.removeAll()
        if let session = daSession {
            DASessionSetDispatchQueue(session, nil)
        }
        daSession = nil
        daReady = false
    }

    func noteHotPlug() {
        guard daReady else { return }
        scheduleRebuild()
    }

    func topologyDidChange() {
        scheduleRebuild()
    }

    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebuildTopology()
            self.onChange?()
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
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

            let kind = classify(url: url, values: values)
            let hint = ignoreHint(name: name, url: url, uuid: uuid)

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
        hintCache = hintCache.filter { key, _ in seen.contains(key) }
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

    private func ignoreHint(name: String, url: URL, uuid: String) -> String? {
        if let cached = hintCache[uuid] { return cached.isEmpty ? nil : cached }
        let n = name.lowercased()
        let p = url.path.lowercased()
        var hint: String?
        if n.contains("time machine") || n.contains("timemachine") { hint = "Time Machine" }
        else if vmHints.contains(where: { n.contains($0) || p.contains($0) }) { hint = "virtual machine" }
        else if p.contains("/library/containers/") { hint = "virtual machine" }
        else {
            // Path probes only when the name didn't already tell us.
            let backup = url.appendingPathComponent("Backups.backupdb")
            let tm = url.appendingPathComponent(".com.apple.timemachine")
            if FileManager.default.fileExists(atPath: backup.path)
                || FileManager.default.fileExists(atPath: tm.path)
            {
                hint = "Time Machine"
            }
        }
        hintCache[uuid] = hint ?? ""
        return hint
    }

    private var vmHints: [String] {
        ["parallels", "vmware", "virtualbox", "utm disk", "docker", "colima", "rancher", "lima"]
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
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
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
        return nil
    }

    private func bsdNames(for path: String, uuid: String) -> [String] {
        if let cached = bsdCache[uuid], cached.path == path {
            return cached.names
        }
        var names: [String] = []
        names.append(contentsOf: daNames(for: path))
        var s = statfs()
        if statfs(path, &s) == 0 {
            let raw = mntfrom(&s)
            var slice = raw.split(separator: "/").last.map(String.init) ?? raw
            if slice.hasPrefix("/dev/") { slice = String(slice.dropFirst(5)) }
            if slice.hasPrefix("disk") { names.append(slice) }
            if let parent = wholeDisk(slice) { names.append(parent) }
            names.append(contentsOf: physicalNames(from: slice))
        }
        if !uuid.isEmpty { names.append(uuid) }
        var seen = Set<String>()
        names = names.filter { seen.insert($0).inserted && !$0.isEmpty }
        bsdCache[uuid] = (path, names)
        return names
    }

    private func diskSession() -> DASession? {
        if let daSession { return daSession }
        daSession = DASessionCreate(kCFAllocatorDefault)
        return daSession
    }

    /// Appear / disappear / volume-path change — not a 12s poll.
    /// Initial `appeared` flood is ignored until daReady.
    private func armDiskArbitration() {
        guard let session = diskSession() else { return }
        DASessionSetDispatchQueue(session, DispatchQueue.main)
        DARegisterDiskAppearedCallback(session, nil, { _, _ in
            DiskMonitor.shared.noteHotPlug()
        }, nil)
        DARegisterDiskDisappearedCallback(session, nil, { _, _ in
            DiskMonitor.shared.noteHotPlug()
        }, nil)
        let watch = [kDADiskDescriptionVolumePathKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, watch, { _, _, _ in
            DiskMonitor.shared.noteHotPlug()
        }, nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.daReady = true
        }
    }

    /// Fixed + External PCI-E / USB SSDs are external. Do not require ejectable.
    private func classify(url: URL, values: URLResourceValues) -> DiskKind {
        if let kind = daKind(url) { return kind }
        if values.volumeIsInternal == false { return .external }
        if values.volumeIsEjectable == true || values.volumeIsRemovable == true { return .external }
        return .internalDrive
    }

    private func daKind(_ url: URL) -> DiskKind? {
        guard let session = diskSession() else { return nil }
        let cfURL = url as CFURL
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, cfURL),
              let raw = DADiskCopyDescription(disk)
        else { return nil }
        let desc = raw as NSDictionary
        if desc[kDADiskDescriptionVolumeNetworkKey] as? Bool == true { return nil }

        let proto = ((desc[kDADiskDescriptionDeviceProtocolKey] as? String) ?? "").lowercased()
        if proto.contains("usb")
            || proto.contains("thunderbolt")
            || proto.contains("firewire")
            || proto.contains("secure digital")
        {
            return .external
        }

        if let deviceInternal = desc[kDADiskDescriptionDeviceInternalKey] as? Bool {
            return deviceInternal ? .internalDrive : .external
        }
        return nil
    }

    /// DiskArbitration BSD + whole-disk name. More stable than peeling statfs
    /// (`/dev/disk3s5` vs APFS container paths).
    private func daNames(for path: String) -> [String] {
        guard let session = diskSession() else { return [] }
        let url = URL(fileURLWithPath: path, isDirectory: true) as CFURL
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url) else { return [] }
        var names: [String] = []
        if let cstr = DADiskGetBSDName(disk) {
            let bsd = String(cString: cstr)
            if bsd.hasPrefix("disk") { names.append(bsd) }
            if let parent = wholeDisk(bsd) { names.append(parent) }
        }
        if let whole = DADiskCopyWholeDisk(disk), let cstr = DADiskGetBSDName(whole) {
            let bsd = String(cString: cstr)
            if bsd.hasPrefix("disk") { names.append(bsd) }
        }
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
            if let uuid = cfString(child, "UUID"), !uuid.isEmpty {
                names.append(uuid)
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

    /// One-shot SMART / bus / temperature. Never call from the 3s I/O timer.
    func health(uuid: String, path: String) -> DiskHealth {
        var smart = "SMART unavailable"
        var bus = ""
        var notes: [String] = []

        if let session = DASessionCreate(kCFAllocatorDefault) {
            let url = URL(fileURLWithPath: path, isDirectory: true) as CFURL
            if let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url),
               let raw = DADiskCopyDescription(disk)
            {
                let desc = raw as NSDictionary
                if let proto = desc["DADeviceProtocol"] as? String, !proto.isEmpty {
                    bus = proto
                }
                if let model = desc["DADeviceModel"] as? String, !model.isEmpty {
                    notes.append(model.trimmingCharacters(in: .whitespaces))
                }
                if desc["DADeviceInternal"] as? Bool == true { notes.append("internal") }
                if desc["DAMediaEjectable"] as? Bool == true { notes.append("ejectable") }
            }
        }

        if let info = diskutilInfo(path) {
            if let status = info["SMARTStatus"] as? String, !status.isEmpty {
                switch status.lowercased() {
                case "verified": smart = "SMART verified"
                case "failing", "failing now": smart = "SMART failing"
                case "not supported": smart = "SMART not supported"
                default: smart = "SMART \(status)"
                }
            }
            if let proto = info["BusProtocol"] as? String, !proto.isEmpty { bus = proto }
            if let solid = info["SolidState"] as? Bool {
                notes.append(solid ? "SSD" : "HDD")
            }
        }

        var seen = Set<String>()
        notes = notes.filter { seen.insert($0.lowercased()).inserted }
        return DiskHealth(
            smart: smart,
            bus: bus,
            temperature: nil,
            note: notes.joined(separator: " · ")
        )
    }

    private func diskutilInfo(_ path: String) -> [String: Any]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["info", "-plist", path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard task.terminationStatus == 0, !data.isEmpty else { return nil }
            var fmt = PropertyListSerialization.PropertyListFormat.xml
            return try PropertyListSerialization.propertyList(from: data, options: [], format: &fmt) as? [String: Any]
        } catch {
            return nil
        }
    }
}
