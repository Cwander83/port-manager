# Roadmap — Port Manager

## Guiding rule

Scope = MVP list in product-spec.md. Nothing else enters before launch.

## Phase 0 — Mockups (next session)
- [ ] Popover layout sketch (menu bar dropdown, row design, detail view)
- [ ] Icon + name decision (working name "PortMate" from research; pick final before repo branding)
- [ ] Output: HTML/SVG or image mockups in `plans/mockups/`

## Phase 1 — MVP (Days 1–2)
- [ ] SPM project scaffold, menu bar shell + popover (port gravity-bar skeleton patterns)
- [ ] `PortScanner`: lsof parse → `PortItem` (port, pid, process, RAM)
- [ ] One-click kill (blunt `kill`) + ⌥-click instant
- [ ] ZombieDetector: orphan parent check, age flag, red styling
- [ ] MockPortScanner + fixture data → build UI against it
- **Exit criteria**: running app shows real ports, kills a node process correctly

## Phase 2 — v1 launch (Days 3–5)
- [ ] KillEngine rules: docker stop, ollama unload, brew services stop
- [ ] ProjectMapper: cwd → repo name; JSON memory for names/colors
- [ ] RAM totals + free-port copy button
- [ ] Preferences: refresh interval, ignore-list, launch-at-login
- [ ] Golden-fixture tests for lsof parsing; kill-rule unit tests
- **Exit criteria**: all four kill rules work against real services

## Phase 3 — Ship (Days 6–7)
- [ ] Icon, readme with GIF, screenshots
- [ ] Hardened Runtime, codesign, notarize, `make release`
- [ ] GitHub public repo + Release v1.0
- [ ] Homebrew cask PR
- **Exit criteria**: `brew install --cask portmate` works on a clean Mac

## Phase 4 — Launch amplification (Week 2)
- [ ] Show HN post ("I built a one-click port killer for macOS")
- [ ] r/macapps + r/webdev posts, Product Hunt
- [ ] Ship README GIFs to the launch channels; monitor GitHub issues for v2 signal

## Phase 5 — v2 (validate first, then pick)
Candidates in priority order (demand-gated):
1. Port-taken notifications
2. Project groups ("kill all of myshop")
3. Global hotkey quick-kill palette
4. Detachable floating HUD panel (evaluated Oct 2026, deferred — see ADR)
5. WidgetKit desktop widget: listener count + RAM glance, tap-to-open deep link (companion, not kill surface)
4. Menu bar listener-count badge
- Decide from issue tracker + launch feedback, not vibes

## Monetization

- Default thesis: **free OSS core**, builds audience for the dev menu bar suite (gravity-bar, ollama-bar, port-manager as a family)
- Optional test: $9–19 one-time "Pro" via Lemon Squeezy if v2 features have pull (groups, notifications)
- No subscription. Devs punish sub-only for tiny utilities.

## Definition of done (launch)

1. App notarized, Gatekeeper-clean install
2. All four kill rules tested against real node/docker/ollama/brew services
3. README: one GIF showing the EADDRINUSE → kill flow
4. Homebrew installable
5. Public repo live

## Open questions (resolve at Phase 0)

- [ ] Final name (PortMate? Orphan? Dockhand? — check Homebrew availability)
- [x] Ollama unload API path — **resolved Oct 2026**: `POST /api/generate` with `{"model": <name>, "keep_alive": 0}` (no `/api/unload` endpoint exists; verified in review, KillEngineTests pin method/path/body)
- [ ] Ignore-list defaults — which system listeners to hide (mDNSResponder, etc.)