# AGENTS.md

## Branch law

- `main` — **protected. Only Chris pushes to main.** Agents NEVER commit or merge to main without explicit permission.
- `develop` — integration branch. All feature branches cut from `develop`, reviewed, merged into `develop`.
- Branch naming: `feat/<slug>`, `fix/<slug>`, `chore/<slug>`.
- `develop → main` = PR Chris merges himself.

## Review law

Every branch that contains code MUST be reviewed by a second agent (accuracy + security) before merging to `develop`. No self-merge.

## Build commands

```bash
swift build          # build
swift test          # tests (XCTest)
swift run PortManager   # run (make release lands in Phase 3)
```

## Conventions

- Swift 6, SwiftUI + AppKit shell (NSStatusItem/NSPopover), SPM.
- Architecture: see plans/architecture.md (ADR-001 is law).
- Core engine modules (`Sources/Core/`) must not import SwiftUI — pure Foundation + Combine, fully testable.
- KillEngine rule dispatch is the product moat — new listener types need a rule + unit test.
- lsof parsing tests use golden fixtures in `Tests/Fixtures/` — never parse live output in unit tests.
- Commit style: Conventional Commits, terse subject (≤50 chars).

## Repo docs

- Product decisions: `plans/product-spec.md`
- Architecture + ADR: `plans/architecture.md`
- Roadmap phases: `plans/roadmap.md`