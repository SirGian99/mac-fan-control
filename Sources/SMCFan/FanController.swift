import Foundation

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
    public init() throws { smc = try SMC() }

    // MARK: - SMC value coding

    static func decode(type: String, bytes: [UInt8]) -> Double {
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

    public func setManual(_ manual: Bool) throws {
        let n = try fanCount()
        var didPerFan = false
        for i in 0..<n {
            guard let key = modeKey(i) else { continue }
            let type = (try? smc.read(key).type) ?? "ui8 "
            try smc.write(key, bytes: FanController.encode(type: type, value: manual ? 1 : 0))
            didPerFan = true
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
