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
    /// Claude plan usage for the deck-wide panel: the live account reading,
    /// fetched every `usageInterval` (and on ↻), with each agent's state file
    /// as a fallback between fetches. nil until something has reported once.
    @Published private(set) var aiUsage: AIUsage?
    @Published private(set) var usageRefreshing = false
    /// Why the last live fetch produced nothing (sign-in missing/expired,
    /// offline). Cleared by the next success; the strip turns red while set.
    @Published private(set) var usageError: String?

    /// Keeps a freshly-launched app showing "Starting" until its port comes up
    /// (or this deadline passes), so polling doesn't snap it back to "Stopped".
    private var pendingUntil: [String: Date] = [:]
    /// Keeps an app showing "Stopping" while a kill is in flight, so polling
    /// doesn't flip it back to "Running" before the ports actually drain.
    private var stoppingUntil: [String: Date] = [:]
    /// Last time each remote agent's `/status` was fetched over ssh, so the
    /// 2.5s poll can throttle the expensive round-trip to ~15s.
    private var lastRemoteFetch: [String: Date] = [:]
    private var timer: Timer?
    private var usageTimer: Timer?
    /// How often the live usage fetch runs. The endpoint costs no limit, but
    /// the numbers only move as fast as requests are made, so a minute is
    /// plenty — and it keeps the keychain read off the 2.5s poll.
    static let usageInterval: TimeInterval = 60

    init() {
        apps = AppConfig.load()
        for app in apps { statuses[app.id] = .stopped }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop, so we're already on the main actor.
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshUsage()
        usageTimer = Timer.scheduledTimer(withTimeInterval: Self.usageInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUsage() }
        }
    }

    var runningCount: Int {
        statuses.values.filter { $0 == .running }.count
    }

    func refresh() {
        let apps = self.apps
        let wantsSchedules = apps.contains { $0.schedule != nil }
        // Decide (on the main actor) which remote agents are due for an ssh
        // status fetch. Throttled to ~15s: the poll fires every 2.5s, but an
        // ssh round-trip is expensive, so most ticks just re-read the cached
        // file. Marked now so overlapping ticks can't stack ssh calls.
        let now = Date()
        var dueRemote = Set<String>()
        for app in apps where app.agent?.remote == true {
            guard app.agent?.host?.contains("@") == true else { continue }
            if lastRemoteFetch[app.id].map({ now.timeIntervalSince($0) >= 15 }) ?? true {
                dueRemote.insert(app.id)
                lastRemoteFetch[app.id] = now
            }
        }
        DispatchQueue.global(qos: .utility).async {
            let listening = Shell.listeningPorts()
            let labels = wantsSchedules ? Shell.scheduledLaunchdLabels() : []
            var statuses: [String: AgentStatus] = [:]
            var configs: [String: AgentConfig] = [:]
            var readings: [AIUsage] = [PlanUsage.readCache()].compactMap { $0 }
            // For a remote agent there is no local port; its pill comes from how
            // fresh the status is. Computed here, applied (grace-aware) after
            // applyStatuses, which would otherwise mark a portless app stopped.
            var remoteFreshLive: [String: Bool] = [:]
            for app in apps {
                guard let panel = app.agent else { continue }
                configs[app.id] = AgentFiles.readConfig(panel)
                if panel.remote {
                    // Fetch over ssh when due (also caches to the state file),
                    // else re-read the last cached file.
                    var st: AgentStatus? = dueRemote.contains(app.id) ? AgentFiles.fetchRemoteStatus(panel) : nil
                    if st == nil { st = AgentFiles.readStateStatus(panel) }
                    if let st { statuses[app.id] = st }
                    let fresh = st?.updatedAt.map { Date().timeIntervalSince($0) < 180 } ?? false
                    // Every state a living process reports — including parked at
                    // the cap and erroring — so the pill says whether there is
                    // something to Stop, not whether it is being productive.
                    // `halted_error` is NOT live: the breaker exited the
                    // process, so the pill must say Stopped (with the red
                    // detail line saying why) and offer Start.
                    let live = ["running", "sweeping", "cooldown", "paused_limit", "halted_limit",
                                "waiting_backend", "idle", "starting", "error"].contains(st?.status ?? "")
                    remoteFreshLive[app.id] = fresh && live
                    if let u = PlanUsage.readAgentState(panel, source: app.name) { readings.append(u) }
                } else {
                    if let u = PlanUsage.readAgentState(panel, source: app.name) { readings.append(u) }
                    if !Set(app.ports).intersection(listening).isEmpty,
                       let status = AgentFiles.fetchStatus(panel) {
                        statuses[app.id] = status
                    }
                }
            }
            DispatchQueue.main.async {
                self.applyStatuses(apps: apps, listening: listening)
                if wantsSchedules { self.applySchedules(apps: apps, labels: labels) }
                // Remote pill: honour an optimistic Start/Stop grace first (so a
                // just-issued systemctl doesn't snap back before telemetry
                // catches up), then the freshness verdict.
                let now = Date()
                for app in apps where app.agent?.remote == true {
                    if let until = self.pendingUntil[app.id], until > now {
                        self.statuses[app.id] = .starting
                    } else if let until = self.stoppingUntil[app.id], until > now {
                        self.statuses[app.id] = .stopping
                    } else {
                        self.statuses[app.id] = (remoteFreshLive[app.id] ?? false) ? .running : .stopped
                        self.pendingUntil[app.id] = nil
                        self.stoppingUntil[app.id] = nil
                    }
                }
                self.agentStatuses = statuses
                for (id, cfg) in configs where self.agentConfigs[id] != cfg {
                    self.agentConfigs[id] = cfg
                }
                // Newest wins, whoever asked. The live fetch normally is, but
                // an agent's rate_limit_event from ten seconds ago beats a
                // fetch from fifty seconds ago — and is all there is when the
                // fetch is failing.
                let newest = readings.max { $0.observedAt < $1.observedAt }
                if newest != self.aiUsage { self.aiUsage = newest }
            }
        }
    }

    // MARK: - Ordering

    /// Drag-to-reorder UI state (lives here rather than as @State because
    /// build.sh compiles with bare swiftc, which lacks the macro plugin the
    /// current SDK's @State needs). `dropTarget` is the row being hovered.
    @Published var dropTarget: String?
    @Published var dropAtEnd = false

    /// Drag-to-reorder: put the app with `id` where `target` currently sits
    /// (before it), shifting the rest. Persisted at once so the order survives
    /// a relaunch; the status maps are keyed by id, so nothing else moves.
    func move(_ id: String, before target: String) {
        guard id != target,
              let from = apps.firstIndex(where: { $0.id == id }),
              let to = apps.firstIndex(where: { $0.id == target }) else { return }
        let app = apps.remove(at: from)
        apps.insert(app, at: to > from ? to - 1 : to)
        AppConfig.save(apps)
    }

    /// Drop past the last row: move to the end.
    func moveToEnd(_ id: String) {
        guard let from = apps.firstIndex(where: { $0.id == id }), from != apps.count - 1 else { return }
        let app = apps.remove(at: from)
        apps.append(app)
        AppConfig.save(apps)
    }

    // MARK: - Plan usage

    /// After a 429 the timer skips fetches until this passes (the ↻ button
    /// still forces one) — the endpoint rate-limits per account, and every
    /// relaunch fetches at once, so a burst of them earns a pause.
    private var usageBackoffUntil: Date?

    /// Fetch the live account usage — on the timer and from the ↻ button.
    /// Off the main thread: the keychain read and the request both block.
    func refreshUsage(force: Bool = false) {
        guard !usageRefreshing else { return }
        if !force, let until = usageBackoffUntil, until > Date() { return }
        usageRefreshing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PlanUsage.fetchLive()
            DispatchQueue.main.async {
                self.usageRefreshing = false
                switch result {
                case .reading(let u):
                    self.usageError = nil
                    self.aiUsage = u
                case .failed(let why):
                    // Keep showing the last reading; the footer says why it
                    // is not moving.
                    self.usageError = why
                    if why.hasPrefix("rate limited") {
                        self.usageBackoffUntil = Date().addingTimeInterval(5 * 60)
                    }
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

    /// Set whether the agent carries on by itself after its usage cap resets.
    /// Local: merged into the config file like model/effort. Remote: merged
    /// into the VM's file over ssh. Either way the agent picks it up at the
    /// top of its next cycle — and if it is parked (halted_limit) with the
    /// flag off, turning it on is what lets it go.
    func setAgentResume(_ app: ManagedApp, _ on: Bool) {
        guard let panel = app.agent, panel.configWritable else { return }
        appendLog(app, "AGENT CONFIG — auto-resume after limit \(on ? "ON" : "OFF") (applies next cycle)")
        if panel.remote {
            // Optimistic: reflect it in the cached status AND the local mirror
            // of the VM's config (what the row reads each poll) until the next
            // fetch brings the VM's own file back.
            if var st = agentStatuses[app.id] { st.resumeAfterLimit = on; agentStatuses[app.id] = st }
            var mirror = agentConfigs[app.id] ?? AgentFiles.readConfig(panel)
            mirror.resumeAfterLimit = on
            agentConfigs[app.id] = mirror
            AgentFiles.writeConfig(panel, mirror)
            lastRemoteFetch[app.id] = nil
            DispatchQueue.global(qos: .userInitiated).async {
                let r = AgentFiles.writeRemoteConfigKey(panel, key: "resume_after_limit", value: on)
                if r.status != 0 {
                    let detail = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async {
                        self.appendLog(app, "REMOTE config write failed (exit \(r.status))" +
                                            (detail.isEmpty ? "" : " — \(detail)"))
                    }
                }
            }
            return
        }
        var cfg = agentConfigs[app.id] ?? AgentFiles.readConfig(panel)
        cfg.resumeAfterLimit = on
        agentConfigs[app.id] = cfg
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
        if app.agent?.remote == true { remoteControl(app, "start"); return }
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
        if app.agent?.remote == true { remoteControl(app, "stop"); return }
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

    /// Start / stop / restart a REMOTE agent by driving its systemd unit over
    /// ssh. The optimistic pill (Starting/Stopping) is held by pendingUntil /
    /// stoppingUntil so the poll's freshness verdict doesn't snap it back before
    /// the VM and the next status fetch catch up; clearing lastRemoteFetch makes
    /// that fetch happen on the very next tick.
    func remoteControl(_ app: ManagedApp, _ verb: String) {
        guard let panel = app.agent, panel.remoteControllable,
              let host = panel.host, let svc = panel.serviceName else {
            appendLog(app, "REMOTE \(verb) — set agent.host (user@host) and agent.serviceName " +
                           "in apps.json first")
            return
        }
        if verb == "stop" {
            statuses[app.id] = .stopping
            pendingUntil[app.id] = nil
            stoppingUntil[app.id] = Date().addingTimeInterval(30)
        } else {                                   // start / restart
            statuses[app.id] = .starting
            stoppingUntil[app.id] = nil
            pendingUntil[app.id] = Date().addingTimeInterval(75)   // agent boots + waits for backend
        }
        lastRemoteFetch[app.id] = nil              // force a fresh ssh status fetch next tick
        appendLog(app, "REMOTE \(verb) — systemctl \(verb) \(svc) on \(host)")
        let command = "\(AgentFiles.remoteBase(host)) \("systemctl \(verb) \(svc)".shellQuoted)"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.runLoginResult(command)
            if result.status != 0 {
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.appendLog(app, "REMOTE \(verb) failed (exit \(result.status))" +
                                        (detail.isEmpty ? "" : " — \(detail)"))
                }
            }
        }
    }

    /// Force-stop, let the ports drain, then relaunch — all in one detached
    /// shell so the new servers reparent to launchd just like a fresh Start.
    func restart(_ app: ManagedApp) {
        if app.agent?.remote == true { remoteControl(app, "restart"); return }
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
    /// For a remote agent there is no local log, so fetch the VM service's
    /// recent journal over ssh into a temp file and open that.
    func openLog(_ app: ManagedApp) {
        if let panel = app.agent, panel.remote {
            appendLog(app, "REMOTE LOGS — journalctl \(panel.serviceName ?? "?")")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(app.id)-journal.log")
            DispatchQueue.global(qos: .userInitiated).async {
                let text = AgentFiles.remoteJournal(panel)
                try? text.data(using: .utf8)?.write(to: url)
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            return
        }
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
