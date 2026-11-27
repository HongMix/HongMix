import Foundation
import IOKit
import Darwin

/// Whole-Mac CPU %, GPU % and RAM for the top bar, sampled once a second off the main thread.
/// GPU: Apple Silicon's GPU driver publishes "Device Utilization %" in its IORegistry PerformanceStatistics
/// (no special rights needed); where it is missing the GPU chip stays hidden.
final class SystemLoad: ObservableObject {
    static let shared = SystemLoad()

    @Published private(set) var cpu: Double = 0           // %
    @Published private(set) var gpu: Double? = nil        // %
    @Published private(set) var ramUsed: Double = 0       // bytes
    @Published private(set) var appRAM: Double = 0        // bytes, this app
    let ramTotal = Double(ProcessInfo.processInfo.physicalMemory)

    private var prevTicks: (busy: UInt64, total: UInt64)?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "HongMix.systemload", qos: .utility)

    private init() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    private func sample() {
        let c = cpuPercent()
        let g = Self.gpuPercent()
        let r = Self.ramUsedBytes()
        let a = Self.appFootprint()
        DispatchQueue.main.async {
            if let c { self.cpu = c }
            self.gpu = g
            self.ramUsed = r
            self.appRAM = a
        }
    }

    /// Busy share of all cores since the previous sample.
    private func cpuPercent() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let now = (busy: user + sys + nice, total: user + sys + idle + nice)
        defer { prevTicks = now }
        guard let p = prevTicks, now.total > p.total else { return nil }
        return Double(now.busy - p.busy) / Double(now.total - p.total) * 100
    }

    /// Like Activity Monitor's "Memory Used": app memory + wired + compressed.
    private static func ramUsedBytes() -> Double {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = Double(vm_kernel_page_size)
        let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
        return (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
    }

    private static func appFootprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) : 0
    }

    private static func gpuPercent() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double?
        while case let entry = IOIteratorNext(it), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let u = stats["Device Utilization %"] as? NSNumber else { continue }
            best = max(best ?? 0, u.doubleValue)
        }
        return best
    }
}
