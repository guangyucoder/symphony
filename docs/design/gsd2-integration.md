# Design Doc: Phase-Level Orchestration for Symphony

**Status:** Draft v2 (rewrite based on review findings)
**Author:** Guangyu Wang
**Date:** 2026-04-07
**Target:** Symphony Elixir fork (ptcg-centering WORKFLOW.md as pilot)
**Supersedes:** v1 (workspace state protocol + context injection approach)

---

## 1. Problem Statement

Symphony dispatches one Linear issue as one long agent session. The agent self-manages all phases
(bootstrap → plan → implement → validate → handoff), self-reports progress, and self-validates.
The orchestrator's only visibility is: "is the agent still alive?" and "has the Linear state
changed?"

This creates a fundamental control gap: **the orchestrator delegates both execution AND decision-
making to the agent.** When the agent skips validation, goes in circles, or loses track of where it
is, Symphony has no mechanism to intervene because it doesn't know what phase the agent is in.

### What GSD-2 gets right

GSD-2 solves this by putting the state machine in the orchestrator, not the agent:

- The orchestrator decomposes work into atomic units (Milestone → Slice → Task)
- Each unit gets a fresh context window with pre-inlined context
- The orchestrator detects completion via artifact observation (not agent self-report)
- The orchestrator runs verification between units
- The agent is a stateless worker that executes one unit per dispatch

**Key insight: the orchestrator knows what phase the agent is in because the orchestrator decided
what phase to dispatch.** No self-reporting needed.

### What we can adopt without rewriting Symphony

We don't need GSD-2's full Milestone/Slice/Task hierarchy. Our WORKFLOW.md already defines 5 clear
phases with observable completion criteria. We need to move the phase state machine from inside the
agent's prompt to the orchestrator's dispatch logic.

---

## 2. Design: Phase-Level Dispatch

### 2.1 Core Idea

**Before (current):**

```
Orchestrator                          Agent
    │                                   │
    ├─── dispatch(issue) ──────────────>│
    │                                   ├── bootstrap
    │    (orchestrator blind)           ├── plan
    │                                   ├── implement
    │                                   ├── validate
    │                                   ├── handoff
    │<── turn complete ────────────────┤
    ├─── "still active?" ──────────────>│
    │<── yes ───────────────────────────┤
    ├─── dispatch continuation ────────>│
    │    ...repeats until Done...       │
```

**After (phase-level dispatch):**

```
Orchestrator                          Agent
    │                                   │
    ├─── detect_phase(workspace) ───>  (observe artifacts)
    │<── :plan                          │
    ├─── dispatch(issue, :plan) ───────>│
    │                                   ├── plan only
    │<── turn complete ────────────────┤
    ├─── detect_phase(workspace) ───>  (PLAN.md exists? ✓)
    │<── :implement                     │
    ├─── run_verification(workspace) ── (baseline check)
    │<── :pass                          │
    ├─── dispatch(issue, :implement) ──>│
    │                                   ├── implement only
    │<── turn complete ────────────────┤
    ├─── detect_phase(workspace) ───>  (new commits? ✓, tests pass? ✓)
    │<── :validate                      │
    ├─── run_verification(workspace) ── (full validation)
    │<── :pass                          │
    ├─── dispatch(issue, :validate) ───>│
    │                                   ├── review + visual only
    │    ...                            │
```

### 2.2 Phase Definitions

Phases are derived from the existing WORKFLOW.md execution flow, mapped to **observable workspace
artifacts** that the orchestrator can check without agent cooperation:

```elixir
defmodule SymphonyElixir.PhaseDetector do
  @moduledoc """
  Determines the current execution phase of an issue workspace by observing
  artifacts. Does not depend on agent self-reporting.
  """

  @type phase :: :bootstrap | :plan | :implement | :validate | :handoff | :done
  @type detection_result :: {:ok, phase()} | {:error, term()}

  @doc """
  Detect the current phase by checking workspace artifacts in order.
  Returns the NEXT phase that needs to be executed.
  """
  @spec detect(Path.t(), map()) :: detection_result()
  def detect(workspace, issue) do
    cond do
      !workspace_initialized?(workspace) ->
        {:ok, :bootstrap}

      !plan_exists?(workspace) ->
        {:ok, :plan}

      !implementation_started?(workspace, issue) ->
        {:ok, :implement}

      !verification_passing?(workspace) ->
        {:ok, :implement}  # still implementing — verification fails

      !review_complete?(workspace) ->
        {:ok, :validate}

      !pr_exists?(workspace) ->
        {:ok, :handoff}

      true ->
        {:ok, :done}
    end
  end

  # --- Observable artifact checks (no agent self-report) ---

  defp workspace_initialized?(workspace) do
    # Git repo initialized + dependencies installed
    File.dir?(Path.join(workspace, ".git")) and
      File.dir?(Path.join(workspace, "node_modules"))
  end

  defp plan_exists?(workspace) do
    # Agent wrote a plan file during :plan phase
    File.exists?(Path.join(workspace, ".symphony", "PLAN.md"))
  end

  defp implementation_started?(workspace, issue) do
    # There are commits on the issue branch beyond the initial clone
    case git_commit_count_on_branch(workspace, issue) do
      {:ok, count} -> count > 0
      _ -> false
    end
  end

  defp verification_passing?(workspace) do
    # Last verification result was :pass (written by orchestrator)
    case File.read(Path.join(workspace, ".symphony", "VERIFICATION.json")) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"result" => "pass"}} -> true
          _ -> false
        end
      _ -> false
    end
  end

  defp review_complete?(workspace) do
    # Review artifacts exist in .symphony/
    File.exists?(Path.join(workspace, ".symphony", "REVIEW.md"))
  end

  defp pr_exists?(workspace) do
    # A PR URL is recorded
    File.exists?(Path.join(workspace, ".symphony", "PR_URL"))
  end
end
```

**Why this works without agent compliance:**
- `workspace_initialized?` — checks `.git/` and `node_modules/`, created by `after_create` hook
- `plan_exists?` — checks for PLAN.md file (agent writes this as its natural output)
- `implementation_started?` — checks `git log` (agent commits are observable)
- `verification_passing?` — checks orchestrator-written file (agent can't fake this)
- `review_complete?` — checks for review artifact (written by `code-review` skill)
- `pr_exists?` — checks for PR URL file (written by `push` skill)

The only artifact that requires agent cooperation is PLAN.md. But even here, if the agent doesn't
write it, the orchestrator simply re-dispatches the `:plan` phase — it doesn't silently skip.

### 2.3 Phase-Specific Prompts

Each phase gets a focused prompt. The agent doesn't need to know about other phases.

```elixir
defmodule SymphonyElixir.PhasePrompt do
  @moduledoc """
  Generates phase-specific prompts. Each prompt is narrow and focused —
  the agent only sees instructions for its current phase.
  """

  @spec build(phase :: atom(), issue :: map(), context :: map()) :: String.t()

  def build(:bootstrap, issue, context) do
    """
    You are bootstrapping workspace for #{issue.identifier}: #{issue.title}

    #{issue_body(issue)}

    ## Instructions
    1. Move the Linear issue to `In Progress`.
    2. Create the Codex Workpad comment on the Linear issue.
    3. Run `./scripts/validate-app.sh` as baseline. Record result.
    4. Create `.symphony/` directory in workspace root.

    ## Scope
    - Do NOT plan or implement. Only bootstrap.
    - End the turn after baseline validation completes.

    #{common_guardrails()}
    """
  end

  def build(:plan, issue, context) do
    """
    You are planning implementation for #{issue.identifier}: #{issue.title}

    #{issue_body(issue)}

    #{if context.baseline_result, do: "## Baseline Verification\n#{context.baseline_result}\n"}

    ## Instructions
    1. Read the full issue description and any existing PR feedback.
    2. Search the codebase for existing related code.
    3. Write a hierarchical plan to `.symphony/PLAN.md` with:
       - Acceptance criteria as checkboxes
       - Sub-tasks with estimated scope
       - Testing strategy
    4. Review the plan via `codex exec` (not self-review).
    5. Sync with `origin/main`.

    ## Scope
    - Do NOT write implementation code. Only plan.
    - End the turn after the plan is written and reviewed.

    #{common_guardrails()}
    """
  end

  def build(:implement, issue, context) do
    plan = context.plan || "No plan found — implement based on issue description."
    verification = context.last_verification

    """
    You are implementing #{issue.identifier}: #{issue.title}

    ## Plan
    #{plan}

    #{if verification, do: "## Last Verification (FAILED — fix these)\n#{verification}\n"}

    ## Instructions
    1. Implement against the plan. Commit after each completed sub-task.
    2. Run `./scripts/validate-app.sh` before ending.
    3. Do NOT skip validation. Do NOT create a PR.

    ## Scope
    - Implement and get tests passing. Nothing else.
    - End the turn when you believe validation will pass.
    - Symphony will run verification automatically after this turn.

    #{common_guardrails()}
    """
  end

  def build(:validate, issue, context) do
    """
    You are validating #{issue.identifier}: #{issue.title}

    ## Instructions
    1. Run `code-review` skill. Fix all CRITICAL/HIGH/MEDIUM findings. Max 5 cycles.
    2. If UI changed: capture screenshots, run `visual-review`. Max 5 cycles.
    3. Run `doc-audit` if docs may be stale.
    4. Write review summary to `.symphony/REVIEW.md`.

    ## Scope
    - Review and fix only. Do NOT add new features.
    - Do NOT create a PR. Only validate.

    #{common_guardrails()}
    """
  end

  def build(:handoff, issue, context) do
    """
    You are handing off #{issue.identifier}: #{issue.title}

    ## Instructions
    1. Merge latest `origin/main`, resolve conflicts, rerun validation.
    2. Push via `push` skill. Write PR URL to `.symphony/PR_URL`.
    3. Move Linear issue to `Human Review`.
    4. Write final results to `## Results` comment on Linear.

    ## Scope
    - Push and handoff only. Do NOT make code changes beyond conflict resolution.

    #{common_guardrails()}
    """
  end
end
```

**Token efficiency:** Each phase prompt is ~500-1500 tokens instead of the current ~4000+ token
full-workflow prompt. Over 5 phases, total prompt tokens are similar, but each individual agent
session has a tighter, more focused instruction set with less room for misinterpretation.

### 2.4 AgentRunner: Phase-Aware Turn Loop

The turn loop changes from "run turns until issue is done" to "run turns until current phase is
complete":

```elixir
defmodule SymphonyElixir.AgentRunner do
  # Current: run(issue, recipient, opts)
  # New:     run(issue, phase, recipient, opts)

  @spec run(map(), atom(), pid() | nil, keyword()) :: {:ok, atom()} | {:error, term()}
  def run(issue, phase, codex_update_recipient \\ nil, opts \\ []) do
    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue),
               context <- build_phase_context(workspace, phase),
               prompt <- PhasePrompt.build(phase, issue, context),
               {:ok, result} <- run_phase_turns(workspace, issue, phase, prompt, opts) do
            {:ok, result}
          end
        after
          Workspace.run_after_run_hook(workspace, issue)
        end
    end
  end

  defp run_phase_turns(workspace, issue, phase, prompt, opts) do
    max_turns = max_turns_for_phase(phase)

    with {:ok, session} <- start_or_resume_session(workspace, issue) do
      try do
        do_phase_turns(
          %RunContext{
            session: session,
            workspace: workspace,
            issue: issue,
            phase: phase,
            prompt: prompt,
            turn_number: 1,
            max_turns: max_turns
          }
        )
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_phase_turns(%RunContext{turn_number: turn, max_turns: max} = ctx) when turn > max do
    {:ok, :max_turns_reached}
  end

  defp do_phase_turns(%RunContext{} = ctx) do
    prompt = if ctx.turn_number == 1, do: ctx.prompt, else: continuation_prompt(ctx)

    with {:ok, _turn_session} <- AppServer.run_turn(ctx.session, prompt, ctx.issue) do
      persist_session_meta(ctx.workspace, ctx.session, ctx.issue)

      # Check if phase is now complete (via artifact observation)
      case PhaseDetector.detect(ctx.workspace, ctx.issue) do
        {:ok, next_phase} when next_phase != ctx.phase ->
          # Phase advanced — return control to orchestrator
          {:ok, :phase_complete}

        {:ok, _same_phase} ->
          # Still in same phase — continue with another turn
          do_phase_turns(%{ctx | turn_number: ctx.turn_number + 1})

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp continuation_prompt(%RunContext{phase: phase, turn_number: turn, max_turns: max}) do
    """
    Continue working on the #{phase} phase. This is turn #{turn}/#{max}.
    Resume from workspace state. Do not restart.
    """
  end

  defp max_turns_for_phase(:bootstrap), do: 3
  defp max_turns_for_phase(:plan), do: 5
  defp max_turns_for_phase(:implement), do: 10
  defp max_turns_for_phase(:validate), do: 8
  defp max_turns_for_phase(:handoff), do: 3
end
```

### 2.5 Orchestrator: Phase Loop

The orchestrator gains a phase-level dispatch loop. This sits between the existing poll/dispatch
mechanism and the AgentRunner:

```elixir
# In do_dispatch_issue/3 — replace direct AgentRunner.run(issue, recipient, attempt: attempt)

defp do_dispatch_issue(%State{} = state, issue, attempt) do
  recipient = self()

  case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
    run_issue_phases(issue, recipient, attempt)
  end) do
    {:ok, pid} ->
      # ... existing monitor/running tracking code unchanged ...
  end
end

defp run_issue_phases(issue, recipient, attempt) do
  {:ok, workspace} = Workspace.create_for_issue(issue)

  run_phase_loop(workspace, issue, recipient, attempt)
end

defp run_phase_loop(workspace, issue, recipient, attempt) do
  case PhaseDetector.detect(workspace, issue) do
    {:ok, :done} ->
      Logger.info("All phases complete for #{issue.identifier}")
      :ok

    {:ok, phase} ->
      Logger.info("Detected phase=#{phase} for #{issue.identifier}")

      # Run pre-phase verification (if configured and phase > :bootstrap)
      :ok = maybe_run_pre_phase_verification(workspace, issue, phase)

      # Dispatch this phase
      case AgentRunner.run(issue, phase, recipient, attempt: attempt) do
        {:ok, :phase_complete} ->
          # Run post-phase verification
          case run_post_phase_verification(workspace, issue, phase) do
            :pass ->
              # Phase done, verification passed — loop to next phase
              run_phase_loop(workspace, issue, recipient, attempt)

            {:fail, result} ->
              # Verification failed — re-dispatch same phase with failure context
              Workspace.write_verification_result(workspace, result)
              run_phase_loop(workspace, issue, recipient, attempt)
          end

        {:ok, :max_turns_reached} ->
          # Agent couldn't complete phase within turn budget
          Logger.warning("Phase #{phase} hit max turns for #{issue.identifier}")
          {:error, {:phase_stalled, phase}}

        {:error, reason} ->
          {:error, reason}
      end

    {:error, reason} ->
      {:error, reason}
  end
end
```

### 2.6 Verification: Orchestrator-Owned, Between Phases

Verification runs in the orchestrator process between phases, not inside the agent session. The
agent literally cannot skip or influence it.

```elixir
defmodule SymphonyElixir.Verification do
  @moduledoc """
  Runs configured verification commands in the workspace.
  Orchestrator-owned — agent cannot bypass.
  """

  @spec run(Path.t(), map(), keyword()) :: :pass | {:fail, String.t()}
  def run(workspace, issue, opts \\ []) do
    commands = Config.verification_commands()
    timeout_ms = Config.verification_timeout_ms()

    if commands == [] do
      :pass
    else
      results = Enum.map(commands, &run_command(&1, workspace, timeout_ms))

      case Enum.find(results, &match?({:fail, _}, &1)) do
        nil -> :pass
        {:fail, output} -> {:fail, output}
      end
    end
  end

  defp run_command(command, workspace, timeout_ms) do
    task = Task.async(fn ->
      System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
    end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} ->
        :pass

      {:ok, {output, status}} ->
        {:fail, "Command `#{command}` failed (exit #{status}):\n#{truncate(output, 4096)}"}

      nil ->
        {:fail, "Command `#{command}` timed out after #{timeout_ms}ms"}
    end
  end
end
```

**Verification writes to `.symphony/VERIFICATION.json`:**

```json
{"result": "pass", "timestamp": "2026-04-07T14:23:00Z", "commands": ["./scripts/validate-app.sh"]}
```

or

```json
{"result": "fail", "timestamp": "2026-04-07T14:23:00Z", "output": "...error text..."}
```

This file is read by `PhaseDetector.verification_passing?/1` to determine if the `:implement`
phase is complete. The agent cannot fake a passing verification.

### 2.7 Interaction with Session Reuse

Current Symphony supports session reuse via `.symphony_session.json` (thread_id persistence). In
the phase-level model:

- **Within a phase**: Session reuse works as-is. Multi-turn within `:implement` reuses the same
  thread.
- **Between phases**: Fresh thread recommended (GSD-2's "fresh context window" insight). The
  orchestrator can optionally start a new thread between phases to prevent context pollution. This
  is configurable: `agent.fresh_thread_between_phases: true` (default: true).
- **On phase retry after verification failure**: Reuse the same thread — the agent needs its
  prior context to understand what to fix.

### 2.8 WORKFLOW.md Front Matter Extensions

```yaml
# New fields (additive, unknown keys already ignored per SPEC.md §5.3)
verification:
  commands:
    - ./scripts/validate-app.sh
  timeout_ms: 300000
  run_before_phases:            # Run verification BEFORE these phases start
    - implement                 # Baseline check before coding
  run_after_phases:             # Run verification AFTER these phases complete
    - implement                 # Must pass before moving to validate
    - handoff                   # Must pass before pushing PR
  on_failure: retry_phase       # retry_phase | escalate
  max_phase_retries: 2          # Max times to re-dispatch a phase after verification failure

agent:
  fresh_thread_between_phases: true
  max_turns_per_phase:
    bootstrap: 3
    plan: 5
    implement: 10
    validate: 8
    handoff: 3
```

### 2.9 Recovery: Phase-Level Granularity

Crash recovery is inherently better in this model because the orchestrator knows exactly which
phase was running:

1. Agent crashes during `:implement` phase
2. Orchestrator catches the exit (existing `handle_info({:DOWN, ...})`)
3. On retry, `PhaseDetector.detect/2` re-evaluates workspace artifacts
4. If plan exists + commits exist + verification failing → `:implement` again
5. The re-dispatched `:implement` prompt includes the last verification failure

No recovery briefing synthesis needed — the orchestrator simply re-detects the phase and dispatches
with the correct context. The agent gets a fresh thread with a focused prompt, not a polluted thread
with "please figure out where you were."

---

## 3. Scope Boundary

### New modules

| Module | Responsibility |
|---|---|
| `PhaseDetector` | Observe workspace artifacts → determine current phase |
| `PhasePrompt` | Generate focused, phase-specific prompts |
| `Verification` | Run configured commands, write results |

### Modified modules

| Module | Changes |
|---|---|
| `AgentRunner` | Accept `phase` param; phase-aware turn loop; `%RunContext{}` struct |
| `Orchestrator` | Phase loop in dispatch path; pass phase to AgentRunner |
| `Config` | Parse `verification` and `agent.max_turns_per_phase` from front matter |
| `Workspace` | Manage `.symphony/` directory; read/write verification results |
| `PromptBuilder` | Simplified — PhasePrompt handles phase-specific rendering; PromptBuilder may become thin wrapper or be replaced |

### Untouched

- Poll/reconcile/retry logic in Orchestrator (unchanged)
- Codex AppServer protocol (unchanged)
- Linear/Tracker integration (unchanged)
- StatusDashboard (unchanged, but gains phase visibility via running_entry)
- SPEC.md core compliance (phase dispatch is an implementation layer above the spec)

---

## 4. What This Design Does NOT Depend On

| Concern | How addressed |
|---|---|
| Agent writing STATE.md | **Not needed.** PhaseDetector reads git state + orchestrator-written verification files |
| Agent self-reporting progress | **Not needed.** Orchestrator observes artifacts |
| Agent following the 5-phase flow | **Not needed.** Orchestrator dispatches one phase at a time |
| Agent running validation | **Not needed.** Orchestrator runs it between phases |
| Agent writing correct PLAN.md | **Partially needed.** But if agent fails to write plan, PhaseDetector stays at `:plan` and re-dispatches. No silent degradation |

The only agent cooperation this design requires is that the agent **does productive work within its
phase** (writes code, creates commits, runs review skills). This is the irreducible minimum — if
the agent can't do productive work at all, no orchestration model helps.

---

## 5. Definition of Done

### 5.1 Feature Completeness

| Capability | Acceptance criteria |
|---|---|
| Phase detection | `PhaseDetector.detect/2` correctly identifies phase from workspace artifacts |
| Phase-specific dispatch | AgentRunner accepts phase, generates focused prompt, limits turns per phase |
| Orchestrator phase loop | Issue dispatch loops through phases with verification between them |
| Orchestrator-level verification | Configured commands run between phases; results written to `.symphony/VERIFICATION.json`; agent cannot bypass |
| Verification-driven re-dispatch | Failed verification re-dispatches same phase with failure context |
| Phase-level recovery | Crash/retry re-detects phase from artifacts and dispatches correctly |
| Fresh thread between phases | Optional new Codex thread per phase (configurable) |
| Backward compatibility | WORKFLOW.md without `verification` config works identically to current behavior |
| Graceful fallback | If PhaseDetector cannot determine phase, fall back to current full-issue dispatch |

### 5.2 Success Metrics

Measured on ptcg-centering over 10-15 issues, before/after comparison:

| Metric | How to measure | Why it matters |
|---|---|---|
| **Issue completion rate** | % reaching `Done` or `Human Review` | Primary outcome |
| **Human intervention rate** | % reaching `Human Input Needed` | Sensitivity: detects partial improvement |
| **Validation skip rate** | Must be 0% (infrastructure guarantee) | Sanity check |
| **Turns per issue** | Total turns across all phases | Efficiency |
| **Verification-triggered fixes** | Count of re-dispatches after verification failure | Measures enforcement value |
| **Phase stuck rate** | % of phases hitting max_turns without completing | Identifies where agents struggle |
| **Tokens per issue** | From codex_totals | Cost |

### 5.3 Qualitative Criteria

- Operator can see in dashboard: issue X is in phase `:implement`, turn 3/10, last verification
  failed
- An issue that currently stalls because agent "forgot" to run validation now fails loudly at the
  verification gate and gets re-dispatched with the error
- Crash recovery requires 0-1 re-orientation turns (vs. current 2-3)

---

## 6. Test Plan

### 6.1 Unit Tests

**PhaseDetector:**

| Test | Description |
|---|---|
| `"detects :bootstrap for empty workspace"` | No .git → :bootstrap |
| `"detects :plan after bootstrap"` | .git + node_modules, no PLAN.md → :plan |
| `"detects :implement after plan"` | PLAN.md exists, no branch commits → :implement |
| `"stays at :implement if verification failing"` | Commits exist but VERIFICATION.json says fail → :implement |
| `"detects :validate after passing verification"` | Commits + passing verification, no REVIEW.md → :validate |
| `"detects :handoff after review"` | REVIEW.md exists, no PR_URL → :handoff |
| `"detects :done when PR exists"` | PR_URL exists → :done |
| `"handles corrupt VERIFICATION.json gracefully"` | Invalid JSON → treats as not passing |

**PhasePrompt:**

| Test | Description |
|---|---|
| `"bootstrap prompt excludes implementation instructions"` | No "implement" or "code" in prompt |
| `"implement prompt includes plan content"` | Plan text appears in prompt |
| `"implement prompt includes verification failure"` | Failed verification context in prompt |
| `"each phase prompt is < 2000 tokens"` | Size check |

**Verification:**

| Test | Description |
|---|---|
| `"passes when command exits 0"` | :pass result |
| `"fails with output when command exits non-zero"` | {:fail, output} with truncated error |
| `"times out and reports failure"` | Slow command → timeout message |
| `"runs multiple commands, fails on first failure"` | Two commands, second fails → fail result |
| `"no-op when commands list is empty"` | :pass without spawning subprocess |
| `"uses Task.async/yield/shutdown timeout pattern"` | Verify no blocking |

**AgentRunner:**

| Test | Description |
|---|---|
| `"returns :phase_complete when phase advances"` | Mock PhaseDetector to return next phase → :phase_complete |
| `"continues turns within same phase"` | PhaseDetector returns same phase → turn_number increments |
| `"returns :max_turns_reached when budget exhausted"` | Hit max turns → :max_turns_reached |
| `"uses RunContext struct"` | No 9+ positional args |

### 6.2 Integration Tests

| Test | Description |
|---|---|
| `"full phase loop: plan → implement → validate → handoff"` | Mock Codex that creates expected artifacts per phase; verify phase progression |
| `"verification failure triggers re-dispatch"` | Agent produces failing code; verification catches it; same phase re-dispatched with failure context |
| `"crash during implement recovers to correct phase"` | Kill task during :implement; retry detects :implement from artifacts |
| `"backward compat: no verification config"` | Minimal WORKFLOW.md; verify standard dispatch works |
| `"max_phase_retries escalation"` | Verification fails 3 times → error returned |

### 6.3 Before/After Pilot

1. **Baseline (1 week):** Run 10-15 issues on current system. Record all metrics.
2. **Treatment (1-2 weeks):** Run 10-15 issues on new system.
3. **Analysis:** Per-issue comparison + qualitative review of phase progression logs.
4. **Decision gate:** If completion rate improves OR human intervention rate drops → full rollout.

---

## 7. Implementation Plan

### Phase 1: PhaseDetector + Verification (3-4 days)

These two modules are independent and testable in isolation.

1. Create `PhaseDetector` module with artifact-based detection.
2. Create `Verification` module with `Task.async/yield/shutdown` execution.
3. Add `verification` config parsing to `Config` (NimbleOptions schema).
4. Add `.symphony/` directory management to `Workspace`.
5. Full unit test coverage for both modules.

### Phase 2: PhasePrompt + AgentRunner Refactor (2-3 days)

1. Create `PhasePrompt` module with per-phase prompt generation.
2. Refactor `AgentRunner` to accept `phase` param.
3. Introduce `%RunContext{}` struct (replace 9+ positional args).
4. Phase-aware turn loop: check `PhaseDetector` between turns.
5. Unit tests for AgentRunner phase behavior.

### Phase 3: Orchestrator Phase Loop (2 days)

1. Add `run_issue_phases/4` to orchestrator dispatch path.
2. Wire phase detection → phase dispatch → verification → loop.
3. Add `fresh_thread_between_phases` support.
4. Integration tests for full phase loop.
5. Backward compatibility test.

### Phase 4: WORKFLOW.md Migration + Pilot (1 week)

1. Update ptcg-centering WORKFLOW.md front matter with verification config.
2. Simplify WORKFLOW.md prompt body (phase-specific prompts handle detail).
3. Run baseline collection (if not already done).
4. Deploy and run treatment group.
5. Analyze and decide.

**Total: 7-9 days engineering + 1-2 weeks pilot.**

---

## 8. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| PhaseDetector misidentifies phase | Wrong prompt dispatched | Conservative detection (require positive signals, not absence); fallback to full-issue dispatch on ambiguity |
| PLAN.md not written by agent | Stuck at :plan forever | max_turns_per_phase (5) → escalate; or treat "agent did work but no PLAN.md" as plan-complete if commits exist |
| Verification runs during stall timeout window | Orchestrator kills task | Send synthetic heartbeat during verification; enforce `verification.timeout_ms < codex.stall_timeout_ms` |
| Phase boundaries don't match real workflow | Wasted re-dispatches | PhaseDetector logic is configurable; start with conservative 5-phase model, tune based on pilot data |
| Fresh thread per phase loses useful context | Agent repeats work | Inject plan + last verification into each phase prompt; fresh thread prevents context pollution |
| Multi-surface validation timing | validate-app.sh doesn't cover web/admin | Add per-surface commands to verification.commands list |
| Some issues don't fit the 5-phase model | "fix typo" shouldn't go through 5 phases | PhaseDetector can detect "trivial" (no plan needed, just implement+handoff); or label-based phase skip |

---

## 9. Comparison with v1 Design

| Aspect | v1 (workspace state protocol) | v2 (phase-level dispatch) |
|---|---|---|
| Agent compliance dependency | HIGH — agent must write STATE.md | LOW — only needs to produce natural artifacts (commits, files) |
| State machine location | Agent (via prompt instructions) | **Orchestrator** (PhaseDetector) |
| Verification | After each turn (too aggressive) | **Between phases** (right granularity) |
| Context quality | Accumulated thread history | **Fresh context per phase** |
| Recovery model | Synthesized recovery briefing | **Automatic phase re-detection** (simpler, more reliable) |
| Prompt complexity | Full workflow + injected state (~6K tokens) | **Focused phase prompt (~1K tokens)** |
| Failure mode on crash | Agent must re-orient from briefing | **Orchestrator re-detects phase, re-dispatches** |
| Engineering complexity | Lower (additive patches) | Higher (new modules + refactor) |

**v2 is more work, but eliminates the fundamental architectural gap that v1 papers over.**

---

## 10. Open Questions

1. **Phase skip for trivial issues:** Should a "fix typo" issue skip `:plan` and `:validate`? If
   so, how does the orchestrator know it's trivial? (Proposal: label-based override, e.g. Linear
   label `trivial` → skip plan + validate phases.)

2. **max_turns_per_phase defaults:** The proposed defaults (bootstrap:3, plan:5, implement:10,
   validate:8, handoff:3) are guesses. Need pilot data to tune.

3. **Thread strategy between phases:** Fresh thread is the GSD-2 way, but session reuse preserves
   context. Default to fresh with `compact_between_turns` as middle ground? Need to test both.

4. **PhaseDetector extensibility:** Current detection is hardcoded for the ptcg-centering workflow.
   Should phase definitions be configurable in WORKFLOW.md? (Proposal: defer to v3. Hardcoded
   phases are fine for pilot. If we need a second workflow, generalize then.)

---

## Appendix B: v2 Review Findings (2026-04-07)

Three independent reviews conducted on v2: Architecture, Elixir Implementation, Product/Testing.

### B.1 — Structural Issue: Phase Loop Process Model (CRITICAL, all reviewers)

**Problem**: Design puts the entire multi-phase loop inside a single Task process. Orchestrator
only sees "process alive" — can't observe phase progress, token counts, or session transitions.
Stall detection and Linear state reconciliation don't work during phase transitions.

**Resolution**: Each phase is an independent `Task.Supervisor.start_child`. Phase transitions are
driven by orchestrator's `handle_info({:DOWN, ...})` handler. Orchestrator state gains
`:current_phase` field. This fully reuses existing monitor/retry/reconcile infrastructure.

```
Phase :plan Task exits :normal
  → {:DOWN} handler fires
  → PhaseDetector.detect(workspace, issue)
  → dispatch next phase as new Task
  → new running_entry with fresh turn_count/tokens/session_id
```

### B.2 — PhaseDetector Bugs (CRITICAL, Arch + Product)

Three known detection failures:

1. **Plan commit fooled as implementation**: Agent commits PLAN.md during `:plan` →
   `implementation_started?` returns true → skips implement.
   **Fix**: Replace git heuristic with orchestrator-written `PHASE_LOG.json` — "orchestrator
   dispatched :implement at least once" is deterministic.

2. **Stale VERIFICATION.json on workspace reuse**: Previous issue left `result: "pass"` →
   PhaseDetector skips implement for new issue.
   **Fix**: Clear `.symphony/` on new issue dispatch (or namespace by issue identifier).

3. **Rework state**: All artifacts exist from previous handoff → PhaseDetector returns `:done`.
   **Fix**: PhaseDetector MUST read `issue.state`. If `Rework` → reset to `:plan` regardless
   of artifacts. If `Merging` → return `:merging` (fast path, skip normal phases).

### B.3 — Missing Functionality in do_phase_turns (HIGH, Elixir)

v2's `do_phase_turns` dropped these from current `do_run_codex_turns`:
- `continue_with_issue?` — Linear state check between turns
- `maybe_compact_thread` — thread compaction
- `on_message` handler — token/event streaming to orchestrator
- `dispatch_id` generation

All must be preserved. With B.1's "each phase = independent Task" model, most of these come
back naturally since each phase Task looks like the current AgentRunner.run call.

### B.4 — Verification Issues (HIGH, Product + Elixir)

- `validate-app.sh` only covers mobile-app. Web/admin surfaces not verified by orchestrator.
  **Fix**: Support per-surface verification via `{glob_pattern, command}` config; orchestrator
  checks `git diff --name-only` to determine which commands to run.
- `Enum.map` runs commands serially. 3 × 5min = 15min worst case.
  **Fix**: Use `Task.async_stream` for parallel execution.
- E2E test mutual exclusion (WORKFLOW.md line 157) not respected.
  **Fix**: Orchestrator-level semaphore for E2E commands.

### B.5 — max_phase_retries Not Implemented (HIGH, Arch)

`run_phase_loop` has unbounded recursion on verification failure. `max_phase_retries: 2` is
declared in WORKFLOW.md front matter but no counter exists in the loop.
**Fix**: Add `phase_attempts` map to phase loop, increment per phase, bail at max.

### B.6 — Remaining Probabilistic Dependencies (MEDIUM, Product)

v2 replaces one big dependency (STATE.md self-report) with three smaller ones:
- PLAN.md — agent must write to `.symphony/PLAN.md`
- REVIEW.md — agent must produce review artifact
- PR_URL — agent must record PR URL

These are more reliable than self-reporting (path is hardcodeable, file existence is binary) but
not zero-trust. Failure mode is "stuck at phase" rather than "silently skip" — acceptable.

For PLAN.md: add minimum content validation (> 100 bytes, contains `- [ ]` checkbox).

### B.7 — NimbleOptions Schema (MEDIUM, Elixir)

Full schema extension needed for `verification` and `agent.max_turns_per_phase` before
implementation begins. `TestSupport.write_workflow_file!/2` must also be updated.

### B.8 — .symphony/ Lifecycle (MEDIUM, Product)

Not defined: when to create, when to clear, what happens on Rework.
**Fix**: Clear `.symphony/` when dispatching a new issue to a reused workspace. On Rework,
clear everything except PLAN.md (agent re-plans, but may reference old plan).