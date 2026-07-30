import Foundation
import SMCFan

func usage() {
    print("""
    fan — control Apple Silicon Mac fan speed via the SMC

    USAGE
      fan [status]              Show fan RPMs and mode        (no root needed)
      fan status --json        Machine-readable status        (no root needed)
      fan keys [F|all|PREFIX]  Dump SMC keys (read-only, no root). Default
                               prefix "F" (fan keys); "all"/"" dumps everything.
      sudo fan set <rpm>       Force ALL fans to <rpm> rpm (manual)
      sudo fan set <rpm> -f N  Force only fan N
      sudo fan max             Force all fans to their maximum
      sudo fan auto [-f IDX]   Restore automatic fan control (all fans,
                               or only fan IDX)
      sudo fan supervise <rpm> [--interval MS] [--temp-margin C] [--epsilon RPM] [--verify-settle MS] [--once]
                               Enforce a software minimum-RPM floor: keep fans
                               in macOS auto whenever the firmware wants >= the
                               floor, forcing them up to the floor only while
                               cool. Ctrl-C restores automatic.

    Setting speed writes to the SMC, which requires root — prefix with sudo.
    Manual mode persists until you run `fan auto` or reboot.
    """)
}

func err(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func requireRoot(_ action: String) {
    guard geteuid() != 0 else { return }
    err("Error: `fan \(action)` writes to the SMC and needs root. Re-run as:\n  sudo fan \(action)")
    exit(1)
}

/// Value following a flag, e.g. optValue(["-f","1"], "-f") == "1"
func optValue(_ args: [String], _ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Set from the SIGINT/SIGTERM handlers below; polled by the supervisor loop's
/// `shouldStop` closure. `sig_atomic_t` is the only type safe to touch from a C
/// signal handler.
var stopRequested: sig_atomic_t = 0

/// C-compatible (non-capturing) signal handler installed for SIGINT/SIGTERM.
func handleStopSignal(_ signal: Int32) {
    stopRequested = 1
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "status"

do {
    let fc = try FanController()

    switch command {
    case "status", "":
        let status = try fc.status()
        let temps = fc.temperatures()
        if args.contains("--json") {
            var payload: [String: Any] = [
                "allManual": status.allManual,
                "fans": status.fans.map { [
                    "index": $0.index, "actual": $0.actual, "min": $0.minRPM,
                    "max": $0.maxRPM, "target": $0.target, "manual": $0.manual,
                ] },
            ]
            if let c = temps.cpu { payload["cpuTempC"] = c }
            if let g = temps.gpu { payload["gpuTempC"] = g }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            if status.fans.isEmpty {
                print("No fans reported (FNum = 0). This Mac may be fanless (e.g. a MacBook Air).")
            } else {
                for f in status.fans {
                    print(String(format: "Fan %d: %5.0f rpm   [min %.0f, max %.0f]   target %.0f   (%@)",
                                 f.index, f.actual, f.minRPM, f.maxRPM, f.target, f.manual ? "manual" : "auto"))
                }
            }
            let unit = TemperatureUnit.system
            if let c = temps.cpu { print("CPU: \(unit.format(celsius: c))") }
            if let g = temps.gpu { print("GPU: \(unit.format(celsius: g))") }
        }

    case "set":
        guard args.count >= 2, let rpm = Double(args[1]) else { usage(); exit(2) }
        if (try? fc.fanCount()) ?? 0 == 0 { err("No controllable fans on this Mac."); exit(1) }
        if let raw = optValue(args, "-f") ?? optValue(args, "--fan"), let idx = Int(raw) {
            requireRoot("set \(Int(rpm)) -f \(idx)")
            try fc.setManual(true)
            try fc.setTarget(rpm: rpm, fan: idx)
            print("Set fan \(idx) → \(Int(rpm)) rpm (manual)")
        } else {
            requireRoot("set \(Int(rpm))")
            try fc.setAllSpeeds(rpm: rpm)
            print("Set \(try fc.fanCount()) fan(s) → \(Int(rpm)) rpm (manual)")
        }

    case "max":
        if (try? fc.fanCount()) ?? 0 == 0 { err("No controllable fans on this Mac."); exit(1) }
        requireRoot("max")
        try fc.setMax()
        print("Set all fans → maximum (manual)")

    case "auto":
        if let raw = optValue(args, "-f") ?? optValue(args, "--fan"), let idx = Int(raw) {
            requireRoot("auto -f \(idx)")
            try fc.setManual(false, fan: idx)
            print("Fan \(idx) → automatic")
        } else {
            requireRoot("auto")
            try fc.setAuto()
            print("Restored automatic fan control")
        }

    case "supervise":
        guard args.count >= 2, let rpm = Double(args[1]) else { usage(); exit(2) }
        if (try? fc.fanCount()) ?? 0 == 0 { err("No controllable fans on this Mac."); exit(1) }
        requireRoot("supervise \(Int(rpm))")

        let intervalMs = Int(optValue(args, "--interval") ?? "") ?? 2000
        let tempMargin = Double(optValue(args, "--temp-margin") ?? "") ?? 10.0
        let epsilon    = Double(optValue(args, "--epsilon") ?? "") ?? 50
        let verifySettleMs = Int(optValue(args, "--verify-settle") ?? "") ?? 800

        let supervisor = MinFloorSupervisor(
            controller: fc,
            floorRPM: rpm,
            intervalMs: intervalMs,
            releaseTempMarginC: tempMargin,
            epsilonRPM: epsilon,
            verifySettleMs: verifySettleMs,
            log: { print($0) }
        )

        if args.contains("--once") {
            print("supervise --once: single control step at floor \(Int(rpm)) rpm")
            try supervisor.stepOnce()
            try supervisor.restoreAuto()
            print("Done; automatic fan control restored.")
        } else {
            print("Minimum-fan-speed supervisor")
            print("  floor        = \(Int(rpm)) rpm")
            print("  interval     = \(intervalMs) ms")
            print(String(format: "  temp-margin  = %.1f C", tempMargin))
            print("  epsilon      = \(Int(epsilon)) rpm")
            print("  verify-settle = \(verifySettleMs) ms")
            print("Fans stay in macOS auto whenever the firmware wants >= floor; forced up to the floor only while cool.")
            print("A held fan is left STEADY and handed back to macOS when temperature climbs — no periodic probing.")
            print("Press Ctrl-C to stop (restores automatic).")

            signal(SIGINT, handleStopSignal)
            signal(SIGTERM, handleStopSignal)

            // run() restores automatic in its own defer, so Ctrl-C (which sets
            // stopRequested) hands the fans back to the firmware on the way out.
            try supervisor.run(shouldStop: { stopRequested != 0 })
            print("Stopped; automatic fan control restored.")
        }

    case "keys":
        // READ-ONLY SMC key enumeration/diagnostic. No writes, no root needed.
        let smc = try SMC()
        let total = try smc.keyCount()

        // Optional fourcc prefix filter. Default "F" (fan keys); "all"/""/"*"
        // dumps everything.
        let filterArg = args.count >= 2 ? args[1] : "F"
        let prefix = (filterArg == "all" || filterArg == "*") ? "" : filterArg

        // Types FanController.decode() understands as numbers.
        let numericTypes: Set<String> = ["flt ", "fpe2", "fp2e", "ui8 ", "ui8",
                                         "si8 ", "si8", "ui16", "si16", "ui32"]

        print("SMC key count: \(total)")
        print(prefix.isEmpty ? "Dumping ALL keys" : "Filter: keys starting with \"\(prefix)\"")

        var shown = 0
        for i in 0..<total {
            guard let name = try? smc.keyFromIndex(i) else { continue }
            guard prefix.isEmpty || name.hasPrefix(prefix) else { continue }

            var type = "?"
            var size = -1
            var value = "<unreadable>"
            do {
                let (t, bytes) = try smc.read(name)
                type = t
                size = bytes.count
                if numericTypes.contains(t) {
                    value = String(format: "%g", FanController.decode(type: t, bytes: bytes))
                } else {
                    let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                    value = "0x[\(hex)]"
                    // Best-effort ASCII for string-ish / flag types.
                    if t == "ch8*" || t == "flag" || t.hasPrefix("{")
                        || bytes.allSatisfy({ $0 == 0 || ($0 >= 0x20 && $0 < 0x7f) }) {
                        let ascii = String(bytes: bytes.filter { $0 != 0 }, encoding: .ascii) ?? ""
                        if !ascii.isEmpty { value += " \"\(ascii)\"" }
                    }
                }
            } catch {
                value = "<read error: \(error)>"
            }

            print(String(format: "%@  type=\"%@\"  size=%d  value=%@", name, type, size, value))
            shown += 1
        }
        print("(\(shown) key(s) shown of \(total) total)")

    case "-h", "--help", "help":
        usage()

    default:
        err("Unknown command: \(command)\n")
        usage()
        exit(2)
    }
} catch {
    err("Error: \(error)")
    exit(1)
}
