import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: AppManager

    // Sized so the whole deck fits the default window without scrolling: at 900pt
    // wide this lays out 3 columns, so 7 apps land in 3 rows with room to spare.
    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 12)]

    /// Reads the version baked into Info.plist by build.sh (VERSION + git build #).
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (build \(build))"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "0b0f17"), Color(hex: "11161f")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(manager.apps) { app in
                            AppTile(
                                app: app,
                                status: manager.statuses[app.id] ?? .stopped,
                                scheduled: manager.scheduled[app.id] ?? false,
                                scheduleBusy: manager.scheduleBusy.contains(app.id),
                                agentStatus: manager.agentStatuses[app.id],
                                agentConfig: manager.agentConfigs[app.id],
                                onStart: { manager.start(app) },
                                onStop: { manager.stop(app) },
                                onRestart: { manager.restart(app) },
                                onOpen: { manager.open(app) },
                                onLogs: { manager.openLog(app) },
                                onSchedule: { manager.setScheduled(app, enabled: $0) },
                                onAgentModel: { manager.setAgentConfig(app, model: $0) },
                                onAgentEffort: { manager.setAgentConfig(app, effort: $0) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        // 690 is the narrowest width that still fits 3 tile columns
        // (3×210 + 2×12 spacing + 2×16 padding); below it the grid drops to 2
        // columns, which pushes the deck to 4 rows and brings scrolling back.
        .frame(minWidth: 690, minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.title2)
                .foregroundStyle(Color(hex: "4f8cff"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Launch Deck")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(appVersion)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text("\(manager.runningCount) running")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Button { manager.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .help("Refresh status")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

struct AppTile: View {
    let app: ManagedApp
    let status: AppStatus
    let scheduled: Bool
    let scheduleBusy: Bool
    let agentStatus: AgentStatus?
    let agentConfig: AgentConfig?
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onOpen: () -> Void
    let onLogs: () -> Void
    let onSchedule: (Bool) -> Void
    let onAgentModel: (String) -> Void
    let onAgentEffort: (String) -> Void

    private var accent: Color { Color(hex: app.color) }

    var body: some View {
        // Icon beside the title rather than above it — that one change is most of
        // the height saving, and it's what lets the full deck fit on one screen.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(accent.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: app.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(app.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                statusPill
            }

            // Only the primary action is labelled; the rest are icon-only so a
            // narrow tile still fits the whole row without truncating.
            HStack(spacing: 7) {
                if status == .stopped {
                    Button(action: onStart) {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(DeckButton(tint: accent, filled: true))
                } else {
                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(DeckButton(tint: Color(hex: "f87171"), filled: false))

                    Button(action: onRestart) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(DeckButton(tint: accent, filled: false, compact: true))
                    .help("Force-stop and start again")

                    if app.url != nil {
                        Button(action: onOpen) {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(DeckButton(tint: accent, filled: false, compact: true))
                        .disabled(status != .running)
                        .opacity(status == .running ? 1 : 0.45)
                        .help("Open in browser")
                    }
                }

                Button(action: onLogs) {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(DeckButton(tint: Color(hex: "94a3b8"), filled: false, compact: true))
                .help("View log")
            }

            if app.schedule != nil { scheduleRow }
            if app.agent != nil { agentRows }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(borderColor, lineWidth: 1.2)
                )
        )
        .shadow(color: status == .running ? accent.opacity(0.28) : .clear, radius: 10, y: 3)
        .animation(.easeInOut(duration: 0.25), value: status)
    }

    /// The launchd timer switch, for apps that have a background job. Kept to a
    /// single short row: it adds ~26pt to the tile, and the grid is tuned so the
    /// whole deck fits without scrolling.
    @ViewBuilder
    private var scheduleRow: some View {
        if let job = app.schedule {
            let on = scheduled
            HStack(spacing: 6) {
                Image(systemName: on ? "clock.arrow.2.circlepath" : "clock.badge.xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(on ? accent : Color.white.opacity(0.35))
                Text(job.caption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(on ? 0.72 : 0.4))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { on }, set: onSchedule))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(accent)
                    .disabled(scheduleBusy)
            }
            .padding(.top, 2)
            .help(on
                  ? "Scheduled runs are on (launchd: \(job.label))"
                  : "Scheduled runs are off — nothing runs in the background")
        }
    }

    /// The background-agent block: AI usage, the two pickers, and what the
    /// agent is doing. Three short rows (~60pt) — the one tile allowed to be
    /// this tall, since it is the only one with anything to say.
    ///
    /// The usage figure is what the agent's LAST request reported, so it is
    /// stamped with its time: the agent cannot ask for a fresher number while
    /// paused without spending the limit it is pausing to protect.
    @ViewBuilder
    private var agentRows: some View {
        if let panel = app.agent {
            let cfg = agentConfig ?? AgentConfig(model: panel.models.first ?? "",
                                                 effort: panel.efforts.first ?? "")
            VStack(alignment: .leading, spacing: 5) {
                usageRow

                HStack(spacing: 6) {
                    agentPicker(label: "Model", value: cfg.model, options: panel.models,
                                onChange: onAgentModel)
                    agentPicker(label: "Effort", value: cfg.effort, options: panel.efforts,
                                onChange: onAgentEffort)
                }
                .help("Applies at the start of the agent's next cycle")

                Text(agentDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.top, 2)
        }
    }

    private var usageRow: some View {
        let five = agentStatus?.fiveHourPct
        let week = agentStatus?.sevenDayPct
        let cap = agentStatus?.capPct ?? 90
        let color: Color = {
            guard let v = five else { return Color.white.opacity(0.35) }
            if v >= cap { return Color(hex: "f87171") }
            if v >= cap * 0.75 { return Color(hex: "f59e0b") }
            return Color(hex: "34d399")
        }()
        return HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text("AI usage")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            // The five-hour window, which is the one that actually stops the agent.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * CGFloat(min(max((five ?? 0) / 100, 0), 1)))
                }
            }
            .frame(height: 5)
            Text(five.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(five == nil ? Color.white.opacity(0.35) : color)
                .fixedSize()
            Text(week.map { "wk \(Int($0.rounded()))%" } ?? "")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize()
        }
        .help(usageHelp)
    }

    private var usageHelp: String {
        guard let s = agentStatus, let five = s.fiveHourPct else {
            return "AI usage is reported by the agent's own requests — start it to see a figure"
        }
        var parts = ["5-hour window \(Int(five.rounded()))%"]
        if let w = s.sevenDayPct { parts.append("7-day \(Int(w.rounded()))%") }
        if let cap = s.capPct { parts.append("agent pauses at \(Int(cap))%") }
        parts.append("\(s.sessionsSwept) sessions swept · \(s.queued) queued · \(s.posted) posted")
        if let at = s.usageObservedAt {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            parts.append("as of \(f.string(from: at))")
        }
        return parts.joined(separator: " · ")
    }

    private func agentPicker(label: String, value: String, options: [String],
                             onChange: @escaping (String) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Picker("", selection: Binding(get: { value }, set: onChange)) {
                ForEach(options, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.mini)
            .tint(accent)
        }
    }

    /// One line on what the agent is doing, from its own `detail` when it is
    /// up, else the plain state. Kept to a single truncated line — the tile
    /// is already the tallest on the deck.
    private var agentDetail: String {
        guard let s = agentStatus else {
            return status == .stopped ? "Sweeps run while limit remains · Start to begin" : "Waiting for the agent…"
        }
        let prefix: String
        switch s.status {
        case "paused_limit":    prefix = "Paused"
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
        return prefix + body + tally
    }

    private var borderColor: Color {
        switch status {
        case .running: return accent.opacity(0.55)
        case .starting: return Color(hex: "f59e0b").opacity(0.5)
        case .stopping: return Color(hex: "f87171").opacity(0.5)
        case .stopped: return Color.white.opacity(0.08)
        }
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            switch status {
            case .running: return ("Running", Color(hex: "34d399"))
            case .starting: return ("Starting", Color(hex: "f59e0b"))
            case .stopping: return ("Stopping…", Color(hex: "f87171"))
            case .stopped: return ("Stopped", Color(hex: "94a3b8"))
            }
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .fixedSize()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}
