# Launch Deck

A small native macOS app — a Steam-Deck-style control panel for your local dev
projects. Each tile starts/stops a project and shows whether it's running.

Ships configured for **QuantForge** (:5173), **Budgeteer** (:5174), **Study App**
(:5180), **PlantForge** (:5190), **Elevator Clicker** (:5185), **Housing
Calculator** (:4174), **InventoryForge** (:4175), **Trade Templates**
(:4181), and QuantForge's **EP Sweep Agent** (:8765).

## Build & run

```bash
cd LaunchDeck
./build.sh          # compiles LaunchDeck.app with swiftc (needs Xcode CLT)
open LaunchDeck.app # launch it
```

To keep it in your Dock: `cp -R LaunchDeck.app /Applications/` and drag it from
there onto the Dock.

## How it works

- **Start** runs the app's `startCommand` from its directory, detached via
  `nohup … &` through an **interactive** login shell (`zsh -ilc`) so your
  `~/.zshrc` is sourced and version managers like nvm put `npm`/`node` on PATH.
  Because the launching shell exits immediately, the servers reparent to
  `launchd` — so quitting Launch Deck never kills your apps.
- **Status** is detected by polling which TCP ports are in `LISTEN` (every
  2.5s). An app is *Running* once its `readyPort` (the frontend) is up,
  *Starting* while only some ports are up, *Stopping* while a kill is in flight.
- **Stop** frees the app's ports by killing the owning **process group**
  (`SIGTERM`, then `SIGKILL` for anything still holding on) — so a supervisor
  like `uvicorn --reload` goes down with its workers. A custom `stopCommand`
  overrides this.
- **Restart** = Stop, wait for the ports to drain, then Start again.
- **Open** opens the app's `url` in your browser.
- **Scheduled jobs** — an app can also own a `launchd` timer job that runs with
  no server and no port, so Start/Stop can't see it. Those get a switch at the
  bottom of the tile (and an entry in the menu bar). InventoryForge's
  *Background scans* is the one that ships: every run pops a real Chromium
  window, so turning it off when you don't want that is the point. The switch
  reads its state straight from `launchd` each poll — flip the job in a terminal
  and the switch follows.
- **Plan usage** — a strip on the header line shows your Claude plan's
  **5-hour** and **weekly** limits with their reset times (hover for the
  full breakdown), the numbers Claude's own `/usage` reports. There is no live query for this: a reading is what
  some `claude` request was told, so the panel says how old it is and who
  asked. The sweep agent refreshes it for free as it works; the ⟳ sends Claude
  a one-word Haiku message purely to be told (it costs a sliver of the limit,
  so it is a button, never a timer).
- **Remote agent over SSH** — an agent can run on another machine (a cloud VM)
  and appear here as a tile (*EP Sweep Agent (VM)*): live status, cycle, queue
  and usage fetched from the VM's status port over SSH (throttled ~15s), and
  **Start / Stop / Restart** drive its `systemd` unit over SSH (Logs shows the
  VM's `journalctl`). Set the tile's `agent.host` (`user@host`) and
  `agent.serviceName` in `apps.json` to enable control. Model/effort are
  read-only (the VM owns its config). See the `vm-agent-deployment` repo.
- **Background agents** — an app can own an AI agent: a loop of headless
  `claude` runs that reports itself over a loopback port. Launch Deck is the
  remote control only — the agent's logic lives in its own repo. The tile gets
  **Model** and **Effort** pickers and a line on what cycle it is in, how many
  candidates are queued, and how many entries have landed. The pickers write the agent's config file, which
  it re-reads at the start of each cycle, so a change never interrupts a batch.
  The one that ships is QuantForge's *EP Sweep Agent*, which keeps grading
  swept episodic pivots into the study library while the subscription has
  limit left, and pauses itself at a cap (default 90%) until the window resets.
  Start/Stop work like any tile — Stop reaches the running `claude` too.
- **Logs** — the `doc.text` button on each tile (and "View … log" in the menu)
  opens that app's log so you can see what happened, including failures like
  `npm: command not found`. Launch Deck also writes its own timestamped
  `▶ Launch Deck: START/STOP/RESTART …` lines into the log alongside the
  server output.

Per-app logs are written to
`~/Library/Application Support/LaunchDeck/logs/<App>.log`.

## Adding or editing apps

Config lives in:

```
~/Library/Application Support/LaunchDeck/apps.json
```

It's seeded on first run. Edit it and relaunch (or hit refresh). Your edits are
kept: when a new build adds apps to the defaults, they're **appended** to your
config rather than overwriting it — and an app you delete stays deleted (a
`seeded.json` ledger next to it records which defaults have already been
offered). Each entry:

```json
{
  "name": "My App",
  "subtitle": "Anything · :3000",
  "icon": "bolt.fill",                  // any SF Symbol name
  "color": "4f8cff",                    // hex, no #
  "directory": "~/code/my-app",
  "startCommand": "npm run dev",
  "stopCommand": null,                  // null = kill the ports below
  "ports": [3000, 4000],                // used for status + default stop
  "readyPort": 3000,                    // the port that means "fully up"
  "url": "http://localhost:3000",       // Open button (or null)
  "schedule": {                         // optional launchd timer job (or omit)
    "label": "com.example.job",         // launchd label
    "plistPath": "~/Library/LaunchAgents/com.example.job.plist",
    "caption": "Background scans"       // shown beside the switch
  }
}
```

`schedule` only points at the job — its on/off state lives in `launchd`, not
here, so the switch can never disagree with what's actually scheduled. The agent
must already be installed at `plistPath`; if it isn't, turning the switch on
says so in that app's log and flips back.

The defaults baked into the binary are in `Sources/Models.swift`.
