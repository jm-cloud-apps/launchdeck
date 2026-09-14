# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Launch Deck is a small **native macOS app** — a Steam-Deck-style control panel for
local dev projects. Each tile starts/stops/restarts a project and shows whether
it's running (by polling which TCP ports are listening). It also lives in the menu
bar. It is pure SwiftUI + AppKit with **no external dependencies and no package
manager** — it's compiled directly with `swiftc` by `build.sh` into a
double-clickable `.app` bundle.

## Commands

```bash
./build.sh            # compile Sources/*.swift into LaunchDeck.app (needs Xcode CLT)
open LaunchDeck.app   # run it
cp -R LaunchDeck.app /Applications/   # install (then drag to Dock to keep it)

./make_icon.sh        # re-render AppIcon.icns from Icon/make_icon.swift (optional)
```

There is no test suite, linter, or CI. Verification = `./build.sh` compiles
cleanly. After changing any `Sources/*.swift`, run `./build.sh` to confirm it
builds; `swiftc` errors are the only build feedback. A running instance keeps the
*old* binary — quit it (menu bar → Quit Launch Deck) and `open LaunchDeck.app`
again to test changes.

Requires macOS 13+ (target is set in `build.sh`).

## Architecture

`@main` is in `Sources/LaunchDeckApp.swift`. It builds one shared `AppManager`
and presents two scenes that share it: a single `Window` (the grid) and a
`MenuBarExtra` (the menu). All source lives in `Sources/`:

- **`LaunchDeckApp.swift`** — app entry; wires the shared `AppManager` into the
  window and the menu-bar item.
- **`AppManager.swift`** — the core. `@MainActor ObservableObject` that owns the
  app list and per-app `statuses`, polls status every 2.5s, and runs
  start/stop/restart. **All process control lives here.**
- **`Models.swift`** — `ManagedApp` (one project, `Codable`), `ScheduledJob`
  (an optional launchd timer job on an app), `AgentPanel` / `AgentStatus` /
  `AgentConfig` (an optional background AI agent on an app), `AppStatus`
  (`stopped` / `starting` / `running`), and `AppConfig` (loads/seeds the JSON
  config). Also holds `defaultApps`, the seed list.
- **`Shell.swift`** — `PlanUsage` (reads Claude plan usage out of an agent's
  state file or the cached last fetch, and `fetchLive()` asks the account's
  usage endpoint with the keychain OAuth token), `AgentFiles` (an agent's `/status` fetch and its config
  file read/merge-write) and `Shell.runLogin(_:)`, which runs a command through a login `zsh`
  (`zsh -lc`, so PATH includes node/python), `runLoginResult(_:)` adds the exit
  status; `Shell.listeningPorts()` parses `lsof` for the set of LISTENing TCP
  ports and `Shell.scheduledLaunchdLabels()` the set of live launchd labels.
  `String.shellQuoted` safely single-quotes interpolated values.
- **`ContentView.swift`** — the window UI: header + one `AppRow` per app with
  Start / Stop / Restart / Open / Logs in aligned columns.
- **`MenuBarContent.swift`** — the menu-bar menu (same actions, plus Refresh /
  Open Window / Quit).
- **`Theme.swift`** — `Color(hex:)`, the `IOS` palette, and the `PillButton` /
  `CircleButton` styles.
- **`Icon/make_icon.swift`** — draws the app icon (run via `make_icon.sh`).

### How process control works (important before touching AppManager)

- **Config** lives at `~/Library/Application Support/LaunchDeck/apps.json`
  (NOT in this repo). On first run `AppConfig.load()` seeds it from `defaultApps`
  in `Models.swift`. To change which apps ship by default, edit `defaultApps`;
  to change a user's live apps, they edit that JSON. Per-app logs go to
  `~/Library/Application Support/LaunchDeck/logs/<App>.log`.
- **Adding an app to `defaultApps` is not enough on its own** for anyone who has
  already run the app — apps.json is only *seeded* once. `load()` therefore
  merges: it appends defaults whose `name` is neither in apps.json nor in the
  `seeded.json` ledger beside it, preserving the user's edits and ordering.
  The ledger records every default ever offered, so an app the user deletes
  stays deleted instead of returning on the next launch. **Editing an existing
  `defaultApps` entry still won't reach an existing install** (matching by name,
  it's already "known") — that only affects fresh seeds. The one exception is
  `AppConfig.backfillNewFields`: when you add a *new field* to a default (as
  `schedule` was), extend that function to copy it onto saved entries where it's
  nil, or the feature ships dead for everyone who already ran the app.
- **Ports must be unique across apps**, since status is inferred from ports
  alone. Where a project's own config collides (elevator-clicker pins vite to
  5180, which is Study App's), override at launch via `startCommand` rather than
  editing the sibling repo.
- Multi-step start commands are wrapped in `zsh -c '…'`. `launchCommand` builds
  `cd … && nohup <startCommand> >> <log> 2>&1 &`, so a bare `a; b` would leave
  only `b` backgrounded and redirected, and `npm install` output would escape
  the log.
- **Start** runs the app's `startCommand` from its `directory`, detached via
  `cd … && nohup <cmd> >> <log> 2>&1 &`. The login shell exits immediately so the
  servers reparent to `launchd` — quitting Launch Deck never kills running apps.
  `start()` ignores the request if the app isn't `stopped`, so you can't stack
  duplicate launches fighting over the same ports.
- **Status** is inferred purely from listening ports (`Shell.listeningPorts()`),
  polled every 2.5s. An app is `running` once its `effectiveReadyPort`
  (`readyPort`, else the last port) is up, `starting` while only some ports are
  up or within the 40s `pendingUntil` grace window after a launch, else
  `stopped`. There is no PID tracking — the ports ARE the source of truth.
- **Stop / Restart** free the ports via `killCommand`: SIGTERM first for a clean
  shutdown, then SIGKILL anything still holding the port a second later. Plain
  SIGTERM alone leaves `uvicorn --reload` / vite processes lingering, which is
  why the escalation matters. A `ManagedApp.stopCommand`, if set, overrides this.
  **Restart** = `killCommand; sleep 2; launchCommand` in one detached shell.
- **Scheduled jobs are a separate axis from Start/Stop.** An app with a
  `schedule` (`ScheduledJob`) owns a launchd timer job that has no port, so the
  port poll can't see it — it gets a switch on the tile instead.
  `setScheduled(_:enabled:)` needs *both* launchctl verbs in each direction:
  off is `bootout` (stop it now) **plus** `disable` (persist it, or the agent
  loads straight back at next login); on is `enable` (clear that override, or
  bootstrap is refused) **plus** `bootstrap`. State is never written to
  apps.json — `Shell.scheduledLaunchdLabels()` re-reads it from launchd every
  poll, treating a label as on only when it's *loaded* (`launchctl list`) and
  *not disabled* (`launchctl print-disabled`, which says `=> disabled` /
  `=> enabled`). Either half alone misreads a job. `scheduleBusy` holds the
  switch while a call is in flight so the poll can't snap it back mid-toggle.

- **Background agents are a third axis**, beside Start/Stop and schedules.
  **Launch Deck holds none of an agent's logic** — what QuantForge's sweep
  agent sweeps, in what order, and what counts as done is decided in
  `quantforge/backend/tools/ep_sweep_agent.py`; this app only starts it, stops
  it, writes two picker values, and renders `/status`. Never move a rule here.
  An app with an `agent` (`AgentPanel`) is still a normal port-tracked tile —
  the agent binds a loopback status port precisely so the existing
  start/stop/kill machinery applies unchanged (Stop's process-group kill also
  takes out the `claude` child). What the panel adds is *reading*: every poll
  fetches `statusURL` (only while the port is up; 1.5s timeout so a wedged
  agent can't stall the poll) into `agentStatuses`, and reads the config file
  into `agentConfigs` whether or not the agent is up, because the pickers are
  most useful on a stopped agent. **Plan usage is deck-wide, not per tile**
  (`PlanUsageInline` on the header line): it is a fact about the Claude account.
  `aiUsage` is whichever is newest of the **live account fetch** and every
  agent's `state.json` `usage` block. `refreshUsage()` runs on its own 60s
  timer (and on ↻): `PlanUsage.fetchLive()` reads Claude Code's OAuth token
  out of the `Claude Code-credentials` keychain item (via `/usr/bin/security`,
  so macOS shows its own prompt once — "Always Allow") and GETs
  `api.anthropic.com/api/oauth/usage`, the endpoint the Claude desktop app's
  usage panel reads, so the deck matches it. It spends no limit. The result is
  cached to `usage.json` in the support dir in the agent's shape, which is what
  the strip shows at launch before the first fetch lands. On failure (no
  sign-in, expired token, offline) the last reading stays and `usageError`
  explains in the tooltip; nothing here refreshes the token — running `claude`
  does. `setAgentConfig` merge-writes only `model`
  and `effort` into that file and leaves the agent's other keys alone; the
  agent reads it per cycle, so nothing here restarts anything. New `agent`
  field → `backfillNewFields` fills it, same as `schedule`.
- **A REMOTE agent (`AgentPanel.remote`) runs on another machine (a cloud VM)
  and is driven over ssh.** Launch Deck never reaches its port directly; instead
  `AgentFiles.fetchRemoteStatus` runs `ssh <host> curl 127.0.0.1:8765/status
  || cat <state.json beside remoteConfigPath>` (loopback stays private; the
  `cat` fallback is what lets a Stop show within one fetch — the agent's last
  act is writing `status: stopped` there, and without it the cache would keep
  the final live body and say Running until it went stale), **throttled to ~15s** via `lastRemoteFetch` since
  the 2.5s poll is far too fast for an ssh round-trip, and caches the body to
  the panel's `expandedStatePath` under
  `~/Library/Application Support/LaunchDeck/vm-telemetry/` so the usage strip and
  freshness reads share it. `readStateStatus` re-reads that cache on the ticks
  between fetches, and (optionally) the `vm-agent-deployment` launchd poller
  keeps it warm while Launch Deck is closed. The app-status pill comes from the
  cache's `updated_at` freshness (fresh + a live status word ⇒ Running; ≥180s
  ⇒ Stopped, detail "Stale · last telemetry … ago"), honouring a
  pending/stopping **grace** after a control action so a just-issued systemctl
  doesn't snap back. **Control:** `start`/`stop`/`restart` route through
  `remoteControl` → `ssh <host> systemctl <verb> <serviceName>`, and the Logs
  button fetches `journalctl -u <serviceName>` to a temp file. The buttons are
  disabled until `remoteControllable` (host is `user@host` and a service is
  named). Model/effort stay **read-only** on a remote tile (the VM owns its
  config; edit it there). Ports are `[]`, so `applyStatuses` marks it stopped
  and the grace-aware remote override in `refresh` sets the real state after.
  New agent sub-fields (`serviceName`, remote `statusURL`) reach an
  already-seeded tile through `backfillNewFields`, which fills only nil/empty
  ones so a user's edited `host` is preserved. The "EP Sweep Agent (VM)" default
  app is the one instance.

### Layout and look (iOS grouped style, since 1.13)

The window is one `ScrollView`: a large title, a **Claude Plan** card (two
limit rows + a footer that always starts "Last refreshed … · via …", with any
fetch error appended in red rather than replacing it), then an **Apps** card
of `AppRow`s separated by inset dividers, and a footer explaining reorder.
Colours come from `IOS` in `Theme.swift` (black background, `#1c1c1e` cards,
system blue/green/red/orange) — use those tokens, not ad-hoc hex. Buttons are
`PillButton` (the App Store "GET" capsule: Start blue, Stop red) and
`CircleButton` (open-in-browser, and a "•••" `Menu` holding Restart / log /
open). **Colour is by state, not by app**: an app's `color` fills only its
icon square; the status dot and the Stop pill take the state colour. Don't
reintroduce per-app coloured buttons or glows.

A plain row is ~50pt; a `schedule` adds a line, an `agent` two. `.defaultSize`
(860×780) fits the current 9 apps; the `ScrollView` is the fallback.
`build.sh` compiles with bare `swiftc`, which lacks the macro plugin the
current SDK's `@State` needs — so transient view state (the drag-over
highlight) lives on `AppManager` as `@Published`, not as `@State`.

**Reordering** is drag-and-drop: the ≡ handle on each row is `.draggable(id)`,
each row and a strip after the last one are `.dropDestination`s;
`AppManager.move(_:before:)` / `moveToEnd` reorder `apps` and call
`AppConfig.save`, so the order persists in apps.json (the whole array is
rewritten — a hand edit made while the app is open is lost, same as the
schedule/agent writes).

The usage fetch backs off 5 min after an HTTP 429 from the usage endpoint
(`usageBackoffUntil`); the ↻ button forces one anyway.

## Versioning (bump on every change)

The human-readable version lives in the **`VERSION`** file (e.g. `1.1.0`).
`build.sh` reads it into `CFBundleShortVersionString` and sets
`CFBundleVersion` from the git commit count (`git rev-list --count HEAD`), so
the build number auto-increments. The version is shown in the window header and
the menu-bar title (read at runtime from `Bundle.main.infoDictionary`).

**Whenever you make a code change, bump `VERSION`** — patch for fixes
(`1.1.0` → `1.1.1`), minor for features (`1.1.0` → `1.2.0`) — then rebuild so
the running app visibly reflects the update. This is how the user can confirm
they're on the latest build.

## Conventions

- Match the existing Swift style: small focused files, `@MainActor` on
  `AppManager`, comments that explain *why* (especially around the detach /
  port-polling / kill-escalation behavior).
- No third-party dependencies — keep it `swiftc`-buildable with just SwiftUI +
  AppKit. Don't introduce SwiftPM/CocoaPods.
- Any shell command built from user/config values must go through
  `String.shellQuoted`.
- The committed `AppIcon.icns` is a build asset; its source is
  `Icon/make_icon.swift`. The compiled `LaunchDeck.app/` is git-ignored.
