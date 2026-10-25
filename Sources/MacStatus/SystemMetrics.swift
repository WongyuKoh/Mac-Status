import Foundation
import Darwin
import IOKit

/// Read-only local telemetry. This class owns the previous CPU sample, so retain it
/// between refreshes instead of constructing a new instance for every poll.
final class SystemMetrics {
    private let lock = NSLock()
    private var previousCPU: [UInt32]?
    private lazy var smc = SMCTemperatureReader()

    init() {
        previousCPU = Self.cpuTicks()
    }

    func read(_ kind: MetricKind) -> MetricReading {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .cpu: return cpu()
        case .memory: return memory()
        case .storage: return storage()
        case .temperature: return temperature()
        default: return .error("지원하지 않는 시스템 항목입니다.")
        }
    }

    private static func cpuTicks() -> [UInt32]? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    private func cpu() -> MetricReading {
        guard let current = Self.cpuTicks() else { return .error("CPU 정보를 읽을 수 없습니다.") }
        defer { previousCPU = current }
        guard let previous = previousCPU else {
            return .init(text: "측정 중", subtitle: "다음 갱신부터 CPU 사용량을 표시합니다.")
        }
        // Kernel tick counters can wrap. Unsigned subtraction preserves the delta.
        let delta = zip(current, previous).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else {
            return .init(text: "측정 중", subtitle: "다음 갱신부터 CPU 사용량을 표시합니다.")
        }
        let user = Double(delta[0] + delta[3]) / Double(total)
        let system = Double(delta[1]) / Double(total)
        return .init(
            value: min(max((user + system) * 100, 0), 100), limit: 100,
            subtitle: "전체 \(ProcessInfo.processInfo.activeProcessorCount)코어 · 현재 사용량",
            details: [
                .init(label: "사용자", value: String(format: "%.1f%%", user * 100), fraction: user),
                .init(label: "시스템", value: String(format: "%.1f%%", system * 100), fraction: system)
            ]
        )
    }

    private func memory() -> MetricReading {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .error("메모리 정보를 읽을 수 없습니다.") }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else {
            return .error("메모리 페이지 크기를 읽을 수 없습니다.")
        }
        let page = Double(pageSize)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        // internal_page_count includes purgeable anonymous pages. Compressor pages
        // are the physical compressed footprint, not the original uncompressed size.
        let app = max(Double(stats.internal_page_count) - Double(stats.purgeable_count), 0) * page
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        let used = min(max(app + wired + compressed, 0), total)
        let gib = 1_073_741_824.0
        return .init(
            value: used / gib, limit: total / gib,
            subtitle: String(format: "전체 %.0f GB · %.1f GB 여유", total / gib, (total - used) / gib),
            details: [
                .init(label: "앱 메모리", value: String(format: "%.1f GB", app / gib)),
                .init(label: "와이어드", value: String(format: "%.1f GB", wired / gib)),
                .init(label: "압축됨", value: String(format: "%.1f GB", compressed / gib))
            ]
        )
    }

    private func storage() -> MetricReading {
        do {
            // Query the user's data volume: on APFS the sealed '/' system volume
            // alone does not describe the storage occupied by the user's files.
            let volume = FileManager.default.homeDirectoryForCurrentUser
            let values = try volume.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey
            ])
            guard let totalInt = values.volumeTotalCapacity, totalInt > 0,
                  let freeInt = values.volumeAvailableCapacity else {
                return .error("저장공간 용량을 읽을 수 없습니다.")
            }
            let total = Double(totalInt)
            let free = min(max(Double(freeInt), 0), total)
            let importantFree = min(max(Double(values.volumeAvailableCapacityForImportantUsage ?? Int64(freeInt)), free), total)
            let gb = 1_000_000_000.0
            return .init(
                value: (total - free) / gb, limit: total / gb,
                subtitle: String(format: "%.1f GB 여유 · %@", free / gb, values.volumeName ?? "데이터 볼륨"),
                details: [
                    .init(label: "전체 용량", value: String(format: "%.1f GB", total / gb)),
                    .init(label: "정리 가능 포함 여유", value: String(format: "%.1f GB", importantFree / gb)),
                    .init(label: "측정 기준", value: "APFS 공유 공간 · GB(십진)")
                ]
            )
        } catch {
            return .error("저장공간 정보를 읽을 수 없습니다.")
        }
    }

    private func temperature() -> MetricReading {
        let state = ProcessInfo.processInfo.thermalState
        let label = Self.thermalLabel(state)
        if let measurement = smc.cpuTemperature() {
            return .init(
                value: measurement.celsius,
                subtitle: "CPU 센서 · \(label)",
                details: [
                    .init(label: "시스템 발열 상태", value: label),
                    .init(label: "센서", value: measurement.key),
                    .init(label: "측정 기준", value: "읽을 수 있는 CPU 센서 중 최고 온도")
                ]
            )
        }
        return .init(
            text: label, subtitle: "온도 센서 미지원 · macOS 발열 상태",
            details: [
                .init(label: "온도 수치", value: "이 Mac에서 센서 접근 불가"),
                .init(label: "시스템 발열 상태", value: label)
            ]
        )
    }

    static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "정상"
        case .fair: return "따뜻함"
        case .serious: return "높음"
        case .critical: return "매우 높음"
        @unknown default: return "알 수 없음"
        }
    }
}

/// Minimal read-only AppleSMC transport. The wire buffer uses explicit offsets,
/// avoiding Swift struct-layout assumptions at the IOKit boundary. Unsupported
/// hardware or denied access simply returns nil; no privileged helper is used.
private final class SMCTemperatureReader {
    private var connection: io_connect_t = 0
    private var workingKeys: [String]?

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS {
            connection = 0
        }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func cpuTemperature() -> (celsius: Double, key: String)? {
        guard connection != 0 else { return nil }
        // Known CPU thermal-zone keys on Intel and Apple Silicon. GPU, battery,
        // enclosure, and ambient sensors are deliberately excluded.
        let candidates = workingKeys ?? [
            "TC0P", "TC0D", "TC0E", "TC0F", "TC1C", "TC2C",
            "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L",
            "Tp0P", "Tp0T", "Tp0X", "Tp0b", "Tp0f", "Tp0j"
        ]
        var valid: [(Double, String)] = []
        for key in candidates {
            guard let raw = read(key), let value = SMCValueDecoder.temperature(bytes: raw.bytes, type: raw.type),
                  value.isFinite, value >= 5, value <= 125 else { continue }
            valid.append((value, key))
        }
        // Cache discovered keys to avoid probing absent sensors at every refresh.
        if workingKeys == nil { workingKeys = valid.map { $0.1 } }
        guard let maximum = valid.max(by: { $0.0 < $1.0 }) else { return nil }
        return (maximum.0, maximum.1)
    }

    private func read(_ key: String) -> (bytes: [UInt8], type: String)? {
        guard key.utf8.count == 4 else { return nil }
        let keyCode = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var request = [UInt8](repeating: 0, count: 80)
        Self.storeNative(keyCode, in: &request, at: 0)
        request[42] = 9 // kSMCGetKeyInfo
        guard let info = call(request) else { return nil }
        let size = Self.nativeUInt32(info, at: 28)
        guard size > 0, size <= 32 else { return nil }
        let typeCode = Self.nativeUInt32(info, at: 32)
        let type = String(bytes: [UInt8((typeCode >> 24) & 255), UInt8((typeCode >> 16) & 255), UInt8((typeCode >> 8) & 255), UInt8(typeCode & 255)], encoding: .ascii) ?? ""
        Self.storeNative(size, in: &request, at: 28)
        request[42] = 5 // kSMCReadKey
        guard let response = call(request) else { return nil }
        return (Array(response[48..<(48 + Int(size))]), type)
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, source.count, destination.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS, outputSize >= 80, output[40] == 0 else { return nil }
        return output
    }

    private static func nativeUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func storeNative(_ value: UInt32, in bytes: inout [UInt8], at offset: Int) {
        for index in 0..<4 { bytes[offset + index] = UInt8((value >> (index * 8)) & 255) }
    }
}

enum SMCValueDecoder {
    static func temperature(bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 256
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: raw))
            return value.isFinite ? value : nil
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        default: return nil
        }
    }
}
