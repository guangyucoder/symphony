# Rework re-ingest & zero-commit guard

> Status: Draft v5 (supersedes v4)
> Author: Supervisor-agent observation from PTCG project (2026-04-12)
> Related: `/Users/guangyuwang/symphony/elixir/lib/symphony_elixir/`
> History: Earlier versions (v1–v4) progressively added more orchestrator machinery — outcome tracking, cycle counters, file-overlap checks, header-anchored comment filtering, watermarks. Three rounds of first-principles review (two prompt-based reviewers + codex) converged on the same verdict: the real problem is small, the existing Symphony infrastructure already handles most of what earlier drafts proposed to add, and the orchestrator should do strictly less than those drafts imagined. v5 strips the design down to the minimum that closes the observed bug.

## Problem

Symphony's Rework loop sometimes passes a ticket back to `Human Review` with the same git sha it arrived with. The agent ran, the test suite passed (it was already green — supervisor findings are semantic, not test failures), the orchestrator handed off. Observed in PTCG on three tickets (ENT-157, ENT-159, ENT-165) across 2–4 cycles each.

## Root cause

Two independent gaps compound into the degenerate loop. Both must be fixed.

**Gap A — Findings never reach the agent.** The `rework-1` prompt (`prompt_builder.ex:133-145`) is a static template with the instruction "run `gh pr view --comments`." Supervisor findings live on Linear (or PR) and are never fetched by the orchestrator and injected into the prompt. Symphony already has `Linear.Adapter.fetch_issue_comments/1` (`linear/adapter.ex:55-65`) but no code path calls it during rework dispatch.

**Gap B — Closeout has no "work produced" gate.** At `closeout.ex:62-101`, the `implement_subtask` branch unconditionally returns `:accepted` and sets `rework_fix_applied=true`. There is no check that any commit was produced. If the agent did nothing, closeout still accepts, `rework_fix_applied=true` causes `rework_fix_rule` to short-circuit, `verify_rule` passes on the unchanged (already-green) HEAD, and `handoff_rule` fires. This is the decisive defect — Gap A alone would still loop without it.

## Proposal

Three small changes, ~30 lines of Elixir total. No new state struct, no new dispatch rules, no feature flag, no migration.

### 1. Inject all Linear comments at rework dispatch (`agent_runner.ex`)

Before building the prompt for a `rework-*` unit:

```elixir
comments =
  case Linear.Adapter.fetch_issue_comments(issue_id(issue)) do
    {:ok, list} -> list
    _ -> []
  end

opts = Keyword.put(opts, :linear_comments, comments)
```

Pass through to `PromptBuilder.build_unit_prompt/3`. No filtering, no author matching, no header matching, no watermark — the orchestrator does not decide what a "finding" looks like. The agent reads the comment body (markdown with timestamps and authors), identifies what's a review finding, distinguishes old from already-addressed from new, and acts. This is semantic work the agent is capable of; the orchestrator's job is only to make sure the comments arrive.

Rationale: every filter we considered (by user, by header, by timestamp) is the orchestrator pre-judging content. Agents read markdown natively — give them the full context and trust them to use it.

### 2. Update the `rework-1` prompt (`prompt_builder.ex:133-145`)

Replace "run `gh pr view --comments`" with a reference to an injected block. The template renders the injected comments verbatim:

```
<ticket_comments>
  {{ each comment with its author, createdAt, body }}
</ticket_comments>

## Instructions — Rework Fix
Review findings are in the `<ticket_comments>` block above (sorted chronologically).
Identify the supervisor's review findings, implement fixes for MEDIUM and above,
and commit.
```

Removing the `gh pr view` instruction is important — two read paths for review context create exactly the "which source is canonical?" ambiguity this design is meant to eliminate.

### 3. Zero-commit guard at rework closeout (`closeout.ex:62-101`)

At `rework-*` dispatch time, `agent_runner.ex` snapshots `dispatch_head = current_git_head(workspace)` and passes it to closeout via the existing `opts`.

In the `implement_subtask` branch for `rework-*` subtasks:

```elixir
if Verifier.current_head(workspace) == opts[:dispatch_head] do
  {:retry, "rework produced no commit"}
else
  # existing logic: mark_subtask_done, set rework_fix_applied=true
end
```

When the guard fires, closeout returns `{:retry, ...}` instead of `:accepted`. `IssueExec.accept_unit/1` is not called, so `current_unit` stays in `issue_exec.json`. On the next resolver tick, `replay_current_unit_rule` (`dispatch_resolver.ex:100`) fires first, increments `current_unit["attempt"]`, and re-dispatches `rework-1` with a fresh Linear fetch. After `@max_unit_attempts = 3` consecutive no-commit retries, the existing circuit breaker (`dispatch_resolver.ex:113-115`) returns `{:stop, :circuit_breaker}`, which `agent_runner.ex:148-150` routes to `escalate_to_human/3`.

No new rules, no new counters, no new escalation path. Everything downstream of the guard is already implemented.

## What this design is NOT doing

Each of the following was in earlier drafts and was cut after review. Flagged here so reviewers know they were considered and rejected, not missed:

- **No `rework_cycle` struct.** No `entry_sha`, `cycle_count`, `last_outcome`, or `addressed_findings` fields.
- **No `escalate_stuck_rule`.** The existing `@max_unit_attempts` circuit breaker does this job.
- **No `comment_watermark`.** Inject everything every dispatch; agent filters by timestamp if it cares.
- **No header matching (`## Symphony Findings`).** Relying on supervisor format compliance is exactly the agent-trust problem this design is built to avoid.
- **No user-based filter.** Same reason.
- **No file-overlap check between commit diff and finding file hints.** Orchestrator cannot do semantic judgment; that's what the supervisor does on the next review cycle.
- **No cross-episode cycle counter.** ENT-165's "committed but didn't address findings" pattern is supervisor-caught; Symphony does not need to adjudicate. Revisit if data demands.
- **No feature flag.** The change is small and the existing retry channel means failure modes degrade gracefully (stuck tickets become retries, not broken dispatches).
- **No `issue_exec.json` migration.** No new persistent fields.

## How this catches PTCG's observed failures

- **ENT-159 (4 zero-commit cycles on `1e3ae4b`):** Gap B fix catches on cycle 1. Attempt increments across up to 3 retries; circuit breaker escalates to HIN at attempt 4. Loop terminates.
- **ENT-157 (2 zero-commit cycles on `15e99b6`):** Same as above.
- **ENT-165 (3 cycles with commits but wrong fixes):** HEAD advances each cycle, so the zero-commit guard does not fire. Supervisor re-reviews after handoff, continues to flag issues. This PR intentionally does not auto-escalate ENT-165 — the supervisor-agent (or a human) decides HIN. If the pattern recurs frequently in post-rollout data, consider a separate PR for cross-episode counting.

## Rollout

Single PR, no coordinated changes:

1. Land all three code changes together. They are not independently useful — Gap A fix without Gap B fix still loops when agent ignores findings; Gap B fix without Gap A fix burns circuit-breaker attempts on agents that can't see findings.
2. No backfill required. No new persistent state is introduced.
3. Canary on 1–2 low-traffic workspaces for one week. Monitor ledger for `{:retry, "rework produced no commit"}` frequency and `:circuit_breaker` escalations. Full rollout if healthy.

## Test plan

Four scenarios, one per invariant:

1. **Injection**: rework-* dispatch fetches Linear comments, prompt contains `<ticket_comments>` block with bodies verbatim.
2. **Zero-commit guard**: rework-1 closeout with `HEAD == dispatch_head` returns `{:retry, :no_commits}`, does not mark subtask done, does not set `rework_fix_applied`.
3. **Circuit breaker integration**: three consecutive zero-commit retries trigger `{:stop, :circuit_breaker}` via existing `replay_current_unit_rule` and `@max_unit_attempts`, which routes to `escalate_to_human`.
4. **Normal path unaffected**: rework-1 closeout with `HEAD != dispatch_head` proceeds through existing logic (`mark_subtask_done`, `rework_fix_applied=true`), no regression on the happy path.

**Smoke**: re-run ENT-159 fixture — must not push to Human Review on sha `1e3ae4b` twice.

## Complementary change (consumer repo, not this PR)

PTCG supervisor skill (`~/.claude/skills/symphony-supervisor/SKILL.md`) should write findings to Linear comments (not PR review comments) so they land in the Linear comment stream Symphony will now fetch. Format is not contractually constrained — the orchestrator injects bodies verbatim and the agent reads whatever format the supervisor uses. This is a separate commit on the PTCG side and does not block Symphony rollout (if findings land on PR instead of Linear, the rework loop degrades to "agent has no fresh findings" — the same failure mode as today, no regression).

## Owner & review

Owner: TBD (Symphony team).
Requested reviewers: `dispatch_resolver` / `closeout` / `agent_runner` owners.
