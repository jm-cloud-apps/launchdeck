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
            PlanUsageInline(usage: manager.aiUsage,
                            probing: manager.usageProbing,
                            error: manager.usageProbeError,
                            onProbe: { manager.probeUsage() })
            Spacer().frame(width: 6)
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

    /// The background-agent block: the two pickers and what the agent is
    /// doing. Two short rows (~40pt). Plan usage is deck-wide, not per tile —
    /// it is a fact about the Claude account, and lives under the header.
    @ViewBuilder
    private var agentRows: some View {
        if let panel = app.agent {
            let cfg = agentConfig ?? AgentConfig(model: panel.models.first ?? "",
                                                 effort: panel.efforts.first ?? "")
            VStack(alignment: .leading, spacing: 5) {
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


/// Claude plan usage on the header line — the five-hour and weekly limits,
/// each as a mini bar with its percent and reset time, the way Claude's own
/// `/usage` reports them but in one row so it costs the deck no height.
///
/// There is no live number to show: a reading is what some request was told,
/// so the tooltip says how old it is and who asked. The sweep agent refreshes
/// it for free as a side effect of working; the ↻ sends a one-word Haiku
/// message purely to be told, which costs a sliver of the thing being
/// measured — hence a button, never a timer.
struct PlanUsageInline: View {
    let usage: AIUsage?
    let probing: Bool
    let error: String?
    let onProbe: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(error == nil ? Color(hex: "c084fc") : Color(hex: "f87171"))
            limit(label: "5h", window: usage?.fiveHour)
            limit(label: "Week", window: usage?.sevenDay)
            Button(action: onProbe) {
                if probing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))
            .disabled(probing)
            .help("Ask Claude for a fresh reading (a one-word message; costs a sliver of the limit)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .help(tooltip)
    }

    private func limit(label: String, window: UsageWindow?) -> some View {
        let pct = window?.pct
        let color: Color = {
            guard let v = pct else { return Color.white.opacity(0.3) }
            if v >= 90 { return Color(hex: "f87171") }
            if v >= 70 { return Color(hex: "f59e0b") }
            return Color(hex: "4f8cff")
        }()
        return HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: 44 * CGFloat(min(max((pct ?? 0) / 100, 0), 1)))
            }
            .frame(width: 44, height: 4)
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(pct == nil ? Color.white.opacity(0.35) : Color.white.opacity(0.85))
                .frame(minWidth: 26, alignment: .trailing)
            if let r = window?.resetsAt {
                Text("↻ \(Self.resetText(r))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize()
            }
        }
    }

    private var tooltip: String {
        var lines = ["Claude plan usage limits"]
        if let f = usage?.fiveHour {
            lines.append("5-hour limit: \(Int(f.pct.rounded()))%" + (f.resetsAt.map { " · resets \(Self.resetText($0))" } ?? ""))
        }
        if let w = usage?.sevenDay {
            lines.append("Weekly · all models: \(Int(w.pct.rounded()))%" + (w.resetsAt.map { " · resets \(Self.resetText($0))" } ?? ""))
        }
        if let e = error { lines.append(e) }
        if let u = usage {
            lines.append("Last updated \(Self.ageText(u.observedAt)) · via \(u.source)")
        } else {
            lines.append("No reading yet — press ↻ to ask Claude, or start the sweep agent")
        }
        return lines.joined(separator: "\n")
    }

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
