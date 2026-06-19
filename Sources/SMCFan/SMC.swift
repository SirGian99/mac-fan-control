import Foundation
import IOKit

public enum SMCError: Error, CustomStringConvertible {
    case driverNotFound
    case open(kern_return_t)
    case call(kern_return_t)
    case smcResult(UInt8)
    case keyNotFound(String)

    public var description: String {
        switch self {
        case .driverNotFound:    return "AppleSMC driver not found"
        case .open(let r):       return "IOServiceOpen failed (0x\(String(format: "%08x", r)))"
        case .call(let r):       return "IOConnectCallStructMethod failed (0x\(String(format: "%08x", r)))"
        case .smcResult(let r):  return "SMC returned error result 0x\(String(format: "%02x", r))"
        case .keyNotFound(let k): return "SMC key not found: \(k)"
        }
    }
}

// 32-byte payload area of the SMC parameter struct.
typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // Explicit trailing padding: without it Swift reuses this struct's tail
    // padding for the outer struct's fields, shrinking SMCParamStruct to 76
    // bytes and breaking the AppleSMC ABI (which expects the 80-byte C layout).
    private var pad0: UInt8 = 0
    private var pad1: UInt8 = 0
    private var pad2: UInt8 = 0
}

// Mirrors AppleSMC's user-client ABI. Must be exactly 80 bytes.
struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,
                           0,0,0,0,0,0,0,0,
                           0,0,0,0,0,0,0,0,
                           0,0,0,0,0,0,0,0)
}

// Sub-commands carried in `data8`.
private let kSMCReadKey: UInt8 = 5
private let kSMCWriteKey: UInt8 = 6
private let kSMCGetKeyFromIndex: UInt8 = 8
private let kSMCGetKeyInfo: UInt8 = 9
// IOConnectCallStructMethod selector (kSMCHandleYPCEvent).
private let kernelIndexSMC: UInt32 = 2

/// Thin wrapper around the AppleSMC IOKit user client.
public final class SMC {
    private var conn: io_connect_t = 0

    public init() throws {
        precondition(MemoryLayout<SMCParamStruct>.stride == 80,
                     "SMCParamStruct must be 80 bytes (got \(MemoryLayout<SMCParamStruct>.stride))")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.driverNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == kIOReturnSuccess else { throw SMCError.open(kr) }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = withUnsafeMutablePointer(to: &output) { outPtr in
            withUnsafePointer(to: &input) { inPtr in
                IOConnectCallStructMethod(conn, kernelIndexSMC, inPtr, inputSize, outPtr, &outputSize)
            }
        }
        guard kr == kIOReturnSuccess else { throw SMCError.call(kr) }
        guard output.result == 0 else { throw SMCError.smcResult(output.result) }
        return output
    }

    /// Pack up to 4 ASCII chars into a big-endian FourCharCode.
    public static func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }
        return r
    }

    /// Decode a FourCharCode type back to its 4-char string (e.g. "flt ").
    public static func typeString(_ code: UInt32) -> String {
        let chars: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),  UInt8(code & 0xff),
        ]
        return String(bytes: chars, encoding: .ascii) ?? ""
    }

    /// Total number of keys the SMC exposes (read from the "#KEY" pseudo-key).
    public func keyCount() throws -> Int {
        let (_, bytes) = try read("#KEY")
        var v: UInt32 = 0
        for b in bytes.prefix(4) { v = (v << 8) | UInt32(b) }
        return Int(v)
    }

    /// Resolve the key name at a given enumeration index.
    public func keyFromIndex(_ index: Int) throws -> String {
        var input = SMCParamStruct()
        input.data8 = kSMCGetKeyFromIndex
        input.data32 = UInt32(index)
        return SMC.typeString(try call(&input).key)
    }

    func keyInfo(_ key: UInt32) throws -> SMCKeyInfoData {
        var input = SMCParamStruct()
        input.key = key
        input.data8 = kSMCGetKeyInfo
        return try call(&input).keyInfo
    }

    public func keyExists(_ keyStr: String) -> Bool {
        (try? keyInfo(SMC.fourCC(keyStr))) != nil
    }

    /// Read a key's raw bytes plus its declared type string.
    public func read(_ keyStr: String) throws -> (type: String, bytes: [UInt8]) {
        let key = SMC.fourCC(keyStr)
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = info.dataSize
        input.data8 = kSMCReadKey
        let out = try call(&input)
        var tuple = out.bytes
        let bytes: [UInt8] = withUnsafeBytes(of: &tuple) { raw in
            Array(raw.prefix(Int(info.dataSize)))
        }
        return (SMC.typeString(info.dataType), bytes)
    }

    /// Write raw bytes to a key. Requires root for most writable keys.
    public func write(_ keyStr: String, bytes: [UInt8]) throws {
        let key = SMC.fourCC(keyStr)
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = info.dataSize
        input.data8 = kSMCWriteKey
        let n = min(Int(info.dataSize), 32, bytes.count)
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for i in 0..<n { raw[i] = bytes[i] }
        }
        _ = try call(&input)
    }
}
