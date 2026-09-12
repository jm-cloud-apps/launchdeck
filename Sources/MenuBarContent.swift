import SwiftUI
import AppKit

struct MenuBarContent: View {
    @ObservedObject var manager: AppManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Launch Deck \(appVersion) — \(manager.runningCount) running")
        if let u = manager.aiUsage {
            Text(usageLine(u))
        }

        Divider()

        ForEach(manager.apps) { app in
            let status = manager.statuses[app.id] ?? .stopped

            Button {
                status == .stopped ? manager.start(app) : manager.stop(app)
            } label: {
                Label(actionLabel(for: app, status: status), systemImage: icon(for: status))
            }

            if status != .stopped {
                Button {
                    manager.restart(app)
                } label: {
                    Label("    Restart \(app.name)", systemImage: "arrow.clockwise")
                }
            }

            if status == .running, app.url != nil {
                Button {
                    manager.open(app)
                } label: {
                    Label("    Open \(app.name) in browser", systemImage: "arrow.up.right.square")
                }
            }

            if let job = app.schedule {
                let on = manager.scheduled[app.id] ?? false
                Button {
                    manager.setScheduled(app, enabled: !on)
                } label: {
                    Label("    \(job.caption): \(on ? "On" : "Off") — turn \(on ? "off" : "on")",
                          systemImage: on ? "clock.arrow.2.circlepath" : "clock.badge.xmark")
                }
                .disabled(manager.scheduleBusy.contains(app.id))
            }

            if app.agent != nil {
                // Read-only in the menu: the pickers live on the tile.
                Text("    \(agentLine(for: app))")
            }

            Button {
                manager.openLog(app)
            } label: {
                Label("    View \(app.name) log", systemImage: "doc.text")
            }
        }

        Divider()

        Button("Refresh status") { manager.refresh() }

        Button("Open Launch Deck Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit Launch Deck") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func usageLine(_ u: AIUsage) -> String {
        var parts: [String] = []
        if let f = u.fiveHour {
            parts.append("5h \(Int(f.pct.rounded()))%" + (f.resetsAt.map { " (resets \(PlanUsageInline.resetText($0)))" } ?? ""))
        }
        if let w = u.sevenDay {
            parts.append("week \(Int(w.pct.rounded()))%" + (w.resetsAt.map { " (resets \(PlanUsageInline.resetText($0)))" } ?? ""))
        }
        return "Claude: " + parts.joined(separator: " · ") + " · \(PlanUsageInline.ageText(u.observedAt))"
    }

    private func agentLine(for app: ManagedApp) -> String {
        let cfg = manager.agentConfigs[app.id]
        let picks = cfg.map { "\($0.model.capitalized) · \($0.effort)" } ?? ""
        guard let s = manager.agentStatuses[app.id] else {
            return picks.isEmpty ? "Agent not running" : "Agent not running — \(picks)"
        }
        return "\(picks) · \(s.status.replacingOccurrences(of: "_", with: " ")) · q\(s.queued) · \(s.posted) posted"
    }

    private var appVersion: String {
        "v" + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?")
    }

    private func actionLabel(for app: ManagedApp, status: AppStatus) -> String {
        switch status {
        case .stopped:  return "Start \(app.name)"
        case .starting: return "Stop \(app.name) (starting…)"
        case .running:  return "Stop \(app.name) (running)"
        case .stopping: return "Stop \(app.name) (stopping…)"
        }
    }

    private func icon(for status: AppStatus) -> String {
        status == .stopped ? "play.fill" : "stop.fill"
    }
}
