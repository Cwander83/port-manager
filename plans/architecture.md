# Architecture — Port Manager

*Filled from PROJECT_PLAN_TEMPLATE.md. Sections marked N/A are consciously excluded — this is a local macOS utility, not a web app.*

## 1. Product & Scope
- **Problem**: no fast visual way to see/kill processes listening on local ports
- **Target users**: B2C prosumer — macOS devs running multiple local services
- **Scale targets**: single machine, single user, ~50 max listeners, refresh every 2s
- **Constraints**: $0/month infra, MVP in ~3 days, fully local/private

## 2. Architecture
- **Pattern**: native single-process desktop app (modular by design: core engine + UI)
- **API contract**: N/A external. Internal: `PortScanner` service → `PortItem` model → SwiftUI views
- **Communication**: internal only — polling loop + Combine/observation for UI updates
- **Process model**: long-lived menu bar agent (NSStatusItem), background timer poll

## 3. Frontend Platform
- **Targets**: macOS 14+ (menu bar + popover)
- **Framework**: SwiftUI over AppKit shell (NSStatusItem/NSPopover — same as gravity-bar)
- **Rendering strategy**: native (template N/A)
- **UI & Styling**: system appearance + SF Symbols; match visual language of gravity-bar/ollama-bar
- **Client state & cache**: ObservableObject store (`PortStore`), UserDefaults for prefs

## 4. Backend Platform
- **Runtime & Language**: Swift 6, native macOS APIs
- **Core engine**:
  - Port scan: `lsof -iTCP -sTCP:LISTEN -P -n` subprocess (stable, no entitlements) → parse to `PortItem`
  - RAM: `proc_pid_rusage` (or `ps` fallback) per PID
  - cwd resolution: `proc_pidpath` / `proc_pidinfo` → git repo folder name for project mapping
  - Parent PID: detect orphaned processes (parent = launchd/none)
- **Kill engine (the moat)** — rule-based dispatcher:
  - default → `kill(pid)`
  - Docker proxy detected (`com.docker.backend`) → `docker stop <container>` (resolve container via `docker ps --format` + port match)
  - Ollama on 11434 → `DELETE /api/unload` (or `api/stop` per local Ollama version; reuse gravity-bar integration knowledge)
  - brew services prefix → `brew services stop <name>`
- **Contract & Validation**: typed structs, no external schema needed
- **Background processing**: `Timer`/`DispatchSourceTimer` poll loop, 2s default

## 5. Data & Storage
- **Primary database**: none. Persistence = `UserDefaults` + one JSON file in `~/Library/Application Support/PortManager/` for port↔project memory (names, colors, notes)
- **Caching layer**: none (fresh scan every poll)
- **Object storage / search / migrations**: N/A

## 6. Hosting & Cloud Infrastructure
- **Provider**: none. Distribution via GitHub Releases + Homebrew cask
- **IaC**: none. Release = `make release` producing signed + notarized `.dmg`
- **Edge & DNS**: N/A

## 7. Security & Compliance
- **AuthN/AuthZ**: N/A (local app). Note: no elevated privileges needed — user owns their own processes
- **Secrets**: none stored
- **Network & perimeter**: app makes only local calls (lsof subprocess, docker CLI, localhost Ollama API). Hardened Runtime + notarization required for Gatekeeper pass
- **Compliance**: none — zero data collection

## 8. Codebase & Developer Experience (DX)
- **Repository style**: single repo, Swift Package Manager (`Package.swift` — matches ollama-bar/gravity-bar)
- **Layout**:
  ```
  Sources/
    PortManagerApp/   — entry, menu bar, popover views
    Core/             — PortScanner, KillEngine, ZombieDetector, ProjectMapper
    Persistence/      — port memory store, preferences
    Mocks/            — MockPortScanner (fixture data for UI dev)
  Tests/
  scripts/            — release build, notarize, cask bump
  ```
- **Toolchain**: SPM, `swift build/test`, Makefile wrappers (matches existing repos)
- **Formatting & linting**: swift-format + SwiftLint (match portfolio convention)

## 9. CI/CD & Delivery
- **Pipeline engine**: GitHub Actions (macos runner)
- **Checks**: `swift build`, `swift test` (XCTest), SwiftLint — on PR
- **Deployment strategy**: tag push → xcodebuild + codesign + notarize → GitHub Release draft → Homebrew cask bump PR
- **Environments**: local only; mock scanner mode for UI work without services running

## 10. Observability & Operations
- **Error tracking**: local `os.Logger` logs viewable in Console.app; optional in-app "copy diagnostics"
- **Health checks**: N/A
- **Alerting**: N/A (v2 idea: port-taken notification is a feature, not ops)

## 11. Testing Strategy
- **Unit tests** (XCTest): lsof output parsing (golden fixtures), kill-rule dispatch (mocked exec), zombie detection logic, project memory store
- **Integration tests**: scan real machine ports in CI (deterministic: spin up `nc -l` listeners in test setup)
- **E2E**: manual smoke checklist per release (scan → kill each listener type → verify)
- **Load testing**: N/A

---

# ADR-001: Port Manager Initial Architecture

## 1. Context
- **Product purpose**: macOS menu bar utility — see and kill port listeners, with kill intelligence per process type
- **Target archetype**: native desktop utility (Internal Tool variant, single user)
- **Primary users & scale**: solo macOS dev; single machine, no server

## 2. Decision Stack
- **Frontend**: SwiftUI + NSStatusItem/NSPopover, macOS 14+
- **Backend & API**: native Swift services — PortScanner (lsof subprocess), KillEngine (rule dispatcher), ZombieDetector
- **Database & storage**: JSON file + UserDefaults (port memory)
- **CMS**: N/A
- **Auth & security**: none; notarized + Hardened Runtime
- **Hosting**: none — GitHub Releases + Homebrew
- **CI/CD & testing**: GitHub Actions (build/test/lint), XCTest + fixture-based parsing tests
- **Observability**: os.Logger local logs

## 3. Key Trade-offs Accepted
- **Native Swift over Tauri/web**: true menu bar feel, ~10MB RAM (the product itself monitors RAM — footprint is credibility), and full reuse of existing gravity-bar/ollama-bar patterns. Cost: no web code reuse, macOS only.
- **lsof subprocess over private APIs**: output format stable for decades, no entitlement drama, easy fixture-testing. Cost: parse fragility mitigated with golden-fixture tests.
- **Polling over FSEvents/kqueue monitoring**: 2s poll is invisible UX-wise, far simpler. Cost: negligible CPU.
- **Docker via `docker stop` over raw kill**: correct daemon state. Cost: requires Docker CLI on PATH (graceful fallback to blunt kill with warning).
- **Menu bar popover over desktop widget / floating HUD**: evaluated Oct 2026. True WidgetKit widgets can't kill processes (sandboxed extension — host app required) and have no room for lists; floating HUD fights desktop space and window layering. Menu bar = standard pattern, one surface, ships fastest. Detachable HUD panel + glance widget remain v2 candidates (see roadmap).
- **v1 scope excludes notifications/groups**: ship narrow, validate, iterate.

## 4. Cost Estimate
- **Estimated monthly spend: $0** (CI free tier; signing cert is existing Apple Developer asset)
- One-time: Apple Developer Program if not already held ($99/yr, shared with portfolio)