import Foundation

/// The temperature unit the user has chosen in System Settings, used to format
/// the °C values the SMC reports.
public enum TemperatureUnit {
    case celsius, fahrenheit

    /// Follows System Settings → Language & Region → Temperature, falling back
    /// to the current locale's measurement system if that preference is unset.
    public static var system: TemperatureUnit {
        if let pref = UserDefaults.standard.string(forKey: "AppleTemperatureUnit") {
            return pref.lowercased().hasPrefix("f") ? .fahrenheit : .celsius
        }
        if Locale.current.measurementSystem == .us { return .fahrenheit }
        return .celsius
    }

    /// Format a Celsius reading for display in this unit (e.g. "46°C" / "115°F").
    public func format(celsius: Double) -> String {
        switch self {
        case .celsius:    return String(format: "%.0f°C", celsius)
        case .fahrenheit: return String(format: "%.0f°F", celsius * 9.0 / 5.0 + 32.0)
        }
    }
}

public struct FanInfo {
    public let index: Int
    public let actual: Double   // current RPM
    public let minRPM: Double
    public let maxRPM: Double
    public let target: Double   // commanded RPM
    public let manual: Bool     // forced (manual) vs automatic
}

public struct FanStatus {
    public let fans: [FanInfo]
    public let allManual: Bool
}

/// High-level fan reads/writes built on top of the raw SMC keys.
public final class FanController {
    let smc: SMC

    // Temperature sensor keys, discovered once (enumerating all SMC keys is slow).
    private var cpuSensorKeys: [String] = []
    private var gpuSensorKeys: [String] = []
    private var sensorsDiscovered = false

    public init() throws { smc = try SMC() }

    // MARK: - SMC value coding

    public static func decode(type: String, bytes: [UInt8]) -> Double {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return 0 }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "fpe2":   // unsigned fixed point, 2 fractional bits, big-endian
            guard bytes.count >= 2 else { return 0 }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4.0
        case "fp2e":   // unsigned fixed point, 14 fractional bits
            guard bytes.count >= 2 else { return 0 }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 16384.0
        case "ui8 ", "ui8", "si8 ", "si8":
            return bytes.isEmpty ? 0 : Double(bytes[0])
        case "ui16", "si16":
            guard bytes.count >= 2 else { return 0 }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return 0 }
            var v: UInt32 = 0
            for b in bytes.prefix(4) { v = (v << 8) | UInt32(b) }
            return Double(v)
        default:
            return 0
        }
    }

    static func encode(type: String, value: Double) -> [UInt8] {
        switch type {
        case "flt ":
            var f = Float32(value)
            return withUnsafeBytes(of: &f) { Array($0) }   // little-endian on arm64
        case "fpe2":
            let raw = UInt16(max(0, min(value * 4.0, 65535)))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui8 ", "ui8":
            return [UInt8(max(0, min(value, 255)))]
        case "ui16":
            let raw = UInt16(max(0, min(value, 65535)))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        default:
            return []
        }
    }

    func readNumber(_ key: String) throws -> Double {
        let (type, bytes) = try smc.read(key)
        return FanController.decode(type: type, bytes: bytes)
    }

    // MARK: - Read

    public func fanCount() throws -> Int {
        Int(try readNumber("FNum"))
    }

    public func fan(_ i: Int) throws -> FanInfo {
        FanInfo(
            index: i,
            actual: (try? readNumber("F\(i)Ac")) ?? 0,
            minRPM: (try? readNumber("F\(i)Mn")) ?? 0,
            maxRPM: (try? readNumber("F\(i)Mx")) ?? 0,
            target: (try? readNumber("F\(i)Tg")) ?? 0,
            manual: isManual(i)
        )
    }

    public func status() throws -> FanStatus {
        let n = try fanCount()
        let fans = try (0..<n).map { try fan($0) }
        return FanStatus(fans: fans, allManual: !fans.isEmpty && fans.allSatisfy { $0.manual })
    }

    /// Per-fan mode key. Apple Silicon uses lowercase `F0md`; older/Intel Macs
    /// used uppercase `F0Md`. 0 = automatic, 1 = forced (manual).
    func modeKey(_ i: Int) -> String? {
        for k in ["F\(i)md", "F\(i)Md"] where smc.keyExists(k) { return k }
        return nil
    }

    // MARK: - Temperatures

    /// Average CPU (P-core cluster) and GPU temperatures in °C, or nil if the
    /// machine exposes no such sensors. On Apple Silicon these come from many
    /// `Tp*` / `Tg*` `flt` sensors, which we average into one figure each.
    public func temperatures() -> (cpu: Double?, gpu: Double?) {
        discoverSensors()
        return (averageTemp(cpuSensorKeys), averageTemp(gpuSensorKeys))
    }

    private func discoverSensors() {
        guard !sensorsDiscovered else { return }
        sensorsDiscovered = true
        guard let count = try? smc.keyCount() else { return }
        for i in 0..<count {
            guard let key = try? smc.keyFromIndex(i), key.count == 4 else { continue }
            let isCPU = key.hasPrefix("Tp")   // performance-core cluster
            let isGPU = key.hasPrefix("Tg")   // GPU cluster
            guard isCPU || isGPU,
                  let (type, bytes) = try? smc.read(key), type == "flt " else { continue }
            let v = FanController.decode(type: type, bytes: bytes)
            guard v > 5 && v < 130 else { continue }   // sanity-bound to real °C
            if isCPU { cpuSensorKeys.append(key) } else { gpuSensorKeys.append(key) }
        }
    }

    private func averageTemp(_ keys: [String]) -> Double? {
        var sum = 0.0, n = 0
        for k in keys {
            guard let (type, bytes) = try? smc.read(k) else { continue }
            let v = FanController.decode(type: type, bytes: bytes)
            if v > 0 { sum += v; n += 1 }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    func isManual(_ i: Int) -> Bool {
        if let key = modeKey(i), let (type, bytes) = try? smc.read(key) {
            return FanController.decode(type: type, bytes: bytes) != 0
        }
        // Fallback for Macs that expose the FS! force bitmask instead.
        if let (type, bytes) = try? smc.read("FS! ") {
            let mask = UInt16(FanController.decode(type: type, bytes: bytes))
            return (mask & (UInt16(1) << UInt16(i))) != 0
        }
        return false
    }

    // MARK: - Control (requires root)

    /// Set the mode of a single fan by writing just its `F{i}md`/`F{i}Md` key
    /// (0 = automatic, 1 = forced/manual). Returns true if a per-fan mode key
    /// existed and was written; false if this Mac exposes no per-fan mode key
    /// (the aggregate `setManual(_:)` falls back to the `FS!` force bitmask).
    @discardableResult
    public func setManual(_ manual: Bool, fan i: Int) throws -> Bool {
        guard let key = modeKey(i) else { return false }
        let type = (try? smc.read(key).type) ?? "ui8 "
        try smc.write(key, bytes: FanController.encode(type: type, value: manual ? 1 : 0))
        return true
    }

    public func setManual(_ manual: Bool) throws {
        let n = try fanCount()
        var didPerFan = false
        for i in 0..<n {
            if try setManual(manual, fan: i) { didPerFan = true }
        }
        if !didPerFan && smc.keyExists("FS! ") {
            let mask: UInt16 = manual ? UInt16((1 << n) - 1) : 0
            try smc.write("FS! ", bytes: [UInt8(mask >> 8), UInt8(mask & 0xff)])
        }
    }

    public func setTarget(rpm: Double, fan i: Int) throws {
        let mn = (try? readNumber("F\(i)Mn")) ?? 0
        let mx = (try? readNumber("F\(i)Mx")) ?? 0
        var target = max(rpm, mn)
        if mx > 0 { target = min(target, mx) }
        let type = try smc.read("F\(i)Tg").type
        try smc.write("F\(i)Tg", bytes: FanController.encode(type: type, value: target))
    }

    public func setAllSpeeds(rpm: Double) throws {
        let n = try fanCount()
        try setManual(true)
        for i in 0..<n { try setTarget(rpm: rpm, fan: i) }
    }

    public func setMax() throws {
        let n = try fanCount()
        try setManual(true)
        for i in 0..<n {
            let mx = (try? readNumber("F\(i)Mx")) ?? 0
            if mx > 0 { try setTarget(rpm: mx, fan: i) }
        }
    }

    public func setAuto() throws {
        try setManual(false)
    }
}

// MARK: - Shared stepped fan curve

/// One band of the stepped fan curve: at temperatures >= `minTempC`, run at
/// `fraction` of the [floor, max] range (0 = floor, 1 = each fan's max).
public struct FanCurveStep: Equatable {
    public let minTempC: Double
    public let fraction: Double
    public init(minTempC: Double, fraction: Double) {
        self.minTempC = minTempC; self.fraction = fraction
    }
}

/// Default stepped curve: floor while cool, stepping up to max as it heats.
public let defaultFanCurve: [FanCurveStep] = [
    FanCurveStep(minTempC: 0,  fraction: 0.0),    // floor below 60 °C
    FanCurveStep(minTempC: 60, fraction: 0.25),
    FanCurveStep(minTempC: 70, fraction: 0.50),
    FanCurveStep(minTempC: 80, fraction: 0.75),
    FanCurveStep(minTempC: 88, fraction: 1.0),     // max at/above 88 °C
]

/// Pick the curve step index for the current temperature, starting from
/// `current`, with downward hysteresis so the fan doesn't flap at a boundary:
/// step UP as soon as temp reaches the next band's `minTempC`; step DOWN only
/// once temp falls `hysteresisC` below the current band's `minTempC`. Returns
/// `current` (clamped) unchanged when temperature is unreadable.
public func fanCurveStep(current: Int, machineTemp: Double?,
                         curve: [FanCurveStep], hysteresisC: Double) -> Int {
    guard !curve.isEmpty else { return 0 }
    let clampedCurrent = min(max(current, 0), curve.count - 1)
    guard let t = machineTemp else { return clampedCurrent }
    var idx = clampedCurrent
    while idx + 1 < curve.count && t >= curve[idx + 1].minTempC { idx += 1 }
    while idx > 0 && t < curve[idx].minTempC - hysteresisC { idx -= 1 }
    return idx
}

/// Target RPM for a step: floor + fraction*(max - floor), never below the floor.
public func fanCurveTarget(stepIndex: Int, floorRPM: Double, fanMaxRPM: Double,
                           curve: [FanCurveStep]) -> Double {
    let ceiling = max(fanMaxRPM, floorRPM)
    guard !curve.isEmpty else { return floorRPM }
    let frac = curve[min(max(stepIndex, 0), curve.count - 1)].fraction
    return floorRPM + max(0.0, min(frac, 1.0)) * (ceiling - floorRPM)
}

// MARK: - Minimum-RPM supervisor

/// Emulates a "minimum fan speed" floor in software on Macs where the hardware
/// minimum key (`F{n}Mn`) is read-only (firmware rejects writes with 0x86), so
/// there is no native "auto-with-a-floor" mode.
///
/// Strategy: keep every fan FORCED and drive its target ourselves along a
/// STEPPED temperature curve — the user's floor while cool, jumping up a band at
/// a time toward the fan's max as the machine heats up (see `fanCurveStep` /
/// `fanCurveTarget`). Within a band the target is constant, so the fans change
/// only when the temperature crosses a boundary; downward hysteresis keeps them
/// from flapping at a threshold. We NEVER release a fan to firmware AUTO while
/// supervising: on this hardware the firmware idles fans to 0 rpm until quite
/// warm, so any release while cool stalls them (and re-spinning from a dead stop
/// takes seconds). Because we always drive the fans, they can't stall; they
/// still step up under load because we step them. Apple's hardware thermal
/// throttle remains the ultimate backstop.
public final class MinFloorSupervisor {
    private let controller: FanController
    private let floorRPM: Double
    private let intervalMs: Int
    private let curve: [FanCurveStep]
    private let hysteresisC: Double
    private let writeDeltaRPM: Double
    private let log: ((String) -> Void)?

    /// Per-fan last commanded target (keyed by fan index), so we only re-write
    /// the SMC when the target moves meaningfully. Persisted across `stepOnce()`.
    private var lastTarget: [Int: Double] = [:]

    /// Per-fan current curve band index, so hysteresis can be applied relative
    /// to the band we're already in. Persisted across `stepOnce()`.
    private var lastStepIndex: [Int: Int] = [:]

    public init(controller: FanController,
                floorRPM: Double,
                intervalMs: Int = 2000,
                curve: [FanCurveStep] = defaultFanCurve,
                hysteresisC: Double = 3,
                writeDeltaRPM: Double = 25,
                log: ((String) -> Void)? = nil) {
        self.controller = controller
        self.floorRPM = floorRPM
        self.intervalMs = intervalMs
        self.curve = curve
        self.hysteresisC = hysteresisC
        self.writeDeltaRPM = writeDeltaRPM
        self.log = log
    }

    /// One iteration of the control logic (extracted so it can be driven once
    /// for testing via the CLI's `--once` flag).
    public func stepOnce() throws {
        let n = try controller.fanCount()
        let temps = controller.temperatures()
        let machineTemp = [temps.cpu, temps.gpu].compactMap { $0 }.max()
        for i in 0..<n {
            let info = try controller.fan(i)
            let idx = fanCurveStep(current: lastStepIndex[i] ?? 0, machineTemp: machineTemp,
                                   curve: curve, hysteresisC: hysteresisC)
            lastStepIndex[i] = idx
            let target = fanCurveTarget(stepIndex: idx, floorRPM: floorRPM,
                                        fanMaxRPM: info.maxRPM, curve: curve)
            // (Re)assert when the fan isn't forced yet (self-heal after sleep/wake) or
            // the target moved enough. setTarget clamps to the fan's [Mn, Mx].
            // Within a band the target is constant, so no rewrites — exactly the
            // "changes only at thresholds" behavior wanted.
            let last = lastTarget[i]
            if !info.manual || last == nil || abs(target - (last ?? -1)) >= writeDeltaRPM {
                try controller.setManual(true, fan: i)
                try controller.setTarget(rpm: target, fan: i)
                lastTarget[i] = target
                let tstr = machineTemp.map { String(format: "%.0f°C", $0) } ?? "?"
                log?(String(format: "fan %d: %@ -> band %d = %.0f rpm (floor %.0f, max %.0f)  actual=%.0f",
                            i, tstr, idx, target, floorRPM, info.maxRPM, info.actual))
            }
        }
    }

    /// Run the control loop until `shouldStop()` returns true. Always hands the
    /// fans back to firmware AUTO on exit — including on a thrown error — via a
    /// `defer`, so the caller (e.g. a Ctrl-C handler) need not restore itself.
    public func run(shouldStop: () -> Bool) throws {
        defer { try? restoreAuto() }
        while true {
            try stepOnce()
            if shouldStop() { break }
            // Sleep the interval in small slices so a stop request is noticed
            // promptly rather than after a full interval.
            var remaining = intervalMs
            while remaining > 0 {
                if shouldStop() { break }
                let chunk = min(250, remaining)
                Thread.sleep(forTimeInterval: Double(chunk) / 1000.0)
                remaining -= chunk
            }
            if shouldStop() { break }
        }
    }

    /// Hand every fan back to firmware AUTO control (`md=0`).
    public func restoreAuto() throws {
        try controller.setAuto()
    }
}
