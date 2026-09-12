import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppManager: ObservableObject {
    @Published private(set) var apps: [ManagedApp] = []
    @Published private(set) var statuses: [String: AppStatus] = [:]
    /// Whether each app's launchd job is scheduled, for apps that have one.
    /// Read back from launchd on every poll — launchd is the source of truth,
    /// so flipping the job in a terminal shows up here too.
    @Published private(set) var scheduled: [String: Bool] = [:]
    /// Apps whose launchctl call is in flight. The switch is disabled while it
    /// is, so a double-tap can't race two bootstraps against each other.
    @Published private(set) var scheduleBusy: Set<String> = []
    /// What each background agent last reported over its status port, for apps
    /// that have one. Absent while the agent is down — the tile then shows the
    /// pickers alone, since those read a file rather than the agent.
    @Published private(set) var agentStatuses: [String: AgentStatus] = [:]
    /// Each agent's model/effort, read back from its config file every poll so
    /// the pickers track a hand edit as well as their own writes.
    @Published private(set) var agentConfigs: [String: AgentConfig] = [:]
    /// Claude plan usage for the deck-wide panel: the newest reading across every
    /// agent's state file and the last manual probe. nil until something has
    /// asked Claude at least once.
    @Published private(set) var aiUsage: AIUsage?
    @Published private(set) var usageProbing = false
    @Published private(set) var usageProbeError: String?

    /// Keeps a freshly-launched app showing "Starting" until its port comes up
    /// (or this deadline passes), so polling doesn't snap it back to "Stopped".
    private var pendingUntil: [String: Date] = [:]
    /// Keeps an app showing "Stopping" while a kill is in flight, so polling
    /// doesn't flip it back to "Running" before the ports actually drain.
    private var stoppingUntil: [String: Date] = [:]
    private var timer: Timer?

    init() {
        apps = AppConfig.load()
        for app in apps { statuses[app.id] = .stopped }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop, so we're already on the main actor.
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var runningCount: Int {
        statuses.values.filter { $0 == .running }.count
    }

    func refresh() {
        let apps = self.apps
        let wantsSchedules = apps.contains { $0.schedule != nil }
        DispatchQueue.global(qos: .utility).async {
            let listening = Shell.listeningPorts()
            let labels = wantsSchedules ? Shell.scheduledLaunchdLabels() : []
            // Agents: the status body only exists while the port is up, but the
            // config file is there either way — read it so the pickers work on a
            // stopped agent, which is when you'd set them.
            var statuses: [String: AgentStatus] = [:]
            var configs: [String: AgentConfig] = [:]
            var readings: [AIUsage] = [PlanUsage.readProbe()].compactMap { $0 }
            for app in apps {
                guard let panel = app.agent else { continue }
                configs[app.id] = AgentFiles.readConfig(panel)
                if let u = PlanUsage.readAgentState(panel, source: app.name) { readings.append(u) }
                if !Set(app.ports).intersection(listening).isEmpty,
                   let status = AgentFiles.fetchStatus(panel) {
                    statuses[app.id] = status
                }
            }
            DispatchQueue.main.async {
                self.applyStatuses(apps: apps, listening: listening)
                if wantsSchedules { self.applySchedules(apps: apps, labels: labels) }
                self.agentStatuses = statuses
                for (id, cfg) in configs where self.agentConfigs[id] != cfg {
                    self.agentConfigs[id] = cfg
                }
                // Newest wins, whoever asked. A probe from a minute ago beats
                // the agent's reading from an hour ago and vice versa.
                let newest = readings.max { $0.observedAt < $1.observedAt }
                if newest != self.aiUsage { self.aiUsage = newest }
            }
        }
    }

    // MARK: - Plan usage

    /// Refresh the usage panel by sending Claude a message. Manual only.
    func probeUsage() {
        guard !usageProbing else { return }
        usageProbing = true
        usageProbeError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PlanUsage.probe()
            DispatchQueue.main.async {
                self.usageProbing = false
                if let u = result {
                    self.aiUsage = u
                } else {
                    self.usageProbeError = "No reading — is `claude` installed and signed in?"
                }
            }
        }
    }

    // MARK: - Background agents

    /// Set an agent's model or effort. Written to the agent's config file, which
    /// it re-reads at the start of every cycle — so the change lands on the
    /// next batch rather than tearing down the one in flight. Only the two keys
    /// are touched; whatever else the file holds (caps, batch sizes) stays.
    func setAgentConfig(_ app: ManagedApp, model: String? = nil, effort: String? = nil) {
        guard let panel = app.agent else { return }
        var cfg = agentConfigs[app.id] ?? AgentFiles.readConfig(panel)
        if let m = model, panel.models.contains(m) { cfg.model = m }
        if let e = effort, panel.efforts.contains(e) { cfg.effort = e }
        agentConfigs[app.id] = cfg          // optimistic; the poll re-reads the file
        appendLog(app, "AGENT CONFIG — model \(cfg.model), effort \(cfg.effort) (applies next cycle)")
        DispatchQueue.global(qos: .userInitiated).async {
            AgentFiles.writeConfig(panel, cfg)
        }
    }

    private func applyStatuses(apps: [ManagedApp], listening: Set<Int>) {
        let now = Date()
        for app in apps {
            let up = Set(app.ports).intersection(listening)

            // Mid-stop: hold "Stopping" until the ports actually drain (or a
            // safety cap passes). Without this, a poll that still sees the port
            // listening would flip the tile back to Running while the kill is
            // in flight — the Stop → Start → Stop flicker.
            if let until = stoppingUntil[app.id] {
                if !up.isEmpty && until > now {
                    statuses[app.id] = .stopping
                    continue
                }
                stoppingUntil[app.id] = nil   // drained (or capped) → resume normal logic
            }

            let status: AppStatus
            if up.isEmpty {
                if let until = pendingUntil[app.id], until > now {
                    status = .starting
                } else {
                    status = .stopped
                    pendingUntil[app.id] = nil
                }
            } else if let ready = app.effectiveReadyPort, up.contains(ready) {
                status = .running
                pendingUntil[app.id] = nil
            } else {
                status = .starting
            }
            statuses[app.id] = status
        }
    }

    private func applySchedules(apps: [ManagedApp], labels: Set<String>) {
        for app in apps {
            guard let job = app.schedule else { continue }
            // A toggle mid-flight owns the value until launchctl returns; the
            // poll would otherwise snap the switch back for one cycle.
            if scheduleBusy.contains(app.id) { continue }
            scheduled[app.id] = labels.contains(job.label)
        }
    }

    // MARK: - Scheduled jobs

    /// Turn an app's launchd job on or off.
    ///
    /// Both halves are needed in both directions. Off = `bootout` (stop it now)
    /// + `disable` (persist it, or login would load the agent straight back).
    /// On = `enable` (clear that override, otherwise bootstrap is refused) +
    /// `bootstrap`. Nothing is written to apps.json: the next poll reads the
    /// truth back out of launchd.
    func setScheduled(_ app: ManagedApp, enabled: Bool) {
        guard let job = app.schedule, !scheduleBusy.contains(app.id) else { return }

        let domain = "gui/$(id -u)"
        let target = "\(domain)/\(job.label)"
        let plist = job.expandedPlistPath
        let command: String
        if enabled {
            guard FileManager.default.fileExists(atPath: plist) else {
                // Nothing to bootstrap — the agent was never installed (or the
                // repo moved). Say so in the log and leave the switch off.
                appendLog(app, "SCHEDULE ON failed — no launch agent at \(plist). " +
                               "Install it: cp scripts/\(job.label).plist ~/Library/LaunchAgents/")
                scheduled[app.id] = false
                return
            }
            command = "launchctl enable \(target); launchctl bootstrap \(domain) \(plist.shellQuoted)"
        } else {
            command = "launchctl bootout \(target); launchctl disable \(target)"
        }

        scheduleBusy.insert(app.id)
        scheduled[app.id] = enabled          // optimistic; the poll corrects it
        appendLog(app, "SCHEDULE \(enabled ? "ON" : "OFF") — \(job.label)")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.runLoginResult(command)
            let actual = Shell.scheduledLaunchdLabels().contains(job.label)
            DispatchQueue.main.async {
                if actual != enabled {
                    // bootout on an already-stopped job (and bootstrap on an
                    // already-loaded one) exit non-zero harmlessly, so only a
                    // wrong *end state* is worth reporting.
                    let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.appendLog(app, "SCHEDULE \(enabled ? "ON" : "OFF") did not take" +
                                        (detail.isEmpty ? "" : " — \(detail)"))
                }
                self.scheduled[app.id] = actual
                self.scheduleBusy.remove(app.id)
            }
        }
    }

    func start(_ app: ManagedApp) {
        // Ignore if it's already coming up or running. Launching a second
        // ./start.sh on top of a live one leaves orphans fighting over the
        // ports, which is what makes a tile bounce back to "Stopped".
        if let s = statuses[app.id], s != .stopped { return }

        statuses[app.id] = .starting
        pendingUntil[app.id] = Date().addingTimeInterval(40)

        appendLog(app, "START — \(app.startCommand)")
        let command = launchCommand(for: app)
        DispatchQueue.global(qos: .userInitiated).async {
            Shell.runLogin(command, interactive: true)   // needs ~/.zshrc for npm/node
        }
    }

    func stop(_ app: ManagedApp) {
        statuses[app.id] = .stopping
        pendingUntil[app.id] = nil
        // Hold "Stopping" until ports drain; 10s cap covers SIGTERM + SIGKILL.
        stoppingUntil[app.id] = Date().addingTimeInterval(10)

        appendLog(app, "STOP — freeing ports \(app.ports.map(String.init).joined(separator: ", "))")
        let command = killCommand(for: app)
        DispatchQueue.global(qos: .userInitiated).async {
            Shell.runLogin(command)
        }
    }

    /// Force-stop, let the ports drain, then relaunch — all in one detached
    /// shell so the new servers reparent to launchd just like a fresh Start.
    func restart(_ app: ManagedApp) {
        statuses[app.id] = .stopping
        pendingUntil[app.id] = Date().addingTimeInterval(40)
        // Show "Stopping" only during the brief kill window; once the old ports
        // drain this clears and pendingUntil takes over (Starting → Running).
        // Kept short so it expires before the new server binds (no false stop).
        stoppingUntil[app.id] = Date().addingTimeInterval(3)

        appendLog(app, "RESTART — \(app.startCommand)")
        let command = "\(killCommand(for: app)); sleep 2; \(launchCommand(for: app))"
        DispatchQueue.global(qos: .userInitiated).async {
            Shell.runLogin(command, interactive: true)   // needs ~/.zshrc for npm/node
        }
    }

    /// Open an app's log file in the default viewer (Console / TextEdit) so you
    /// can see what happened — including failures like "npm: command not found".
    func openLog(_ app: ManagedApp) {
        let url = logURL(for: app)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url)   // create empty so there's something to open
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Logging

    private static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private func logURL(for app: ManagedApp) -> URL {
        AppConfig.logDir.appendingPathComponent("\(app.id).log")
    }

    /// Append a timestamped Launch Deck line to the app's log, so the log shows
    /// what Launch Deck *did* (the command it ran) next to the process output.
    /// The detached server appends its own stdout/stderr to the same file.
    private func appendLog(_ app: ManagedApp, _ message: String) {
        let line = "\n[\(Self.logStamp.string(from: Date()))] ▶ Launch Deck: \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = logURL(for: app)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)   // file didn't exist yet
        }
    }

    // MARK: - Command builders

    /// Detached launch command. `nohup … &` lets the login shell exit
    /// immediately so the job reparents to launchd — quitting Launch Deck
    /// never kills your running apps.
    private func launchCommand(for app: ManagedApp) -> String {
        let dir = app.expandedDirectory.shellQuoted
        let log = AppConfig.logDir.appendingPathComponent("\(app.id).log").path.shellQuoted
        return "cd \(dir) && nohup \(app.startCommand) >> \(log) 2>&1 &"
    }

    /// Stop command. Uses a custom `stopCommand` when set; otherwise frees every
    /// port — SIGTERM first for a clean shutdown, then SIGKILL anything still
    /// holding on a second later. This is what reliably clears the port (plain
    /// SIGTERM leaves `uvicorn --reload` / vite processes lingering).
    private func killCommand(for app: ManagedApp) -> String {
        if let custom = app.stopCommand, !custom.isEmpty {
            return "cd \(app.expandedDirectory.shellQuoted) && \(custom)"
        }
        // Kill whatever owns each port — by *process group* (kill -<pgid>), so a
        // respawning supervisor goes down with its workers (one `kill -<pgid>`
        // takes out the whole `start.sh` tree: uvicorn reloader + worker + vite).
        // SIGTERM first for a clean shutdown, then SIGKILL anything still holding
        // on a second later.
        //
        // NOTE: piped `while read` — NOT `for pid in $pids`. These commands run
        // under /bin/zsh, which does NOT word-split unquoted parameters, so an
        // lsof result of multiple PIDs ("4990\n4993") would otherwise be passed
        // as a single bogus token and nothing gets killed (the "Stop does
        // nothing" bug). `while read` splits per line in both zsh and bash.
        let killGroup = "while read -r pid; do " +
            "pgid=$(ps -o pgid= -p \"$pid\" | tr -d ' '); " +
            "[ -n \"$pgid\" ] && kill -%@ \"-$pgid\" 2>/dev/null; done"
        return app.ports.map { port in
            let lsof = "lsof -nP -tiTCP:\(port) -sTCP:LISTEN"
            let term = killGroup.replacingOccurrences(of: "%@", with: "TERM")
            let kill = killGroup.replacingOccurrences(of: "%@", with: "KILL")
            return "\(lsof) | \(term); sleep 1; \(lsof) | \(kill)"
        }.joined(separator: "; ")
    }

    func open(_ app: ManagedApp) {
        guard let raw = app.url, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
}
