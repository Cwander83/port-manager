# Port Manager

> **macOS menu bar utility that shows every process listening on every port — node servers, Docker containers, Ollama models, Postgres — and kills the right one, the right way, with one click.**

Dev running multiple projects knows the pain:

```
Error: listen EADDRINUSE: address already in use :::3000
```

Port Manager puts a live listener list in your menu bar: what's on each port, how much RAM it holds, and one-click kill — with type-aware intelligence:

| Listener | Correct action |
|---|---|
| node / python / go process | `kill <pid>` |
| Docker proxy | `docker stop <container>` — no more confused Docker daemon |
| Ollama model on `:11434` | unload model, keep daemon alive |
| brew services (postgres, redis…) | `brew services stop <name>` |

Zombie processes (orphaned node processes, forgotten listeners) get flagged red and sorted to the bottom. One click frees the RAM you forgot you were holding.

**Status:** planning → building. See [plans/](./plans) for research, product spec, architecture (ADR), and roadmap.

## Stack

Swift 6 · SwiftUI + NSStatusItem/AppKit shell · Swift Package Manager · macOS 14+ · zero external dependencies · ~10 MB RAM footprint.

## Development

```bash
swift build
swift test
swift run PortManager   # run from CLI until .app bundling lands (Phase 3: Makefile + signed dmg)
```

## License

MIT — see [LICENSE](./LICENSE).