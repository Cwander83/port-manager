# Product Spec — Port Manager

## Problem statement

Developers running multiple local services (dev servers, Docker, databases, Ollama) have no fast, visual way to answer: *what's listening on which port, and how do I make it stop?* The only tool is `lsof` + `kill` from memory.

## Target users

- **Primary**: solo web devs on macOS running 5+ concurrent local services (you)
- **Secondary**: any dev/AI tinkerer — Ollama models left loaded eat GBs of RAM invisibly
- Profile: B2C prosumer, $15–30 one-time purchase tolerance, hates subscriptions

## Scale targets

Single user, single machine. No server. N/A: concurrency, storage, uptime.

## Constraints

- Budget: $0 infra (local app, GitHub Releases distribution)
- Timeline: MVP in ~3 focused days (pattern matches gravity-bar/ollama-bar builds)
- Privacy: everything local, zero telemetry required for v1

---

## MVP features (v0.1)

1. **Port list** — menu bar popover: every listening TCP port, owning process, PID, RAM
2. **One-click kill** — confirm by default; ⌥-click = instant kill
3. **Port → project mapping** — resolve process cwd → git repo name; remember names + colors across launches
4. **Free-port helper** — copy next available port in one click

## v1 (launch)

5. **Smart kill rules** — the differentiator (see research.md table): Docker → `docker stop`, Ollama → model unload, brew services → `brew services stop`
6. **Zombie detection** — flag orphaned node processes (no terminal parent), listeners older than N days, red highlight
7. **RAM column** — total RAM held by listeners; "kill 4 zombies, free 3.2GB" summary line
8. **Preferences** — refresh interval, ignore-list (system services like mDNSResponder), launch-at-login
9. **Mock mode** — fixture dataset for UI dev without real processes (gravity-bar pattern)

## v2 ideas (post-launch, validate demand first)

- Project groups: "kill all of myshop" (dev server + API + db proxy in one action)
- Port-taken notification: "3000 grabbed by X — kill?"
- Global hotkey + quick-kill palette: ⌘⇧K → "3000" → Enter
- Menu bar badge: count of active listeners

---

## UX outline (text mockup; real mockups → `mockups/`)

```
[ 🐙 4 ]                        ← menu bar: icon + listener count
────────────────────────────────
PORT MANAGER              ⟳ 2s ago
  6 listeners · 4.1 GB RAM
────────────────────────────────
● :3000  myshop · next dev         128 MB   [kill]
● :5432  postgres (brew)            64 MB   [stop]
● :8080  myapp-container (docker)  210 MB   [stop]
🔴 :8081  node — orphaned, 3d       0.9 MB   [kill]
● :11434 ollama · llama3:70b       4.2 GB   [unload]
────────────────────────────────
  Next free port: 3001  [copy]
  Preferences…   Quit (⌘Q)
```

- Click row → detail (full path, cmdline, start time, parent process)
- Destructive actions always one visible click away, never nested menus
- Color semantics: ● active service, 🔴 zombie/orphan, dim = brew/system service

## Non-goals (MVP)

- No Windows/Linux (macOS only; Tauri rewrite only if demand screams)
- No network monitoring, packet inspection, firewall — ports only
- No cloud sync, no accounts, no subscription