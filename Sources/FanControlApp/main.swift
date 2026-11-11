import AppKit
import SwiftUI
import SMCFan

// MARK: - Model

/// The three fan-control modes exposed by the UI.
enum FanControlMode: String { case automatic, minimum }

/// Observable state for the popover. Reads run in-process (no privilege);
/// writes are delegated to the bundled `fan` CLI via an admin prompt.
final class FanModel: ObservableObject {
    @Published var fans: [FanInfo] = []
    @Published var manual = false
    @Published var sliderRPM: Double = 2500
    @Published var minRPM: Double = 1200
    @Published var maxRPM: Double = 6000
    @Published var status = ""
    @Published var alwaysAuthorize = false
    /// Current fan-control mode. `.automatic` hands all fans to firmware;
    /// `.minimum` runs the per-fan floor supervisor so fans never drop below
    /// `sliderRPM` (but the firmware may still ramp them higher under load).
    @Published var mode: FanControlMode = .automatic
    @Published var cpuTemp: Double?
    @Published var gpuTemp: Double?

    /// True while an admin prompt / privileged action is in flight, so the
    /// popover doesn't dismiss out from under it.
    var isPerformingPrivilegedAction = false

    var hasFans: Bool { !fans.isEmpty }

    // Root-owned helper + sudoers rule installed by "Always authorize".
    private let installedHelper = "/Library/FanControl/fanctl"

    private let controller: FanController?

    // Per-fan floor supervisor state (mirrors MinFloorSupervisor). `sliderRPM`
    // is the floor value; `lastTarget` is the last commanded RPM per fan and
    // `lastStepIndex` the current curve band per fan, so we only re-issue a
    // privileged write when the stepped target moves meaningfully.
    private var lastTarget: [Int: Double] = [:]
    private var lastStepIndex: [Int: Int] = [:]
    private let hysteresisC = 5.0
    private let writeDeltaRPM = 25.0

    init() {
        controller = try? FanController()
        // Trust the saved preference only if the privileged helper is still present.
        alwaysAuthorize = UserDefaults.standard.bool(forKey: "alwaysAuthorize")
            && FileManager.default.fileExists(atPath: installedHelper)
        mode = FanControlMode(rawValue: UserDefaults.standard.string(forKey: "fanControlMode") ?? "") ?? .automatic
        refresh()
        // Default the floor to the saved value, or to the fan's real minimum RPM
        // — NOT the current fan speed, which isn't "the minimum".
        if let saved = UserDefaults.standard.object(forKey: "floorRPM") as? Double, saved > 0 {
            sliderRPM = min(max(saved, minRPM), maxRPM)
        } else {
            sliderRPM = minRPM
        }

        // Launch reconciliation: if Minimum was on but we can't act silently
        // (no passwordless helper yet), start clean in Automatic to avoid a
        // surprise prompt at launch. Otherwise the supervisor timer resumes it.
        if mode == .minimum
            && !(alwaysAuthorize && FileManager.default.fileExists(atPath: installedHelper)) {
            mode = .automatic
        }
    }

    func refresh(includeTemps: Bool = true) {
        guard let c = controller else { status = "Cannot open SMC"; return }
        do {
            let s = try c.status()
            fans = s.fans
            manual = s.allManual
            if includeTemps {
                let t = c.temperatures()
                cpuTemp = t.cpu
                gpuTemp = t.gpu
            }
            if let f = s.fans.first {
                if f.minRPM > 0 { minRPM = f.minRPM }
                if f.maxRPM > 0 { maxRPM = f.maxRPM }
                if mode == .automatic && (sliderRPM < minRPM || sliderRPM > maxRPM) {
                    sliderRPM = min(max(sliderRPM, minRPM), maxRPM)
                }
            }
            status = s.fans.isEmpty ? "No fans found" : ""
        } catch {
            status = "\(error)"
        }
    }

    /// Ensure the scoped passwordless rule is installed so we can act without a
    /// prompt on every change. Shows ONE admin prompt the first time. Returns
    /// whether we're authorized afterward.
    @discardableResult
    private func ensureAuthorized() -> Bool {
        // Already authorized AND the installed helper matches this build's `fan`
        // (a mismatch means a stale rule/helper from an older version — reinstall
        // so the scoped commands stay current instead of silently failing).
        if alwaysAuthorize
            && FileManager.default.fileExists(atPath: installedHelper)
            && installedHelperIsCurrent() {
            return true
        }
        enableAlwaysAuthorize()   // one admin prompt; sets alwaysAuthorize on success
        return alwaysAuthorize
    }

    /// True if the root-owned helper is byte-identical to this build's bundled
    /// `fan`, i.e. the passwordless install is current (not from an older version).
    private func installedHelperIsCurrent() -> Bool {
        guard let installed = FileManager.default.contents(atPath: installedHelper),
              let current = FileManager.default.contents(atPath: helperPath()) else { return false }
        return installed == current
    }

    func setMode(_ newMode: FanControlMode) {
        let previous = mode
        // Minimum mode actuates the fans, so authorize once up front.
        if newMode != .automatic {
            guard ensureAuthorized() else {
                mode = previous
                status = "Controlling fans needs authorization."
                return
            }
        }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: "fanControlMode")
        lastTarget.removeAll()
        lastStepIndex.removeAll()
        switch newMode {
        case .automatic:
            runPrivileged(["auto"])
        case .minimum:
            superviseTick()                                            // react immediately
        }
    }

    func applySpeed() {
        // Remember the chosen floor so it persists across launches.
        UserDefaults.standard.set(sliderRPM, forKey: "floorRPM")
        switch mode {
        case .automatic:
            break
        case .minimum:
            // Re-apply immediately with the new floor.
            lastTarget.removeAll()
            lastStepIndex.removeAll()
            superviseTick()
        }
    }

    /// One iteration of the per-fan floor supervisor, sharing `fanCurveStep` /
    /// `fanCurveTarget` with the CLI's MinFloorSupervisor. Fans are always driven
    /// (never released), with the target following a stepped temperature curve:
    /// the floor when cool, stepping up toward each fan's max as the machine
    /// heats up. Within a band the target is constant (with hysteresis at the
    /// boundaries), so it changes only when temperature crosses a threshold.
    func superviseTick() {
        guard mode == .minimum, let c = controller else { return }
        let floor = sliderRPM.rounded()
        let temps = c.temperatures()
        let machineTemp = [temps.cpu, temps.gpu].compactMap { $0 }.max()
        guard let s = try? c.status(), !s.fans.isEmpty else { return }
        for f in s.fans {
            let i = f.index
            let idx = fanCurveStep(current: lastStepIndex[i] ?? 0, machineTemp: machineTemp,
                                   curve: defaultFanCurve, hysteresisC: hysteresisC)
            lastStepIndex[i] = idx
            let target = fanCurveTarget(stepIndex: idx, floorRPM: floor,
                                        fanMaxRPM: f.maxRPM, curve: defaultFanCurve)
            let last = lastTarget[i]
            if !f.manual || last == nil || abs(target - (last ?? -1)) >= writeDeltaRPM {
                runPrivileged(["set", String(Int(target.rounded())), "-f", String(i)])
                lastTarget[i] = target
            }
        }
    }

    /// Called on quit: hand the fans back to the firmware synchronously if we
    /// were holding a floor or in manual mode.
    func shutdownRestoreAuto() {
        if mode != .automatic || manual { runPrivileged(["auto"]) }
    }

    private func beginPrivileged() { isPerformingPrivilegedAction = true }
    private func endPrivileged() {
        // Brief grace period so a trailing click on the auth dialog doesn't
        // immediately dismiss the popover once focus returns.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.isPerformingPrivilegedAction = false
        }
    }

    /// Apply a fan command as root. With "Always authorize" on, this goes
    /// through the scoped passwordless sudo rule (no prompt); otherwise it uses
    /// the standard macOS admin dialog around the bundled helper.
    private func runPrivileged(_ cliArgs: [String]) {
        beginPrivileged()
        defer { endPrivileged() }
        if alwaysAuthorize,
           FileManager.default.fileExists(atPath: installedHelper),
           sudoNoPrompt(cliArgs) {
            refresh()
            return
        }
        let parts = ([helperPath()] + cliArgs).map { "'" + $0 + "'" }.joined(separator: " ")
        let source = "do shell script \"\(parts)\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let e = errorInfo, let msg = e[NSAppleScript.errorMessage] as? String {
            // -128 == user cancelled the auth dialog; not an error worth showing.
            if (e[NSAppleScript.errorNumber] as? Int) != -128 { status = msg }
        }
        refresh()
    }

    /// Run the installed root helper via `sudo -n` (never prompts). Returns
    /// false if the sudo rule isn't in place, so the caller can fall back.
    private func sudoNoPrompt(_ cliArgs: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", installedHelper] + cliArgs
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func helperPath() -> String {
        let exeDir = (Bundle.main.executablePath as NSString?)?.deletingLastPathComponent ?? "."
        return exeDir + "/fan"
    }

    // MARK: - Authorization (scoped passwordless sudo, installed automatically)

    private func enableAlwaysAuthorize() {
        // Install a root-owned copy of the helper and a sudoers rule scoped to
        // ONLY the fan subcommands. /Library/FanControl is root-owned so the
        // helper can't be swapped by a non-root user (no privilege escalation).
        let script = """
        #!/bin/sh
        set -e
        mkdir -p /Library/FanControl
        cp '\(helperPath())' /Library/FanControl/fanctl
        chown -R root:wheel /Library/FanControl
        chmod 755 /Library/FanControl /Library/FanControl/fanctl
        T="$(mktemp)"
        printf '%s ALL=(root) NOPASSWD: /Library/FanControl/fanctl set [0-9]*, /Library/FanControl/fanctl set [0-9]* -f [0-9], /Library/FanControl/fanctl auto, /Library/FanControl/fanctl auto -f [0-9], /Library/FanControl/fanctl max\\n' '\(NSUserName())' > "$T"
        if visudo -cf "$T" >/dev/null 2>&1; then
          install -m 0440 -o root -g wheel "$T" /etc/sudoers.d/fancontrol
          rm -f "$T"
        else
          rm -f "$T"; exit 1
        fi
        """
        if runPrivilegedScript(script) {
            alwaysAuthorize = true
            UserDefaults.standard.set(true, forKey: "alwaysAuthorize")
        } else {
            alwaysAuthorize = false   // revert the toggle if it failed or was cancelled
        }
    }

    private func disableAlwaysAuthorize() {
        let script = """
        #!/bin/sh
        rm -f /etc/sudoers.d/fancontrol
        rm -rf /Library/FanControl
        """
        if runPrivilegedScript(script) {
            alwaysAuthorize = false
            UserDefaults.standard.set(false, forKey: "alwaysAuthorize")
        } else {
            // Cancelled/failed: the rule may still be installed, so reflect the
            // real state instead of showing "off" while passwordless sudo lives on.
            let stillInstalled = FileManager.default.fileExists(atPath: installedHelper)
            alwaysAuthorize = stillInstalled
            UserDefaults.standard.set(stillInstalled, forKey: "alwaysAuthorize")
        }
    }

    /// Run a shell script as root via a single admin prompt (write to temp,
    /// execute with administrator privileges). Returns true on success.
    @discardableResult
    private func runPrivilegedScript(_ script: String) -> Bool {
        beginPrivileged()
        defer { endPrivileged() }
        let tmp = NSTemporaryDirectory() + "fanctl-setup-\(getpid()).sh"
        do { try script.write(toFile: tmp, atomically: true, encoding: .utf8) } catch { return false }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let source = "do shell script \"/bin/sh -- '\(tmp)'\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let e = errorInfo {
            if (e[NSAppleScript.errorNumber] as? Int) != -128 {
                status = (e[NSAppleScript.errorMessage] as? String) ?? "Authorization failed"
            }
            return false
        }
        return true
    }

    // MARK: - Uninstall

    func uninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall FanControl?"
        alert.informativeText = "This removes the login item and moves FanControl to the Trash. "
            + "Fan control returns to automatic."
        alert.addButton(withTitle: "Uninstall")   // default
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 1. Hand the fans back to macOS while the bundled helper still exists.
        if mode != .automatic || manual { runPrivileged(["auto"]) }

        // 2. Remove the passwordless-sudo helper + rule if "Always authorize" was on.
        if alwaysAuthorize || FileManager.default.fileExists(atPath: installedHelper) {
            disableAlwaysAuthorize()
        }

        // 3. Remove the login item (user domain — no root needed).
        removeLoginItem()

        // 3. Move the app bundle to the Trash, then quit.
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
            DispatchQueue.main.async {
                if let error = error {
                    NSAlert(error: error).runModal()
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func removeLoginItem() {
        let label = "local.fancontrol"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        try? task.run()
        task.waitUntilExit()
        let plist = ("~/Library/LaunchAgents/\(label).plist" as NSString).expandingTildeInPath
        try? FileManager.default.removeItem(atPath: plist)
    }
}

// MARK: - View

struct FanView: View {
    @ObservedObject var model: FanModel

    private var sliderTitle: String {
        switch model.mode {
        case .automatic: return "Speed"
        case .minimum: return "Minimum speed"
        }
    }

    private var modeCaption: String {
        switch model.mode {
        case .automatic: return "macOS controls the fans automatically."
        case .minimum: return "Fans won’t drop below this, and step up in stages as your Mac heats up."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "fanblades")
                Text("Fan Control").font(.headline)
                Spacer()
            }
            Divider()

            if model.fans.isEmpty {
                Text(model.status.isEmpty ? "No controllable fans found on this Mac." : model.status)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.fans, id: \.index) { f in
                    HStack {
                        Text("Fan \(f.index + 1)")
                        Spacer()
                        Text(verbatim: "\(Int(f.actual)) rpm").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }

            if let cpu = model.cpuTemp {
                HStack {
                    Text("CPU")
                    Spacer()
                    Text(TemperatureUnit.system.format(celsius: cpu)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let gpu = model.gpuTemp {
                HStack {
                    Text("GPU")
                    Spacer()
                    Text(TemperatureUnit.system.format(celsius: gpu)).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle("Minimum fan speed", isOn: Binding(
                get: { model.mode == .minimum },
                set: { model.setMode($0 ? .minimum : .automatic) }
            ))
            .toggleStyle(.switch)
            .disabled(!model.hasFans)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(sliderTitle)
                    Spacer()
                    Text(verbatim: "\(Int(model.sliderRPM)) rpm").monospacedDigit()
                }
                Slider(
                    value: $model.sliderRPM,
                    in: model.minRPM...max(model.maxRPM, model.minRPM + 1),
                    onEditingChanged: { editing in if !editing { model.applySpeed() } }
                )
                .disabled(model.mode == .automatic || !model.hasFans)
                HStack {
                    Text(verbatim: "min \(Int(model.minRPM))")
                    Spacer()
                    Text(verbatim: "max \(Int(model.maxRPM))")
                }
                .font(.caption2).foregroundStyle(.secondary)
                Text(modeCaption)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.mode == .minimum {
                    let topTarget = model.fans.map { $0.target }.max() ?? 0
                    let ramping = topTarget > model.sliderRPM + 100
                    Text(ramping ? "Ramping · \(Int(topTarget)) rpm" : "At minimum")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .opacity(model.mode == .automatic ? 0.5 : 1)

            // Shown only when there's something to report. The popover is
            // .applicationDefined, so it resizes cleanly when this appears.
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Button("Refresh") { model.refresh() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)

            Button(role: .destructive) { model.uninstall() } label: {
                Text("Uninstall FanControl…").frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = FanModel()
    private var timer: Timer?
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ensureLoginItemRegistered()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "—"
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .applicationDefined   // don't auto-close on focus loss (auth prompts, edits)
        popover.delegate = self
        // The SwiftUI content is created only while the popover is open (see
        // togglePopover / popoverDidClose). A hidden NSHostingView otherwise
        // sits in a continuous layout loop and burns CPU in the background.

        // Click outside still dismisses the popover — but not while an auth
        // prompt or other privileged action is in flight.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown, !self.model.isPerformingPrivilegedAction else { return }
            self.popover.performClose(nil)
        }

        // Light background poll for the menu-bar number. Temperatures (many SMC
        // reads) are gathered only while the popover is actually open.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.model.mode == .minimum { self.model.superviseTick() }
            self.model.refresh(includeTemps: self.popover.isShown)
            self.updateTitle()
        }
        model.refresh(includeTemps: false)
        updateTitle()

        showFirstRunAuthNoticeIfNeeded()
    }

    /// One-time heads-up (first launch only) that controlling the fans needs a
    /// single admin authorization. A flag ensures it shows at most once, ever.
    private func showFirstRunAuthNoticeIfNeeded() {
        let key = "didShowAuthIntro"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "One-time permission needed"
        alert.informativeText = "To control your fans, FanControl needs administrator permission. "
            + "The first time you turn on “Minimum fan speed,” macOS will ask for your password — just once. "
            + "After that it adjusts the fans silently, and always hands control back to macOS when you switch it off or quit."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// On first launch after install, register the per-user LaunchAgent so the
    /// app starts automatically at login. We only write the plist if it's
    /// missing — macOS auto-loads ~/Library/LaunchAgents at the next login, so
    /// we don't bootstrap it now (that would start a duplicate in this session).
    private func ensureLoginItemRegistered() {
        let label = "local.fancontrol"
        let dir = ("~/Library/LaunchAgents" as NSString).expandingTildeInPath
        let plistPath = "\(dir)/\(label).plist"
        guard !FileManager.default.fileExists(atPath: plistPath),
              let exe = Bundle.main.executablePath else { return }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: URL(fileURLWithPath: plistPath))
        }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        // Show just the number (highest of the fans) — no icon, per request.
        if let rpm = model.fans.map(\.actual).max() {
            button.title = "\(Int(rpm))"
        } else {
            button.title = "—"
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        model.refresh()   // full state (incl temps) before building the view
        let host = NSHostingController(rootView: FanView(model: model))
        popover.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        let fit = host.view.fittingSize
        popover.contentSize = NSSize(width: max(fit.width, 280), height: max(fit.height, 200))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // Tear down the SwiftUI view when the popover closes so nothing renders in
    // the background (the fix for the idle-CPU / layout-loop problem).
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    // Restore firmware AUTO on quit if we were holding a floor or in manual mode.
    func applicationWillTerminate(_ notification: Notification) {
        model.shutdownRestoreAuto()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
