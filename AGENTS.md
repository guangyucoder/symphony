# AGENTS.md

## Project Overview

Symphony — an Elixir/OTP service that orchestrates coding agents to execute Linear issues
autonomously. Polls Linear, dispatches agents to isolated workspaces, handles retry/reconciliation.

This fork adds **unit-lite mode**: instead of one long Codex session per issue, the orchestrator
dispatches one small unit at a time (bootstrap, plan, implement_subtask, verify, handoff, etc.),
each in a fresh session.

## Quick Start

```bash
cd elixir
mix deps.get
mix compile --warnings-as-errors
mix test                           # full suite
mix run --no-start -e 'Application.ensure_all_started(:jason); Code.require_file("scripts/verify_unit_lite.exs")'  # integration verification
```

## Architecture

### Two Execution Modes

Controlled by `agent.execution_mode` in WORKFLOW.md front matter:

- **`legacy`** (default): One Codex session per issue. Agent self-manages all phases. Current
  upstream Symphony behavior.
- **`unit_lite`**: Orchestrator dispatches one unit at a time. Each unit is a fresh Codex session.
  Verification is orchestrator-owned. See [Unit-Lite Design](docs/design/symphony-gsd2-first-principles-lite.md).

### Core Modules

| Module | Purpose |
|--------|---------|
| `Orchestrator` | GenServer. Poll Linear, dispatch, reconcile, retry. Entry point for both modes |
| `AgentRunner` | Executes Codex sessions. `run/3` for legacy, `run_unit_lite/3` for unit-lite |
| `Config` | Reads WORKFLOW.md front matter via NimbleOptions. All config accessors |
| `Workspace` | Per-issue directory lifecycle. Hooks, safety invariants, `.symphony/` dir |
| `PromptBuilder` | Renders prompts. `build_prompt/2` (legacy), `build_unit_prompt/3` (unit-lite) |

### Unit-Lite Modules (new)

| Module | Purpose |
|--------|---------|
| `DispatchResolver` | Rule-based dispatch: issue state + exec state + workpad → next unit |
| `Unit` | Struct: `kind`, `subtask_id`, `display_name`, `attempt` |
| `IssueExec` | Reads/writes `.symphony/issue_exec.json` — durable execution state per issue |
| `Ledger` | Append-only `.symphony/ledger.jsonl` — event history for recovery + audit |
| `WorkpadParser` | Parses `### Plan` checklist from Linear workpad comment |
| `Closeout` | Post-unit acceptance: checks artifacts, runs doc-impact, updates state |
| `Verifier` | Runs validation commands (orchestrator-owned, agent cannot bypass) |
| `DocImpact` | Lightweight check: did this code change make docs stale? |

### Existing Modules

| Module | Purpose |
|--------|---------|
| `Codex.AppServer` | Codex app-server protocol (JSON-RPC over stdio) |
| `Linear.Client` | Linear GraphQL API |
| `Linear.Issue` | Normalized issue struct |
| `Tracker` | Issue tracker abstraction (Linear adapter) |
| `Workflow` / `WorkflowStore` | WORKFLOW.md file watcher + parser |
| `StatusDashboard` | Terminal UI for operator visibility |
| `HttpServer` | Optional Phoenix-based dashboard |

### Dependency Direction

```
Orchestrator → AgentRunner → {AppServer, PromptBuilder, Workspace}
            → DispatchResolver → {IssueExec, WorkpadParser, Unit}
            → Closeout → {Verifier, DocImpact, IssueExec, Ledger}
Config ← (read by all modules, writes nothing)
```

Rules:
- `Orchestrator` is the only module that spawns long-lived Tasks and monitors processes
- `AgentRunner` never reads Linear state directly — Orchestrator passes issue data
- `DispatchResolver` is pure: input → output, no side effects
- `Closeout` may write to `IssueExec` and `Ledger` but never spawns processes
- `Verifier` runs shell commands via short-lived Tasks (with timeout + shutdown) but never writes to Codex or Linear

## Key Files

| File | Purpose |
|------|---------|
| `SPEC.md` | Language-agnostic specification for Symphony |
| `WORKFLOW.md` | Per-repo workflow contract (front matter + prompt template) |
| `elixir/` | Elixir implementation |
| `docs/design/` | Design docs (v3, v4, lite execution plan) |
| `elixir/scripts/verify_unit_lite.exs` | Integration verification script |

## Unit-Lite Dispatch Rules

```
if Merging       → merge
if current_unit  → replay (crash recovery, circuit breaker at 3 attempts)
if done          → stop
if Rework + workpad complete → rework_fix (skip re-plan)
if Rework + stale  → plan (reset)
if !bootstrapped → bootstrap
if !checklist    → plan
if doc_fix_required → doc_fix
if pending subtask → implement_subtask(next)
if all done + no doc_fix yet → doc_fix (once before verify)
if unverified    → verify
else             → handoff
```

## Unit-Lite Invariants

1. **One unit per session.** Agent cannot self-decide "now I'll also do handoff."
2. **One subtask per implement session.** No scope creep.
3. **`last_verified_sha == HEAD` required for handoff.** Code changes invalidate verification.
4. **Crash recovery replays current unit.** Circuit breaker at 3 attempts → escalate to Human Input Needed.
5. **Doc fix runs once before verify, not per-subtask.** Prevents N×doc_fix token waste.
6. **Orchestrator owns verification.** Agent prompt doesn't include validation commands.
7. **Rework skips re-plan when workpad is complete.** `rework_fix_applied` flag prevents re-dispatch loops.

## Testing

```bash
mix test                                            # 73 unit tests
mix run --no-start -e '...'                         # 9 integration scenarios (see Quick Start)
mix compile --warnings-as-errors                    # zero warnings policy
```

Tests cover: WorkpadParser, IssueExec, Ledger, DispatchResolver, PromptBuilder, Closeout,
DocImpact, and integration scenarios (full flow, doc-impact, crash recovery, HEAD invalidation,
merging, rework).

## What NOT To Do

- **Don't bypass the dispatch resolver** — always go through `DispatchResolver.resolve/1`
- **Don't put validation in agent prompts** — validation is orchestrator-owned (`Verifier`)
- **Don't write to `issue_exec.json` outside IssueExec module** — atomic writes only
- **Don't use `run_unit_lite` in legacy mode** — check `Config.unit_lite?()` first
- **Don't grow monolithic prompts** — each unit prompt should be < 2000 chars
- **Don't skip tests** — `mix compile --warnings-as-errors && mix test` before every commit
- **Don't forget to rebuild the escript after code changes** — `mix escript.build`. The `bin/symphony` binary is a frozen snapshot; `mix compile` alone does NOT update it. A running Symphony process uses the escript it was started with, not the latest `.beam` files.

## Deployment

After any code change to Symphony:

```bash
cd elixir
mix compile --warnings-as-errors && mix test   # verify
mix escript.build                                # rebuild binary
# Then restart Symphony (start-symphony.sh kills old process automatically)
```

**Common pitfall**: editing code, running `mix test` (passes), restarting Symphony
via `start-symphony.sh`, but forgetting `mix escript.build`. The new process loads
the OLD escript — your fix is not running. Always rebuild before restart.

## Configuration

WORKFLOW.md front matter (unit-lite additions):

```yaml
agent:
  execution_mode: unit_lite     # "legacy" | "unit_lite"

verification:
  baseline_commands:
    - ./scripts/validate-app.sh --quick
  full_commands:
    - ./scripts/validate-app.sh

docs:
  doc_impact_command: null       # optional external command
```

## Further Reading

- [SPEC.md](SPEC.md) — Symphony specification
- [Unit-Lite Design](docs/design/symphony-gsd2-first-principles-lite.md) — First-principles design
- [Harness Engineering](docs/engineering/HARNESS_ENGINEERING.md) — Engineering principles
