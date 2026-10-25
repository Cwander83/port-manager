# BUILD STATUS — Resume Here

*Last updated: Oct 25, 2026. Session token budget exhausted mid-build. This file is the handoff.*

## Where things are

| Branch | State |
|---|---|
| `main` | Protected (PR + 1 approval, no force-push). Setup commit only. Chris merges develop→main. |
| `develop` | Current integration: app-shell + real lsof port-scanner merged (through 73372dc). Docs current. |
| `feat/kill-engine` | **COMPLETE, 99/99 tests green, zero warnings** at commit `8b60c34`, pushed to origin. Awaiting final review round (round 7, verify-only — round 6 findings all fixed). |
| Worktrees | `/Users/chriswander/Codebases/.pm-wt/kill-engine` (branch checked out) + `.pm-wt/port-scanner` (merged, removable). |

## NEXT STEPS (in order)

1. **Round-7 verify-only review of `feat/kill-engine` @ 8b60c34.** Reviewer prompt template in this file below. Prior rounds: 1 REQUEST_CHANGES (11 S2s), 2 RC (4 integration S2s), 4 RC (S1 precision + contracts; round 3 was fixes-only), 6 RC (1 S2 brew misrouting). Round 6 S2 fix verified conceptually but never reviewed: brew canHandle reverted to `kind == .brew`, scanner classifies mongod/nginx/httpd under brew paths as `.brew` (path-truth). Also added: docker-pr/docker-proxy acceptance in DockerKillRule, ollama token-boundary matching, CommandRunner child reaping, empty-name guards, doc corrections, force-unwrap cleanup.
2. **Orchestrator verifies build locally** (reviewers have no shell access): `cd /Users/chriswander/Codebases/.pm-wt/kill-engine && rm -rf .build && swift build && swift test` — must be clean + 99/99.
3. **Merge to develop**: `git checkout develop && git merge --no-ff feat/kill-engine -m "merge: feat/kill-engine — rule-based kill engine"` + push. Reviewer conditions for merge message: none outstanding beyond round-7 APPROVE.
4. **Cleanup**: `git worktree remove ../.pm-wt/port-scanner` (merged); keep or remove kill-engine worktree after merge.
5. **Phase 1 final branch: `feat/kill-ui`** (see spec below).

## Process law (established this session)

- **Agents never touch main.** All work: feature branches off `develop` → coder agent → reviewer agent (adversarial, verify-fix loop until APPROVE) → orchestrator's OWN local build/test verification → merge to develop. Chris merges develop→main via PR.
- **Model team (token-efficient tiers, user-approved)**: coder = `ollama/kimi-k2.7-code:cloud`; reviewer = `ollama-cloud/deepseek-v4.1-flash#high`; mechanical/docs = orchestrator. Reviewers can't run shell — static only.
- **Reviewers must check branches against merged develop** (cross-branch S1s were found: scanner whole-second timestamps vs engine microsecond comparison).
- **Coder agents can die silently** — verify worktree state (git log + grep expected fixes) before trusting any report. One agent died mid-rebase; resumed successfully with explicit state description.
- Commit style: Conventional Commits, terse.

## Reviewer prompt template (round 7 + kill-ui reviews)

```
Verify-only pass on branch `feat/kill-engine` in worktree /Users/chriswander/Codebases/.pm-wt/kill-engine.
Findings applied in commit 8b60c34 (git diff d1c519a..8b60c34). Read-only, no shell.
Focus ONLY on: brew canHandle revert + scanner path-truth classification (.brew for
mongod/nginx/httpd under brew paths; Postgres.app/DMG/MacPorts stay .other → DefaultKillRule,
still killable); docker-pr/docker-proxy prefix acceptance; ollama token-boundary match (no \Q\E);
CommandRunner SIGKILL reap before timeout throw; empty processName guards; doc corrections;
force-unwrap replacements correctness. 99 tests expected. Verify scanner test placement
(PortManagerTests.swift also touched — rebase artifact?). New-risk: scanner mongod/nginx/httpd
detection runs AFTER .docker classification (docker mongo stays .docker)? label() skip intact?
.other postgres test uses mock identity (kills nothing real)?
REPORT: VERDICT APPROVE/REQUEST_CHANGES/BLOCK + per-item one-liners + new findings.
```

## feat/kill-ui spec (Phase 1 closer)

Branch off develop AFTER kill-engine merges. Scope:
1. Wire kill buttons in `PortListView` → `KillEngine.action(for: item)` (async, off-main).
2. Confirm dialog (default on) showing `action.commandDescription` exactly — the transparency feature. ⌥-click = skip confirm (power-user path).
3. On confirm → `engine.execute(action, using: runner)` async; success → force refresh scan; failure → error banner with `localizedDescription`.
4. Buttons disabled during in-flight action per row (no double-kill).
5. Zombie rows kill instantly too (same flow). Escalation (SIGKILL) NOT in UI yet — v2, needs its own confirm.
6. Reviewer focus: MainActor isolation (no blocking calls on UI thread), no state races on rapid double-click, error surfaces verbatim.
Exit criteria (Phase 1 done): app shows real ports, kills a node process correctly, docker stop works, ollama unload works, brew stop works.

## Open items → GitHub issue #1 (update after merges)

- ✅ N1 scan starvation + N3 dual-stack id — RESOLVED in feat/port-scanner (merged).
- ProcessRunner S3 residuals: pre-launch cancel window (nanoseconds, unreachable in practice), SIGKILL escalation for uninterruptible lsof, timeout scheduled pre-launch, discriminating stale-scan clobber test (current test passes on buggy code — reviewer sketched correct version in round-5 review).
- Unify `Core/ProcessRunner` (lsof) + `KillEngine/CommandRunner` (docker/brew) — two async subprocess runners, hardest code duplicated. Follow-up refactor, NOT in any current branch.
- PortStore → Core move (decouple test target from executable) — follow-up.
- Phase 2 remaining: ProjectMapper (cwd→repo names + JSON memory), Preferences, RAM totals polish, ignore-list.
- Phase 3: Makefile, sign/notarize, Homebrew cask, launch. Docs in `plans/roadmap.md`.

## Known-good facts

- Ollama unload = `POST /api/generate` `{"model":<name>,"keep_alive":0}` (verified round 2, tests pin it).
- `ri_phys_footprint` = bytes (Activity Monitor figure); `ps rss` = KB × 1024. Both handled.
- lsof exits 1 on zero matches = empty result, NOT error. Also parses partial output on non-zero with rows.
- `pbi_start_tvsec` compared at SECOND granularity (`sameStart` helper) — scanner whole-second vs engine µs.
- Zombie = orphan (ppid 1) AND kind == .node only (GUI apps under launchd are NOT zombies).
- Intel brew paths: /usr/local/Cellar|opt|bin + contains /cellar/ or /homebrew/. `/usr/local/homebrew/` is NOT real.
- Test count at 8b60c34: 99 (63 kill-engine + 36 scanner).