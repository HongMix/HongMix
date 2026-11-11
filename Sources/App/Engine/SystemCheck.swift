import Foundation
import AppKit
import IOKit
import IOKit.ps
import Network
import SystemConfiguration
import CoreWLAN
import AVFoundation

/// Pre-show check: what this Mac looks like right now (chip, CPU/GPU load, memory, disk, battery,
/// every network connection with its IP and internet speed, remote-control addresses, devices).
/// Shown once after launch (StartupCheckView); nothing here changes any setting.
final class SystemCheck: ObservableObject {
    static let shared = SystemCheck()

    struct MacInfo {
        var model = "Mac"
        var chip = ""
        var macOS = ""
        var perfCores = 0
        var effCores = 0
        var gpuCores: Int?
        var neuralCores: Int?
        var memoryGB = 0
    }

    struct Usage {
        var cpu: Double = 0             // 0…1
        var gpu: Double?                // 0…1
        var memUsed: Double = 0         // bytes
        var memTotal: Double = 1
        var diskFree: Double = 0
        var diskTotal: Double = 1
        var diskName = ""
        var battery: Int?               // %
        var onAC = true
        var charging = false
        var minutesLeft: Int?
        var thermal: ProcessInfo.ThermalState = .nominal
    }

    enum IfaceKind { case ethernet, wifi, other }

    struct Iface: Identifiable {
        let id: String                  // BSD name (en0 …)
        var name: String
        var kind: IfaceKind
        var ip: String?
        var linkMbps: Int?
        var running = false
        /// Ethernet port whose cable is out (the port reports a medium but no link).
        var cableOut = false
        var expensive = false           // hotspot / metered
        var internet: Bool?             // nil = not checked yet
        var down: Double?               // Mbit/s
        var up: Double?
        var latencyMs: Double?
        var testing = false
        var selfAssigned: Bool { ip?.hasPrefix("169.254.") ?? false }
    }

    struct Warning: Identifiable { let id = UUID(); let text: String }

    @Published var mac = MacInfo()
    @Published var usage = Usage()
    @Published var ifaces: [Iface] = []
    @Published var publicIP: String?
    @Published var speedRunning = false
    @Published var speedSeconds: Double = 0
    @Published var checkedAt: Date?

    static let internetCheckKey = "startupCheckInternet"
    static let showAtLaunchKey = "startupCheckShow"
    /// Speed test + public IP use an outside server (Cloudflare); can be turned off.
    var internetCheck: Bool {
        get { UserDefaults.standard.object(forKey: Self.internetCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.internetCheckKey); objectWillChange.send() }
    }
    static var showAtLaunch: Bool {
        get { UserDefaults.standard.object(forKey: showAtLaunchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showAtLaunchKey) }
    }

    private let queue = DispatchQueue(label: "hongmix.systemcheck", qos: .utility)
    private var generation = 0

    // MARK: - Run

    func run(recordFolder: String) {
        generation += 1
        let gen = generation
        queue.async {
            let mac = Self.macInfo()
            let usage = Self.usage(recordFolder: recordFolder)
            let ifaces = Self.interfaces()
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.mac = mac
                self.usage = usage
                self.ifaces = ifaces
                self.publicIP = nil
                self.checkedAt = Date()
                self.startNetworkTests(gen: gen)
            }
        }
    }

    /// Internet check + speed test, one connection after another (parallel tests would share the uplink).
    private func startNetworkTests(gen: Int) {
        let candidates = ifaces.filter { $0.ip != nil && !$0.selfAssigned }
        guard internetCheck, !candidates.isEmpty else {
            for i in ifaces.indices where ifaces[i].ip != nil { ifaces[i].internet = nil }
            return
        }
        speedRunning = true
        speedSeconds = 0
        let t0 = CACurrentMediaTime()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self = self, self.speedRunning, gen == self.generation else { t.invalidate(); return }
            self.speedSeconds = CACurrentMediaTime() - t0
        }
        func next(_ k: Int) {
            guard gen == generation else { timer.invalidate(); return }
            guard k < candidates.count else {
                speedRunning = false
                speedSeconds = CACurrentMediaTime() - t0
                timer.invalidate()
                return
            }
            let bsd = candidates[k].id
            guard let idx = ifaces.firstIndex(where: { $0.id == bsd }) else { next(k + 1); return }
            ifaces[idx].testing = true
            SpeedProbe.test(bsdName: bsd) { [weak self] result in
                guard let self = self, gen == self.generation,
                      let i = self.ifaces.firstIndex(where: { $0.id == bsd }) else { return }
                self.ifaces[i].testing = false
                self.ifaces[i].expensive = result.expensive
                self.ifaces[i].internet = result.internet
                self.ifaces[i].latencyMs = result.latencyMs
                self.ifaces[i].down = result.down
                self.ifaces[i].up = result.up
                if self.publicIP == nil, let ip = result.publicIP { self.publicIP = ip }
                next(k + 1)
            } progress: { [weak self] down, up in
                guard let self = self, gen == self.generation,
                      let i = self.ifaces.firstIndex(where: { $0.id == bsd }) else { return }
                if let d = down { self.ifaces[i].down = d }
                if let u = up { self.ifaces[i].up = u }
            }
        }
        next(0)
    }

    // MARK: - Warnings

    func warnings(engine: SwitcherEngine) -> [Warning] {
        var w: [Warning] = []
        let u = usage
        if u.battery != nil && !u.onAC { w.append(Warning(text: L("전원 어댑터가 연결되지 않았습니다"))) }
        if let b = u.battery, b < 30, !u.onAC { w.append(Warning(text: Lf("배터리가 %@%% 남았습니다", "\(b)"))) }
        if u.diskTotal > 1, u.diskFree < 20e9 || u.diskFree / u.diskTotal < 0.1 {
            w.append(Warning(text: Lf("녹화 디스크 여유 공간이 부족합니다 (%@)", Self.bytes(u.diskFree))))
        }
        if u.memTotal > 1, (u.memTotal - u.memUsed) / u.memTotal < 0.1 { w.append(Warning(text: L("메모리 여유가 10% 미만입니다"))) }
        if u.thermal == .serious || u.thermal == .critical { w.append(Warning(text: L("맥이 뜨겁습니다 — 성능이 떨어질 수 있습니다"))) }
        for i in ifaces where i.cableOut {
            w.append(Warning(text: Lf("%@ 케이블 연결 안 됨", i.name)))
        }
        let need = Self.streamKbps(engine)
        if need > 0, let up = ifaces.compactMap({ $0.up }).max(), up * 1000 < Double(need) * 1.5 {
            w.append(Warning(text: Lf("업로드 속도가 송출 비트레이트(%@)에 비해 부족합니다", Self.mbps(Double(need) / 1000))))
        }
        if NSScreen.screens.count > 1, !Self.separateSpaces {
            w.append(Warning(text: L("'디스플레이마다 별도의 Spaces'가 꺼져 있습니다")))
        }
        return w
    }

    static func streamKbps(_ engine: SwitcherEngine) -> Int {
        engine.outputs.filter { $0.config.kind == .stream }.map { $0.config.videoKbps + $0.config.audioKbps }.reduce(0, +)
    }

    static var separateSpaces: Bool {
        !(UserDefaults(suiteName: "com.apple.spaces")?.bool(forKey: "spans-displays") ?? false)
    }

    // MARK: - Mac

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return 0 }
        return Int(v)
    }

    static func macInfo() -> MacInfo {
        var m = MacInfo()
        m.chip = sysctlString("machdep.cpu.brand_string")
        m.perfCores = sysctlInt("hw.perflevel0.physicalcpu")
        m.effCores = sysctlInt("hw.perflevel1.physicalcpu")
        if m.perfCores == 0 { m.perfCores = sysctlInt("hw.physicalcpu") }
        m.memoryGB = Int((Double(sysctlInt("hw.memsize")) / 1_073_741_824).rounded())
        let v = ProcessInfo.processInfo.operatingSystemVersion
        m.macOS = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        m.gpuCores = gpuProperty("gpu-core-count") as? Int
        // Every Apple M-series chip so far has a 16-core Neural Engine (Ultra: 32).
        if m.chip.hasPrefix("Apple M") { m.neuralCores = m.chip.contains("Ultra") ? 32 : 16 }
        m.model = modelName() ?? sysctlString("hw.model")
        return m
    }

    /// "MacBook Pro" etc. from System Information (fast with one data type).
    private static func modelName() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPHardwareDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = (j["SPHardwareDataType"] as? [[String: Any]])?.first else { return nil }
        return a["machine_name"] as? String
    }

    private static func gpuProperty(_ key: String) -> Any? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var s = IOIteratorNext(it)
        while s != 0 {
            defer { IOObjectRelease(s) }
            if let v = IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                return v
            }
            s = IOIteratorNext(it)
        }
        return nil
    }

    // MARK: - Usage

    static func usage(recordFolder: String) -> Usage {
        var u = Usage()
        u.cpu = cpuLoad()
        if let stats = gpuProperty("PerformanceStatistics") as? [String: Any],
           let pct = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? Int {
            u.gpu = Double(pct) / 100
        }
        u.memTotal = Double(sysctlInt("hw.memsize"))
        u.memUsed = memoryUsed()
        var url = URL(fileURLWithPath: (recordFolder as NSString).expandingTildeInPath)
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeLocalizedNameKey]) {
            u.diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            u.diskTotal = Double(v.volumeTotalCapacity ?? 1)
            u.diskName = v.volumeLocalizedName ?? ""
        }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                if let c = d[kIOPSCurrentCapacityKey] as? Int, let m = d[kIOPSMaxCapacityKey] as? Int, m > 0 {
                    u.battery = Int((Double(c) / Double(m) * 100).rounded())
                }
                u.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                u.charging = d[kIOPSIsChargingKey] as? Bool ?? false
                if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0, !u.onAC { u.minutesLeft = t }
            }
        }
        u.thermal = ProcessInfo.processInfo.thermalState
        return u
    }

    /// CPU busy fraction over 0.5 s, all cores.
    private static func cpuLoad() -> Double {
        func sample() -> (busy: Double, total: Double)? {
            var count: natural_t = 0
            var info: processor_info_array_t?
            var infoCount: mach_msg_type_number_t = 0
            guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
                  let info = info else { return nil }
            defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
            var busy = 0.0, total = 0.0
            for c in 0..<Int(count) {
                let base = c * Int(CPU_STATE_MAX)
                let user = Double(info[base + Int(CPU_STATE_USER)]), sys = Double(info[base + Int(CPU_STATE_SYSTEM)])
                let nice = Double(info[base + Int(CPU_STATE_NICE)]), idle = Double(info[base + Int(CPU_STATE_IDLE)])
                busy += user + sys + nice
                total += user + sys + nice + idle
            }
            return (busy, total)
        }
        guard let a = sample() else { return 0 }
        usleep(500_000)
        guard let b = sample(), b.total > a.total else { return 0 }
        return max(0, min(1, (b.busy - a.busy) / (b.total - a.total)))
    }

    /// Like Activity Monitor's "Memory Used": app memory + wired + compressed.
    private static func memoryUsed() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        return (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }

    // MARK: - Network

    static func interfaces() -> [Iface] {
        var list: [Iface] = []
        let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        for sc in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(sc) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(sc) as String? else { continue }
            let kind: IfaceKind = type == (kSCNetworkInterfaceTypeIEEE80211 as String) ? .wifi
                : type == (kSCNetworkInterfaceTypeEthernet as String) ? .ethernet : .other
            guard kind != .other else { continue }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(sc) as String?) ?? bsd
            // iPhone USB tethering etc. show up as Ethernet with "iPhone" in the name.
            list.append(Iface(id: bsd, name: name, kind: kind))
        }
        // IPv4, link state and speed from the kernel
        var addrs: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addrs) == 0, let first = addrs {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let a = p {
                defer { p = a.pointee.ifa_next }
                let bsd = String(cString: a.pointee.ifa_name)
                guard let i = list.firstIndex(where: { $0.id == bsd }), let sa = a.pointee.ifa_addr else { continue }
                let flags = Int32(a.pointee.ifa_flags)
                if (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 { list[i].running = true }
                if sa.pointee.sa_family == UInt8(AF_INET) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        list[i].ip = String(cString: host)
                    }
                } else if sa.pointee.sa_family == UInt8(AF_LINK), let data = a.pointee.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    if d.ifi_baudrate > 0 { list[i].linkMbps = Int(d.ifi_baudrate / 1_000_000) }
                }
            }
            freeifaddrs(first)
        }
        if let wifi = CWWiFiClient.shared().interface(), let i = list.firstIndex(where: { $0.id == wifi.interfaceName }) {
            if wifi.powerOn(), wifi.transmitRate() > 0 { list[i].linkMbps = Int(wifi.transmitRate()) }
            if !wifi.powerOn() { list[i].running = false; list[i].ip = nil }
        }
        // Keep what an operator cares about: connected interfaces, Ethernet ports with a cable but no IP,
        // and real Ethernet ports whose cable is out. Thunderbolt Bridge ports, tethered iPhone/iPad and the
        // Mac's internal "Ethernet Adapter (enX)" entries are hidden unless they actually have an address.
        for i in list.indices where list[i].kind == .ethernet && list[i].ip == nil {
            list[i].cableOut = linkState(list[i].id) == false
        }
        list = list.filter { i in
            if i.ip != nil { return true }
            if i.kind == .wifi { return true }
            let n = i.name
            let virtual = n.hasPrefix("Thunderbolt") || n.contains("iPhone") || n.contains("iPad")
                || n.range(of: #"\(en[0-9]+\)$"#, options: .regularExpression) != nil
            return !virtual && (i.cableOut || i.running)
        }
        // Order: connected first, Ethernet before Wi-Fi, then by name
        return list.sorted {
            if ($0.ip != nil) != ($1.ip != nil) { return $0.ip != nil }
            if $0.kind != $1.kind { return $0.kind == .ethernet }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Ethernet link from the driver: true = link up, false = medium present but no link (cable out),
    /// nil = the interface reports no medium at all (virtual).
    private static func linkState(_ bsd: String) -> Bool? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var req = ifmediareq()
        withUnsafeMutableBytes(of: &req.ifm_name) { buf in
            _ = bsd.utf8CString.withUnsafeBytes { src in memcpy(buf.baseAddress, src.baseAddress, min(buf.count - 1, src.count)) }
        }
        // SIOCGIFMEDIA = _IOWR('i', 56, struct ifmediareq)
        let SIOCGIFMEDIA: UInt = 0xC000_0000 | (UInt(MemoryLayout<ifmediareq>.size & 0x1FFF) << 16) | (UInt(UInt8(ascii: "i")) << 8) | 56
        guard ioctl(fd, SIOCGIFMEDIA, &req) == 0 else { return nil }
        let IFM_AVALID: Int32 = 0x1, IFM_ACTIVE: Int32 = 0x2
        guard req.ifm_status & IFM_AVALID != 0 else { return nil }
        return req.ifm_status & IFM_ACTIVE != 0
    }

    /// LAN address for the remote-control lines (first connected Ethernet, else Wi-Fi).
    var primaryIP: String? {
        ifaces.first(where: { $0.ip != nil && !$0.selfAssigned && $0.internet != false })?.ip
            ?? ifaces.first(where: { $0.ip != nil })?.ip
    }

    // MARK: - Formatting

    static func bytes(_ b: Double) -> String {
        b >= 1e12 ? String(format: "%.1f TB", b / 1e12) : String(format: "%.0f GB", b / 1e9)
    }

    static func mbps(_ v: Double) -> String {
        v >= 100 ? String(format: "%.0f Mbps", v) : String(format: "%.1f Mbps", v)
    }
}

// MARK: - Speed test

/// Internet check + speed test bound to one network interface, against Cloudflare's speed servers
/// (nearest PoP, no account). Download/upload use 4 parallel connections and stop as soon as the rate
/// is steady (≥1.5 s and the last second within ±10 %), at most 5 s each.
/// Metered connections (iPhone hotspot) only get the internet check.
enum SpeedProbe {
    struct Result {
        var internet = false
        var expensive = false
        var latencyMs: Double?
        var down: Double?
        var up: Double?
        var publicIP: String?
    }

    static let host = "speed.cloudflare.com"

    static func test(bsdName: String, done: @escaping (Result) -> Void, progress: @escaping (Double?, Double?) -> Void) {
        let monitor = NWPathMonitor()
        let q = DispatchQueue(label: "hongmix.speed.\(bsdName)")
        var started = false
        monitor.pathUpdateHandler = { path in
            guard !started else { return }
            started = true
            monitor.cancel()
            guard let iface = path.availableInterfaces.first(where: { $0.name == bsdName }) else {
                DispatchQueue.main.async { done(Result()) }
                return
            }
            var r = Result()
            trace(iface, q) { ip, latency, expensive in
                r.expensive = expensive
                guard let ip = ip else { DispatchQueue.main.async { done(r) }; return }
                r.internet = true
                r.publicIP = ip
                r.latencyMs = latency
                guard !r.expensive else { DispatchQueue.main.async { done(r) }; return }
                transfer(iface, q, upload: false, report: { v in DispatchQueue.main.async { progress(v, nil) } }) { d in
                    r.down = d
                    DispatchQueue.main.async { progress(d, nil) }
                    transfer(iface, q, upload: true, report: { v in DispatchQueue.main.async { progress(nil, v) } }) { u in
                        r.up = u
                        DispatchQueue.main.async { done(r) }
                    }
                }
            }
        }
        monitor.start(queue: q)
    }

    private static func params(_ iface: NWInterface) -> NWParameters {
        let p = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        p.requiredInterface = iface
        return p
    }

    /// /cdn-cgi/trace: public IP + time to first byte (min of 3) as latency. Fails within 4 s → no internet.
    /// Also reports whether the connection is metered (iPhone hotspot etc.).
    private static func trace(_ iface: NWInterface, _ q: DispatchQueue, done: @escaping (String?, Double?, Bool) -> Void) {
        let c = NWConnection(host: NWEndpoint.Host(host), port: 443, using: params(iface))
        var finished = false
        func finish(_ ip: String?, _ l: Double?) {
            guard !finished else { return }
            finished = true
            let expensive = c.currentPath?.isExpensive ?? false
            c.cancel()
            done(ip, l, expensive)
        }
        q.asyncAfter(deadline: .now() + 4) { finish(nil, nil) }
        var times: [Double] = []
        var ip: String?
        func request() {
            let t0 = CACurrentMediaTime()
            let req = "GET /cdn-cgi/trace HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: HongMix\r\nConnection: keep-alive\r\n\r\n"
            c.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in })
            var buf = Data()
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, err in
                    if let d = data { buf.append(d) }
                    if err != nil { finish(ip, times.min()); return }
                    // complete when the body has Content-Length bytes
                    if let sep = buf.range(of: Data("\r\n\r\n".utf8)) {
                        let head = String(decoding: buf[..<sep.lowerBound], as: UTF8.self).lowercased()
                        let len = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
                        let body = buf[sep.upperBound...]
                        if let len = len, body.count >= len {
                            let text = String(decoding: body.prefix(len), as: UTF8.self)
                            for line in text.split(separator: "\n") where line.hasPrefix("ip=") { ip = String(line.dropFirst(3)) }
                            times.append((CACurrentMediaTime() - t0) * 1000)
                            if times.count >= 3 { finish(ip, times.min()) } else { request() }
                            return
                        }
                    }
                    read()
                }
            }
            read()
        }
        c.stateUpdateHandler = { st in
            switch st {
            case .ready: request()
            case .failed, .cancelled: finish(ip, times.min())
            default: break
            }
        }
        c.start(queue: q)
    }

    /// Parallel download or upload; returns Mbit/s.
    private static func transfer(_ iface: NWInterface, _ q: DispatchQueue, upload: Bool,
                                 report: @escaping (Double) -> Void, done: @escaping (Double?) -> Void) {
        let streams = 4
        let size = upload ? 30_000_000 : 99_000_000   // Cloudflare refuses downloads of 100 MB or more
        var bytes = 0
        var conns: [NWConnection] = []
        var samples: [(t: Double, b: Int)] = []
        let t0 = CACurrentMediaTime()
        var finished = false
        let chunk = Data(count: 256 * 1024)

        func rate(over window: Double) -> Double? {
            guard let last = samples.last, let first = samples.last(where: { last.t - $0.t >= window }) else { return nil }
            return Double(last.b - first.b) * 8 / (last.t - first.t) / 1e6
        }
        func finish() {
            guard !finished else { return }
            finished = true
            conns.forEach { $0.cancel() }
            let total = CACurrentMediaTime() - t0
            let r = rate(over: 1.0) ?? (total > 0.3 ? Double(bytes) * 8 / total / 1e6 : nil)
            done(r)
        }
        // sampler: every 250 ms; steady after 1.5 s → stop
        func tick() {
            guard !finished else { return }
            let t = CACurrentMediaTime() - t0
            samples.append((t, bytes))
            if let r = rate(over: 0.5) { report(r) }
            if t >= 1.5, let a = rate(over: 1.0), let b = rate(over: 0.5), a > 0, abs(b - a) / a < 0.1 { finish(); return }
            if t >= 5 || (t > 4 && bytes == 0) { finish(); return }
            q.asyncAfter(deadline: .now() + 0.25, execute: tick)
        }
        for _ in 0..<streams {
            let c = NWConnection(host: NWEndpoint.Host(host), port: 443, using: params(iface))
            conns.append(c)
            c.stateUpdateHandler = { st in
                guard case .ready = st else { return }
                if upload {
                    let head = "POST /__up HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: HongMix\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\n\r\n"
                    c.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in })
                    var sent = 0
                    func pump() {
                        guard !finished, sent < size else { return }
                        let n = min(chunk.count, size - sent)
                        c.send(content: chunk.prefix(n), completion: .contentProcessed { err in
                            guard err == nil else { return }
                            sent += n
                            bytes += n
                            pump()
                        })
                    }
                    pump()
                } else {
                    let req = "GET /__down?bytes=\(size) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: HongMix\r\nConnection: close\r\n\r\n"
                    c.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in })
                    func read() {
                        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, err in
                            if let d = data { bytes += d.count }
                            if finished || done || err != nil { return }
                            read()
                        }
                    }
                    read()
                }
            }
            c.start(queue: q)
        }
        q.asyncAfter(deadline: .now() + 0.25, execute: tick)
    }
}
