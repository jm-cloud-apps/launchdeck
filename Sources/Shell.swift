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
                           effort: json["effort"] as? String ?? fallback.effort)
    }

    /// Merge model/effort into the existing file, preserving every other key.
    static func writeConfig(_ panel: AgentPanel, _ cfg: AgentConfig) {
        let path = panel.expandedConfigPath
        var json: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        json["model"] = cfg.model
        json["effort"] = cfg.effort
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
