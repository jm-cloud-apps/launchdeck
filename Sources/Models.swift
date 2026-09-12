import Foundation

enum AppStatus: String, Codable {
    case stopped, starting, running, stopping
}

/// A launchd background job that belongs to an app — work that runs on a timer
/// with no server and no port, so the tile's port-based status can't see it
/// (InventoryForge's scan collector is the case this exists for).
///
/// This only says *where* the job is. Its on/off state is launchd's, read back
/// live with `launchctl`, never mirrored in apps.json — otherwise the switch
/// would drift from reality the moment the job is touched from a terminal.
struct ScheduledJob: Codable, Equatable {
    var label: String        // launchd label, e.g. "com.inventoryforge.collector"
    var plistPath: String    // the installed agent, under ~/Library/LaunchAgents
    var caption: String      // shown beside the switch, e.g. "Background scans"

    var expandedPlistPath: String {
        (plistPath as NSString).expandingTildeInPath
    }
}

/// A background AI agent that belongs to an app — a loop of headless `claude`
/// runs that reports itself over a loopback HTTP port (QuantForge's EP sweep
/// agent is the case this exists for).
///
/// Launch Deck is the remote control, not the brain: what gets swept, in what
/// order, and what counts as done all live in the agent's own repo. The port
/// is still what says whether it is running, same as any tile; this only says
/// where to read the rest — the cycle and queue, the model/effort in use —
/// and where the pickers write. (Plan usage is read from the agent's state
/// file into the deck-wide panel, not shown per tile.) Model and effort are
/// read by the agent at the start of each cycle, so changing them here never
/// aborts a batch mid-grade.
struct AgentPanel: Codable, Equatable {
    var statusURL: String    // e.g. "http://127.0.0.1:8765/status"
    var configPath: String   // the JSON the agent reads model/effort from
    var models: [String]     // aliases `claude --model` accepts, in picker order
    var efforts: [String]    // `claude --effort` levels, in picker order

    var expandedConfigPath: String {
        (configPath as NSString).expandingTildeInPath
    }

    /// The agent's persisted state, beside its config. Read for the plan-usage
    /// panel even when the agent is down — it is the last `rate_limit_event`
    /// the agent saw, which is the freshest figure available without spending.
    var expandedStatePath: String {
        ((expandedConfigPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("state.json")
    }
}

/// One plan-usage window, as Claude reports it: percent used and when it resets.
struct UsageWindow: Equatable {
    var pct: Double
    var resetsAt: Date?
}

/// Claude plan usage — the five-hour and weekly limits — plus where and when
/// the reading came from. There is no live query for this: a figure is what
/// some `claude` request was told, so it always carries its timestamp.
struct AIUsage: Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var observedAt: Date
    var source: String     // "EP Sweep Agent" or "probe"

    /// Decodes the shape the sweep agent writes (`usage` in its state.json):
    /// `{"five_hour": {"pct": 63, "resets_at": 1789173600}, "seven_day": {…},
    ///   "observed_at": 1789170000}`. The probe writes the same shape.
    init?(json: [String: Any], source: String) {
        guard let at = json["observed_at"] as? Double else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let w = json[key] as? [String: Any], let pct = w["pct"] as? Double else { return nil }
            let resets = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return UsageWindow(pct: pct, resetsAt: resets)
        }
        fiveHour = window("five_hour")
        sevenDay = window("seven_day")
        guard fiveHour != nil || sevenDay != nil else { return nil }
        observedAt = Date(timeIntervalSince1970: at)
        self.source = source
    }
}

/// What the agent's `/status` says about itself. Decoded loosely on purpose:
/// the tile should degrade to "Running" with blanks, not refuse to render,
/// when the agent adds a field.
struct AgentStatus: Equatable {
    var status: String           // running · cooldown · paused_limit · waiting_backend · stopped
    var detail: String
    var cycle: Int
    var queued: Int              // candidates swept and waiting to be graded
    var posted: Int              // entries the library confirms this agent added
    var sessionsSwept: Int

    init?(json: [String: Any]) {
        guard let status = json["status"] as? String else { return nil }
        self.status = status
        detail = json["detail"] as? String ?? ""
        cycle = json["cycle"] as? Int ?? 0
        let cov = json["coverage"] as? [String: Any]
        queued = cov?["queued"] as? Int ?? 0
        posted = cov?["posted"] as? Int ?? 0
        sessionsSwept = cov?["sessions"] as? Int ?? 0
    }
}

/// The two fields the tile's pickers own, read back from the agent's config
/// file each poll so a hand edit shows up too.
struct AgentConfig: Equatable {
    var model: String
    var effort: String
}

/// One launchable project. Decoded from apps.json so you can add apps
/// without recompiling. `id` is the name, so names must be unique.
struct ManagedApp: Identifiable, Codable, Equatable {
    var id: String { name }
    var name: String
    var subtitle: String
    var icon: String            // SF Symbol name
    var color: String           // hex, e.g. "4f8cff"
    var directory: String       // working dir, supports a leading ~
    var startCommand: String    // shell command run from `directory`
    var stopCommand: String?    // optional override; default = kill the listed ports
    var ports: [Int]            // ports this app listens on (used for status + default stop)
    var readyPort: Int?         // the port that means "fully up" (usually the frontend)
    var url: String?            // opened in the browser by the Open button
    // Defaulted so the memberwise init and older apps.json files (which have no
    // such key) both keep working.
    var schedule: ScheduledJob? = nil   // optional launchd timer job, toggled on the tile
    var agent: AgentPanel? = nil        // optional background AI agent, with usage + pickers on the tile

    var expandedDirectory: String {
        (directory as NSString).expandingTildeInPath
    }

    /// Port that signals the app is fully ready; falls back to the last port.
    var effectiveReadyPort: Int? {
        readyPort ?? ports.last
    }
}

/// Loads/seeds apps.json under ~/Library/Application Support/LaunchDeck/.
enum AppConfig {
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchDeck", isDirectory: true)
    }
    static var configURL: URL { supportDir.appendingPathComponent("apps.json") }
    static var seededURL: URL { supportDir.appendingPathComponent("seeded.json") }
    static var logDir: URL { supportDir.appendingPathComponent("logs", isDirectory: true) }

    static func load() -> [ManagedApp] {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        guard let data = try? Data(contentsOf: configURL),
              let saved = try? JSONDecoder().decode([ManagedApp].self, from: data),
              !saved.isEmpty else {
            // First run: write the default config so it's easy to edit later.
            write(defaultApps)
            writeSeeded(Set(defaultApps.map(\.name)))
            return defaultApps
        }

        // Upgrade path: a build that adds entries to `defaultApps` would otherwise
        // never reach anyone who already has an apps.json — it's only written on
        // first run. So append the defaults this install has never been offered,
        // keeping the user's own edits and ordering intact. The `seeded` ledger is
        // what makes a *deliberately deleted* app stay deleted rather than
        // reappearing on every launch.
        let (backfilled, didBackfill) = backfillNewFields(saved)
        let known = Set(saved.map(\.name)).union(loadSeeded())
        let additions = defaultApps.filter { !known.contains($0.name) }
        guard !additions.isEmpty else {
            if didBackfill { write(backfilled) }
            return backfilled
        }

        let merged = backfilled + additions
        write(merged)
        writeSeeded(known.union(additions.map(\.name)))
        return merged
    }

    /// Fill in fields added to `defaultApps` *after* an app was already seeded.
    /// The merge above matches by name, so an existing entry counts as "known"
    /// and never picks up a newly added field — InventoryForge's `schedule`
    /// would have stayed nil forever on this machine, and the toggle with it.
    /// Only nil fields are filled, so a deliberate user edit is never clobbered.
    private static func backfillNewFields(_ saved: [ManagedApp]) -> ([ManagedApp], Bool) {
        let defaults = Dictionary(defaultApps.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        let filled = saved.map { app -> ManagedApp in
            var copy = app
            if app.schedule == nil, let job = defaults[app.name]?.schedule {
                copy.schedule = job
                changed = true
            }
            if app.agent == nil, let panel = defaults[app.name]?.agent {
                copy.agent = panel
                changed = true
            }
            return copy
        }
        return (filled, changed)
    }

    private static func write(_ apps: [ManagedApp]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(apps) {
            try? data.write(to: configURL)
        }
    }

    /// Names of default apps this install has been offered at least once.
    private static func loadSeeded() -> Set<String> {
        guard let data = try? Data(contentsOf: seededURL),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names)
    }

    private static func writeSeeded(_ names: Set<String>) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(names.sorted()) {
            try? data.write(to: seededURL)
        }
    }
}

private let githubRoot =
    "~/Library/CloudStorage/OneDrive-Personal/Desktop - onedrive/github"

/// Vite/npm dev server, installing deps first on a fresh clone.
///
/// The `zsh -c` wrapper matters: `launchCommand` builds
/// `cd … && nohup <startCommand> >> <log> 2>&1 &`, so a bare compound command
/// splits — only its *last* segment is backgrounded and redirected, and the
/// `npm install` output escapes the log. Wrapping makes the whole sequence one
/// nohup'd, redirected, detached process.
private func npmDev(port: Int? = nil) -> String {
    let dev = port.map { "npm run dev -- --port \($0)" } ?? "npm run dev"
    return "zsh -c '[ -d node_modules ] || npm install; \(dev)'"
}

/// No-build-step sites (plain HTML/CSS/JS): just serve the directory.
/// Bound to loopback — these are local dev tools, not LAN services.
private func staticServer(port: Int) -> String {
    "python3 -m http.server \(port) --bind 127.0.0.1"
}

let defaultApps: [ManagedApp] = [
    ManagedApp(
        name: "QuantForge",
        subtitle: "Trading platform · :5173",
        icon: "chart.line.uptrend.xyaxis",
        color: "4f8cff",
        directory: "\(githubRoot)/quantforge",
        startCommand: "./start.sh",
        stopCommand: nil,
        ports: [8000, 5173],
        readyPort: 5173,
        url: "http://localhost:5173"
    ),
    ManagedApp(
        name: "Budgeteer",
        subtitle: "Budget app · :5174",
        icon: "dollarsign.circle.fill",
        color: "34d399",
        directory: "\(githubRoot)/budgeteer",
        startCommand: "./start.sh",
        stopCommand: nil,
        ports: [8001, 5174],
        readyPort: 5174,
        url: "http://localhost:5174"
    ),
    ManagedApp(
        name: "Study App",
        subtitle: "StudyForge · :5180",
        icon: "book.fill",
        color: "f59e0b",
        directory: "\(githubRoot)/study-app",
        startCommand: "[ -d node_modules ] || npm install; npm run dev",
        stopCommand: nil,
        ports: [5180, 5182],
        readyPort: 5180,
        url: "http://localhost:5180"
    ),
    ManagedApp(
        name: "PlantForge",
        subtitle: "Plant inventory · :5190",
        icon: "leaf.fill",
        color: "16a34a",
        directory: "\(githubRoot)/plantforge",
        startCommand: npmDev(),
        stopCommand: nil,
        ports: [5190],
        readyPort: 5190,
        url: "http://localhost:5190"
    ),
    ManagedApp(
        name: "Elevator Clicker",
        subtitle: "Kids' clicker game · :5185",
        icon: "building.2.fill",
        color: "a78bfa",
        directory: "\(githubRoot)/elevator-clicker",
        // Its vite.config.js pins 5180 with strictPort, which is Study App's port —
        // so override on the CLI. strictPort still applies to 5185, meaning a
        // collision fails loudly instead of silently landing on another port
        // (which would leave the tile stuck on "Stopped" forever).
        startCommand: npmDev(port: 5185),
        stopCommand: nil,
        ports: [5185],
        readyPort: 5185,
        url: "http://localhost:5185"
    ),
    ManagedApp(
        name: "Housing Calculator",
        subtitle: "Buy vs rent · :4174",
        icon: "house.fill",
        color: "38bdf8",
        directory: "\(githubRoot)/housing-calculator",
        startCommand: staticServer(port: 4174),
        stopCommand: nil,
        ports: [4174],
        readyPort: 4174,
        url: "http://localhost:4174"
    ),
    ManagedApp(
        name: "InventoryForge",
        subtitle: "Pokémon restocks · :4175",
        icon: "shippingbox.fill",
        color: "f472b6",
        directory: "\(githubRoot)/inventoryforge",
        // Dashboard only. The collector is a scheduled headed-browser job with no
        // port, so port-based status can't track it — it's the `schedule` toggle
        // below, not Start/Stop.
        startCommand: staticServer(port: 4175),
        stopCommand: nil,
        ports: [4175],
        readyPort: 4175,
        url: "http://localhost:4175",
        // Each run pops a real Chromium window (patchright headed is the only way
        // past Cloudflare), so being able to silence it for a while matters.
        schedule: ScheduledJob(
            label: "com.inventoryforge.collector",
            plistPath: "~/Library/LaunchAgents/com.inventoryforge.collector.plist",
            caption: "Background scans"
        )
    ),
    ManagedApp(
        name: "Trade Templates",
        subtitle: "Client site demos · :4181",
        icon: "rectangle.3.group.fill",
        color: "2dd4bf",
        directory: "\(githubRoot)/templates",
        // Static showcase — no build step, so just serve the repo root. Port 4181
        // matches the `templates` entry in quantforge's .claude/launch.json on
        // purpose: it's the same directory served the same way, so whichever
        // starts first wins rather than the two racing on different ports.
        startCommand: staticServer(port: 4181),
        stopCommand: nil,
        ports: [4181],
        readyPort: 4181,
        // Opens the gallery, which is what you'd actually put in front of a client.
        url: "http://localhost:4181"
    ),
    ManagedApp(
        name: "EP Sweep Agent",
        subtitle: "QuantForge · claude sweeps · :8765",
        icon: "sparkles",
        color: "c084fc",
        directory: "\(githubRoot)/quantforge/backend",
        // A loop of headless `claude -p` runs, each one sweep-and-grade cycle
        // against the QuantForge backend (which must be up on :8000 — the agent
        // waits for it rather than failing). The status port is the tile's
        // liveness signal, and the kill-by-port-group Stop reaches the running
        // `claude` child too, since it shares the group.
        startCommand: "zsh -c 'source venv/bin/activate && exec python tools/ep_sweep_agent.py --port 8765'",
        stopCommand: nil,
        ports: [8765],
        readyPort: 8765,
        url: "http://127.0.0.1:8765/status",
        agent: AgentPanel(
            statusURL: "http://127.0.0.1:8765/status",
            configPath: "\(githubRoot)/quantforge/backend/data/ep_sweep_agent/config.json",
            models: ["opus", "sonnet", "haiku"],
            efforts: ["low", "medium", "high", "xhigh", "max"]
        )
    ),
]
