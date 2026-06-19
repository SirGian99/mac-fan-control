import Foundation
import SMCFan

func usage() {
    print("""
    fan — control Apple Silicon Mac fan speed via the SMC

    USAGE
      fan [status]              Show fan RPMs and mode        (no root needed)
      fan status --json        Machine-readable status        (no root needed)
      sudo fan set <rpm>       Force ALL fans to <rpm> rpm (manual)
      sudo fan set <rpm> -f N  Force only fan N
      sudo fan max             Force all fans to their maximum
      sudo fan auto            Restore automatic fan control

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

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "status"

do {
    let fc = try FanController()

    switch command {
    case "status", "":
        let status = try fc.status()
        if args.contains("--json") {
            let payload: [String: Any] = [
                "allManual": status.allManual,
                "fans": status.fans.map { [
                    "index": $0.index, "actual": $0.actual, "min": $0.minRPM,
                    "max": $0.maxRPM, "target": $0.target, "manual": $0.manual,
                ] },
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else if status.fans.isEmpty {
            print("No fans reported (FNum = 0). This Mac may be fanless (e.g. a MacBook Air).")
        } else {
            for f in status.fans {
                print(String(format: "Fan %d: %5.0f rpm   [min %.0f, max %.0f]   target %.0f   (%@)",
                             f.index, f.actual, f.minRPM, f.maxRPM, f.target, f.manual ? "manual" : "auto"))
            }
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
        requireRoot("auto")
        try fc.setAuto()
        print("Restored automatic fan control")

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
