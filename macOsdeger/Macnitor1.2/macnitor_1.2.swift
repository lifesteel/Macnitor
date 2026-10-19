import SwiftUI
import Combine
import IOKit
import AppKit
import Darwin
import ServiceManagement
import UserNotifications

// MARK: - Kısayol modeli
nonisolated enum ShortcutKind: String, Sendable {
    case screenshot
    case launcher

    var fileName: String { "\(rawValue).json" }

    var defaultValue: Shortcut {
        switch self {
        case .screenshot:   // ⌃⌥⌘ basılı tut
            return Shortcut(modifiers: NSEvent.ModifierFlags([.command, .option, .control]).rawValue, keyCode: nil, keyLabel: nil)
        case .launcher:     // ⌘ tek başına bas-bırak
            return Shortcut(modifiers: NSEvent.ModifierFlags.command.rawValue, keyCode: nil, keyLabel: nil)
        }
    }

    /// Sadece modifier ile kaydedilirken gereken en az modifier sayısı
    var minModifiers: Int { self == .launcher ? 1 : 2 }
}

nonisolated struct Shortcut: Codable, Equatable, Sendable {
    var modifiers: UInt          // sadece ⌃⌥⇧⌘ bitleri
    var keyCode: UInt16?         // nil ise sadece modifier kısayolu
    var keyLabel: String?

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private static func fileURL(_ kind: ShortcutKind) -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Macnitor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(kind.fileName)
    }

    static func load(_ kind: ShortcutKind) -> Shortcut {
        guard let data = try? Data(contentsOf: fileURL(kind)),
              let s = try? JSONDecoder().decode(Shortcut.self, from: data) else { return kind.defaultValue }
        return s
    }

    func save(_ kind: ShortcutKind) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL(kind), options: .atomic)
    }

    var display: String {
        let f = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + (keyLabel ?? "")
    }

    static func label(for e: NSEvent) -> String {
        switch e.keyCode {
        case 49: return "Boşluk"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let c = (e.charactersIgnoringModifiers ?? "").uppercased()
            if let u = c.unicodeScalars.first, (0xF700...0xF8FF).contains(u.value) || c.isEmpty {
                return "Tuş \(e.keyCode)"   // F tuşları vb.
            }
            return c
        }
    }
}

// MARK: - Apple Silicon sıcaklık sensörleri
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

// MARK: - Tek merkezde emülatör listesi
nonisolated enum EmulatorCatalog {
    static let names: Set<String> = [
        "Ryujinx", "Astris", "Eden", "Citron", "Dolphin",
        "Cemu", "Whisky", "CrossOver", "RetroArch"
    ]
}

// MARK: - Sıcaklık okuma durumu
nonisolated enum TemperatureStatus: String, Sendable {
    case ok = "Okunuyor"
    case sensorNotFound = "Sensör bulunamadı"
    case clientCreateFailed = "IOHID istemcisi oluşturulamadı"
    case readFailed = "Sıcaklık okunamadı"
}

// MARK: - Menü çubuğu metrik seçimi
nonisolated enum MenuBarMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "Bellek"
    case temperature = "Isı"

    var id: String { rawValue }

    static let storageKey = "menuBarMetrics"
    static let defaultValues: Set<String> = [MenuBarMetric.cpu.rawValue]
}

// MARK: - Arka planda okunan sonuç
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
    var tempStatus: TemperatureStatus = .readFailed
}

// MARK: - NSImage Cache
nonisolated private let cachedDotGreen = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in NSColor.systemGreen.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true }
nonisolated private let cachedDotOrange = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true }
nonisolated private let cachedDotRed = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in NSColor.systemRed.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true }

nonisolated func statusDotImage(level: Int) -> NSImage {
    let img: NSImage
    switch level {
    case 2:  img = cachedDotRed
    case 1:  img = cachedDotOrange
    default: img = cachedDotGreen
    }
    img.isTemplate = false
    return img
}

// MARK: - Ağır okumalar
actor MetricsReader {
    private var prevTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var last = Metrics(cpu: 0, gpu: 0, memory: 0)
    private var hidClient: AnyObject?
    private var prevEmu: (pid: pid_t, cpuNs: UInt64, wallNs: UInt64)?
    private var lastHIDAttempt: Date = .distantPast
    private let hidRetryInterval: TimeInterval = 30
    private var hasBattery: Bool? = nil

    func read(emulatorPID: pid_t?) -> Metrics {
        let t = readTemperatures()
        let e = readEmulator(pid: emulatorPID)
        last = Metrics(cpu: readCPU(), gpu: readGPU(), memory: readMemory(),
                       socTemp: t.soc, batteryTemp: t.battery,
                       emuCPU: e.cpu, emuMemoryMB: e.memMB,
                       memPressure: readPressure(), swapUsedGB: readSwapGB(),
                       tempStatus: t.status)
        return last
    }

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

    private func readTemperatures() -> (soc: Double?, battery: Double?, status: TemperatureStatus) {
        let now = Date()
        if hidClient == nil || now.timeIntervalSince(lastHIDAttempt) >= hidRetryInterval {
            lastHIDAttempt = now
            if let raw = IOHIDEventSystemClientCreate(kCFAllocatorDefault) {
                let client = raw.takeRetainedValue()
                let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
                _ = IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
                hidClient = client
            } else {
                hidClient = nil
            }
        }

        guard let client = hidClient else { return (nil, nil, .clientCreateFailed) }
        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject], !services.isEmpty else {
            return (nil, nil, .sensorNotFound)
        }

        var dieTemps: [Double] = []
        var batteryTemp: Double?
        for service in services {
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0)?.takeRetainedValue()
            else { continue }
            let value = IOHIDEventGetFloatValue(event, Int32(15 << 16))
            guard value > 0, value < 150 else { continue }
            if name.contains("tdie") { dieTemps.append(value) }
            else if name.contains("battery") { batteryTemp = value }
        }

        if batteryTemp == nil { batteryTemp = readSmartBatteryTemp() }

        if dieTemps.isEmpty && batteryTemp == nil { return (nil, nil, .readFailed) }
        return (dieTemps.max(), batteryTemp, .ok)
    }

    private func readSmartBatteryTemp() -> Double? {
        if hasBattery == nil {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            hasBattery = (service != 0)
            if service != 0 { IOObjectRelease(service) }
        }
        guard hasBattery == true else { return nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanagedProps: Unmanaged<CFMutableDictionary>? = nil
        let result = IORegistryEntryCreateCFProperties(service, &unmanagedProps, kCFAllocatorDefault, 0)

        guard result == KERN_SUCCESS, let props = unmanagedProps?.takeRetainedValue() as? [String: Any] else { return nil }
        guard let temp = props["Temperature"] as? Int else { return nil }

        let celsius = Double(temp) / 10.0 - 273.15
        if celsius > 0 && celsius < 100 { return celsius }
        let directC = Double(temp) / 10.0
        if directC > 0 && directC < 100 { return directC }
        return nil
    }

    private func readPressure() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return Int(level)
    }

    private func readSwapGB() -> Double {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return 0 }
        return Double(swap.xsu_used) / 1_073_741_824
    }

    private func readCPU() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return last.cpu }

        let now = (user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
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

    private func readGPU() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return last.gpu }
        defer { IOObjectRelease(iterator) }

        var best = 0.0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let props = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let util = props["Device Utilization %"] as? NSNumber {
                best = max(best, util.doubleValue)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return best
    }
}

// MARK: - Ana sınıf
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
    @Published private(set) var tempStatus: TemperatureStatus = .readFailed
    @Published private(set) var notificationAuthStatus: UNAuthorizationStatus = .notDetermined

    // Kısayol
    @Published private(set) var hasInputMonitoring: Bool = false
    @Published private(set) var shortcut: Shortcut = Shortcut.load(.screenshot)
    @Published private(set) var launcherShortcut: Shortcut = Shortcut.load(.launcher)
    @Published private(set) var recordingTarget: ShortcutKind?
    @Published var launcherEnabled: Bool = UserDefaults.standard.object(forKey: "launcherEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(launcherEnabled, forKey: "launcherEnabled") }
    }
    let launcher = LauncherController()

    @Published var selectedMetrics: Set<MenuBarMetric> = Set()
    @Published var highTempThreshold: Double = 90.0
    @Published var medTempThreshold: Double = 75.0

    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private var recordMonitor: Any?
    private var tapCandidate = false
    private var tapStart: Date = .distantPast
    private var recordPeak: NSEvent.ModifierFlags = []
    private var pendingModifierFire: DispatchWorkItem?
    private var lastScreenshotAt: Date = .distantPast

    var heatLevel: Int {
        var level = 0
        switch thermalState {
        case .fair: level = 1
        case .serious, .critical: level = 2
        default: break
        }
        if let t = socTemperature {
            if t >= highTempThreshold { level = max(level, 2) }
            else if t >= medTempThreshold { level = max(level, 1) }
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

    private let knownEmulators = EmulatorCatalog.names
    private let reader = MetricsReader()
    let gameMode = GameModeManager()
    private var hasCompletedFirstCheck = false
    private var cancellables = Set<AnyCancellable>()
    private var isSampling = false
    private var emulatorPID: pid_t?
    private var lastReminderAt: Date?
    private var lastPressure = 1
    private var lastPressureActionAt: Date?
    private var lastSwapWarningAt: Date?
    private nonisolated(unsafe) var timer: Timer?

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
        let saved = UserDefaults.standard.stringArray(forKey: MenuBarMetric.storageKey) ?? Array(MenuBarMetric.defaultValues)
        self.selectedMetrics = Set(saved.compactMap { MenuBarMetric(rawValue: $0) })
        self.highTempThreshold = UserDefaults.standard.object(forKey: "highTempThreshold") as? Double ?? 90.0
        self.medTempThreshold = UserDefaults.standard.object(forKey: "medTempThreshold") as? Double ?? 75.0

        thermalState = ProcessInfo.processInfo.thermalState
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        refreshPermissions()

        setupListeners()
        checkEmulators()
        hasCompletedFirstCheck = true
        rescheduleTimer()
        refreshNotificationAuthStatus(requestIfNeeded: true)

        setupShortcutMonitors()
    }

    // MARK: Kısayol dinleme (uygulama içinde)

    func refreshPermissions() {
        hasInputMonitoring = CGPreflightListenEventAccess()
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunchApp() {
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
        let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]
        task.launch()
        NSApplication.shared.terminate(nil)
    }

    private func setupShortcutMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlags(event)
        }) { globalMonitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleKey(event)
        }) { globalMonitors.append(m) }

        // Uygulama (ör. başlatıcı paneli) odaktayken de aynı kısayollar çalışsın
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlags(event)
            return event
        }) { localMonitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleKey(event)
            return event
        }) { localMonitors.append(m) }
    }

    private func handleFlags(_ e: NSEvent) {
        handleShortcutFlags(e)
        handleLauncherFlags(e)
    }

    private func handleKey(_ e: NSEvent) {
        tapCandidate = false
        handleShortcutKey(e)
        handleLauncherKey(e)
    }

    // MARK: Ekran görüntüsü kısayolu

    // Sadece modifier kısayolu: kombinasyon 0,3 sn başka tuş olmadan basılı kalırsa tetiklenir
    private func handleShortcutFlags(_ e: NSEvent) {
        pendingModifierFire?.cancel()
        guard recordingTarget == nil, shortcut.keyCode == nil else { return }
        let flags = e.modifierFlags.intersection(Shortcut.relevant)
        guard flags.rawValue == shortcut.modifiers else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fireScreenshotShortcut() }
        }
        pendingModifierFire = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // Modifier + tuş kısayolu
    private func handleShortcutKey(_ e: NSEvent) {
        pendingModifierFire?.cancel()   // araya normal tuş girdiyse modifier-only kısayol iptal
        guard recordingTarget == nil, let code = shortcut.keyCode, !e.isARepeat, e.keyCode == code else { return }
        guard e.modifierFlags.intersection(Shortcut.relevant).rawValue == shortcut.modifiers else { return }
        fireScreenshotShortcut()
    }

    private func fireScreenshotShortcut() {
        guard Date().timeIntervalSince(lastScreenshotAt) > 1.2 else { return }
        lastScreenshotAt = Date()
        takeScreenshotToClipboard()
    }

    // MARK: Uygulama başlatıcı kısayolu

    // Sadece modifier: Windows tuşu gibi, basıp bırakınca (arada başka girdi olmadan) tetiklenir
    private func handleLauncherFlags(_ e: NSEvent) {
        guard launcherEnabled, recordingTarget == nil, launcherShortcut.keyCode == nil else {
            tapCandidate = false
            return
        }
        let target = launcherShortcut.modifiers
        let flags = e.modifierFlags.intersection(Shortcut.relevant).rawValue

        if flags == target {
            if !tapCandidate { tapCandidate = true; tapStart = Date() }
        } else if tapCandidate {
            tapCandidate = false
            let elapsed = Date().timeIntervalSince(tapStart)
            let hasExtraModifier = (flags & ~target) != 0
            if !hasExtraModifier, elapsed < 0.6, !otherInputDuringTap(within: elapsed + 0.03) {
                launcher.toggle()
            }
        }
    }

    // Modifier + tuş kısayolu
    private func handleLauncherKey(_ e: NSEvent) {
        guard launcherEnabled, recordingTarget == nil, let code = launcherShortcut.keyCode,
              !e.isARepeat, e.keyCode == code else { return }
        guard e.modifierFlags.intersection(Shortcut.relevant).rawValue == launcherShortcut.modifiers else { return }
        launcher.toggle()
    }

    /// Modifier basılıyken tuş, tıklama veya kaydırma oldu mu? (⌘Tab, ⌘+tık gibi durumları eler)
    private func otherInputDuringTap(within seconds: TimeInterval) -> Bool {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.contains {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < seconds
        }
    }

    // MARK: Kısayol kaydı

    func startRecording(_ kind: ShortcutKind) {
        stopRecording()
        recordingTarget = kind
        recordPeak = []
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            self?.handleRecording(e)
            return nil   // kayıt sırasında tuşlar yutulur (bip sesi çıkmaz)
        }
    }

    func stopRecording() {
        if let m = recordMonitor { NSEvent.removeMonitor(m) }
        recordMonitor = nil
        recordingTarget = nil
    }

    private func handleRecording(_ e: NSEvent) {
        guard let kind = recordingTarget else { return }
        let flags = e.modifierFlags.intersection(Shortcut.relevant)

        if e.type == .keyDown {
            if e.keyCode == 53 { stopRecording(); return }           // Esc: iptal
            guard !flags.isEmpty else { return }                     // en az bir modifier şart
            finishRecording(Shortcut(modifiers: flags.rawValue, keyCode: e.keyCode, keyLabel: Shortcut.label(for: e)), kind: kind)
            return
        }

        // flagsChanged: sadece modifier kısayolu
        if flags.isEmpty {
            if recordPeak.rawValue.nonzeroBitCount >= kind.minModifiers {
                finishRecording(Shortcut(modifiers: recordPeak.rawValue, keyCode: nil, keyLabel: nil), kind: kind)
            } else {
                recordPeak = []
            }
        } else if flags.rawValue.nonzeroBitCount >= recordPeak.rawValue.nonzeroBitCount {
            recordPeak = flags
        }
    }

    private func finishRecording(_ s: Shortcut, kind: ShortcutKind) {
        switch kind {
        case .screenshot: shortcut = s
        case .launcher:   launcherShortcut = s
        }
        s.save(kind)
        stopRecording()
    }

    func takeScreenshotToClipboard() {
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        task.arguments = ["-c", "-x", "-i"]

        do {
            try task.run()
            notify(title: "Ekran Görüntüsü Alındı", body: "Görüntü panoya kopyalandı. Cmd+V ile yapıştırabilirsiniz.")
        } catch {
            print("Ekran görüntüsü alınamadı: \(error)")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pendingModifierFire?.cancel()
        for m in globalMonitors { NSEvent.removeMonitor(m) }
        globalMonitors.removeAll()
        for m in localMonitors { NSEvent.removeMonitor(m) }
        localMonitors.removeAll()
        stopRecording()
        launcher.hide()
    }

    func toggleMetric(_ metric: MenuBarMetric) {
        var set = selectedMetrics
        if set.contains(metric) {
            if set.count > 1 { set.remove(metric) }
        } else {
            set.insert(metric)
        }
        selectedMetrics = set
        let sortedRaw = MenuBarMetric.allCases.filter { set.contains($0) }.map { $0.rawValue }
        UserDefaults.standard.set(sortedRaw, forKey: MenuBarMetric.storageKey)
    }

    func updateTempThresholds(med: Double, high: Double) {
        medTempThreshold = med
        highTempThreshold = high
        UserDefaults.standard.set(med, forKey: "medTempThreshold")
        UserDefaults.standard.set(high, forKey: "highTempThreshold")
    }

    func refreshNotificationAuthStatus(requestIfNeeded: Bool) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            self.notificationAuthStatus = settings.authorizationStatus

            if requestIfNeeded && settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                let newSettings = await center.notificationSettings()
                self.notificationAuthStatus = newSettings.authorizationStatus
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestNotificationPermission() { refreshNotificationAuthStatus(requestIfNeeded: true) }

    private func setupListeners() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: ws.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.checkEmulators() } }
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

    private var autoFreeEnabled: Bool { UserDefaults.standard.object(forKey: "autoFreeOllama") as? Bool ?? true }
    private var autoGameModeEnabled: Bool { UserDefaults.standard.bool(forKey: "autoGameMode") }
    private var savedQuitSet: Set<String> {
        Set((UserDefaults.standard.string(forKey: "gameModeQuitApps") ?? "").split(separator: ",").map(String.init))
    }

    private func notify(title: String, body: String) {
        Task {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
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

    private func handleSwapWarning(_ swapGB: Double) {
        guard swapGB >= 4.0 else { return }
        if let last = lastSwapWarningAt, Date().timeIntervalSince(last) < 600 { return }
        lastSwapWarningAt = Date()
        notify(title: "Yüksek Swap Kullanımı", body: "Sistem \(String(format: "%.1f", swapGB)) GB swap kullanıyor. Performans düşebilir.")
    }

    private func checkBreakReminder() {
        let minutes = UserDefaults.standard.integer(forKey: "breakIntervalMinutes")
        guard minutes > 0, let start = sessionStart else { return }
        let reference = lastReminderAt ?? start
        guard Date().timeIntervalSince(reference) >= Double(minutes) * 60 else { return }

        lastReminderAt = Date()
        let played = Int(Date().timeIntervalSince(start) / 60)

        Task {
            let content = UNMutableNotificationContent()
            content.title = "Mola zamanı"
            content.body = "\(played) dakikadır oynuyorsun. Mac'in soğuması için kısa bir mola ver."
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        let interval = effectiveInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        t.tolerance = interval * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        guard !isSampling else { return }
        isSampling = true

        if let pid = emulatorPID {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) != size {
                emulatorPID = nil
            }
        }

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
        if m.tempStatus != tempStatus { tempStatus = m.tempStatus }

        handleMemoryPressure(m.memPressure)
        handleSwapWarning(m.swapUsedGB)
        checkBreakReminder()
        isSampling = false
    }
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

    private static let emulatorNames = EmulatorCatalog.names

    static func runningUserApps() -> [RunningAppInfo] {
        let myID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .compactMap { app -> RunningAppInfo? in
                guard app.activationPolicy == .regular,
                      let id = app.bundleIdentifier,
                      id != myID, id != "com.apple.finder",
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
        psRequest.timeoutInterval = 1
        psRequest.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: psRequest),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]], !models.isEmpty else { return 0 }

        var count = 0
        for model in models {
            guard let name = model["name"] as? String else { continue }
            var request = URLRequest(url: genURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "keep_alive": 0] as [String: Any])
            if (try? await URLSession.shared.data(for: request)) != nil { count += 1 }
        }
        return count
    }
}

// MARK: - Uygulama başlatıcı
nonisolated struct LauncherApp: Identifiable, Sendable, Hashable {
    let id: String      // .app yolu
    let name: String
    var url: URL { URL(fileURLWithPath: id) }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = "" { didSet { refilter() } }
    @Published private(set) var apps: [LauncherApp] = [] { didSet { refilter() } }
    @Published private(set) var results: [LauncherApp] = []
    @Published var selection = 0
    @Published var focusToken = UUID()
    var onClose: (() -> Void)?

    nonisolated static func scanApps() -> [LauncherApp] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities",
                    "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var out: [LauncherApp] = []
        for d in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = d + "/" + item
                let name = (item as NSString).deletingPathExtension
                if seen.insert(path).inserted { out.append(LauncherApp(id: path, name: name)) }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func reload() {
        Task {
            let found = await Task.detached { LauncherModel.scanApps() }.value
            self.apps = found
        }
    }

    private func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func refilter() {
        selection = 0
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        if q.isEmpty { results = apps; return }
        var starts: [LauncherApp] = []
        var contains: [LauncherApp] = []
        for app in apps {
            let n = fold(app.name)
            if n.hasPrefix(q) { starts.append(app) }
            else if n.contains(q) { contains.append(app) }
        }
        results = starts + contains
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    func launchSelected() {
        guard results.indices.contains(selection) else { return }
        launch(results[selection])
    }

    func launch(_ app: LauncherApp) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        onClose?()
    }
}

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Uygulama ara…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { model.launchSelected() }
            }
            .padding(14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, app in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.id))
                                    .resizable().frame(width: 28, height: 28)
                                Text(app.name).font(.body)
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(index == model.selection ? Color.accentColor.opacity(0.25) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { model.launch(app) }
                            .id(app.id)
                        }
                        if model.results.isEmpty {
                            Text("Sonuç yok").foregroundStyle(.secondary).padding(20)
                        }
                    }
                }
                .onChange(of: model.selection) { _, newValue in
                    if model.results.indices.contains(newValue) {
                        proxy.scrollTo(model.results[newValue].id)
                    }
                }
            }
        }
        .frame(width: 560, height: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _, _ in focused = true }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.escape) { model.onClose?(); return .handled }
    }
}

@MainActor
final class LauncherController {
    private let model = LauncherModel()
    private var panel: LauncherPanel?
    private var resignObserver: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    init() {
        model.onClose = { [weak self] in self?.hide() }
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        model.reload()
        model.query = ""
        model.selection = 0
        model.focusToken = UUID()

        let p = panel ?? makePanel()
        panel = p

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.frame {
            let size = p.frame.size
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                     y: f.midY - size.height / 2 + f.height * 0.12))
        }

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> LauncherPanel {
        let p = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: LauncherView(model: model))

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        return p
    }
}

// MARK: - Panel sekmeleri
private enum MonitorPanelTab: String, CaseIterable, Identifiable {
    case status = "Durum"
    case capture = "Ekran"
    case launcher = "Başlat"

    var id: String { rawValue }
}

// MARK: - Menü çubuğu açılır paneli
struct ContentView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var gameMode: GameModeManager
    @AppStorage("gameModeQuitApps") private var quitList = ""
    @AppStorage("breakIntervalMinutes") private var breakMinutes = 0
    @AppStorage("autoFreeOllama") private var autoFreeOllama = true
    @AppStorage("autoGameMode") private var autoGameMode = false

    @State private var runningApps: [RunningAppInfo] = []
    @State private var appsExpanded = false
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var showAdvancedSettings = false
    @State private var selectedTab: MonitorPanelTab = .status

    @State private var localMedTemp: Double = 75.0
    @State private var localHighTemp: Double = 90.0

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
            Picker("Sekme", selection: $selectedTab) {
                ForEach(MonitorPanelTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch selectedTab {
            case .status:
                statusTab
            case .capture:
                captureTab
            case .launcher:
                launcherTab
            }

            Divider()

            Button("Çıkış") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            localMedTemp = monitor.medTempThreshold
            localHighTemp = monitor.highTempThreshold
        }
    }

    @ViewBuilder
    private var statusTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sistem Durumu").font(.headline)
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                metricRow(title: "CPU: \(Int(monitor.cpuUsage))%", metric: .cpu)
                metricRow(title: "GPU: \(Int(monitor.gpuUsage))%", metric: .gpu)
                metricRow(title: "Bellek: \(Int(monitor.memoryUsage))%", metric: .memory)
                metricRow(title: "Isı: \(tempText(monitor.socTemperature))", metric: .temperature)
            }.font(.body)

            Text("Bellek baskısı: \(monitor.memoryPressureLabel) · Swap: \(String(format: "%.1f", monitor.swapUsedGB)) GB")
                .font(.caption)

            Text("Pil ısısı: \(tempText(monitor.batteryTemperature))").font(.caption)

            if monitor.tempStatus != .ok {
                Text("Sıcaklık durumu: \(monitor.tempStatus.rawValue)")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Text("Isı durumu: \(monitor.thermalLabel)").font(.caption)
            Text("Emülatör: \(monitor.isEmulatorRunning ? "Açık" : "Kapalı")").font(.caption)

            if let name = monitor.emulatorName {
                Text("\(name): CPU \(monitor.emulatorCPU.map { "\(Int($0.rounded()))%" } ?? "…") · RAM \(monitor.emulatorMemoryMB.map { "\(Int($0.rounded())) MB" } ?? "…")")
                    .font(.caption)
                if let start = monitor.sessionStart {
                    HStack(spacing: 4) {
                        Text("Oyun süresi:").font(.caption)
                        Text(start, style: .timer).font(.caption)
                    }
                }
            }

            Divider()

            Picker("Mod", selection: $monitor.powerMode) {
                ForEach(SystemMonitor.PowerMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }

            Toggle("Ollama'yı otomatik boşalt", isOn: $autoFreeOllama)

            if monitor.notificationAuthStatus == .denied {
                Button { monitor.openNotificationSettings() } label: {
                    Label("Bildirimler kapalı — Ayarlar'dan aç", systemImage: "bell.slash")
                        .font(.caption).foregroundStyle(.orange)
                }.buttonStyle(.plain)
            }

            Picker("Mola hatırlatıcı", selection: $breakMinutes) {
                Text("Kapalı").tag(0)
                Text("30 dk").tag(30)
                Text("45 dk").tag(45)
                Text("60 dk").tag(60)
            }.onChange(of: breakMinutes) { _, minutes in if minutes > 0 { monitor.requestNotificationPermission() } }

            Toggle("Girişte otomatik başlat", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    guard (SMAppService.mainApp.status == .enabled) != enabled else { return }
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
                }

            Divider()

            Button { gameMode.activate(quitBundleIDs: quitSet, monitor: monitor) } label: {
                Label("Oyun Modunu Başlat", systemImage: "gamecontroller.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).disabled(gameMode.isWorking)

            if !gameMode.status.isEmpty { Text(gameMode.status).font(.caption).foregroundStyle(.secondary) }

            Toggle("Emülatör açılınca otomatik başlat", isOn: $autoGameMode)
                .onChange(of: autoGameMode) { _, enabled in if enabled { monitor.requestNotificationPermission() } }

            DisclosureGroup("Kapatılacak uygulamalar", isExpanded: $appsExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if runningApps.isEmpty { Text("Açık uygulama yok").font(.caption).foregroundStyle(.secondary) }
                        ForEach(runningApps) { app in Toggle(app.name, isOn: binding(for: app.id)) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140)
            }.onChange(of: appsExpanded) { _, expanded in if expanded { runningApps = GameModeManager.runningUserApps() } }

            DisclosureGroup("Gelişmiş Ayarlar (Sıcaklık Eşikleri)", isExpanded: $showAdvancedSettings) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Orta Sıcaklık:")
                        Spacer()
                        Text("\(Int(localMedTemp))°C").foregroundStyle(.orange)
                    }
                    Slider(value: $localMedTemp, in: 50...85, step: 1)
                        .onChange(of: localMedTemp) { _, newValue in
                            if newValue >= localHighTemp - 2 { localHighTemp = newValue + 3 }
                            monitor.updateTempThresholds(med: localMedTemp, high: localHighTemp)
                        }

                    HStack {
                        Text("Kritik Sıcaklık:")
                        Spacer()
                        Text("\(Int(localHighTemp))°C").foregroundStyle(.red)
                    }
                    Slider(value: $localHighTemp, in: 75...105, step: 1)
                        .onChange(of: localHighTemp) { _, newValue in
                            if newValue <= localMedTemp + 2 { localMedTemp = newValue - 3 }
                            monitor.updateTempThresholds(med: localMedTemp, high: localHighTemp)
                        }
                }.font(.caption).padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var permissionBox: some View {
        if monitor.hasInputMonitoring {
            Label("Girdi İzleme izni verildi", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kısayolun uygulama odakta değilken de çalışması için Girdi İzleme izni gerekli.")
                    .font(.caption).foregroundStyle(.orange)
                HStack {
                    Button("İzin Ver") { monitor.requestInputMonitoring() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("İzin Verdim, Yeniden Başlat") { monitor.relaunchApp() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(8)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)
        }
    }

    @ViewBuilder
    private var captureTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ekran Görüntüsü").font(.headline)

            HStack {
                Text("Kısayol:").font(.caption)
                Button {
                    monitor.recordingTarget == .screenshot ? monitor.stopRecording() : monitor.startRecording(.screenshot)
                } label: {
                    Text(monitor.recordingTarget == .screenshot ? "Tuşlara bas… (Esc iptal)" : monitor.shortcut.display)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }

            Divider()

            permissionBox

            Button {
                monitor.takeScreenshotToClipboard()
            } label: {
                Label("Ekran Görüntüsü Al", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .onAppear { monitor.refreshPermissions() }
        .onDisappear { monitor.stopRecording() }
    }

    @ViewBuilder
    private var launcherTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Uygulama Başlatıcı").font(.headline)

            Toggle("Başlatıcı açık", isOn: $monitor.launcherEnabled)

            HStack {
                Text("Kısayol:").font(.caption)
                Button {
                    monitor.recordingTarget == .launcher ? monitor.stopRecording() : monitor.startRecording(.launcher)
                } label: {
                    Text(monitor.recordingTarget == .launcher ? "Tuşlara bas… (Esc iptal)" : monitor.launcherShortcut.display)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }

            if monitor.launcherShortcut.keyCode == nil {
                Text("Sadece modifier: tuşa tek başına bas-bırak. Araya başka tuş veya tıklama girerse açılmaz.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("Açıkken aynı kısayol, Esc veya dışarı tıklama paneli kapatır.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()

            permissionBox

            Button {
                monitor.launcher.toggle()
            } label: {
                Label("Başlatıcıyı Aç", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .onAppear { monitor.refreshPermissions() }
        .onDisappear { monitor.stopRecording() }
    }

    private func metricRow(title: String, metric: MenuBarMetric) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: Binding(get: { monitor.selectedMetrics.contains(metric) }, set: { _ in monitor.toggleMetric(metric) }))
            .toggleStyle(.checkbox).labelsHidden().help("Menü çubuğunda göster")
        }
    }
}

// MARK: - Uygulama kapanırken timer'ı güvenle durdur
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var monitor: SystemMonitor?

    func applicationWillTerminate(_ notification: Notification) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { monitor?.stop() }
        } else {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.monitor?.stop() } }
        }
    }
}

// MARK: - Uygulama girişi
@main
struct MonitorApp: App {
    @StateObject private var monitor = SystemMonitor()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private var menuBarText: String {
        var parts: [String] = []
        for metric in MenuBarMetric.allCases {
            guard monitor.selectedMetrics.contains(metric) else { continue }
            switch metric {
            case .cpu: parts.append("\(Int(monitor.cpuUsage))%")
            case .gpu: parts.append("\(Int(monitor.gpuUsage))%")
            case .memory: parts.append("\(Int(monitor.memoryUsage))%")
            case .temperature:
                if let t = monitor.socTemperature { parts.append("\(Int(t.rounded()))°") }
                else { parts.append("--°") }
            }
        }
        return parts.isEmpty ? "Macnitor" : parts.joined(separator: " · ")
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(monitor).environmentObject(monitor.gameMode)
                .onAppear { appDelegate.monitor = monitor }
        } label: {
            Image(nsImage: statusDotImage(level: monitor.heatLevel))
            Text(menuBarText)
        }
        .menuBarExtraStyle(.window)
    }
}
