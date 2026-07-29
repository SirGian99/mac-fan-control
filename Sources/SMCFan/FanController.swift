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

// MARK: - Shared floor decision

public enum FloorAction: Equatable { case stayAuto, enterHold, stayHold, release }

/// Pure per-fan decision for the minimum-RPM floor supervisor.
/// `firmwareTarget` is the fan's F{n}Tg — it equals the firmware's live intent
/// ONLY when the fan is NOT holding. While holding we don't probe; we watch
/// temperature and release once it climbs past the baseline (+margin). If temp
/// is unreadable, `priorBlindTicks` accumulates and we release as a fail-safe.
public func floorFanAction(holding: Bool,
                           firmwareTarget: Double,
                           machineTemp: Double?,
                           holdBaseline: Double?,
                           priorBlindTicks: Int,
                           floorRPM: Double,
                           epsilonRPM: Double,
                           releaseTempMarginC: Double,
                           blindProbeTicks: Int) -> FloorAction {
    if holding {
        if let t = machineTemp, let b = holdBaseline {
            return t > b + releaseTempMarginC ? .release : .stayHold
        } else {
            // this tick is blind: if it pushes us to the threshold, release
            return (priorBlindTicks + 1 >= blindProbeTicks) ? .release : .stayHold
        }
    } else {
        return firmwareTarget < floorRPM - epsilonRPM ? .enterHold : .stayAuto
    }
}

// MARK: - Minimum-RPM supervisor

/// Emulates a "minimum fan speed" floor in software on Macs where the hardware
/// minimum key (`F{n}Mn`) is read-only (firmware rejects writes with 0x86), so
/// there is no native "auto-with-a-floor" mode.
///
/// Strategy: leave a fan in firmware AUTO whenever the firmware itself already
/// wants to spin at/above the user's floor (so it ramps freely under load), and
/// only switch it to FORCED-at-floor when the machine is cool enough that the
/// firmware would otherwise idle the fan below the floor.
///
/// Key subtlety: while a fan is FORCED, `F{n}Tg` reflects OUR forced value, not
/// the firmware's intent — so we can only read the firmware's true desired
/// target while the fan is in AUTO. To avoid physically disturbing a held fan
/// just to probe (which makes it audibly oscillate), we do NOT release it on a
/// timer. Instead, while holding, we keep the fan steady and watch temperature
/// (read-only); we hand it back to the firmware only once temps climb past where
/// the hold began, at which point the firmware's live `F{n}Tg` drives the ramp.
public final class MinFloorSupervisor {
    private let controller: FanController
    private let floorRPM: Double
    private let intervalMs: Int
    private let releaseTempMarginC: Double
    private let epsilonRPM: Double
    private let log: ((String) -> Void)?

    /// Per-fan state (keyed by fan index): are we currently forcing this fan up
    /// to the floor? Persisted across `stepOnce()` calls.
    private var holding: [Int: Bool] = [:]
    /// Machine temperature (°C) captured when a fan last entered HOLD. While a
    /// fan is held we leave it physically STEADY and only hand it back to the
    /// firmware once the temperature has climbed past this baseline + margin —
    /// so we never disturb the fan just to probe the firmware's intent.
    private var holdBaselineTemp: [Int: Double] = [:]
    /// Consecutive ticks a held fan has seen an UNREADABLE temperature. After
    /// enough of them we release once as a fail-safe (see `blindProbeTicks`).
    private var blindTicks: [Int: Int] = [:]

    public init(controller: FanController,
                floorRPM: Double,
                intervalMs: Int = 2000,
                releaseTempMarginC: Double = 4.0,
                epsilonRPM: Double = 50,
                log: ((String) -> Void)? = nil) {
        self.controller = controller
        self.floorRPM = floorRPM
        self.intervalMs = intervalMs
        self.releaseTempMarginC = releaseTempMarginC
        self.epsilonRPM = epsilonRPM
        self.log = log
    }

    /// If temperature is unreadable for this many consecutive ticks while
    /// holding, release once so the firmware (the real thermal backstop) can
    /// re-evaluate. ~30s worth of ticks. Never hit when sensors are readable.
    private var blindProbeTicks: Int { max(1, 30_000 / max(1, intervalMs)) }

    /// One iteration of the control logic (extracted so it can be driven once
    /// for testing via the CLI's `--once` flag).
    public func stepOnce() throws {
        let n = try controller.fanCount()

        // Machine temperature (°C), read-only — does NOT disturb the fans. This
        // is the signal we use to decide when a held fan should be handed back to
        // the firmware, instead of physically releasing it to probe (which is
        // what caused the fan to audibly oscillate).
        let temps = controller.temperatures()
        let machineTemp = [temps.cpu, temps.gpu].compactMap { $0 }.max()
        let tempStr = machineTemp.map { String(format: "%.0f°C", $0) } ?? "?"

        for i in 0..<n {
            let info = try controller.fan(i)
            let actual = info.actual

            // Single shared decision, identical to the one the GUI uses.
            let action = floorFanAction(
                holding: holding[i] == true,
                firmwareTarget: info.target,
                machineTemp: machineTemp,
                holdBaseline: holdBaselineTemp[i],
                priorBlindTicks: blindTicks[i] ?? 0,
                floorRPM: floorRPM,
                epsilonRPM: epsilonRPM,
                releaseTempMarginC: releaseTempMarginC,
                blindProbeTicks: blindProbeTicks)

            switch action {
            case .stayAuto:
                // AUTO: the fan is under firmware control, so `target` is the
                // firmware's LIVE desired speed — reading it disturbs nothing.
                // Firmware already wants >= the floor: leave it in AUTO so it
                // ramps freely (the loaded/warm case).
                log?(String(format: "fan %d: AUTO (free ramp)  intent=%.0f  floor=%.0f  actual=%.0f",
                            i, info.target, floorRPM, actual))

            case .enterHold:
                // Firmware would idle below the floor: force up to the floor
                // and remember the temperature at which we started holding.
                try controller.setManual(true, fan: i)
                try controller.setTarget(rpm: floorRPM, fan: i)
                holding[i] = true
                holdBaselineTemp[i] = machineTemp
                blindTicks[i] = 0
                log?(String(format: "fan %d: AUTO -> HOLD@%.0f (intent=%.0f, base %@)  actual=%.0f",
                            i, floorRPM, info.target, tempStr, actual))

            case .stayHold:
                // HOLD: the fan is forced up to the floor. Keep it STEADY.
                // Re-assert the target only (idempotent, no md toggle) so there
                // is no physical disturbance.
                if machineTemp != nil, let b = holdBaselineTemp[i] {
                    blindTicks[i] = 0
                    try controller.setTarget(rpm: floorRPM, fan: i)
                    log?(String(format: "fan %d: HOLD@%.0f steady (temp %@, base %.0f°C)  actual=%.0f",
                                i, floorRPM, tempStr, b, actual))
                } else {
                    // Temperature unreadable: don't react to a transient miss.
                    let blind = (blindTicks[i] ?? 0) + 1
                    blindTicks[i] = blind
                    try controller.setTarget(rpm: floorRPM, fan: i)
                    log?(String(format: "fan %d: HOLD@%.0f steady (temp unreadable %d/%d)  actual=%.0f",
                                i, floorRPM, blind, blindProbeTicks, actual))
                }

            case .release:
                // Hand the fan back to the firmware — either the machine warmed
                // past the baseline, or (fail-safe) temperature has been
                // unreadable for too long.
                if let t = machineTemp, let b = holdBaselineTemp[i] {
                    try controller.setManual(false, fan: i)   // release to AUTO
                    holding[i] = false
                    holdBaselineTemp[i] = nil
                    blindTicks[i] = 0
                    log?(String(format: "fan %d: HOLD -> release to AUTO (temp %.0f°C > base %.0f+%.0f)  actual=%.0f",
                                i, t, b, releaseTempMarginC, actual))
                } else {
                    let blind = (blindTicks[i] ?? 0) + 1
                    try controller.setManual(false, fan: i)
                    holding[i] = false
                    holdBaselineTemp[i] = nil
                    blindTicks[i] = 0
                    log?(String(format: "fan %d: HOLD -> release to AUTO (temp unreadable for %d ticks, fail-safe)  actual=%.0f",
                                i, blind, actual))
                }
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
