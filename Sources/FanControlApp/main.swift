import AppKit
import SwiftUI
import SMCFan

// MARK: - Model

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

    /// True while an admin prompt / privileged action is in flight, so the
    /// popover doesn't dismiss out from under it.
    var isPerformingPrivilegedAction = false

    var hasFans: Bool { !fans.isEmpty }

    // Root-owned helper + sudoers rule installed by "Always authorize".
    private let installedHelper = "/Library/FanControl/fanctl"

    private let controller: FanController?

    init() {
        controller = try? FanController()
        // Trust the saved preference only if the privileged helper is still present.
        alwaysAuthorize = UserDefaults.standard.bool(forKey: "alwaysAuthorize")
            && FileManager.default.fileExists(atPath: installedHelper)
        refresh()
        if let f = fans.first { sliderRPM = f.target > 0 ? f.target : f.actual }
    }

    func refresh() {
        guard let c = controller else { status = "Cannot open SMC"; return }
        do {
            let s = try c.status()
            fans = s.fans
            manual = s.allManual
            if let f = s.fans.first {
                if f.minRPM > 0 { minRPM = f.minRPM }
                if f.maxRPM > 0 { maxRPM = f.maxRPM }
                if !manual && (sliderRPM < minRPM || sliderRPM > maxRPM) {
                    sliderRPM = min(max(f.actual, minRPM), maxRPM)
                }
            }
            status = s.fans.isEmpty ? "No fans found" : ""
        } catch {
            status = "\(error)"
        }
    }

    func setMode(manual on: Bool) {
        if on { runPrivileged(["set", String(Int(sliderRPM.rounded()))]) }
        else  { runPrivileged(["auto"]) }
    }

    func applySpeed() {
        guard manual else { return }
        runPrivileged(["set", String(Int(sliderRPM.rounded()))])
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

    // MARK: - "Always authorize" (opt-in passwordless sudo)

    func setAlwaysAuthorize(_ on: Bool) {
        on ? enableAlwaysAuthorize() : disableAlwaysAuthorize()
    }

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
        printf '%s ALL=(root) NOPASSWD: /Library/FanControl/fanctl set [0-9]*, /Library/FanControl/fanctl auto, /Library/FanControl/fanctl max\\n' '\(NSUserName())' > "$T"
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
        if manual { runPrivileged(["auto"]) }

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
                        Text("\(Int(f.actual)) rpm").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Picker("Mode", selection: Binding(
                get: { model.manual },
                set: { model.setMode(manual: $0) }
            )) {
                Text("Auto").tag(false)
                Text("Manual").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.hasFans)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(Int(model.sliderRPM)) rpm").monospacedDigit()
                }
                Slider(
                    value: $model.sliderRPM,
                    in: model.minRPM...max(model.maxRPM, model.minRPM + 1),
                    onEditingChanged: { editing in if !editing { model.applySpeed() } }
                )
                .disabled(!model.manual || !model.hasFans)
                HStack {
                    Text("min \(Int(model.minRPM))")
                    Spacer()
                    Text("max \(Int(model.maxRPM))")
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .opacity(model.manual ? 1 : 0.5)

            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Always authorize", isOn: Binding(
                    get: { model.alwaysAuthorize },
                    set: { model.setAlwaysAuthorize($0) }
                ))
                .toggleStyle(.switch)
                Text("Skip the password prompt.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .disabled(!model.hasFans)

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

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        let host = NSHostingController(rootView: FanView(model: model))
        host.sizingOptions = [.preferredContentSize]   // popover tracks the (now constant) content size
        popover.contentViewController = host

        // Click outside still dismisses the popover — but not while an auth
        // prompt or other privileged action is in flight.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown, !self.model.isPerformingPrivilegedAction else { return }
            self.popover.performClose(nil)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.refresh()
            self.updateTitle()
        }
        updateTitle()
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
        } else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
