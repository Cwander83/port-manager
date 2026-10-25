# Research — Port Manager

## The pain (validated)

Every multi-project dev hits daily:

```
Error: listen EADDRINUSE: address already in use :::3000
```

Current workflow = remember arcane command, find PID, kill, maybe kill wrong thing, maybe leave zombie processes eating RAM. Frequent, small pain = exact profile that sells one-time Mac utilities (Bartender, Ice, CleanShot).

Sources (Oct 2026):
- Ideatwister 50-niche checklist listed "Local Port Manager for macOS Devs Who Run 12 Services" — tray app, show ports, kill offender, remember port↔project. Target: solo dev running 5+ local services.
- GitHub trending: zero-server/local-first dev tools surging (GitNexus +1,195 stars/day, qmd +859) — local utilities riding same sentiment.
- Indie SaaS patterns 2026: dev tools/APIs ≈ 76% margins, narrow single-job tools outperform broad ones.

## Competitive scan

| Tool | Gap |
|---|---|
| `lsof` + `kill` (CLI) | The incumbent. Works, but memorized-commands tax every time, no memory, no context |
| SwiftBar/xbar scripts | Hacked-together versions exist, ugly, no kill intelligence |
| Terminal multiplexer dashboards | Wrong layer — don't watch ports system-wide |
| Docker Desktop | Container view only, ignores non-Docker listeners |
| **Nothing** owns "port-level mission control for macOS" | Open lane |

## Differentiator (the moat, small but real)

Dumb kill wrappers exist. Product = **knows what's on the port and kills it the right way**:

| Listener | Correct action |
|---|---|
| node/python/go process | `kill <pid>` |
| Docker proxy (`com.docker.backend`) | `docker stop <container>` — naive kill leaves daemon confused |
| Ollama loaded model on 11434 | unload model, keep daemon alive |
| brew services (postgres/redis) | `brew services stop <name>` |

## Synergy with existing portfolio

- `gravity-bar`: menu bar layout, provider card UI, polling, preferences, mock-mode dev loop — all reusable patterns
- `ollama-bar`: Ollama API integration (`/api/ps`) already written once
- Port Manager completes a "dev menu bar suite": quotas (gravity-bar), Ollama (ollama-bar), ports (this)

## Risks

- Small TAM ceiling — fine, this is a ship-fast portfolio + revenue micro-tool, not a startup
- macOS changes to process APIs — mitigate via lsof subprocess parsing (stable for decades)
- Free OSS clones appear if it takes off — speed + distribution (Homebrew) is the defense