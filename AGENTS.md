# AGENTS.md

## Project Overview

Symphony — an Elixir/OTP service that orchestrates coding agents to execute Linear
issues autonomously. Polls Linear, dispatches agents to isolated workspaces, handles
retry / reconciliation. This fork runs **unit-lite mode** with a **warm-session
review loop**: the orchestrator dispatches one small unit at a time (bootstrap,
plan, implement_subtask, code_review, doc_fix, handoff, …). Two persistent Codex
threads survive across dispatches — one for implementing, one for reviewing —
resumed via `AppServer.resume_session/2` on each round. `verify` is still a unit
but only in the merge flow; normal-flow tests run inside the implement session.

## Quick Start

```bash
cd elixir
mix deps.get
mix compile --warnings-as-errors
mix test                 # full suite
```

## Architecture

### Execution Model

One mode only: **unit-lite**. The orchestrator dispatches one unit at a time and a
fresh Codex session runs it. Verification is orchestrator-owned. See
[Unit-Lite Design](docs/design/symphony-gsd2-first-principles-lite.md) for the
underlying design rationale.

### Core Modules

| Module | Purpose |
|--------|---------|
| `Orchestrator` | GenServer. Polls Linear, dispatches, reconciles, retries |
| `AgentRunner` | Executes Codex sessions via `run_unit_lite/3` (the only entry) |
| `Config` | Reads WORKFLOW.md front matter via NimbleOptions |
| `Workspace` | Per-issue directory lifecycle. Hooks, safety invariants, `.symphony/` dir, `prepare_for_dispatch/2` |
| `PromptBuilder` | Renders unit prompts via `build_unit_prompt/3` |
| `DispatchResolver` | Rule-based dispatch: issue state + exec state + workpad → next unit |
| `Unit` | Struct: `kind`, `subtask_id`, `display_name`, `attempt` |
| `IssueExec` | Reads/writes `.symphony/issue_exec.json` — durable per-issue state |
| `Ledger` | Append-only `.symphony/ledger.jsonl` — event history for recovery + audit |
| `WorkpadParser` | Parses `### Plan` checklist (with `touch:` / `accept:` continuation lines) from Linear workpad |
| `Closeout` | Post-unit acceptance: HEAD-advance guard, workpad sync, state updates |
| `Verifier` | Runs validation commands (orchestrator-owned, agent cannot bypass) |

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
            → Closeout → {Verifier, IssueExec, Ledger, Linear.Adapter}
Config ← (read by all modules, writes nothing)
```

Rules:
- `Orchestrator` is the only module that spawns long-lived Tasks and monitors processes
- `AgentRunner` never reads Linear state directly — Orchestrator passes issue data
- `DispatchResolver` is pure: input → output, no side effects
- `Closeout` may write to `IssueExec` and `Ledger` and may call Linear `mark_subtask_done`, but never spawns processes
- `Verifier` runs shell commands via short-lived Tasks (with timeout + shutdown) but never writes to Codex or Linear

## Key Files

| File | Purpose |
|------|---------|
| `SPEC.md` | Language-agnostic specification for Symphony |
| `WORKFLOW.md` | Per-repo workflow contract (front matter + prompt template) |
| `elixir/` | Elixir implementation |
| `docs/design/` | Design docs (v3, v4, lite execution plan; v3/v4 describe rejected legacy directions) |

## Unit-Lite Dispatch Rules (warm-session review loop)

```
if Merging                                    → merge (with verify-fix sub-path on verify failure)
if current_unit                               → replay (crash recovery, circuit breaker at max_unit_attempts)
if done                                       → stop
if Rework + workpad complete                  → rework_fix (skip re-plan)
if Rework + stale                             → plan (reset)
if !bootstrapped                              → bootstrap
if !checklist                                 → plan
if pending subtask                            → implement_subtask(next)
if review_round > max_review_rounds + verdict=findings  → {:stop, :review_exhausted} (Human Input Needed)
if verdict=findings + HEAD==last_reviewed_sha → implement_subtask(review-fix-N) (resume implement thread)
if all done + (no verdict OR HEAD advanced)   → code_review (first round or re-review; bundles $code-review + $visual-review on web UI)
if verdict=clean + !doc_fix_applied           → doc_fix (pre-handoff sweep; re-opens review if it commits)
if verdict=clean + doc_fix_applied + HEAD==last_reviewed_sha → handoff
```

## Unit-Lite Invariants

1. **One unit per session.** Agent cannot self-decide "now I'll also do handoff."
2. **One subtask per implement session.** No scope creep.
3. **HEAD must advance for mutation-bearing units.** Closeout requires a commit since dispatch for `implement_subtask` (regular plan-N + synthetic kinds) and `doc_fix` (with the no-op-on-clean-tree exception). Uncommitted WIP gets retried so the next dispatch's reset doesn't silently destroy it.
4. **`last_reviewed_sha == HEAD` required for handoff.** Any commit after the last review (e.g., a doc_fix that really updated docs) invalidates the verdict and re-fires `code_review`.
5. **Verification lives inside the warm implement session.** `./scripts/verify-changed.sh` runs as part of each subtask's turn; the orchestrator no longer dispatches a separate `verify` unit in the normal flow (merge path still uses one).
6. **Crash recovery replays current unit.** Circuit breaker at `agent.max_unit_attempts` (default 3) → escalate to Human Input Needed.
7. **Review rounds are capped.** `review_round > max_review_rounds` with a findings verdict escalates to Human Input Needed instead of burning tokens forever.
8. **doc_fix runs once per review cycle.** `doc_fix_applied` flag (set by closeout, cleared on rework/escalation) prevents re-firing after a post-doc_fix re-review flips `last_accepted_unit` back to `code_review`.
9. **Orchestrator owns verdict parsing.** Agent must append `Verdict: clean` or `Verdict: findings` to the workpad's `### Code Review` section; closeout re-fetches from Linear (post-turn, not pre-dispatch snapshot) and fails closed on missing/invalid/fetch-error.
10. **Rework skips re-plan when workpad is complete.** `rework_fix_applied` flag prevents re-dispatch loops.
11. **Rework entry clears warm-session state.** `plan_rework_entry_cleanup/1` calls `IssueExec.rework_reset_updates/0`; the same field set is used by `reset_for_rework/1` and `escalate_to_human/3` so no call site drifts.
12. **Workpad sync is fatal for regular plan-N.** If `Adapter.mark_subtask_done` fails after a plan-N commit, closeout returns `{:retry, _}` and persists `pending_workpad_mark` as `%{subtask_id, committed_sha}` (the post-commit HEAD) so the next entry can recover the mark without requiring HEAD to advance again. Recovery requires current HEAD to still equal `committed_sha`: if HEAD has moved past it (e.g., a replan re-emitted plan-N with new content), the stale sentinel is cleared and the normal HEAD-advance check decides; if HEAD is unreadable, recovery is deferred (sentinel preserved). Synthetic kinds (`rework-*`, `verify-fix-*`, `merge-sync-*`) are warn-only since their dispatch is not derived from the workpad checkbox.

## Testing

```bash
cd elixir
mix compile --warnings-as-errors
mix test
```

Tests cover: WorkpadParser, IssueExec, Ledger, DispatchResolver, PromptBuilder,
Closeout (incl. baseline-clear / split-brain / pending-mark recovery), Workspace
(incl. `prepare_for_dispatch/2`), AgentRunner unit-lite hook ordering, end-to-end
integration scenarios.

## What NOT To Do

- **Don't bypass the dispatch resolver** — always go through `DispatchResolver.resolve/1`
- **Don't put validation in agent prompts** — validation is orchestrator-owned (`Verifier`)
- **Don't write to `issue_exec.json` outside IssueExec module** — atomic writes only
- **Don't grow monolithic prompts** — each unit prompt should stay focused
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

WORKFLOW.md front matter (relevant sections):

```yaml
agent:
  max_unit_attempts: 3            # circuit breaker for crash-replays per unit
  max_concurrent_agents: 3

review:
  max_review_rounds: 5            # strict ceiling on findings-fix cycles before
                                  # escalating to Human Input Needed (warm-session)

verification:
  # NOTE: verification.* applies only to the merge-time verify subpath now.
  # Normal-flow tests run inside the warm implement session via
  # ./scripts/verify-changed.sh — no separate verify unit dispatch.
  baseline_commands:
    - ./scripts/validate-app.sh --quick
  full_commands:
    - ./scripts/validate-app.sh
  max_verify_attempts: 3
  max_verify_fix_cycles: 2
```

> Stale keys removed in round-4 cleanup (`agent.execution_mode`, `agent.max_turns`,
> `agent.compact_between_turns`, `docs.doc_impact_command`) are now ignored. Config
> logs a warning when it sees them so operators notice instead of silently running
> stripped-down behaviour.

## Further Reading

- [SPEC.md](SPEC.md) — Symphony specification
- [Unit-Lite Design](docs/design/symphony-gsd2-first-principles-lite.md) — First-principles design
- [Harness Engineering](docs/engineering/HARNESS_ENGINEERING.md) — Engineering principles
