import AppKit
import Darwin
import IOKit.ps
import SwiftUI

struct ProcInfo: Identifiable {
    let pid: Int32
    let name: String
    let cpu: Double
    let memMB: Double
    var id: Int32 { pid }
}

enum ProcessLister {
    /// Топ процессов через /bin/ps (сортировка по CPU или по памяти).
    static func top(byMemory: Bool, count: Int) -> [ProcInfo] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-c", "-o", "pid=,pcpu=,rss=,comm=", byMemory ? "-m" : "-r"]
        p.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let myPid = ProcessInfo.processInfo.processIdentifier
        var list: [ProcInfo] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard cols.count == 4,
                  let pid = Int32(cols[0]),
                  let cpu = Double(cols[1]),
                  let rss = Double(cols[2]),
                  pid != myPid else { continue }
            list.append(ProcInfo(pid: pid, name: String(cols[3]), cpu: cpu, memMB: rss / 1024))
            if list.count >= count { break }
        }
        return list
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 40)
    @Published private(set) var memUsed: Double = 0
    let memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var battery: Int?
    @Published private(set) var charging = false
    @Published private(set) var processes: [ProcInfo] = []
    @Published var sortByMemory = false {
        didSet { fetchProcesses() }
    }

    /// Процессы обновляем только когда вкладка открыта.
    var showProcesses = false {
        didSet { if showProcesses { fetchProcesses() } }
    }

    private let host = mach_host_self()
    private var prevTicks: (UInt32, UInt32, UInt32, UInt32)?
    private var timer: Timer?

    init() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        updateCPU()
        updateMemory()
        updateBattery()
        if showProcesses { fetchProcesses() }
    }

    private func updateCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = self.host
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let t = info.cpu_ticks
        if let p = prevTicks {
            let user = Double(t.0 &- p.0)
            let system = Double(t.1 &- p.1)
            let idle = Double(t.2 &- p.2)
            let nice = Double(t.3 &- p.3)
            let total = user + system + idle + nice
            if total > 0 { cpu = (user + system + nice) / total }
            cpuHistory.append(cpu)
            if cpuHistory.count > 40 { cpuHistory.removeFirst(cpuHistory.count - 40) }
        }
        prevTicks = (t.0, t.1, t.2, t.3)
    }

    private func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = self.host
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = Double(sysconf(_SC_PAGESIZE))
        // Как в Мониторинге системы: память приложений + связанная + сжатая.
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        memUsed = max(0, (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page)
    }

    private func updateBattery() {
        guard let blobRef = IOPSCopyPowerSourcesInfo(),
              let listRef = IOPSCopyPowerSourcesList(blobRef.takeUnretainedValue()) else {
            battery = nil
            return
        }
        let blob = blobRef.takeRetainedValue()
        let list = listRef.takeRetainedValue() as Array
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = desc[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            battery = current * 100 / maximum
            let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            charging = isCharging || onAC
            return
        }
        battery = nil
    }

    func fetchProcesses() {
        let byMemory = sortByMemory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = ProcessLister.top(byMemory: byMemory, count: 6)
            Task { @MainActor [weak self] in self?.processes = list }
        }
    }

    func terminate(_ p: ProcInfo) {
        if let app = NSRunningApplication(processIdentifier: p.pid) {
            app.terminate()
        } else {
            kill(p.pid, SIGTERM)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.fetchProcesses()
        }
    }
}

// MARK: - Вкладка

struct SystemTabView: View {
    @EnvironmentObject var system: SystemMonitor
    @EnvironmentObject var model: IslandModel
    @State private var confirmPid: Int32?

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                statBlock("CPU", String(format: "%.0f%%", system.cpu * 100)) {
                    ZStack {
                        Sparkline(values: system.cpuHistory, closed: true)
                            .fill(LinearGradient(colors: [Color.green.opacity(0.35), Color.green.opacity(0.02)],
                                                 startPoint: .top, endPoint: .bottom))
                        Sparkline(values: system.cpuHistory, closed: false)
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    }
                    .frame(height: 36)
                }
                statBlock("Память",
                          String(format: "%.1f / %.0f ГБ", system.memUsed / 1_073_741_824, system.memTotal / 1_073_741_824)) {
                    let f = system.memUsed / max(system.memTotal, 1)
                    UsageBar(fraction: f, color: f > 0.85 ? .red : (f > 0.7 ? .orange : .blue))
                }
                if let level = system.battery {
                    statBlock("Батарея", "\(level)%" + (system.charging ? " · питание" : "")) {
                        UsageBar(fraction: Double(level) / 100, color: level <= 20 ? .red : .green)
                    }
                }
            }
            .frame(width: 210)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Процессы")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.45))
                    Spacer()
                    Picker("", selection: $system.sortByMemory) {
                        Text("CPU").tag(false)
                        Text("RAM").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 110)
                    .controlSize(.small)
                }
                .padding(.bottom, 4)

                ForEach(system.processes) { p in
                    processRow(p)
                }
                Spacer(minLength: 0)
            }
        }
        // Вид теперь всегда в дереве, поэтому процессы опрашиваем только пока островок раскрыт.
        .onAppear { system.showProcesses = model.expanded }
        .onChange(of: model.expanded) { _, isExpanded in system.showProcesses = isExpanded }
        .onDisappear { system.showProcesses = false }
    }

    private func statBlock<Content: View>(_ title: String, _ value: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).foregroundStyle(Color.white.opacity(0.5))
                Spacer()
                Text(value).font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .font(.system(size: 11, weight: .medium))
            content()
        }
    }

    private func processRow(_ p: ProcInfo) -> some View {
        let app = NSRunningApplication(processIdentifier: p.pid)
        return HStack(spacing: 8) {
            Group {
                if let icon = app?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape").foregroundStyle(Color.white.opacity(0.4))
                }
            }
            .frame(width: 16, height: 16)

            Text(app?.localizedName ?? p.name)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(String(format: "%.1f%%", p.cpu))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(system.sortByMemory ? Color.white.opacity(0.45) : Color.white)
                .frame(width: 52, alignment: .trailing)
            Text(Self.memString(p.memMB))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(system.sortByMemory ? Color.white : Color.white.opacity(0.45))
                .frame(width: 64, alignment: .trailing)

            if p.pid > 1 {
                Button {
                    if confirmPid == p.pid {
                        system.terminate(p)
                        confirmPid = nil
                    } else {
                        confirmPid = p.pid
                    }
                } label: {
                    if confirmPid == p.pid {
                        Text("Завершить?")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.red)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.white.opacity(0.3))
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 66, alignment: .trailing)
                .help("Завершить процесс")
            } else {
                Color.clear.frame(width: 66)
            }
        }
        .frame(height: 24)
    }

    static func memString(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f ГБ", mb / 1024) : String(format: "%.0f МБ", mb)
    }
}

struct Sparkline: Shape {
    var values: [Double]
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        for (i, v) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1)
            let y = rect.maxY - rect.height * CGFloat(min(max(v, 0), 1))
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
