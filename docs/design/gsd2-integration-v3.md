# Design Doc: Phase-Level Orchestration for Symphony (v3)

**Status:** Draft v3 (rewrite based on GSD-2 source code analysis + ChatGPT adversarial review)
**Author:** Guangyu Wang
**Date:** 2026-04-07
**Target:** Symphony Elixir fork (ptcg-centering WORKFLOW.md as pilot)
**Supersedes:** v1 (workspace state protocol), v2 (artifact-based PhaseDetector)

---

## 1. Problem Statement

Symphony dispatches one Linear issue as one long agent session. The agent self-manages all phases
(bootstrap → plan → implement → validate → handoff), self-reports progress, and self-validates.
The orchestrator's only visibility is "is the agent still alive?" and "has the Linear state changed?"

### What GSD-2 actually does (from source code, not README)

GSD-2's dispatch loop (`auto-loop.ts`) runs this cycle on every iteration:

```
invalidateAllCaches()
→ deriveState(basePath)        # re-derive from SQLite + disk, zero in-memory state
→ resolveDispatch(ctx)          # ~20 ordered rules, first match wins → dispatch/stop/skip
→ runUnit(prompt)               # execute one context-window-sized unit
→ postUnitVerification()        # multi-layer verification + evidence JSON
→ back to top
```

Key mechanisms we must adapt:

1. **State = derived, not stored.** `deriveState()` reads SQLite DB + filesystem every iteration.
   No in-memory state survives between iterations. Crash recovery is free — restart and re-derive.

2. **Dispatch = rule table, not heuristics.** `resolveDispatch()` is an ordered list of ~20 rules.
   Each rule's `match()` returns `dispatch | stop | skip | null`. First non-null wins.

3. **Unit = context-window-sized.** A task must fit in one context window. The orchestrator
   dispatches one task at a time, not a whole phase.

4. **Phase Anchor = structured handoff.** Each phase writes `{intent, decisions, blockers,
   nextSteps}` to an anchor file. Next phase's prompt pre-inlines it. Fresh thread without
   fresh context is amnesia; anchor prevents it.

5. **Verification = evidence, not exit codes.** `verification-gate.ts` does multi-source command
   discovery, runtime error capture, dependency audit, and artifact content validation. Results
   persist as `T##-VERIFY.json` with schema-versioned evidence.

6. **Stuck detection = sliding window.** Four rules: same error ×2, same unit ×3, A→B→A→B
   oscillation, same ENOENT ×2. Git working tree activity as supplementary "alive" signal.

### What we adopt vs. what we don't

| GSD-2 mechanism | Adopt? | Why |
|---|---|---|
| Derived state from ledger + evidence | **Yes** | Eliminates agent self-report dependency |
| Rule-based dispatch resolver | **Yes** | Replaces fragile cond chain |
| Context-window-sized units | **Partially** | Subtask dispatch within implement; other phases stay atomic |
| Phase anchor (structured handoff) | **Yes** | Solves fresh-thread amnesia |
| Multi-layer verification with evidence | **Yes** | Covers real workflow requirements |
| Stuck detection (sliding window) | **Yes** | Critical for unattended operation |
| SQLite as primary state store | **No** | Symphony is stateless by design; use append-only ledger |
| Milestone/Slice/Task hierarchy | **No** | Symphony receives work as Linear issues, not project roadmaps |
| Complexity-based model routing | **Defer** | Valuable but orthogonal; v2 scope |
| Plugin rule registry | **Defer** | Over-engineering for single-workflow pilot |

---

## 2. Design

### 2.1 Execution Ledger — The Source of Truth

The core lesson from GSD-2: **the orchestrator must own an explicit execution record.** GSD uses
SQLite + disk files. We use an append-only JSONL ledger — simpler, crash-safe (append-only writes
are atomic on POSIX), and readable by both orchestrator and agent.

**File:** `.symphony/ledger.jsonl` — orchestrator-owned, agent MUST NOT write.

```jsonl
{"ts":"2026-04-07T14:00:00Z","event":"flow_routed","flow":"normal","issue_state":"Todo"}
{"ts":"2026-04-07T14:00:01Z","event":"phase_dispatched","phase":"bootstrap","attempt":1}
{"ts":"2026-04-07T14:01:30Z","event":"phase_completed","phase":"bootstrap","duration_ms":89000}
{"ts":"2026-04-07T14:01:31Z","event":"anchor_written","phase":"bootstrap","path":".symphony/anchors/bootstrap.json"}
{"ts":"2026-04-07T14:01:32Z","event":"phase_dispatched","phase":"plan","attempt":1}
{"ts":"2026-04-07T14:03:00Z","event":"phase_completed","phase":"plan","artifact":"PLAN.md"}
{"ts":"2026-04-07T14:03:01Z","event":"subtasks_parsed","phase":"implement","count":5,"ids":["st-1","st-2","st-3","st-4","st-5"]}
{"ts":"2026-04-07T14:03:02Z","event":"subtask_dispatched","phase":"implement","subtask_id":"st-1","attempt":1}
{"ts":"2026-04-07T14:05:00Z","event":"subtask_completed","phase":"implement","subtask_id":"st-1"}
{"ts":"2026-04-07T14:05:01Z","event":"verification_run","phase":"implement","subtask_id":"st-1","result":"pass","evidence_path":".symphony/evidence/implement-st-1-a1.json"}
{"ts":"2026-04-07T14:05:02Z","event":"subtask_dispatched","phase":"implement","subtask_id":"st-2","attempt":1}
```

**`deriveState(ledger, issue, workspace)` — the Symphony equivalent of GSD's `deriveState()`:**

```elixir
defmodule SymphonyElixir.StateResolver do
  @type state :: %{
    flow: :normal | :merging | :rework,
    phase: phase(),
    phase_attempt: non_neg_integer(),
    subtask: subtask_ref() | nil,
    completed_phases: [phase()],
    completed_subtasks: [String.t()],
    last_verification: verification_result() | nil,
    stuck_window: [dispatch_entry()],
    anchors: %{phase() => anchor()}
  }

  @spec derive(Path.t(), map(), Path.t()) :: {:ok, state()} | {:error, term()}
  def derive(ledger_path, issue, workspace) do
    with {:ok, entries} <- read_ledger(ledger_path) do
      state = %{
        flow: route_flow(issue),
        phase: derive_current_phase(entries, workspace),
        phase_attempt: count_phase_attempts(entries),
        subtask: derive_current_subtask(entries),
        completed_phases: extract_completed_phases(entries),
        completed_subtasks: extract_completed_subtasks(entries),
        last_verification: last_verification_result(entries),
        stuck_window: last_n_dispatches(entries, 6),
        anchors: load_anchors(workspace)
      }
      {:ok, state}
    end
  end

  defp route_flow(%{state: "Merging"}), do: :merging
  defp route_flow(%{state: "Rework"}), do: :rework
  defp route_flow(_issue), do: :normal
end
```

**Why ledger, not PhaseDetector:**

| | v2 PhaseDetector | v3 Ledger |
|---|---|---|
| State source | Inferred from file existence | **Explicit orchestrator records** |
| Agent can fake | Yes (create empty PLAN.md) | **No** (orchestrator-only writes) |
| Rework handling | Bug: artifacts exist → :done | **Explicit**: ledger reset on rework |
| Stale state | Bug: old VERIFICATION.json | **Explicit**: entries are timestamped and scoped |
| Crash recovery | Re-guess from artifacts | **Re-derive from ledger** (append-only survives crash) |

### 2.2 Dispatch Resolver — Rule Table

GSD-2's `resolveDispatch()` uses ~20 ordered rules. We adapt this to Symphony's three flows:

```elixir
defmodule SymphonyElixir.DispatchResolver do
  @type action :: {:dispatch, phase(), prompt()} | {:stop, reason()} | :skip

  @spec resolve(StateResolver.state(), map(), Path.t()) :: action()
  def resolve(state, issue, workspace) do
    rules(state.flow)
    |> Enum.find_value(fn rule -> rule.(state, issue, workspace) end)
    || {:stop, :no_matching_rule}
  end

  defp rules(:merging), do: [
    &merging_land/3,          # Run land skill immediately
    &merging_done/3           # Already merged → stop
  ]

  defp rules(:rework), do: [
    &rework_reset_ledger/3,   # First dispatch after rework: reset ledger to plan
    &rework_plan/3,           # Re-plan with existing PR context
    # ...then fall through to normal implement/validate/handoff rules
    &normal_implement_next_subtask/3,
    &normal_verification_retry/3,
    &normal_validate/3,
    &normal_handoff/3,
    &normal_done/3
  ]

  defp rules(:normal), do: [
    &normal_bootstrap/3,
    &normal_plan/3,
    &normal_implement_next_subtask/3,
    &normal_verification_retry/3,
    &normal_validate/3,
    &normal_handoff/3,
    &normal_done/3
  ]

  # --- Rule implementations ---

  defp normal_bootstrap(state, _issue, workspace) do
    if :bootstrap not in state.completed_phases do
      {:dispatch, :bootstrap, PhasePrompt.build(:bootstrap, state)}
    end
  end

  defp normal_plan(state, _issue, _workspace) do
    if :plan not in state.completed_phases do
      {:dispatch, :plan, PhasePrompt.build(:plan, state)}
    end
  end

  defp normal_implement_next_subtask(state, _issue, _workspace) do
    case state.subtask do
      %{id: id, status: :pending} ->
        {:dispatch, {:implement, id}, PhasePrompt.build(:implement_subtask, state)}
      _ ->
        nil  # no pending subtask → skip this rule
    end
  end

  defp normal_verification_retry(state, _issue, _workspace) do
    case state.last_verification do
      %{result: :fail, phase: phase, attempt: n} when n < max_retries() ->
        {:dispatch, {:verify_fix, phase}, PhasePrompt.build(:fix_verification, state)}
      %{result: :fail, attempt: n} when n >= max_retries() ->
        {:stop, {:verification_exhausted, state.last_verification}}
      _ ->
        nil
    end
  end

  defp normal_validate(state, _issue, _workspace) do
    if :validate not in state.completed_phases and
       all_subtasks_complete?(state) and
       verification_passing?(state) do
      {:dispatch, :validate, PhasePrompt.build(:validate, state)}
    end
  end

  defp normal_handoff(state, _issue, _workspace) do
    if :handoff not in state.completed_phases and
       :validate in state.completed_phases do
      {:dispatch, :handoff, PhasePrompt.build(:handoff, state)}
    end
  end

  defp normal_done(state, _issue, _workspace) do
    if :handoff in state.completed_phases do
      {:stop, :all_phases_complete}
    end
  end
end
```

### 2.3 Subtask-Level Dispatch in Implement Phase

GSD-2's core constraint: "a task must fit in one context window." We apply this to the implement
phase. The plan phase produces a structured checklist; the orchestrator parses it and dispatches
one subtask at a time.

**Plan output format (enforced via prompt):**

```markdown
## Plan
- [ ] **st-1**: Add BorderDetector component to src/screens/editor/
- [ ] **st-2**: Integrate BorderDetector into EditorScreen
- [ ] **st-3**: Add unit tests for BorderDetector
- [ ] **st-4**: Update AGENTS.md with new component docs
- [ ] **st-5**: Run validate-app.sh and fix any failures
```

**Orchestrator parses subtasks after plan phase completes:**

```elixir
defmodule SymphonyElixir.SubtaskParser do
  @subtask_pattern ~r/^- \[[ x]\] \*\*(st-\d+)\*\*:\s*(.+)$/m

  def parse(plan_path) do
    case File.read(plan_path) do
      {:ok, content} ->
        subtasks =
          Regex.scan(@subtask_pattern, content)
          |> Enum.map(fn [_, id, title] -> %{id: id, title: String.trim(title)} end)

        if subtasks == [] do
          {:error, :no_subtasks_found}
        else
          {:ok, subtasks}
        end

      {:error, reason} ->
        {:error, {:plan_read_failed, reason}}
    end
  end
end
```

**If parsing fails** (agent wrote freeform plan without checklist): fall back to dispatching
`:implement` as a single phase with `max_turns`. Log a warning. This is the graceful degradation
path — subtask dispatch is better, but whole-phase dispatch is acceptable.

**Verification runs after each subtask**, not after the entire implement phase. This catches
errors early and gives the agent focused fix context.

### 2.4 Phase Anchor — Structured Handoff

Adapted from GSD-2's `phase-anchor.ts`. The orchestrator writes an anchor after each phase
completes. The next phase's prompt pre-inlines it.

```elixir
defmodule SymphonyElixir.PhaseAnchor do
  @type t :: %{
    phase: atom(),
    completed_at: DateTime.t(),
    intent: String.t(),
    decisions: [String.t()],
    blockers: [String.t()],
    next_steps: [String.t()],
    artifacts: [String.t()]
  }

  def write(workspace, anchor) do
    path = anchor_path(workspace, anchor.phase)
    Workspace.atomic_write(path, Jason.encode!(anchor))
  end

  def read_for_prompt(workspace, prior_phase) do
    case File.read(anchor_path(workspace, prior_phase)) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, anchor} -> format_for_prompt(anchor)
          _ -> nil
        end
      _ -> nil
    end
  end

  defp format_for_prompt(anchor) do
    """
    ## Handoff from #{anchor["phase"]}
    **Intent:** #{anchor["intent"]}
    **Decisions:** #{Enum.join(anchor["decisions"] || [], "; ")}
    **Blockers:** #{Enum.join(anchor["blockers"] || [], "; ")}
    **Next steps:** #{Enum.join(anchor["next_steps"] || [], "; ")}
    """
  end
end
```

**Who writes the anchor content?** The agent produces the raw content as part of its phase output.
The orchestrator extracts it from a structured section in the agent's final message, validates it,
and writes the anchor file. If the agent doesn't produce one, the orchestrator writes a minimal
anchor from observable data (git log summary, file list).

**Anchor chain:**
- bootstrap → plan: baseline result, environment stamp, existing PR status
- plan → implement: plan summary, architectural decisions, risk notes
- implement → validate: what was built, which files changed, test status
- validate → handoff: review findings, visual review status, remaining issues

### 2.5 Verification Gate — Multi-Layer Evidence

Adapted from GSD-2's `verification-gate.ts` + `verification-evidence.ts`.

```elixir
defmodule SymphonyElixir.VerificationGate do
  @type evidence :: %{
    schema_version: 1,
    phase: atom(),
    subtask_id: String.t() | nil,
    attempt: pos_integer(),
    git_sha: String.t(),
    timestamp: DateTime.t(),
    commands: [command_result()],
    artifact_checks: [artifact_check()],
    touched_surfaces: [String.t()],
    result: :pass | :fail | :advisory
  }

  @spec run(Path.t(), map(), atom(), keyword()) :: {:pass, evidence()} | {:fail, evidence()}
  def run(workspace, issue, phase, opts \\ []) do
    touched = detect_touched_surfaces(workspace)
    commands = select_commands(touched, phase)

    command_results = run_commands_parallel(commands, workspace)
    artifact_checks = check_artifacts(workspace, phase, opts)

    evidence = build_evidence(phase, opts, command_results, artifact_checks, touched, workspace)
    write_evidence(workspace, evidence)

    if all_passing?(evidence), do: {:pass, evidence}, else: {:fail, evidence}
  end

  # Select verification commands based on touched surfaces
  defp select_commands(touched, _phase) do
    base = Config.verification_commands()

    surface_commands =
      Config.verification_surface_commands()
      |> Enum.filter(fn {glob, _cmd} -> Enum.any?(touched, &path_matches?(&1, glob)) end)
      |> Enum.map(fn {_glob, cmd} -> cmd end)

    base ++ surface_commands
  end

  defp detect_touched_surfaces(workspace) do
    case git_diff_names(workspace) do
      {:ok, files} -> files
      _ -> []
    end
  end

  # Run commands in parallel with Task.async_stream
  defp run_commands_parallel(commands, workspace) do
    timeout = Config.verification_timeout_ms()

    commands
    |> Task.async_stream(
      fn cmd -> run_single_command(cmd, workspace, timeout) end,
      timeout: timeout + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, :timeout} -> %{command: "unknown", status: :timeout, output: ""}
    end)
  end

  # Artifact checks go beyond file existence
  defp check_artifacts(workspace, :plan, _opts) do
    plan_path = Path.join(workspace, ".symphony/PLAN.md")
    [%{
      name: "PLAN.md",
      exists: File.exists?(plan_path),
      valid: plan_has_subtasks?(plan_path),
      detail: if(!plan_has_subtasks?(plan_path), do: "Plan must contain subtask checklist")
    }]
  end

  defp check_artifacts(_workspace, _phase, _opts), do: []

  defp plan_has_subtasks?(path) do
    case File.read(path) do
      {:ok, content} -> Regex.match?(~r/\*\*st-\d+\*\*/, content) and byte_size(content) > 100
      _ -> false
    end
  end
end
```

**WORKFLOW.md front matter for verification:**

```yaml
verification:
  commands:
    - ./scripts/validate-app.sh
  surface_commands:
    "apps/web/**": "cd apps/web && pnpm tsc --noEmit && pnpm lint"
    "apps/admin/**": "cd apps/admin && pnpm tsc --noEmit && pnpm lint"
  timeout_ms: 300000
  max_retries: 2
  e2e_mutex: true              # Only one workspace runs E2E at a time
  run_after_subtasks: true     # Run after each subtask, not just end of implement
  run_before_handoff: true     # Final gate before pushing PR
```

**Evidence files** stored at `.symphony/evidence/{phase}-{subtask}-a{attempt}.json`, enabling
audit trail per subtask per attempt.

### 2.6 Stuck Detection — Sliding Window

Adapted from GSD-2's `detect-stuck.ts`.

```elixir
defmodule SymphonyElixir.StuckDetector do
  @type entry :: %{key: String.t(), error: String.t() | nil}

  @spec check([entry()]) :: :ok | {:stuck, reason()}
  def check(window) when length(window) < 2, do: :ok

  def check(window) do
    cond do
      # Rule 1: Same error twice in a row
      same_error_consecutive?(window) ->
        {:stuck, :repeated_error}

      # Rule 2: Same unit key 3+ times
      same_key_repeated?(window, 3) ->
        {:stuck, :no_progress_loop}

      # Rule 3: A→B→A→B oscillation in last 4
      oscillating?(window) ->
        {:stuck, :oscillation}

      true ->
        :ok
    end
  end

  defp same_error_consecutive?([%{error: e1}, %{error: e2} | _])
       when is_binary(e1) and e1 == e2, do: true
  defp same_error_consecutive?(_), do: false

  defp same_key_repeated?(window, threshold) do
    window
    |> Enum.take(threshold)
    |> Enum.map(& &1.key)
    |> Enum.uniq()
    |> length() == 1
  end

  defp oscillating?(window) when length(window) >= 4 do
    [a, b, c, d | _] = Enum.map(window, & &1.key)
    a == c and b == d and a != b
  end
  defp oscillating?(_), do: false
end
```

Integrated into dispatch loop: before dispatching, check stuck window from ledger. If stuck,
write `:stop` to ledger and move issue to `Human Input Needed`.

### 2.7 Per-Issue GenServer — IssueExecution

GSD-2 runs one project at a time. Symphony runs multiple issues concurrently. The right OTP
translation: **one GenServer per active issue**, supervised by a DynamicSupervisor.

```elixir
defmodule SymphonyElixir.IssueExecution do
  use GenServer

  defmodule State do
    defstruct [
      :issue,
      :workspace,
      :ledger_path,
      :current_task_ref,
      :codex_update_recipient,
      phase_attempts: %{},
      verification_mutex: nil  # For E2E exclusion
    ]
  end

  # --- Lifecycle ---

  def start_link(issue, opts) do
    GenServer.start_link(__MODULE__, {issue, opts})
  end

  def init({issue, opts}) do
    recipient = Keyword.get(opts, :codex_update_recipient)
    {:ok, workspace} = Workspace.create_for_issue(issue)
    ledger_path = Path.join(workspace, ".symphony/ledger.jsonl")
    Workspace.ensure_symphony_dir(workspace)

    state = %State{
      issue: issue,
      workspace: workspace,
      ledger_path: ledger_path,
      codex_update_recipient: recipient
    }

    send(self(), :run_next)
    {:ok, state}
  end

  # --- Main dispatch loop (one iteration per message) ---

  def handle_info(:run_next, state) do
    # 1. Re-derive state from ledger (GSD pattern: zero in-memory state dependency)
    {:ok, derived} = StateResolver.derive(state.ledger_path, state.issue, state.workspace)

    # 2. Check for stuck
    case StuckDetector.check(derived.stuck_window) do
      {:stuck, reason} ->
        Ledger.append(state.ledger_path, :stuck_detected, %{reason: reason})
        # Move issue to Human Input Needed, stop
        {:stop, :normal, state}

      :ok ->
        # 3. Resolve next action
        case DispatchResolver.resolve(derived, state.issue, state.workspace) do
          {:dispatch, phase_or_subtask, prompt} ->
            dispatch_phase(state, derived, phase_or_subtask, prompt)

          {:stop, reason} ->
            Ledger.append(state.ledger_path, :execution_stopped, %{reason: reason})
            {:stop, :normal, state}

          :skip ->
            # Nothing to do right now; schedule retry
            Process.send_after(self(), :run_next, 5_000)
            {:noreply, state}
        end
    end
  end

  # Agent task completed normally
  def handle_info({:DOWN, ref, :process, _pid, :normal}, %{current_task_ref: ref} = state) do
    # Phase/subtask completed. Run verification, write anchor, then loop.
    handle_phase_completion(state)
  end

  # Agent task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current_task_ref: ref} = state) do
    Ledger.append(state.ledger_path, :phase_crashed, %{reason: inspect(reason)})
    # Re-derive and re-dispatch on next iteration
    send(self(), :run_next)
    {:noreply, %{state | current_task_ref: nil}}
  end

  # Codex updates forwarded to orchestrator for dashboard
  def handle_info({:codex_worker_update, _issue_id, update}, state) do
    if state.codex_update_recipient do
      send(state.codex_update_recipient, {:codex_worker_update, state.issue.id, update})
    end
    {:noreply, state}
  end

  # Issue state changed (from orchestrator reconciliation)
  def handle_cast({:issue_state_changed, new_issue}, state) do
    # Re-route flow if needed (e.g., moved to Rework or Merging)
    Ledger.append(state.ledger_path, :issue_state_changed, %{
      old: state.issue.state, new: new_issue.state
    })
    send(self(), :run_next)
    {:noreply, %{state | issue: new_issue}}
  end

  # --- Private ---

  defp dispatch_phase(state, derived, phase_or_subtask, prompt) do
    Ledger.append(state.ledger_path, :phase_dispatched, %{
      phase: phase_or_subtask,
      attempt: Map.get(state.phase_attempts, phase_or_subtask, 0) + 1
    })

    # Spawn agent task
    recipient = self()
    {:ok, pid} = Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      AgentRunner.run_phase(state.workspace, state.issue, phase_or_subtask, prompt, recipient)
    end)
    ref = Process.monitor(pid)

    phase_attempts = Map.update(state.phase_attempts, phase_or_subtask, 1, &(&1 + 1))

    {:noreply, %{state | current_task_ref: ref, phase_attempts: phase_attempts}}
  end

  defp handle_phase_completion(state) do
    # 1. Detect what phase just completed (from ledger: last dispatched)
    {:ok, derived} = StateResolver.derive(state.ledger_path, state.issue, state.workspace)

    # 2. Run verification if configured for this phase
    verification_result = maybe_run_verification(state, derived)

    # 3. Write anchor if phase truly completed
    if verification_result in [:pass, :not_configured] do
      maybe_write_anchor(state, derived)
      Ledger.append(state.ledger_path, :phase_completed, %{phase: derived.phase})
    else
      Ledger.append(state.ledger_path, :verification_failed, %{
        phase: derived.phase,
        evidence: verification_result
      })
    end

    # 4. Continue to next phase
    send(self(), :run_next)
    {:noreply, %{state | current_task_ref: nil}}
  end

  defp maybe_run_verification(state, derived) do
    if should_verify?(derived.phase) do
      # Send heartbeat during verification to prevent stall detection
      heartbeat_timer = :timer.send_interval(30_000, {:codex_worker_update, state.issue.id,
        %{event: "verification_running", timestamp: DateTime.utc_now()}})

      result = VerificationGate.run(state.workspace, state.issue, derived.phase)

      :timer.cancel(heartbeat_timer)
      result
    else
      :not_configured
    end
  end
end
```

**Orchestrator changes:** Replace `AgentRunner.run(issue, recipient, opts)` in `do_dispatch_issue`
with starting an `IssueExecution` GenServer:

```elixir
defp do_dispatch_issue(%State{} = state, issue, _attempt) do
  case DynamicSupervisor.start_child(
    SymphonyElixir.IssueSupervisor,
    {IssueExecution, [issue, codex_update_recipient: self()]}
  ) do
    {:ok, pid} ->
      ref = Process.monitor(pid)
      # Track in running map as before
      ...
  end
end
```

The Orchestrator's existing `reconcile_running_issues` sends `{:issue_state_changed, new_issue}`
to the IssueExecution GenServer when Linear state changes. The GenServer handles flow re-routing
internally.

### 2.8 .symphony/ Directory Layout

```
<workspace>/
  .symphony/
    ledger.jsonl                          # Execution log (orchestrator-owned)
    PLAN.md                               # Agent-written plan with subtask checklist
    anchors/
      bootstrap.json                      # Phase anchor
      plan.json
      implement.json
      validate.json
    evidence/
      bootstrap-a1.json                   # Verification evidence
      implement-st-1-a1.json
      implement-st-1-a2.json              # Retry attempt
      implement-st-2-a1.json
      validate-a1.json
      handoff-a1.json
    sessions/
      bootstrap.json                      # Session meta per phase
      plan.json
      implement-st-1.json
  .symphony_session.json                  # (legacy, kept for backward compat)
```

**Lifecycle:**
- **New issue dispatch:** `Workspace.ensure_symphony_dir()` creates `.symphony/` with empty dirs.
- **Workspace reuse (same issue, retry):** `.symphony/` preserved. Ledger re-derive handles.
- **Workspace reuse (new issue):** Clear `.symphony/` entirely. Write `flow_routed` to fresh ledger.
- **Rework:** Append `rework_reset` to ledger. Clear `anchors/` and `evidence/` for phases after
  plan. Keep `PLAN.md` as starting point for re-planning.

### 2.9 Phase Prompt Construction

Each phase prompt is narrow and focused. Pre-inlines the phase anchor from the prior phase
(GSD-2 pattern) plus relevant workspace context.

Prompt budget: ~2K tokens per phase prompt + up to 8K tokens of pre-inlined context (anchor +
plan + verification failure). Total: ~10K tokens max per dispatch, vs current ~4K monolithic
prompt that tries to cover all phases.

```elixir
defmodule SymphonyElixir.PhasePrompt do
  def build(phase, derived_state) do
    [
      phase_instructions(phase, derived_state),
      anchor_section(derived_state),
      verification_section(derived_state),
      common_guardrails()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> cap_preamble(30_000)  # GSD-2 pattern: 30K char cap
  end

  defp anchor_section(state) do
    prior = prior_phase(state.phase)
    case Map.get(state.anchors, prior) do
      nil -> nil
      anchor -> PhaseAnchor.format_for_prompt(anchor)
    end
  end

  defp verification_section(%{last_verification: %{result: :fail} = v}) do
    """
    ## Last Verification FAILED — fix before proceeding
    #{v.output}
    """
  end
  defp verification_section(_), do: nil
end
```

---

## 3. Scope

### New modules (5)

| Module | Lines (est.) | Responsibility |
|---|---|---|
| `StateResolver` | ~150 | Derive state from ledger + issue + workspace |
| `DispatchResolver` | ~200 | Rule-based dispatch table |
| `IssueExecution` | ~250 | Per-issue GenServer FSM |
| `VerificationGate` | ~200 | Multi-layer verification with evidence |
| `PhaseAnchor` | ~80 | Structured handoff between phases |

### Enhanced modules (3)

| Module | Changes |
|---|---|
| `Workspace` | `.symphony/` lifecycle, `atomic_write`, `ensure_symphony_dir`, ledger R/W |
| `Config` | `verification` schema, `agent.max_turns_per_phase`, `verification.surface_commands` |
| `Orchestrator` | Replace `AgentRunner.run` with `IssueExecution.start_link` in dispatch; forward state changes |

### Supporting modules (3)

| Module | Lines (est.) | Responsibility |
|---|---|---|
| `Ledger` | ~60 | Append-only JSONL read/write |
| `SubtaskParser` | ~40 | Parse plan checklist into subtask list |
| `StuckDetector` | ~50 | Sliding window stuck detection |
| `PhasePrompt` | ~200 | Phase-specific prompt construction |

### Removed/replaced

| Module | Disposition |
|---|---|
| `PhaseDetector` (v2) | Replaced by `StateResolver` + `DispatchResolver` |
| `PromptBuilder` | Replaced by `PhasePrompt` for phase dispatch; kept as thin wrapper for backward compat |
| `AgentRunner.run/3` | Kept for backward compat; new path goes through `IssueExecution` |

---

## 4. Definition of Done

### 4.1 Feature Completeness

| Capability | Acceptance criteria |
|---|---|
| Execution ledger | `.symphony/ledger.jsonl` created, appended by orchestrator only, re-derivable after crash |
| Flow routing | `Merging` → land flow, `Rework` → plan reset, normal → 5-phase flow |
| Rule-based dispatch | DispatchResolver returns correct action for all flow × phase combinations |
| Subtask dispatch | Plan parsed into subtasks; implement dispatches one at a time; fallback to whole-phase |
| Phase anchor | Written after each phase; injected into next phase prompt |
| Multi-layer verification | Surface-aware commands, parallel execution, evidence JSON, E2E mutex |
| Stuck detection | 4-rule sliding window; stuck → `Human Input Needed` |
| Per-issue GenServer | IssueExecution owns FSM; orchestrator only polls/claims/monitors |
| Crash recovery | Kill process mid-phase → restart → re-derive from ledger → correct phase |
| Backward compatibility | WORKFLOW.md without verification config → existing behavior unchanged |

### 4.2 Success Metrics

Before/after on ptcg-centering, 10-15 issues:

| Metric | Why it matters |
|---|---|
| Issue completion rate (→ Done or Human Review) | Primary outcome |
| Human intervention rate (→ Human Input Needed) | Sensitivity |
| Verification-caught errors | Measures enforcement value |
| Subtask completion rate within implement | Measures granularity benefit |
| Turns per issue | Efficiency |
| Phase stuck events | Measures stuck detection value |
| Tokens per issue | Cost |

---

## 5. Test Plan

### Unit Tests

**StateResolver:** derive from empty ledger → :bootstrap; derive after plan_completed →
:implement; derive after rework reset → :plan; derive with stale entries → correct phase.

**DispatchResolver:** normal flow full cycle; merging flow → land; rework flow → reset + plan;
verification failure → retry rule; all done → stop; no match → stop with reason.

**SubtaskParser:** parse valid checklist; empty plan → error; freeform plan without IDs → error;
partial checklist → parse what's there.

**StuckDetector:** same error 2x → stuck; same key 3x → stuck; A-B-A-B → stuck; normal
progression → ok; window too small → ok.

**VerificationGate:** command pass; command fail with evidence; timeout; parallel execution;
surface-specific command selection; artifact content validation; E2E mutex.

**PhaseAnchor:** write + read roundtrip; missing anchor → nil; corrupt JSON → nil.

**Ledger:** append + read; empty file → []; concurrent append safety; crash mid-write → last
complete line preserved.

### Integration Tests

| Test | Description |
|---|---|
| Full normal flow | Mock Codex produces expected artifacts per phase; verify ledger has complete history |
| Verification failure → retry | Agent produces failing code; verification catches; re-dispatch with fix context |
| Crash recovery | Kill IssueExecution mid-implement; restart; verify resumes from correct subtask |
| Rework flow | Issue reaches handoff; human moves to Rework; verify re-plan from ledger |
| Merging fast path | Issue in Merging state; verify land-only dispatch |
| Stuck detection | Agent loops on same error; verify escalation to Human Input Needed |
| Backward compat | Minimal WORKFLOW.md, no verification config; verify existing behavior |

### Before/After Pilot

1. Baseline (1 week): 10-15 issues on current system, record all metrics.
2. Treatment (1-2 weeks): Same on new system.
3. Per-issue qualitative review.

---

## 6. Implementation Plan

### Phase 1: Core Infrastructure (3-4 days)

1. `Ledger` module (append-only JSONL read/write)
2. `StateResolver` (derive from ledger + issue + workspace)
3. `DispatchResolver` (rule table for normal/merging/rework flows)
4. `StuckDetector` (sliding window)
5. `Config` extensions (verification schema, surface_commands, max_turns_per_phase)
6. Full unit tests for all above

### Phase 2: Execution Layer (3-4 days)

1. `IssueExecution` GenServer + `IssueSupervisor` (DynamicSupervisor)
2. `PhasePrompt` (phase-specific prompt construction)
3. `PhaseAnchor` (structured handoff)
4. `SubtaskParser` (plan checklist → subtask list)
5. `VerificationGate` (multi-layer verification with evidence)
6. `Workspace` extensions (.symphony/ lifecycle, atomic_write)
7. Wire `IssueExecution` into Orchestrator's dispatch path
8. Unit + integration tests

### Phase 3: Integration + Pilot (1 week)

1. Update ptcg-centering WORKFLOW.md (verification config, phase prompt adjustments)
2. Backward compatibility testing with minimal WORKFLOW.md
3. Run baseline collection
4. Deploy and run treatment
5. Analyze and iterate

**Total: 7-9 days engineering + 1-2 weeks pilot.**

---

## 7. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Subtask parser fails on freeform plans | No subtask dispatch | Graceful fallback to whole-phase implement |
| Ledger grows unbounded | Slow state derivation | Compact on issue completion; typical issue < 100 entries |
| IssueExecution GenServer crash | Issue execution stops | Supervised by DynamicSupervisor; restart re-derives from ledger |
| Agent doesn't produce anchor content | Phase anchor is empty | Orchestrator writes minimal anchor from git log + file list |
| Verification heartbeat gap | Stall detection kills verification | Send heartbeat every 30s during verification |
| E2E mutex deadlock | Verification blocks indefinitely | Mutex timeout (5 min); release on process death |
| Fresh thread loses important context | Agent repeats work | Phase anchor + plan injection; prior task summaries |
| PLAN.md format not followed | Subtask parsing fails | Prompt enforces format; fallback to whole-phase |

---

## 8. Comparison with v2

| Aspect | v2 (artifact-based PhaseDetector) | v3 (ledger + rule resolver) |
|---|---|---|
| State source | File existence heuristics | **Orchestrator-owned ledger** |
| Dispatch logic | Linear cond chain, 5 phases | **Rule table, 3 flows × N rules** |
| Implement granularity | 10 turns, one big phase | **Subtask-level dispatch** |
| Phase handoff | None (fresh thread = amnesia) | **Phase Anchor** |
| Verification | Single command, exit code | **Multi-layer, surface-aware, evidence JSON** |
| Stuck detection | None | **Sliding window, 4 rules** |
| Process model | Phase loop in single Task | **Per-issue GenServer** |
| Rework/Merging | Not handled (bug) | **First-class flow routing** |
| Crash recovery | Re-guess from artifacts | **Re-derive from ledger** |
| GSD-2 fidelity | Surface-level (file presence) | **Core mechanisms (derive → resolve → execute → verify)** |

---

## Appendix C: Review Findings and Resolutions (2026-04-07)

Three-track review: Claude Agent Team (reviewer-alpha conservative + reviewer-beta aggressive,
with debate) + reviewer-gamma independent cross-validation. Codex track failed (quota exceeded).

### C.1 — Ledger Security: Agent Can Tamper (CRITICAL)

**Problem:** `.symphony/ledger.jsonl` is inside the workspace. Production config uses
`thread_sandbox: danger-full-access`. Agent has full filesystem access and could append
`phase_completed` events to skip verification.

**Resolution:** Two-layer defense:

1. **Ledger storage outside workspace.** Move ledger to `~/.symphony/ledgers/{issue_identifier}/
   ledger.jsonl`. This path is outside the workspace root and not accessible to the Codex
   sandbox (which is scoped to workspace directory). The `.symphony/` dir inside the workspace
   remains for agent-written artifacts (PLAN.md) and orchestrator-written files that the agent
   needs to read (anchors, evidence).

2. **Entry validation.** `Ledger.append/3` stamps each entry with a monotonic sequence number
   and process PID. `StateResolver.derive/3` validates that all entries have sequential IDs and
   originate from an IssueExecution PID. Entries failing validation are logged and skipped.

```elixir
# Ledger location
defp ledger_dir(issue_identifier) do
  safe_id = String.replace(issue_identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  Path.join([System.user_home!(), ".symphony", "ledgers", safe_id])
end
```

### C.2 — IssueExecution.init Blocks on Workspace Creation (CRITICAL)

**Problem:** `Workspace.create_for_issue/1` in `init/1` runs `after_create` hook (git clone +
pnpm install), which blocks the DynamicSupervisor for tens of seconds per issue.

**Resolution:** Use `handle_continue/2` for async initialization:

```elixir
def init({issue, opts}) do
  state = %State{
    issue: issue,
    codex_update_recipient: Keyword.get(opts, :codex_update_recipient),
    status: :initializing
  }
  {:ok, state, {:continue, :setup}}
end

def handle_continue(:setup, state) do
  case Workspace.create_for_issue(state.issue) do
    {:ok, workspace} ->
      ledger_path = ledger_path_for_issue(state.issue)
      File.mkdir_p!(Path.dirname(ledger_path))
      Workspace.ensure_symphony_dir(workspace)
      state = %{state | workspace: workspace, ledger_path: ledger_path, status: :running}
      send(self(), :run_next)
      {:noreply, state}

    {:error, reason} ->
      Logger.error("Workspace setup failed: #{inspect(reason)}")
      {:stop, {:workspace_setup_failed, reason}, state}
  end
end

# Guard: don't dispatch if still initializing
def handle_info(:run_next, %{status: :initializing} = state), do: {:noreply, state}
```

### C.3 — E2E Mutex Implementation (CRITICAL)

**Problem:** `e2e_mutex: true` is declared but has no implementation. Concurrent E2E tests
violate production constraints.

**Resolution:** Named GenServer as global semaphore:

```elixir
defmodule SymphonyElixir.E2EMutex do
  use GenServer

  @mutex_timeout_ms 300_000  # 5 minutes

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def init(_), do: {:ok, %{holder: nil, timer: nil}}

  def acquire(issue_id, timeout \\ @mutex_timeout_ms) do
    GenServer.call(__MODULE__, {:acquire, issue_id, self()}, timeout + 5_000)
  end

  def release(issue_id) do
    GenServer.cast(__MODULE__, {:release, issue_id})
  end

  def handle_call({:acquire, issue_id, pid}, _from, %{holder: nil} = state) do
    ref = Process.monitor(pid)
    timer = Process.send_after(self(), {:timeout, issue_id}, @mutex_timeout_ms)
    {:reply, :ok, %{holder: {issue_id, ref}, timer: timer}}
  end

  def handle_call({:acquire, _, _}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  # Auto-release on holder crash
  def handle_info({:DOWN, ref, :process, _, _}, %{holder: {_id, ^ref}} = state) do
    cancel_timer(state.timer)
    {:noreply, %{holder: nil, timer: nil}}
  end

  # Auto-release on timeout
  def handle_info({:timeout, issue_id}, %{holder: {^issue_id, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{holder: nil, timer: nil}}
  end
end
```

`VerificationGate.run/4` acquires the mutex before running E2E commands (when `e2e_mutex: true`),
releases after completion. Retry with backoff if busy.

### C.4 — issue_state_changed Race with Running Task (HIGH)

**Problem:** `handle_cast({:issue_state_changed, ...})` sends `:run_next` even if a task is
running, potentially causing double dispatch.

**Resolution:**

```elixir
def handle_cast({:issue_state_changed, new_issue}, state) do
  Ledger.append(state.ledger_path, :issue_state_changed, %{
    old: state.issue.state, new: new_issue.state
  })

  new_state = %{state | issue: new_issue}

  if state.current_task_ref != nil do
    # Task running — check if we need to kill it (e.g., moved to Done/Cancelled)
    if terminal_state?(new_issue.state) do
      kill_current_task(state)
      send(self(), :run_next)
      {:noreply, %{new_state | current_task_ref: nil}}
    else
      # Non-terminal change (e.g., Rework) — let current task finish,
      # :run_next after {:DOWN} will pick up new flow
      {:noreply, %{new_state | pending_reflow: true}}
    end
  else
    send(self(), :run_next)
    {:noreply, new_state}
  end
end
```

### C.5 — :run_next Missing current_task_ref Guard (HIGH)

**Resolution:** Add guard at top of handler:

```elixir
def handle_info(:run_next, %{current_task_ref: ref} = state) when ref != nil do
  # Task already running — ignore. Will re-trigger after {:DOWN}.
  {:noreply, state}
end

def handle_info(:run_next, %{status: :initializing} = state), do: {:noreply, state}

def handle_info(:run_next, state) do
  # ... existing derive + resolve logic ...
end
```

### C.6 — Verification Return Type Mismatch (HIGH)

**Problem:** `VerificationGate.run/4` returns `{:pass, evidence} | {:fail, evidence}`, but
`handle_phase_completion` checks `verification_result in [:pass, :not_configured]`.

**Resolution:** Fix `maybe_run_verification` to unwrap:

```elixir
defp maybe_run_verification(state, derived) do
  if should_verify?(derived.phase) do
    heartbeat_timer = start_verification_heartbeat(state)

    result = case VerificationGate.run(state.workspace, state.issue, derived.phase) do
      {:pass, evidence} -> {:pass, evidence}
      {:fail, evidence} -> {:fail, evidence}
    end

    :timer.cancel(heartbeat_timer)
    result
  else
    :not_configured
  end
end

defp handle_phase_completion(state) do
  {:ok, derived} = StateResolver.derive(state.ledger_path, state.issue, state.workspace)

  case maybe_run_verification(state, derived) do
    {:pass, evidence} ->
      Ledger.append(state.ledger_path, :verification_passed, %{phase: derived.phase})
      maybe_write_anchor(state, derived)
      Ledger.append(state.ledger_path, :phase_completed, %{phase: derived.phase})

    {:fail, evidence} ->
      Ledger.append(state.ledger_path, :verification_failed, %{
        phase: derived.phase, evidence_path: evidence.path
      })

    :not_configured ->
      maybe_write_anchor(state, derived)
      Ledger.append(state.ledger_path, :phase_completed, %{phase: derived.phase})
  end

  send(self(), :run_next)
  {:noreply, %{state | current_task_ref: nil}}
end
```

### C.7 — Phase/Issue Timeout (HIGH)

**Resolution:** Add timers to IssueExecution:

```elixir
# In handle_continue(:setup, ...) after successful init:
phase_timeout_ms = Config.phase_timeout_ms()  # default 1_800_000 (30 min)
issue_timeout_ms = Config.issue_timeout_ms()   # default 7_200_000 (2 hours)
issue_timer = Process.send_after(self(), :issue_timeout, issue_timeout_ms)
state = %{state | issue_timer: issue_timer}

# In dispatch_phase, start phase timer:
phase_timer = Process.send_after(self(), :phase_timeout, phase_timeout_ms)
state = %{state | phase_timer: phase_timer}

# Handlers:
def handle_info(:phase_timeout, state) do
  Ledger.append(state.ledger_path, :phase_timeout, %{phase: current_phase(state)})
  kill_current_task(state)
  # Escalate or retry based on config
  {:stop, :normal, state}
end

def handle_info(:issue_timeout, state) do
  Ledger.append(state.ledger_path, :issue_timeout, %{})
  kill_current_task(state)
  # Move to Human Input Needed
  {:stop, :normal, state}
end
```

### C.8 — Rework Ledger Reset Semantics (MEDIUM)

**Resolution:** Define explicitly:

When `StateResolver.derive` encounters a `rework_reset` event in the ledger:
- `completed_phases` resets to `[:bootstrap]` only (bootstrap is always preserved)
- `completed_subtasks` resets to `[]`
- `last_verification` resets to `nil`
- `phase` returns to `:plan`
- Anchors for plan/implement/validate/handoff are ignored (cleared on disk)
- PLAN.md is preserved as reference for re-planning

```elixir
# In rework_reset_ledger/3 rule:
defp rework_reset_ledger(state, issue, workspace) do
  if state.flow == :rework and not rework_already_reset?(state) do
    # Clear post-bootstrap artifacts
    clear_phase_artifacts(workspace, [:plan, :implement, :validate, :handoff])
    {:dispatch, :rework_reset, ""}  # Special: no prompt, just reset
  end
end
```

### C.9 — SubtaskParser Resilience (MEDIUM)

**Resolution:** Add lenient parsing mode:

```elixir
@subtask_strict ~r/^- \[[ x]\] \*\*(st-\d+)\*\*:\s*(.+)$/mi
@subtask_lenient ~r/^- \[[ x]\] \*?\*?(?:st-)?(\d+)\*?\*?[:.]\s*(.+)$/mi

def parse(plan_path) do
  case File.read(plan_path) do
    {:ok, content} ->
      subtasks = try_parse(content, @subtask_strict)
      subtasks = if subtasks == [], do: try_parse(content, @subtask_lenient), else: subtasks
      subtasks = if subtasks == [], do: try_numbered_list(content), else: subtasks

      if subtasks == [],
        do: {:error, :no_subtasks_found},
        else: {:ok, Enum.map(subtasks, &normalize_id/1)}
    {:error, reason} ->
      {:error, {:plan_read_failed, reason}}
  end
end
```

### C.10 — Anchor Content Extraction Format (MEDIUM)

**Resolution:** Define extraction protocol. Agent is prompted to output anchor in a fenced block:

```markdown
<!-- SYMPHONY_ANCHOR -->
{
  "intent": "...",
  "decisions": ["..."],
  "blockers": [],
  "next_steps": ["..."]
}
<!-- /SYMPHONY_ANCHOR -->
```

Orchestrator parses agent's final Codex message for this block. If missing, generates minimal
anchor from observable data:

```elixir
defp extract_anchor_from_agent_output(output) do
  case Regex.run(~r/<!-- SYMPHONY_ANCHOR -->\s*(\{.*?\})\s*<!-- \/SYMPHONY_ANCHOR -->/s, output) do
    [_, json] -> Jason.decode(json)
    nil -> :not_found
  end
end

defp generate_fallback_anchor(workspace, phase) do
  %{
    phase: phase,
    intent: "Phase #{phase} completed (no agent-provided anchor)",
    decisions: [],
    blockers: [],
    next_steps: [],
    artifacts: list_changed_files(workspace)
  }
end
```

### C.11 — Todo + Existing PR Feedback Sweep (MEDIUM)

**Resolution:** Add to bootstrap dispatch rule:

```elixir
defp normal_bootstrap(state, issue, workspace) do
  if :bootstrap not in state.completed_phases do
    has_pr = existing_pr?(workspace)
    prompt = PhasePrompt.build(:bootstrap, state, %{has_existing_pr: has_pr})
    {:dispatch, :bootstrap, prompt}
  end
end
```

Bootstrap phase prompt conditionally includes: "Existing PR detected. Run PR feedback sweep
before proceeding to plan."

### C.12 — cap_preamble Configurable (MEDIUM)

**Resolution:** Read from Config instead of hardcoding:

```elixir
defp cap_preamble(text, max \\ Config.prompt_preamble_cap()) do
  # Config default: 30_000
end
```

### C.13 — Ledger Archival on Workspace Cleanup (MEDIUM)

**Resolution:** Before clearing `.symphony/`, archive ledger:

```elixir
defp archive_ledger(issue_identifier) do
  src = ledger_path_for_identifier(issue_identifier)
  if File.exists?(src) do
    archive_dir = Path.join([System.user_home!(), ".symphony", "archive", issue_identifier])
    File.mkdir_p!(archive_dir)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[^0-9]/, "")
    File.cp(src, Path.join(archive_dir, "ledger-#{timestamp}.jsonl"))
  end
end
```

### Implementation Priority Update

Based on review findings, revised estimates:

| Phase | Original | Revised | Reason |
|---|---|---|---|
| Phase 1 | 3-4 days | **4-5 days** | Ledger security (C.1) + E2E mutex (C.3) add complexity |
| Phase 2 | 3-4 days | **5-6 days** | IssueExecution race conditions (C.4-C.6) + timeout (C.7) need careful testing |
| Phase 3 | 1 week | 1 week | Unchanged |
| **Total** | 7-9 days | **9-11 days** + 1-2 weeks pilot |
