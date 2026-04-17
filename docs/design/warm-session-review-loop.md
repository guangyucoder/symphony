# Warm-Session Review Loop

Replace the cold-session-per-unit model (bootstrap → plan → implement × N → doc_fix → verify → verify-fix → code_review → handoff) with a two-session PR-review loop that mirrors how humans work on pull requests.

## Invariants

1. **One Implement session A**, resumed across all implement dispatches for the issue. Agent remembers its own code/tests/decisions.
2. **One Review session B**, resumed across all review dispatches. Reviewer remembers prior findings; next round is delta review.
3. **Loop terminates** when B writes `Verdict: clean` in the workpad's latest `### Code Review` section, OR `review_round > max_review_rounds` (strict-greater: cap = N fix cycles) (then escalate to Human Input Needed).
4. **Cold-dispatch prompts carry full context**. **Resumed-dispatch prompts carry only delta** — new findings (for A) or new diff since `last_reviewed_sha` (for B).
5. **No workpad byte-cap truncation may drop the latest `### Code Review` or `### Plan` sections.** Drop oldest `#### [plan-N] continuation` first, with an explicit elision marker.

## State (new in `issue_exec.json`)

- `implement_thread_id` — set on first implement, used by subsequent `resume_session`
- `review_thread_id` — set on first review, used by subsequent `resume_session`
- `review_verdict` — `nil | "pending" | "findings" | "clean"`
- `review_round` — integer, bumped on each review dispatch
- `last_reviewed_sha` — HEAD at most recent review dispatch

## Flow

```
bootstrap → plan → implement_subtask (× N)
                        │
                   (all subtasks done + HEAD advanced past last_reviewed_sha)
                        ↓
                   code_review (resume B if exists, else start)
                   reviewer writes ### Code Review with Verdict
                        ↓
   clean ─────────► doc_fix → handoff
   findings ──────► implement (resume A, inject latest ### Code Review delta)
                    │ agent fixes, commits
                    └──► code_review (resume B, inject diff since last_reviewed_sha)
   (round >= max) ► Human Input Needed
```

## Deletions / Scope notes (post-implementation reality)

- **`verify` unit removed from the normal flow.** Tests run inside the warm
  implement session (`./scripts/verify-changed.sh` per subtask). The `verify`
  kind is KEPT alive for the `:merging` flow only — `merge_verify_rule` still
  dispatches `Unit.verify()` after a merge-sync commit, and `verify_fix_rule`
  recovers a failed merge verify with a one-shot `verify-fix-*` subtask.
- **`verify-fix-*` subtasks removed from the normal flow** (the implement
  session handles its own test failures). Kept in the `:merging` flow as the
  merge-verify repair path.
- **`rework-1` is still alive** as the warm-session entry point after a human
  triggers rework: `rework_fix_rule` dispatches `implement_subtask("rework-1")`
  which resumes the warm implement thread with rework comments injected. The
  original design planned to collapse this into `review_verdict=findings`, but
  the separate subtask kind carries the ticket_comments payload that a pure
  flag-based state can't.
- Today's `code_review` gate that I added earlier gets REPLACED by this
  architecture (not additive).

## Machine gates (survive agent skipping)

- Pre-push hook at handoff time — final typecheck + test:unit + test:e2e
- Closeout for implement: HEAD must advance + `verify-changed.sh` exit 0 (closeout runs it)
- Closeout for code_review: workpad must have a new `### Code Review` section with a parseable `Verdict:` line

## Test categories

1. **DispatchResolver rules** (pure state machine)
2. **IssueExec field persistence**
3. **Workpad section-aware truncation** (never drops Plan / latest Code Review)
4. **PromptBuilder delta injection** (resumed turn prompt is small; cold-start is full)
5. **AgentRunner session resume** (fallback to start on resume failure)
6. **Closeout verdict parsing** (workpad Verdict line → exec.review_verdict)
7. **End-to-end integration** (full loop, 2-3 review rounds, clean exit)

## Out of scope (for this change)

- Cross-family review (B = Claude when A = Codex) — possible later; first iteration keeps both on Codex
- Review session's own test-running ability — B only reviews code, doesn't run tests
- Preserving sessions across Symphony process restarts beyond what Codex's thread-resume naturally supports
