import SwiftUI
import Combine
import IOKit
import AppKit
import Darwin
import ServiceManagement
import UserNotifications

// MARK: - Apple Silicon sıcaklık sensörleri (özel/belgesiz IOHID API'leri)
@_silgen_name("IOHIDEventSystemClientCreate")
nonisolated func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventSystemClientSetMatching")
nonisolated func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
nonisolated func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
nonisolated func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDServiceClientCopyEvent")
nonisolated func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventGetFloatValue")
nonisolated func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

// MARK: - Arka planda okunan, thread'ler arası güvenle taşınan sonuç
nonisolated struct Metrics: Sendable {
    var cpu: Double
    var gpu: Double
    var memory: Double
    var socTemp: Double? = nil
    var batteryTemp: Double? = nil
    var emuCPU: Double? = nil
    var emuMemoryMB: Double? = nil
    var memPressure: Int = 1
    var swapUsedGB: Double = 0
}

// MARK: - Ağır okumalar ana thread dışında, kendi aktöründe yapılır
actor MetricsReader {
    private var prevTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var last = Metrics(cpu: 0, gpu: 0, memory: 0)
    private var hidClient: AnyObject?
    private var prevEmu: (pid: pid_t, cpuNs: UInt64, wallNs: UInt64)?

    func read(emulatorPID: pid_t?) -> Metrics {
        let t = readTemperatures()
        let e = readEmulator(pid: emulatorPID)
        last = Metrics(cpu: readCPU(), gpu: readGPU(), memory: readMemory(),
                       socTemp: t.soc, batteryTemp: t.battery,
                       emuCPU: e.cpu, emuMemoryMB: e.memMB,
                       memPressure: readPressure(), swapUsedGB: readSwapGB())
        return last
    }

    // Emülatör sürecinin kendi CPU (%) ve bellek (MB) kullanımı
    // CPU değeri çekirdek başınadır: %100 = bir çekirdeğin tamamı, 8 çekirdekte en fazla %800.
    private func readEmulator(pid: pid_t?) -> (cpu: Double?, memMB: Double?) {
        guard let pid else { prevEmu = nil; return (nil, nil) }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return (nil, nil) }

        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let cpuTicks = info.pti_total_user &+ info.pti_total_system
        let cpuNs = cpuTicks * UInt64(tb.numer) / UInt64(max(tb.denom, 1))
        let wallNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let memMB = Double(info.pti_resident_size) / 1_048_576

        let previous = prevEmu
        prevEmu = (pid, cpuNs, wallNs)
        guard let p = previous, p.pid == pid, wallNs > p.wallNs, cpuNs >= p.cpuNs else { return (nil, memMB) }
        let cpu = Double(cpuNs - p.cpuNs) / Double(wallNs - p.wallNs) * 100.0
        return (cpu, memMB)
    }

    // SoC (CPU+GPU aynı çip üzerinde) ve pil sıcaklığı (°C)
    private func readTemperatures() -> (soc: Double?, battery: Double?) {
        if hidClient == nil {
            hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue()
            if let c = hidClient {
                let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
                _ = IOHIDEventSystemClientSetMatching(c, matching as CFDictionary)
            }
        }
        guard let client = hidClient,
              let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject]
        else { return (nil, nil) }

        var dieTemps: [Double] = []
        var batteryTemp: Double?
        for service in services {
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0)?.takeRetainedValue()
            else { continue }
            let value = IOHIDEventGetFloatValue(event, Int32(15 << 16))
            guard value > 0, value < 150 else { continue }
            if name.contains("tdie") {
                dieTemps.append(value)
            } else if name.contains("battery") {
                batteryTemp = value
            }
        }
        return (dieTemps.max(), batteryTemp)
    }

    // macOS bellek baskısı seviyesi: 1 = normal, 2 = uyarı, 4 = kritik
    private func readPressure() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return Int(level)
    }

    // Kullanılan swap (diske taşınan bellek), GB
    private func readSwapGB() -> Double {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return 0 }
        return Double(swap.xsu_used) / 1_073_741_824
    }

    // Gerçek CPU kullanımı (%)
    private func readCPU() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return last.cpu }

        let now = (user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                   idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { prevTicks = now }
        guard let prev = prevTicks else { return last.cpu }

        let user = Double(now.user &- prev.user)
        let sys  = Double(now.system &- prev.system)
        let idle = Double(now.idle &- prev.idle)
        let nice = Double(now.nice &- prev.nice)
        let total = user + sys + idle + nice
        guard total > 0 else { return last.cpu }
        return (user + sys + nice) / total * 100.0
    }

    // Gerçek bellek kullanımı (%)
    private func readMemory() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return last.memory }

        let pageSize = Double(sysconf(_SC_PAGESIZE))
        let usedPages = Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return min(100, usedPages * pageSize / total * 100.0)
    }

    // Gerçek GPU kullanımı (%), IOKit
    private func readGPU() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return last.gpu }
        defer { IOObjectRelease(iterator) }

        var best = 0.0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let props = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let util = props["Device Utilization %"] as? NSNumber {
                best = max(best, util.doubleValue)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return best
    }
}

// MARK: - Ana sınıf (tamamen MainActor)
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var gpuUsage: Double = 0
    @Published private(set) var memoryUsage: Double = 0
    @Published private(set) var socTemperature: Double?
    @Published private(set) var batteryTemperature: Double?
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var isEmulatorRunning: Bool = false
    @Published private(set) var isLowPowerMode: Bool = false
    @Published private(set) var emulatorName: String?
    @Published private(set) var emulatorCPU: Double?
    @Published private(set) var emulatorMemoryMB: Double?
    @Published private(set) var sessionStart: Date?
    @Published private(set) var memoryPressure: Int = 1
    @Published private(set) var swapUsedGB: Double = 0

    /// 0 = yeşil, 1 = turuncu, 2 = kırmızı (macOS termal durumu ve SoC sıcaklığının en kötüsü)
    var heatLevel: Int {
        var level = 0
        switch thermalState {
        case .fair: level = 1
        case .serious, .critical: level = 2
        default: break
        }
        if let t = socTemperature {
            if t >= 90 { level = max(level, 2) }
            else if t >= 75 { level = max(level, 1) }
        }
        return level
    }

    var memoryPressureLabel: String {
        switch memoryPressure {
        case 2:  return "Uyarı"
        case 4:  return "Kritik"
        default: return "Normal"
        }
    }

    /// macOS'in kendi termal durumu serious/critical ise sistem kısıtlama yapıyor demektir.
    var isThrottling: Bool { thermalState == .serious || thermalState == .critical }

    var thermalLabel: String {
        switch thermalState {
        case .nominal:  return "Normal"
        case .fair:     return "Hafif Sıcak"
        case .serious:  return "Sıcak (Kısıtlama Başlayabilir)"
        case .critical: return "Kritik (Kısıtlanıyor)"
        @unknown default: return "Bilinmiyor"
        }
    }

    enum PowerMode: String, CaseIterable, Identifiable {
        case performance = "Yüksek Performans"
        case balanced = "Dengeli"
        case eco = "Güç Tasarrufu"

        var id: String { rawValue }
        var baseInterval: TimeInterval {
            switch self {
            case .performance: return 1.0
            case .balanced:    return 3.0
            case .eco:         return 8.0
            }
        }
    }

    @Published var powerMode: PowerMode = .balanced {
        didSet { rescheduleTimer() }
    }

    private let knownEmulators: Set<String> = [
        "Ryujinx", "Astris", "Eden", "Citron", "Dolphin",
        "Cemu", "Whisky", "CrossOver", "RetroArch"
    ]

    private let reader = MetricsReader()
    let gameMode = GameModeManager()
    private var hasCompletedFirstCheck = false
    private var cancellables = Set<AnyCancellable>()
    private var isSampling = false
    private var emulatorPID: pid_t?
    private var lastReminderAt: Date?
    private var lastPressure = 1
    private var lastPressureActionAt: Date?
    private nonisolated(unsafe) var timer: Timer?

    /// Gerçekte kullanılacak aralık: seçilen mod + sistem durumuna göre otomatik uzar.
    private var effectiveInterval: TimeInterval {
        var interval = powerMode.baseInterval
        if isEmulatorRunning { interval = max(interval, 10.0) }
        if isLowPowerMode    { interval = max(interval, 10.0) }
        switch thermalState {
        case .serious:  interval = max(interval, 15.0)
        case .critical: interval = max(interval, 30.0)
        default: break
        }
        return interval
    }

    init() {
        thermalState = ProcessInfo.processInfo.thermalState
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if autoFreeEnabled { requestNotificationPermission() }
        setupListeners()
        checkEmulators()
        hasCompletedFirstCheck = true
        rescheduleTimer()
    }

    deinit {
        timer?.invalidate()
    }

    private func setupListeners() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: ws.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.checkEmulators() }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.thermalState = ProcessInfo.processInfo.thermalState
                    self.rescheduleTimer()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .NSProcessInfoPowerStateDidChange)
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                    self.rescheduleTimer()
                }
            }
            .store(in: &cancellables)
    }

    private func checkEmulators() {
        let emu = NSWorkspace.shared.runningApplications.first {
            guard let name = $0.localizedName else { return false }
            return knownEmulators.contains(name)
        }
        emulatorPID = emu?.processIdentifier
        emulatorName = emu?.localizedName

        let found = emu != nil
        if found != isEmulatorRunning {
            isEmulatorRunning = found
            if found {
                sessionStart = Date()
                lastReminderAt = nil
                if hasCompletedFirstCheck {
                    if autoGameModeEnabled {
                        gameMode.activate(quitBundleIDs: savedQuitSet, monitor: self, notify: true)
                    } else if autoFreeEnabled {
                        Task { _ = await GameModeManager.unloadOllamaModels() }
                    }
                }
            } else {
                sessionStart = nil
                emulatorCPU = nil
                emulatorMemoryMB = nil
            }
            rescheduleTimer()
        }
    }

    private var autoFreeEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoFreeOllama") as? Bool ?? true
    }

    private var autoGameModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoGameMode")
    }

    private var savedQuitSet: Set<String> {
        Set((UserDefaults.standard.string(forKey: "gameModeQuitApps") ?? "")
            .split(separator: ",").map(String.init))
    }

    // MARK: Bildirim İzni İstemi GÜNCELLENDİ
    func requestNotificationPermission() {
        Task {
            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    // MARK: Bildirim Gönderme GÜNCELLENDİ
    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func handleMemoryPressure(_ level: Int) {
        defer { lastPressure = level }
        guard level >= 2, lastPressure < 2 else { return }
        if let last = lastPressureActionAt, Date().timeIntervalSince(last) < 300 { return }
        lastPressureActionAt = Date()

        Task {
            let freed = autoFreeEnabled ? await GameModeManager.unloadOllamaModels() : 0
            let body = freed > 0
                ? "\(freed) Ollama modeli bellekten atıldı. Tarayıcı sekmelerini kapatmak da yardımcı olur."
                : "Tarayıcı sekmelerini ve kullanmadığın uygulamaları kapatmak yardımcı olur."
            notify(title: "Bellek baskısı yüksek", body: body)
        }
    }

    // MARK: Mola Hatırlatıcı GÜNCELLENDİ
    private func checkBreakReminder() {
        let minutes = UserDefaults.standard.integer(forKey: "breakIntervalMinutes")
        guard minutes > 0, let start = sessionStart else { return }
        let reference = lastReminderAt ?? start
        guard Date().timeIntervalSince(reference) >= Double(minutes) * 60 else { return }

        lastReminderAt = Date()
        let played = Int(Date().timeIntervalSince(start) / 60)
        let content = UNMutableNotificationContent()
        content.title = "Mola zamanı"
        content.body = "\(played) dakikadır oynuyorsun. Mac'in soğuması için kısa bir mola ver."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        let interval = effectiveInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
        t.tolerance = interval * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        guard !isSampling else { return }
        isSampling = true
        let reader = self.reader
        let pid = emulatorPID
        Task { [weak self] in
            let m = await reader.read(emulatorPID: pid)
            guard let self else { return }
            self.apply(m)
        }
    }

    private func differs(_ a: Double?, _ b: Double?, threshold: Double = 1) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case let (x?, y?): return abs(x - y) >= threshold
        default: return true
        }
    }

    private func apply(_ m: Metrics) {
        if abs(m.cpu - cpuUsage) >= 1 { cpuUsage = m.cpu }
        if abs(m.memory - memoryUsage) >= 1 { memoryUsage = m.memory }
        if abs(m.gpu - gpuUsage) >= 1 { gpuUsage = m.gpu }
        if differs(m.socTemp, socTemperature) { socTemperature = m.socTemp }
        if differs(m.batteryTemp, batteryTemperature) { batteryTemperature = m.batteryTemp }
        if differs(m.emuCPU, emulatorCPU) { emulatorCPU = m.emuCPU }
        if differs(m.emuMemoryMB, emulatorMemoryMB, threshold: 20) { emulatorMemoryMB = m.emuMemoryMB }
        if m.memPressure != memoryPressure { memoryPressure = m.memPressure }
        if abs(m.swapUsedGB - swapUsedGB) >= 0.1 { swapUsedGB = m.swapUsedGB }
        
        handleMemoryPressure(m.memPressure)
        checkBreakReminder()
        isSampling = false
    }
}

// MARK: - Renkli menü çubuğu ikonu
nonisolated func statusDotImage(level: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
        let color: NSColor
        switch level {
        case 2:  color = .systemRed
        case 1:  color = .systemOrange
        default: color = .systemGreen
        }
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    image.isTemplate = false
    return image
}

// MARK: - Oyun Modu
struct RunningAppInfo: Identifiable {
    let id: String
    let name: String
}

@MainActor
final class GameModeManager: ObservableObject {
    @Published private(set) var status: String = ""
    @Published private(set) var isWorking = false

    private static let emulatorNames: Set<String> = [
        "Ryujinx", "Astris", "Eden", "Citron", "Dolphin",
        "Cemu", "Whisky", "CrossOver", "RetroArch"
    ]

    static func runningUserApps() -> [RunningAppInfo] {
        let myID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .compactMap { app -> RunningAppInfo? in
                guard app.activationPolicy == .regular,
                      let id = app.bundleIdentifier,
                      id != myID,
                      id != "com.apple.finder",
                      let name = app.localizedName,
                      !emulatorNames.contains(name) else { return nil }
                return RunningAppInfo(id: id, name: name)
            }
            .sorted { $0.name < $1.name }
    }

    func activate(quitBundleIDs: Set<String>, monitor: SystemMonitor, notify: Bool = false) {
        guard !isWorking else { return }
        isWorking = true
        status = "Çalışıyor…"
        monitor.powerMode = .eco

        Task {
            let unloaded = await Self.unloadOllamaModels()
            let quit = Self.quitApps(bundleIDs: quitBundleIDs)

            var parts: [String] = []
            if unloaded > 0 { parts.append("\(unloaded) Ollama modeli bellekten atıldı") }
            if quit > 0 { parts.append("\(quit) uygulama kapatıldı") }
            status = parts.isEmpty ? "Kapatılacak bir şey bulunamadı" : parts.joined(separator: " · ")
            isWorking = false

            // MARK: Bildirim Gönderme GÜNCELLENDİ
            if notify && !parts.isEmpty {
                let content = UNMutableNotificationContent()
                content.title = "Oyun Modu otomatik başladı"
                content.body = status
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
    }

    private static func quitApps(bundleIDs: Set<String>) -> Int {
        var count = 0
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, bundleIDs.contains(id),
                  let name = app.localizedName, !emulatorNames.contains(name) else { continue }
            if app.terminate() { count += 1 }
        }
        return count
    }

    nonisolated static func unloadOllamaModels() async -> Int {
        guard let psURL = URL(string: "http://localhost:11434/api/ps"),
              let genURL = URL(string: "http://localhost:11434/api/generate") else { return 0 }

        var psRequest = URLRequest(url: psURL)
        psRequest.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: psRequest),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return 0 }

        var count = 0
        for model in models {
            guard let name = model["name"] as? String else { continue }
            var request = URLRequest(url: genURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: ["model": name, "keep_alive": 0] as [String: Any])
            if (try? await URLSession.shared.data(for: request)) != nil { count += 1 }
        }
        return count
    }
}

// MARK: - Menü çubuğu açılır paneli
struct ContentView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var gameMode: GameModeManager
    @AppStorage("showTempInMenuBar") private var showTempInMenuBar = false
    @AppStorage("gameModeQuitApps") private var quitList = ""
    @AppStorage("breakIntervalMinutes") private var breakMinutes = 0
    @AppStorage("autoFreeOllama") private var autoFreeOllama = true
    @AppStorage("autoGameMode") private var autoGameMode = false
    @State private var runningApps: [RunningAppInfo] = []
    @State private var appsExpanded = false
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    private var quitSet: Set<String> {
        Set(quitList.split(separator: ",").map(String.init))
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { quitSet.contains(id) },
            set: { isOn in
                var set = quitSet
                if isOn { set.insert(id) } else { set.remove(id) }
                quitList = set.sorted().joined(separator: ",")
            }
        )
    }

    private func tempText(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))°C" } ?? "Okunamadı"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sistem Durumu")
                .font(.headline)

            Divider()

            Text("CPU: \(Int(monitor.cpuUsage))%")
            Text("GPU: \(Int(monitor.gpuUsage))%")
            Text("Bellek: \(Int(monitor.memoryUsage))%")
            Text("Bellek baskısı: \(monitor.memoryPressureLabel) · Swap: \(String(format: "%.1f", monitor.swapUsedGB)) GB")
                .font(.caption)
            Text("SoC (CPU/GPU) ısısı: \(tempText(monitor.socTemperature))")
            Text("Pil ısısı: \(tempText(monitor.batteryTemperature))")
            Text("Isı durumu: \(monitor.thermalLabel)")
            Text("Emülatör: \(monitor.isEmulatorRunning ? "Açık" : "Kapalı")")

            if let name = monitor.emulatorName {
                Text("\(name): CPU \(monitor.emulatorCPU.map { "\(Int($0.rounded()))%" } ?? "…") · RAM \(monitor.emulatorMemoryMB.map { "\(Int($0.rounded())) MB" } ?? "…")")
                    .font(.caption)
                if let start = monitor.sessionStart {
                    HStack(spacing: 4) {
                        Text("Oyun süresi:")
                        Text(start, style: .timer)
                    }
                    .font(.caption)
                }
            }

            Divider()

            Picker("Mod", selection: $monitor.powerMode) {
                ForEach(SystemMonitor.PowerMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            Toggle("Menü çubuğunda ısıyı göster", isOn: $showTempInMenuBar)

            Toggle("Ollama'yı otomatik boşalt", isOn: $autoFreeOllama)

            Picker("Mola hatırlatıcı", selection: $breakMinutes) {
                Text("Kapalı").tag(0)
                Text("30 dk").tag(30)
                Text("45 dk").tag(45)
                Text("60 dk").tag(60)
            }
            .onChange(of: breakMinutes) { _, minutes in
                if minutes > 0 { monitor.requestNotificationPermission() }
            }

            Toggle("Girişte otomatik başlat", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    guard (SMAppService.mainApp.status == .enabled) != enabled else { return }
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                }

            Divider()

            Button {
                gameMode.activate(quitBundleIDs: quitSet, monitor: monitor)
            } label: {
                Label("Oyun Modunu Başlat", systemImage: "gamecontroller.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(gameMode.isWorking)

            if !gameMode.status.isEmpty {
                Text(gameMode.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Emülatör açılınca otomatik başlat", isOn: $autoGameMode)
                .onChange(of: autoGameMode) { _, enabled in
                    if enabled { monitor.requestNotificationPermission() }
                }

            DisclosureGroup("Kapatılacak uygulamalar", isExpanded: $appsExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if runningApps.isEmpty {
                            Text("Açık uygulama yok")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(runningApps) { app in
                            Toggle(app.name, isOn: binding(for: app.id))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            .onChange(of: appsExpanded) { _, expanded in
                if expanded { runningApps = GameModeManager.runningUserApps() }
            }

            Divider()

            Button("Çıkış") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

// MARK: - Uygulama girişi (menü çubuğu uygulaması)
@main
struct MonitorApp: App {
    @StateObject private var monitor = SystemMonitor()
    @AppStorage("showTempInMenuBar") private var showTempInMenuBar = false

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private var menuBarText: String {
        let cpu = "\(Int(monitor.cpuUsage))%"
        if showTempInMenuBar, let t = monitor.socTemperature {
            return "\(cpu) · \(Int(t.rounded()))°"
        }
        return cpu
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(monitor.gameMode)
        } label: {
            Image(nsImage: statusDotImage(level: monitor.heatLevel))
            Text(menuBarText)
        }
        .menuBarExtraStyle(.window)
    }
}
