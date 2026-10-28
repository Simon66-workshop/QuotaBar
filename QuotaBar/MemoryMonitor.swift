import Foundation
#if os(macOS)
import Darwin

enum MemoryMonitor {
    /// A single Mach sample; no process walks, subprocesses, or extra timer.
    static func snapshot() -> MemoryUsage? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS, total > 0 else { return nil }

        // Exact requested Memory Used formula. Speculative/free/inactive pages
        // are not added; purgeable pages get no separate subtraction or addition.
        // Count the compressor's physical footprint, not its uncompressed pages.
        let usedPages = UInt64(stats.active_count) + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        return MemoryUsage(usedBytes: usedPages * UInt64(pageSize), totalBytes: total)
    }
}
#endif
