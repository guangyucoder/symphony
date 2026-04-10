# Harness Engineering

> Adapted from [OpenAI's Harness Engineering](https://openai.com/index/harness-engineering/)

## Why This Exists

This repo is organized agent-first. The goal is not "make agents try harder" but "make the repo
easier for agents to understand, execute, verify, and improve."

**One sentence: environment over effort.**

## Core Principles

### 1. Repository as the Source of Truth

Agents can't see Slack, Google Docs, or prior conversation history. Therefore:

- Key constraints must live in repo docs, tests, or lint rules
- If a constraint only exists in someone's memory, it doesn't exist for agents
- If docs conflict with code, fix one of them — don't tolerate divergence

**For Symphony:** WORKFLOW.md is the execution contract. AGENTS.md is the navigation entry.
SPEC.md is the specification. Everything else lives in `docs/`.

### 2. Progressive Disclosure

Entry docs should be light; detailed knowledge should be structured.

- `AGENTS.md` is a directory, not an encyclopedia
- Detailed specs go in `docs/`
- Entry docs only keep high-signal info: quick start, key boundaries, forbidden patterns

**For Symphony:** AGENTS.md stays under ~200 lines. Module-level detail goes in code @moduledoc.
Design rationale goes in `docs/design/`.

### 3. Mechanical Enforcement of Invariants

Architecture constraints should be enforced by code, not by memory.

- `mix compile --warnings-as-errors` — no warnings policy
- `Verifier` runs validation commands — agent can't skip
- `DispatchResolver` enforces one-unit-per-session — agent can't self-escalate
- `Closeout` enforces `last_verified_sha == HEAD` — stale verification blocks handoff
- `DocImpact` detects doc staleness — agent must fix before next subtask

**The pattern:** When a review finding appears twice, promote it to an automated check.

### 4. Capability-Driven Problem Solving

When an agent gets stuck, don't just retry. Ask: what capability is missing?

- Agent keeps skipping validation → Don't add more prompt text. Make verification orchestrator-owned.
- Agent drifts during implement → Don't add guardrail paragraphs. Dispatch one subtask at a time.
- Agent loses context across sessions → Don't build summary chains. Keep repo docs fresh.
- Same review comment appears twice → Add a test or lint rule, not another prompt instruction.

### 5. Continuous Governance

High-throughput environments generate entropy. Cleanup should be continuous, not periodic.

- `DocImpact.check/2` runs after every code-changing unit
- `doc_fix_required` flag blocks next subtask until docs are updated
- Stale docs are treated as bugs, not tech debt

### 6. Make the Application Legible

Agents need programmable feedback loops, not "run it and see."

- `mix test` — stable, fast test suite
- `mix compile --warnings-as-errors` — compiler as first reviewer
- `scripts/verify_unit_lite.exs` — integration verification with real git
- `ledger.jsonl` — structured audit trail, not opaque logs
- `issue_exec.json` — machine-readable execution state

## Anti-Patterns

- Monolithic `AGENTS.md` that nobody reads
- Constraints that only exist as prompt instructions
- Known-wrong docs left in the repo
- Retrying the same failure without adding capability
- Agent context that lives only in session history, not in the repo

## How This Applies to Unit-Lite

| Problem | Wrong fix | Right fix (harness) |
|---------|-----------|---------------------|
| Agent skips validation | "Please run validate-app.sh" in prompt | `Verifier` runs it outside agent session |
| Agent drifts in implement | "Only do this subtask" in prompt | `DispatchResolver` dispatches one subtask |
| Context lost between sessions | Summary chain / anchor files | Keep `AGENTS.md` + `docs/` fresh via `DocImpact` |
| Same review finding recurs | Remind in next review | Add test / lint rule / guardrail |
| Agent doesn't know project structure | Longer prompt | Better `AGENTS.md` + `docs/ARCHITECTURE.md` |
