import SwiftUI
import UniformTypeIdentifiers

/// The window: an iOS-style grouped screen — large title, a "Claude Plan"
/// card with the two limits and when they were last read, then an "Apps"
/// card of rows you can drag to reorder. Dark palette from `IOS` in Theme.
struct ContentView: View {
    @ObservedObject var manager: AppManager

    /// Reads the version baked into Info.plist by build.sh (VERSION + git build #).
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }

    var body: some View {
        ZStack {
            IOS.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    usageSection
                    appsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Launch Deck")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(IOS.label)
            Text(appVersion)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IOS.tertiary)
            Spacer()
            Button { manager.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(CircleButton())
            .help("Refresh status")
        }
    }

    // MARK: Claude plan

    /// The two limits as iOS-style rows, and — the part that answers "is this
    /// current?" — a footer stamping when the reading was taken and by whom,
    /// re-rendered every 30s so the age keeps moving.
    private var usageSection: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(alignment: .leading, spacing: 7) {
                sectionHeader("Claude Plan", trailing: usageHeaderTrailing)
                Card {
                    limitRow(label: "5-hour limit", window: manager.aiUsage?.fiveHour)
                    Divider().background(IOS.separator).padding(.leading, 16)
                    limitRow(label: "Weekly limit", window: manager.aiUsage?.sevenDay)
                }
                usageFooter
            }
        }
    }

    private var usageHeaderTrailing: some View {
        Button { manager.refreshUsage(force: true) } label: {
            if manager.usageRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(IOS.blue)
        .font(.system(size: 12, weight: .semibold))
        .disabled(manager.usageRefreshing)
        .help("Fetch the live account usage now (free — it refreshes every minute anyway)")
    }

    private func limitRow(label: String, window: UsageWindow?) -> some View {
        let pct = window?.pct
        let tint: Color = {
            guard let v = pct else { return IOS.gray }
            if v >= 90 { return IOS.red }
            if v >= 70 { return IOS.orange }
            return IOS.blue
        }()
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(IOS.label)
                Text(window?.resetsAt.map { "Resets \(PlanUsageInline.resetText($0))" } ?? "No reading yet")
                    .font(.system(size: 11))
                    .foregroundStyle(IOS.secondary)
            }
            .frame(width: 130, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(IOS.fill).frame(height: 6)
                GeometryReader { geo in
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * min(max((pct ?? 0) / 100, 0), 1), height: 6)
                }
                .frame(height: 6)
            }
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(pct == nil ? IOS.tertiary : IOS.label)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// "Last refreshed …" always leads, so a stale reading is never mistaken
    /// for a live one; a fetch problem is appended in red rather than
    /// replacing it, because the last good numbers are still what's shown.
    private var usageFooter: some View {
        let stamp: String = manager.aiUsage.map {
            "Last refreshed \(PlanUsageInline.ageText($0.observedAt)) · via \($0.source) · refreshes every minute"
        } ?? "No reading yet — press ↻ to fetch the live account usage."
        return HStack(spacing: 0) {
            Text(stamp)
                .font(.system(size: 11))
                .foregroundStyle(IOS.secondary)
            if let e = manager.usageError {
                Text(" · \(e)")
                    .font(.system(size: 11))
                    .foregroundStyle(IOS.red)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeader("Apps", trailing:
                Text("\(manager.runningCount) running")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IOS.secondary))
            Card {
                ForEach(Array(manager.apps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 {
                        Divider().background(IOS.separator).padding(.leading, 62)
                    }
                    AppRow(
                        app: app,
                        status: manager.statuses[app.id] ?? .stopped,
                        scheduled: manager.scheduled[app.id] ?? false,
                        scheduleBusy: manager.scheduleBusy.contains(app.id),
                        agentStatus: manager.agentStatuses[app.id],
                        agentConfig: manager.agentConfigs[app.id],
                        isDropTarget: manager.dropTarget == app.id,
                        onStart: { manager.start(app) },
                        onStop: { manager.stop(app) },
                        onRestart: { manager.restart(app) },
                        onOpen: { manager.open(app) },
                        onLogs: { manager.openLog(app) },
                        onSchedule: { manager.setScheduled(app, enabled: $0) },
                        onAgentModel: { manager.setAgentConfig(app, model: $0) },
                        onAgentEffort: { manager.setAgentConfig(app, effort: $0) },
                        onAgentResume: { manager.setAgentResume(app, $0) }
                    )
                    // Drop a dragged row here: it lands before this one.
                    .dropDestination(for: String.self) { items, _ in
                        manager.dropTarget = nil
                        guard let id = items.first else { return false }
                        manager.move(id, before: app.id)
                        return true
                    } isTargeted: { over in
                        manager.dropTarget = over ? app.id : (manager.dropTarget == app.id ? nil : manager.dropTarget)
                    }
                }
                // A thin landing strip after the last row, so "move to the
                // bottom" is possible.
                Rectangle().fill(manager.dropAtEnd ? IOS.blue.opacity(0.5) : Color.clear)
                    .frame(height: 3)
                    .dropDestination(for: String.self) { items, _ in
                        manager.dropAtEnd = false
                        guard let id = items.first else { return false }
                        manager.moveToEnd(id)
                        return true
                    } isTargeted: { manager.dropAtEnd = $0 }
            }
            Text("Drag the ≡ handle to reorder. Order is saved to apps.json.")
                .font(.system(size: 11))
                .foregroundStyle(IOS.tertiary)
                .padding(.horizontal, 16)
        }
    }

    private func sectionHeader<T: View>(_ title: String, trailing: T) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IOS.secondary)
                .kerning(0.4)
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
    }
}

/// An inset grouped card — the iOS list container.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(IOS.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct AppRow: View {
    let app: ManagedApp
    let status: AppStatus
    let scheduled: Bool
    let scheduleBusy: Bool
    let agentStatus: AgentStatus?
    let agentConfig: AgentConfig?
    let isDropTarget: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onOpen: () -> Void
    let onLogs: () -> Void
    let onSchedule: (Bool) -> Void
    let onAgentModel: (String) -> Void
    let onAgentEffort: (String) -> Void
    let onAgentResume: (Bool) -> Void

    /// The app's colour fills its icon square, the way Settings does — and
    /// nothing else. State is what colours the rest: green running, orange
    /// starting, red stopping/error.
    private var accent: Color { Color(hex: app.color) }

    var body: some View {
        // A remote agent drives its VM systemd unit over ssh (Start/Stop =
        // systemctl, Logs = journalctl). The buttons are disabled until its
        // host is set in apps.json, with a help string saying so.
        let controlReady = (app.agent?.remote != true) || (app.agent?.remoteControllable ?? false)
        let controlHelp = controlReady ? nil
            : "Set agent.host (user@host) and agent.serviceName in apps.json to control the VM"

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                // The iOS Settings icon: colour-filled rounded square, white glyph.
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent)
                        .frame(width: 30, height: 30)
                    Image(systemName: app.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IOS.label)
                        .lineLimit(1)
                    Text(app.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(IOS.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 120, alignment: .leading)

                Spacer(minLength: 8)

                statusLabel
                    .frame(width: 76, alignment: .trailing)

                HStack(spacing: 8) {
                    if status == .stopped {
                        Button("Start", action: onStart)
                            .buttonStyle(PillButton(tint: IOS.blue))
                            .disabled(!controlReady)
                            .opacity(controlReady ? 1 : 0.45)
                            .help(controlHelp ?? "Start")
                    } else {
                        Button("Stop", action: onStop)
                            .buttonStyle(PillButton(tint: IOS.red))
                            .disabled(!controlReady)
                            .opacity(controlReady ? 1 : 0.45)
                    }
                    Button(action: onOpen) { Image(systemName: "arrow.up.right") }
                        .buttonStyle(CircleButton())
                        .disabled(status != .running || app.url == nil)
                        .opacity(status == .running && app.url != nil ? 1 : 0.3)
                        .help(app.url == nil ? "No URL" : "Open in browser")
                    Menu {
                        Button("Restart", action: onRestart)
                            .disabled(status == .stopped || !controlReady)
                        Button(app.agent?.remote == true ? "View VM journal" : "View log", action: onLogs)
                        if app.url != nil {
                            Button("Open in browser", action: onOpen).disabled(status != .running)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .buttonStyle(CircleButton(tint: IOS.secondary))
                    .frame(width: 26, height: 26)
                    .help("More")
                }

                // Reorder handle — the iOS edit-mode grip. Drag it onto
                // another row to move this app there.
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(IOS.tertiary)
                    .frame(width: 18)
                    .contentShape(Rectangle())
                    .draggable(app.id)
                    .help("Drag to reorder")
            }

            if app.schedule != nil { scheduleRow }
            if app.agent != nil { agentRows }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(isDropTarget ? IOS.blue.opacity(0.12) : Color.clear)
        .overlay(alignment: .top) {
            if isDropTarget { Rectangle().fill(IOS.blue).frame(height: 2) }
        }
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    /// The launchd timer switch, for apps that have a background job — one
    /// short indented line under the name.
    @ViewBuilder
    private var scheduleRow: some View {
        if let job = app.schedule {
            let on = scheduled
            HStack(spacing: 6) {
                Image(systemName: on ? "clock.arrow.2.circlepath" : "clock.badge.xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(on ? IOS.blue : IOS.tertiary)
                Text(job.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(on ? IOS.label.opacity(0.85) : IOS.secondary)
                    .lineLimit(1)
                Toggle("", isOn: Binding(get: { on }, set: onSchedule))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(IOS.green)
                    .disabled(scheduleBusy)
                Spacer()
            }
            .padding(.leading, 42)
            .help(on
                  ? "Scheduled runs are on (launchd: \(job.label))"
                  : "Scheduled runs are off — nothing runs in the background")
        }
    }

    /// The background-agent block, indented under the name: the pickers and
    /// the auto-resume switch on one line, what the agent is doing on the
    /// next. Plan usage is deck-wide, not per row — it has its own card.
    @ViewBuilder
    private var agentRows: some View {
        if let panel = app.agent {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    if panel.remote {
                        // Monitor-only: the VM owns the config, so show what it
                        // is running read-only (change it over ssh on the VM).
                        readOnlyPick(label: "Model", value: agentStatus?.model?.capitalized ?? "—")
                        readOnlyPick(label: "Effort", value: agentStatus?.effort ?? "—")
                    } else {
                        let cfg = agentConfig ?? AgentConfig(model: panel.models.first ?? "",
                                                             effort: panel.efforts.first ?? "")
                        agentPicker(label: "Model", value: cfg.model, options: panel.models,
                                    onChange: onAgentModel)
                        agentPicker(label: "Effort", value: cfg.effort, options: panel.efforts,
                                    onChange: onAgentEffort)
                    }
                    resumeRow(panel)
                    Spacer()
                }
                .help(panel.remote
                      ? (panel.host.map { "Runs on \($0) — set model/effort over ssh" }
                         ?? "Runs on the VM — set model/effort over ssh")
                      : "Applies at the start of the agent's next cycle")

                Text(agentDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(["error", "halted_error"].contains(agentStatus?.status ?? "")
                                     ? IOS.red : IOS.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 42)
        }
    }

    /// What the agent does at its usage cap. On (default): waits for the
    /// window to reset and carries on by itself. Off: parks ("Halted") and the
    /// next window is yours — press Start to spend it. A remote row reads the
    /// VM's own setting out of the telemetry and writes it back over ssh; a
    /// local one uses the config file like the pickers.
    private func resumeRow(_ panel: AgentPanel) -> some View {
        let value: Bool = panel.remote
            ? (agentStatus?.resumeAfterLimit ?? true)
            : (agentConfig?.resumeAfterLimit ?? true)
        let parked = agentStatus?.status == "halted_limit"
        return HStack(spacing: 5) {
            Toggle("", isOn: Binding(get: { value }, set: onAgentResume))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(IOS.green)
                .disabled(!panel.configWritable)
            Text(parked ? "Auto-resume off · parked at cap" : "Auto-resume")
                .font(.system(size: 11))
                .foregroundStyle(parked ? IOS.orange : IOS.secondary)
                .lineLimit(1)
        }
        .help(panel.configWritable
              ? (value ? "At the usage cap the agent waits for the window to reset, then continues."
                       : "At the usage cap the agent parks until you press Start — the next window is yours.")
              : "Set agent.host and agent.remoteConfigPath in apps.json to change this over ssh")
    }

    /// Read-only twin of `agentPicker` for a remote agent — same footprint,
    /// no menu (the VM owns the setting).
    private func readOnlyPick(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(IOS.secondary)
            Text(value).font(.system(size: 11, weight: .semibold)).foregroundStyle(IOS.label.opacity(0.85))
        }
    }

    private func agentPicker(label: String, value: String, options: [String],
                             onChange: @escaping (String) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(IOS.secondary)
            Picker("", selection: Binding(get: { value }, set: onChange)) {
                ForEach(options, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.mini)
            .tint(IOS.blue)
        }
    }

    /// One line on what the agent is doing, from its own `detail` when it is
    /// up, else the plain state. Kept to a single truncated line — the tile
    /// is already the tallest on the deck.
    private var agentDetail: String {
        let remote = app.agent?.remote == true
        guard let s = agentStatus else {
            if remote {
                return "No telemetry yet — is the VM poller running? (\(app.agent?.host ?? "VM"))"
            }
            return status == .stopped ? "Sweeps run while limit remains · Start to begin" : "Waiting for the agent…"
        }
        // For a remote agent the freshness of the synced file is the story: a
        // stale file means the poller or the VM has gone quiet, which the pill
        // alone (Stopped) doesn't distinguish from a deliberately idle agent.
        if remote, let age = s.updatedAt.map({ Date().timeIntervalSince($0) }), age >= 180 {
            return "Stale · last telemetry \(Self.ago(age)) ago — VM off or poller stopped"
        }
        let prefix: String
        switch s.status {
        case "paused_limit":    prefix = "Paused"
        case "halted_limit":    prefix = "Halted"
        case "halted_error":    prefix = "Halted"   // the breaker tripped; detail says why
        case "waiting_backend": prefix = "Waiting"
        case "sweeping":        prefix = "Sweeping"
        case "cooldown":        prefix = "Cooling down"
        case "idle":            prefix = "Idle"
        case "error":           prefix = "Error"
        case "stopped":         prefix = "Stopped"
        default:                prefix = "Cycle \(s.cycle)"
        }
        let body = s.detail.isEmpty ? "" : " · \(s.detail)"
        // Queue and posted are the ledger's numbers: what is waiting, and what
        // the library confirms landed. Together they say the loop is moving.
        let tally = " · q\(s.queued) · \(s.posted) posted"
        // A remote tile stamps the telemetry age so a fresh-looking cycle line
        // is never mistaken for a live local one.
        let via = (remote && s.updatedAt != nil)
            ? " · via VM \(Self.ago(Date().timeIntervalSince(s.updatedAt!))) ago" : ""
        return prefix + body + tally + via
    }

    /// Compact age like the usage strip uses ("20s", "3m", "1h").
    static func ago(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    private var stateColor: Color {
        switch status {
        case .running: return IOS.green
        case .starting: return IOS.orange
        case .stopping: return IOS.red
        case .stopped: return IOS.tertiary
        }
    }

    /// Dot + word, in the state colour; muted when there is nothing to say.
    private var statusLabel: some View {
        let text: String = {
            switch status {
            case .running: return "Running"
            case .starting: return "Starting"
            case .stopping: return "Stopping…"
            case .stopped: return "Stopped"
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(stateColor).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(status == .stopped ? IOS.secondary : stateColor)
                .fixedSize()
        }
    }
}


/// Date/age formatting shared by the plan card and the menu bar line.
/// (The header strip it was named for is gone; the card in ContentView and
/// `MenuBarContent.usageLine` are its readers.)
enum PlanUsageInline {
    /// "3:00 PM" today, else "Mon 10:00 PM" — the way Claude's own panel says it.
    static func resetText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }

    static func ageText(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { let h = s / 3600; return "\(h) hour\(h == 1 ? "" : "s") ago" }
        let d = s / 86400
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }
}
