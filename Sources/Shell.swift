import Foundation

extension String {
    /// Safe single-quoting for interpolation into a shell command.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum Shell {
    /// Runs a command through a login zsh and returns its combined
    /// stdout/stderr. Blocking — call off the main thread.
    ///
    /// Pass `interactive: true` for commands that launch dev servers: it adds
    /// `-i`, which sources `~/.zshrc`. Version managers like nvm define `npm`
    /// and `node` there, so without it a detached `npm run dev` fails with
    /// "command not found" and the frontend never comes up. The lightweight
    /// non-interactive shell is fine for the frequent port-status polling.
    @discardableResult
    static func runLogin(_ command: String, interactive: Bool = false) -> String {
        runLoginResult(command, interactive: interactive).output
    }

    /// Same, but also reports the exit status — for commands where the status is
    /// the answer (`launchctl bootstrap` says nothing on success, and plenty on
    /// failure).
    static func runLoginResult(_ command: String, interactive: Bool = false) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [interactive ? "-ilc" : "-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Which launchd labels are currently scheduled for this user.
    ///
    /// "Scheduled" needs both halves: the job has to be **loaded** (`launchctl
    /// list`) *and* not **disabled** in launchd's override database
    /// (`print-disabled`). Loaded-only would read a job as on that launchd will
    /// refuse to bootstrap after the next login; disabled-only would read a job
    /// as on that was simply booted out. Both are read in one shell so the
    /// 2.5s poll still costs a single process spawn.
    static func scheduledLaunchdLabels() -> Set<String> {
        let out = runLogin(
            "launchctl list 2>/dev/null; echo '<<<DISABLED>>>'; " +
            "launchctl print-disabled gui/$(id -u) 2>/dev/null"
        )
        let parts = out.components(separatedBy: "<<<DISABLED>>>")

        // `launchctl list` is PID<TAB>status<TAB>label, with a header row.
        var loaded = Set<String>()
        for line in (parts.first ?? "").split(separator: "\n") {
            let cols = line.split(separator: "\t")
            if cols.count >= 3 { loaded.insert(String(cols[2])) }
        }

        // `print-disabled` is `"label" => disabled` (older macOS says `=> true`).
        var disabled = Set<String>()
        if parts.count > 1 {
            for line in parts[1].split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let arrow = trimmed.range(of: "=>") else { continue }
                let value = trimmed[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                guard value == "disabled" || value == "true" else { continue }
                let label = trimmed[..<arrow.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                disabled.insert(label)
            }
        }
        return loaded.subtracting(disabled)
    }

    /// Every local TCP port currently in the LISTEN state.
    static func listeningPorts() -> Set<Int> {
        let out = runLogin("lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '{print $9}'")
        var ports = Set<Int>()
        for line in out.split(separator: "\n") {
            guard let colon = line.lastIndex(of: ":") else { continue }
            let portString = line[line.index(after: colon)...]
            if let port = Int(portString) { ports.insert(port) }
        }
        return ports
    }
}


/// Claude plan usage: where the numbers come from. The live account fetch is
/// the source of truth; the agent's state file and the cached last fetch are
/// what fills the strip before the first fetch lands. Blocking — call off
/// the main thread.
enum PlanUsage {
    static var cacheURL: URL { AppConfig.supportDir.appendingPathComponent("usage.json") }

    /// The `usage` block out of an agent's state.json, if it has one.
    static func readAgentState(_ panel: AgentPanel, source: String) -> AIUsage? {
        guard let data = FileManager.default.contents(atPath: panel.expandedStatePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any]
        else { return nil }
        return AIUsage(json: usage, source: source)
    }

    /// The last live fetch, cached — so the strip has a number at launch
    /// before the first fetch of this run comes back.
    static func readCache() -> AIUsage? {
        guard let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return AIUsage(json: json, source: "account")
    }

    /// Where Claude Code keeps its sign-in on macOS: one keychain item holding
    /// `{"claudeAiOauth": {"accessToken": …}}`. Read through `security` so the
    /// first read shows the standard keychain prompt — "Always Allow" there and
    /// it never asks again. Only the token is read; nothing is written back.
    static let keychainService = "Claude Code-credentials"
    static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// What a live fetch can say: a reading, or why there is none.
    enum LiveResult {
        case reading(AIUsage)
        case failed(String)
    }

    /// Ask the account for the live numbers — the same endpoint the Claude
    /// desktop app's usage panel reads, so this always matches it. Costs no
    /// limit, which is why it can run on a timer. `utilization` arrives as a
    /// percent and `resets_at` as ISO-8601 with fractional seconds; both are
    /// written to `usage.json` in the agent's shape so one decoder serves all.
    static func fetchLive() -> LiveResult {
        guard let token = keychainToken() else {
            return .failed("No Claude sign-in found — run `claude` and sign in once")
        }
        var request = URLRequest(url: usageEndpoint)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let done = DispatchSemaphore(value: 0)
        var body: Data?
        var code = 0
        var failure: String?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            body = data
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = error?.localizedDescription
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        if let failure { return .failed("Usage fetch failed: \(failure)") }
        if code == 401 || code == 403 {
            return .failed("Claude sign-in expired — run `claude` once to refresh it")
        }
        if code == 429 {
            // The endpoint has its own rate limit; the caller backs off.
            return .failed("rate limited by the usage endpoint — retrying in a few minutes")
        }
        guard code == 200, let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return .failed("Usage fetch failed (HTTP \(code))") }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var out: [String: Any] = ["observed_at": Date().timeIntervalSince1970]
        for key in ["five_hour", "seven_day"] {
            guard let w = json[key] as? [String: Any],
                  let util = w["utilization"] as? Double else { continue }
            var window: [String: Any] = ["pct": util.rounded()]
            if let r = w["resets_at"] as? String,
               let date = iso.date(from: r) ?? plain.date(from: r) {
                window["resets_at"] = date.timeIntervalSince1970
            }
            out[key] = window
        }
        guard let usage = AIUsage(json: out, source: "account") else {
            return .failed("Usage fetch returned no limits")
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]) {
            try? data.write(to: cacheURL)
        }
        return .reading(usage)
    }

    /// The OAuth access token out of the keychain, or nil if there is no
    /// sign-in (or the prompt was denied). `security` is called directly, not
    /// through a login shell, so nothing in `~/.zshrc` can see the secret.
    private static func keychainToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }
}

/// The two things Launch Deck touches on a background agent: its status port
/// and its config file. Blocking — call off the main thread.
enum AgentFiles {
    /// One `GET /status`, with a short timeout so a wedged agent costs the
    /// 2.5s poll nothing it can feel. nil on any failure.
    static func fetchStatus(_ panel: AgentPanel) -> AgentStatus? {
        guard let url = URL(string: panel.statusURL) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        let done = DispatchSemaphore(value: 0)
        var result: AgentStatus?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            result = AgentStatus(json: json)
        }.resume()
        _ = done.wait(timeout: .now() + 2)
        return result
    }

    /// The agent's full status read from its state file (the `/status` body a
    /// poller has written for a remote agent, or the local agent's own
    /// state.json). No network — this is how a remote/off tile still reports
    /// what the VM agent is doing. nil if the file is missing or unreadable.
    static func readStateStatus(_ panel: AgentPanel) -> AgentStatus? {
        guard let data = FileManager.default.contents(atPath: panel.expandedStatePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return AgentStatus(json: json)
    }

    /// Fetch a REMOTE agent's `/status` over ssh and cache it to the state file.
    /// The VM's status port is loopback-only, so we curl it on the far side.
    /// Writing the body to `expandedStatePath` means the usage strip and the
    /// freshness logic read the same data — so the tile is live even without the
    /// standalone launchd poller. nil on any failure (unreachable).
    static func remoteBase(_ host: String) -> String {
        "ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new \(host.shellQuoted)"
    }

    static func fetchRemoteStatus(_ panel: AgentPanel) -> AgentStatus? {
        guard let host = panel.host, host.contains("@") else { return nil }
        let url = panel.statusURL.isEmpty ? "http://127.0.0.1:8765/status" : panel.statusURL
        // When the port is down the agent has exited — and its last act is to
        // write `status: stopped` to its state.json beside the config. Read
        // that instead, or the cache keeps the final *live* body ("sweeping",
        // stamped seconds before Stop) and the tile says Running for the 180s
        // it takes that stamp to go stale.
        var far = "curl -s --max-time 5 \(url)"
        if let cfg = panel.remoteConfigPath, !cfg.isEmpty {
            let state = ((cfg as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("state.json")
            far += " || cat \(state.shellQuoted)"
        }
        let out = Shell.runLogin("\(remoteBase(host)) \(far.shellQuoted)")
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = AgentStatus(json: json) else { return nil }
        let path = panel.expandedStatePath
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path))
        return status
    }

    /// Merge ONE key into a remote agent's config.json over ssh, preserving the
    /// rest of the file — the same "touch only your key" rule as writeConfig,
    /// done on the far side with python3 (present: the agent runs on it). The
    /// agent re-reads its config every cycle, so the change lands on the next
    /// one. Returns (exit status, output) so the caller can log a failure.
    static func writeRemoteConfigKey(_ panel: AgentPanel, key: String, value: Bool)
        -> (status: Int32, output: String) {
        guard let host = panel.host, host.contains("@"),
              let path = panel.remoteConfigPath, !path.isEmpty else {
            return (1, "Set agent.host and agent.remoteConfigPath in apps.json first.")
        }
        let py = """
        import json, os, sys
        p = sys.argv[1]; k = sys.argv[2]; v = sys.argv[3] == "true"
        try:
            d = json.load(open(p))
        except Exception:
            d = {}
        d[k] = v
        os.makedirs(os.path.dirname(p), exist_ok=True)
        t = p + ".tmp"
        json.dump(d, open(t, "w"), indent=1, sort_keys=True)
        os.replace(t, p)
        print("ok")
        """
        let far = "python3 -c \(py.shellQuoted) \(path.shellQuoted) \(key.shellQuoted) \(value ? "true" : "false")"
        return Shell.runLoginResult("\(remoteBase(host)) \(far.shellQuoted)")
    }

    /// The remote service's recent journal, for the Logs button. Returns the
    /// text (or an error line), never throws.
    static func remoteJournal(_ panel: AgentPanel, lines: Int = 200) -> String {
        guard let host = panel.host, host.contains("@"), let svc = panel.serviceName else {
            return "Set agent.host (user@host) and agent.serviceName in apps.json first."
        }
        let out = Shell.runLogin(
            "\(remoteBase(host)) \("journalctl -u \(svc) -n \(lines) --no-pager".shellQuoted)")
        return out.isEmpty ? "No output — is \(svc) installed on \(host)?" : out
    }

    /// The agent's config, falling back to the first entry of each picker list
    /// when the file is missing or unreadable (the agent seeds the same
    /// defaults on its first cycle, so the tile and the agent agree).
    static func readConfig(_ panel: AgentPanel) -> AgentConfig {
        let fallback = AgentConfig(model: panel.models.first ?? "opus",
                                   effort: panel.efforts.first ?? "high")
        guard let data = FileManager.default.contents(atPath: panel.expandedConfigPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return fallback }
        return AgentConfig(model: json["model"] as? String ?? fallback.model,
                           effort: json["effort"] as? String ?? fallback.effort,
                           resumeAfterLimit: json["resume_after_limit"] as? Bool ?? true)
    }

    /// Merge the tile's keys into the existing file, preserving every other key.
    static func writeConfig(_ panel: AgentPanel, _ cfg: AgentConfig) {
        let path = panel.expandedConfigPath
        var json: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        json["model"] = cfg.model
        json["effort"] = cfg.effort
        json["resume_after_limit"] = cfg.resumeAfterLimit
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
