# Merge-conflict auto-resolve (Merging flow)

## Problem

Before this change, the `Merging` flow had two brittle edges:

1. `do_merge_with_ci_check` referenced `Verifier.check_pr_mergeability/1`
   but the function did not exist — compiling with `--warnings-as-errors`
   failed. Production builds shipped the warning.
2. When `check_pr_mergeability` returned `:conflicting`, `agent_runner`
   set `merge_conflict = true` and cleared `current_unit`, but no
   dispatch rule acted on the flag. The ticket stayed stuck in Merging
   until a human intervened.

## Flow

When the orchestrator enters the `Merging` flow:

```
merge → programmatic merge attempt
  │
  ├── CI pass + mergeable  → gh pr merge → Done
  ├── CI pass + conflicting → set merge_conflict=true, clear current_unit
  │     └── next tick: merge_sync_rule dispatches
  │           implement_subtask(merge-sync-1)
  │           → agent resolves conflicts in workspace, pushes
  │           → closeout sets merge_needs_verify=true,
  │             clears merge_conflict
  │           └── next tick: merge_verify_rule dispatches verify
  │                 → verify passes → reset merge_needs_verify
  │                 → next tick: merge_rule retries programmatic merge
  ├── CI pass + unknown    → count bumped, skip; escalate after N tries
  ├── CI fail              → verify-fix (bounded by
  │                          Config.max_verify_fix_cycles())
  └── Programmatic merge {:error, _}
        → escalate_to_human (resets all merge_* flags)
```

The `:conflicting` branch also resets `mergeability_unknown_count`:
a confirmed negative answer means GitHub finished computing
mergeability, so the unknown-retry window is closed.

## State contract

New persistent fields in `issue_exec.json`:

| Field | Type | Set by | Cleared by |
|-------|------|--------|------------|
| `merge_conflict` | boolean | agent_runner.handle_merge_conflict | closeout (merge-sync accept or merged), escalate_to_human |
| `merge_sync_count` | integer | agent_runner.handle_merge_conflict | closeout (merge), escalate_to_human |
| `mergeability_unknown_count` | integer | agent_runner.handle_mergeability_unknown | agent_runner (:mergeable / :conflicting), closeout (merge) |
| `merge_needs_verify` | boolean | closeout (merge-sync accept) | closeout (verify pass or merge), escalate_to_human |

All four are in the `@default_state` and `reset_for_rework/1` reset in
`issue_exec.ex`, so a Rework cycle starts clean.

## Dispatch-rule ordering (Merging)

```
replay → verify_fix → merge_sync → merge_verify → merge → merge_done
```

`verify_fix` precedes `merge_sync` so an in-flight `verify_error` (for
example, a test failure that happened before the merge attempt) is
fixed before trying another conflict-resolution pass. `merge_sync`
precedes `merge_verify` so a fresh conflict pre-empts stale
re-verification if both flags somehow coexist (tested).

## Merging-entry cleanup exception

When a ticket enters the `Merging` state, `agent_runner` clears stale
non-merge `current_unit` entries so a crashed handoff unit does not
replay and bounce the ticket back to Human Review. Two units are
explicitly exempt:

- `implement_subtask` with `subtask_id` starting `merge-sync-` — an
  in-flight conflict resolution should continue.
- `verify` when `merge_needs_verify = true` — verification of the
  merge-sync commit is still part of the Merging flow.

## Tunable retry caps

The three retry caps that govern this flow are now config-driven
(`agent.max_unit_attempts`, `verification.max_verify_attempts`,
`verification.max_verify_fix_cycles`). Defaults preserve existing
behaviour (3 / 3 / 2); override in `WORKFLOW.md` when tuning.

## Non-goals

- Symphony does not try to auto-rebase or push `main` on its own. The
  merge-sync agent owns that inside its workspace — the orchestrator
  only observes state transitions.
- No automatic retry when `gh pr merge` itself fails with a non-conflict
  error (e.g., branch protection). That path escalates to human.
