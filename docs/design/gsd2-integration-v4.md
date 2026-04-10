# Design Doc: Unit-Level Orchestration for Symphony (v4)

**Status:** Draft v4
**Author:** Guangyu Wang
**Date:** 2026-04-07
**Target:** Symphony Elixir fork (ptcg-centering WORKFLOW.md as pilot)
**Supersedes:** v1 (self-report), v2 (artifact heuristics), v3 (phase-level dispatch)

---

## 0. Changes from v3

v3 received a "Revise" verdict. Three ship blockers identified:

1. **Ledger trust**: `danger-full-access` means path relocation is not a privilege boundary.
2. **Completion keyed off derived.phase**: After a unit completes, `derived.phase` may already
   reflect the *next* phase. Need explicit current-unit bookkeeping.
3. **Unit granularity too coarse**: 5 phases compress too many distinct workflow operations.
   Need ~12 first-class unit types matching the production workflow.

Additional gaps: post-unit closeout pipeline missing, verification inline in GenServer (blocks
responsiveness), phase_attempts in RAM (not crash-consistent), workpad/results not modeled,
PLAN.md vs Linear workpad authority conflict, many workflow operations not encoded.

---

## 1. Problem Statement

(Unchanged from v3. Symphony dispatches one issue as one long session. Agent self-manages all
phases. Orchestrator is blind to execution progress.)

### GSD-2 mechanisms (corrected from v3)

v3 overstated "zero in-memory state" — actual GSD has a 100ms derive cache and centralizes
mutable auto-mode state in `AutoSession`. The correct characterization:

- **State is primarily derived from durable facts** (SQLite + disk), with short-lived in-memory
  caching for performance. Crash recovery works because durable state is always re-derivable.
- **Post-unit pipeline is extensive**: auto-commit, worktree sync, rogue-write detection, artifact
  verification, hooks, triage capture, quick-task dispatch — all happen between unit completion
  and next dispatch. v3 modeled only "derive → dispatch → run → verify → next", missing ~60%
  of what GSD does between units.
- **Unit types are fine-grained**: GSD unitizes planning, research, gate evaluation, execution,
  slice completion, milestone validation, milestone completion, hooks, triage, and quick tasks.
  Not just "5 phases."
- **Crash recovery includes lock file + session forensics**: Not just "re-derive from ledger."
  GSD writes crash locks with PID/session file and synthesizes recovery briefings from session
  JSONL.

---

## 2. Design

### 2.1 Unit Types — The Workflow Contract

The core abstraction is **unit**, not phase. Each unit type maps to a specific workflow operation
from WORKFLOW-production.md, is context-window-sized, and has clear entry/exit criteria.

```elixir
@type unit_type ::
  # Normal flow
  :bootstrap           # Todo→In Progress, workpad, env stamp, baseline validation
  | :plan              # Write plan + subtask checklist to .symphony/PLAN.md
  | :plan_review       # Subprocess review of plan (no self-review)
  | :implement_subtask # One subtask from plan checklist
  | :code_review       # code-review skill in separate subprocess
  | :visual_review     # visual-review skill (if UI changed)
  | :doc_audit         # doc-audit (if docs may be stale)
  | :handoff_prep      # Merge origin/main, rerun validation, PR feedback sweep
  | :handoff_push      # Push via skill, attach PR URL, move to Human Review
  # Merging flow
  | :merge_land        # Run land skill, wait on CI, handle failures
  # Rework flow
  | :rework_replan     # Re-read issue + comments, reuse PR/workpad, re-plan
```

**Mapping to WORKFLOW-production.md:**

| Workflow operation | Unit type | WORKFLOW.md reference |
|---|---|---|
| Route & Bootstrap (Phase 1) | `:bootstrap` | L193-200 |
| Plan + search-before-planning (Phase 2) | `:plan` | L201-208 |
| Plan review via subprocess (Phase 2) | `:plan_review` | L209 |
| Implement one sub-task (Phase 3) | `:implement_subtask` | L215-219 |
| Code review via skill, max 5 cycles (Phase 4) | `:code_review` | L230-234 |
| Visual review, max 5 cycles (Phase 4) | `:visual_review` | L226-229 |
| Doc audit (Phase 4) | `:doc_audit` | L235 |
| Pre-handoff: merge main, rerun validation, PR sweep (Phase 5) | `:handoff_prep` | L237-243 |
| Push + attach PR + move to Human Review (Phase 5) | `:handoff_push` | L244 |
| Merging: land + CI wait + failure handling | `:merge_land` | L82-108 |
| Rework: re-read + re-plan with existing PR | `:rework_replan` | L246-252 |

### 2.2 Execution Ledger

Append-only JSONL, owned by the `LedgerWriter` GenServer (see §2.8 for trust model).

Every ledger entry includes:

```elixir
@type ledger_entry :: %{
  seq: pos_integer(),           # Monotonic sequence (for ordering/validation)
  ts: DateTime.t(),
  exec_id: String.t(),          # Opaque execution ID (unique per IssueExecution lifetime)
  event: atom(),
  payload: map()
}
```

Events (subset):

```jsonl
{"seq":1,"ts":"...","exec_id":"ex-abc123","event":"flow_routed","payload":{"flow":"normal","issue_state":"Todo"}}
{"seq":2,"ts":"...","exec_id":"ex-abc123","event":"unit_dispatched","payload":{"unit_type":"bootstrap","unit_id":"bootstrap-a1","attempt":1}}
{"seq":3,"ts":"...","exec_id":"ex-abc123","event":"unit_completed","payload":{"unit_id":"bootstrap-a1","duration_ms":89000}}
{"seq":4,"ts":"...","exec_id":"ex-abc123","event":"closeout_done","payload":{"unit_id":"bootstrap-a1","anchor_written":true,"committed":false}}
{"seq":5,"ts":"...","exec_id":"ex-abc123","event":"verification_run","payload":{"unit_id":"bootstrap-a1","result":"pass","evidence_path":"..."}}
{"seq":6,"ts":"...","exec_id":"ex-abc123","event":"unit_dispatched","payload":{"unit_type":"plan","unit_id":"plan-a1","attempt":1}}
```

**StateResolver derives from ledger + issue + workspace + evidence:**

```elixir
defmodule SymphonyElixir.StateResolver do
  @type state :: %{
    flow: :normal | :merging | :rework,
    completed_units: [String.t()],       # unit_ids that have completed
    last_dispatched: unit_ref() | nil,    # what was most recently dispatched
    last_completed: unit_ref() | nil,     # what most recently completed
    last_verification: verification_ref() | nil,
    pending_subtasks: [subtask()],        # parsed from PLAN.md, minus completed
    stuck_window: [dispatch_entry()],
    anchors: %{atom() => anchor()},
    issue_state: String.t()
  }

  def derive(ledger_path, issue, workspace) do
    with {:ok, entries} <- LedgerWriter.read(ledger_path) do
      # Derive ALL state from ledger entries — no in-memory supplements
      completed = extract_completed_unit_ids(entries)
      subtasks = parse_subtasks_if_plan_complete(entries, workspace)
      pending = subtract_completed(subtasks, completed)

      {:ok, %{
        flow: route_flow(issue),
        completed_units: completed,
        last_dispatched: last_event(entries, :unit_dispatched),
        last_completed: last_event(entries, :unit_completed),
        last_verification: last_event(entries, :verification_run),
        pending_subtasks: pending,
        stuck_window: last_n_events(entries, :unit_dispatched, 6),
        anchors: load_anchors(workspace),
        issue_state: issue.state
      }}
    end
  end
end
```

### 2.3 Dispatch Resolver — Expanded Rule Table

Rules return `{:dispatch, %UnitSpec{}} | {:stop, reason} | :skip | nil`.

```elixir
defmodule SymphonyElixir.DispatchResolver do
  @type unit_spec :: %{
    type: unit_type(),
    id: String.t(),       # e.g. "implement_subtask-st-3-a1"
    prompt: String.t(),
    max_turns: pos_integer()
  }

  def resolve(state, issue, workspace) do
    rules(state.flow)
    |> Enum.find_value(fn rule -> rule.(state, issue, workspace) end)
    || {:stop, :no_matching_rule}
  end

  # --- Normal flow: ordered rules ---
  defp rules(:normal), do: [
    &bootstrap/3,                    # Not yet bootstrapped
    &plan/3,                         # No plan yet
    &plan_review/3,                  # Plan exists but not reviewed
    &implement_next_subtask/3,       # Pending subtasks remain
    &verification_retry/3,           # Last verification failed, retries remain
    &code_review/3,                  # All subtasks done + verification passing, not yet reviewed
    &visual_review/3,                # UI changed, not yet visually reviewed
    &doc_audit/3,                    # Docs may be stale, not yet audited
    &handoff_prep/3,                 # Reviews done, not yet prepped for handoff
    &handoff_push/3,                 # Prepped, not yet pushed
    &done/3                          # All units complete → stop
  ]

  # --- Merging flow ---
  defp rules(:merging), do: [
    &merge_land/3,                   # Run land, wait CI, handle failures
    &merge_ci_wait/3,                # CI still pending → skip (wait for next poll)
    &merge_done/3                    # Merged → stop
  ]

  # --- Rework flow ---
  defp rules(:rework), do: [
    &rework_replan/3,                # Re-read issue + comments, re-plan
    # After replan, fall through to normal implement→review→handoff
    &implement_next_subtask/3,
    &verification_retry/3,
    &code_review/3,
    &visual_review/3,
    &doc_audit/3,
    &handoff_prep/3,
    &handoff_push/3,
    &done/3
  ]

  # --- Rule implementations (examples) ---

  defp bootstrap(state, _issue, _workspace) do
    unless has_completed?(state, "bootstrap") do
      {:dispatch, %{type: :bootstrap, id: next_unit_id(:bootstrap, state), max_turns: 3,
        prompt: UnitPrompt.build(:bootstrap, state)}}
    end
  end

  defp plan(state, _issue, _workspace) do
    if has_completed?(state, "bootstrap") and not has_completed?(state, "plan") do
      {:dispatch, %{type: :plan, id: next_unit_id(:plan, state), max_turns: 5,
        prompt: UnitPrompt.build(:plan, state)}}
    end
  end

  defp plan_review(state, _issue, workspace) do
    if has_completed?(state, "plan") and not has_completed?(state, "plan_review") do
      if plan_exists_and_valid?(workspace) do
        {:dispatch, %{type: :plan_review, id: next_unit_id(:plan_review, state), max_turns: 3,
          prompt: UnitPrompt.build(:plan_review, state)}}
      end
    end
  end

  defp implement_next_subtask(state, _issue, _workspace) do
    if has_completed?(state, "plan_review") do
      case next_pending_subtask(state) do
        %{id: st_id} = subtask ->
          {:dispatch, %{type: :implement_subtask, id: "implement_subtask-#{st_id}-a#{attempt(state, st_id)}",
            max_turns: 5, prompt: UnitPrompt.build(:implement_subtask, state, subtask)}}
        nil -> nil  # All subtasks done, skip to next rule
      end
    end
  end

  defp code_review(state, _issue, _workspace) do
    if all_subtasks_done?(state) and verification_passing?(state) and
       not has_completed?(state, "code_review") do
      {:dispatch, %{type: :code_review, id: next_unit_id(:code_review, state), max_turns: 8,
        prompt: UnitPrompt.build(:code_review, state)}}
    end
  end

  defp visual_review(state, _issue, workspace) do
    if has_completed?(state, "code_review") and
       ui_changed?(workspace) and
       not has_completed?(state, "visual_review") do
      {:dispatch, %{type: :visual_review, id: next_unit_id(:visual_review, state), max_turns: 5,
        prompt: UnitPrompt.build(:visual_review, state)}}
    end
  end

  defp handoff_prep(state, _issue, _workspace) do
    if reviews_complete?(state) and not has_completed?(state, "handoff_prep") do
      {:dispatch, %{type: :handoff_prep, id: next_unit_id(:handoff_prep, state), max_turns: 3,
        prompt: UnitPrompt.build(:handoff_prep, state)}}
    end
  end
end
```

### 2.4 CurrentUnit — Explicit Bookkeeping

v3's critical flaw: completion was keyed off `derived.phase` which might already reflect the next
state. v4 tracks the exact dispatched unit:

```elixir
defmodule SymphonyElixir.IssueExecution do
  defmodule CurrentUnit do
    @enforce_keys [:type, :id, :attempt, :worker_pid, :monitor_ref, :started_at, :deadline]
    defstruct [
      :type,          # :bootstrap | :plan | :implement_subtask | ...
      :id,            # "implement_subtask-st-3-a1"
      :attempt,       # 1-based
      :worker_pid,
      :monitor_ref,
      :started_at,    # DateTime
      :deadline,      # DateTime (phase timeout)
      :exec_id        # Opaque execution ID for ledger correlation
    ]
  end

  defmodule State do
    defstruct [
      :issue,
      :workspace,
      :ledger_path,
      :exec_id,                    # Opaque ID for this execution lifetime
      :codex_update_recipient,
      :issue_timer,                # 2-hour ticket timeout
      current_unit: nil,           # %CurrentUnit{} | nil
      status: :initializing,       # :initializing | :running | :stopping
      pending_reflow: false        # issue state changed while unit running
    ]
  end
end
```

**Completion always references `current_unit`, never derived state:**

```elixir
def handle_info({:DOWN, ref, :process, _pid, :normal}, %{current_unit: %{monitor_ref: ^ref} = unit} = state) do
  # Unit completed. Run closeout pipeline, then dispatch next.
  run_closeout_pipeline(state, unit)
end

def handle_info({:DOWN, ref, :process, _pid, reason}, %{current_unit: %{monitor_ref: ^ref} = unit} = state) do
  # Unit crashed.
  LedgerWriter.append(state.ledger_path, state.exec_id, :unit_crashed, %{
    unit_id: unit.id, reason: inspect(reason)
  })
  cancel_unit_timer(state)
  send(self(), :run_next)
  {:noreply, %{state | current_unit: nil}}
end
```

### 2.5 Post-Unit Closeout Pipeline

Adapted from GSD's `auto-post-unit.ts`. Runs as a separate Task after unit completion,
before next dispatch. Orchestrator stays responsive.

```elixir
defp run_closeout_pipeline(state, completed_unit) do
  # Spawn closeout as a Task — keeps GenServer responsive
  closeout_pid = spawn_closeout_task(state, completed_unit)
  closeout_ref = Process.monitor(closeout_pid)

  {:noreply, %{state |
    current_unit: nil,
    closeout_ref: closeout_ref,
    closeout_unit: completed_unit
  }}
end

# Closeout task (runs outside GenServer)
defp do_closeout(state, unit) do
  workspace = state.workspace

  # 1. Record unit completion in ledger
  LedgerWriter.append(state.ledger_path, state.exec_id, :unit_completed, %{
    unit_id: unit.id, type: unit.type,
    duration_ms: DateTime.diff(DateTime.utc_now(), unit.started_at, :millisecond)
  })

  # 2. Artifact verification (content validity, not just existence)
  artifact_check = verify_expected_artifacts(workspace, unit.type)

  # 3. Auto-commit check (WORKFLOW.md: "commit after each completed sub-task")
  commit_status = check_uncommitted_changes(workspace, unit)

  # 4. Write anchor (if phase boundary)
  anchor = maybe_write_anchor(workspace, unit, state)

  # 5. Run verification (if configured for this unit type)
  verification = maybe_run_verification(workspace, state.issue, unit)

  # 6. Record closeout in ledger
  LedgerWriter.append(state.ledger_path, state.exec_id, :closeout_done, %{
    unit_id: unit.id,
    artifact_check: artifact_check,
    committed: commit_status,
    anchor_written: anchor != nil,
    verification: verification_summary(verification)
  })

  # Return result to GenServer via message
  send(state.self_pid, {:closeout_complete, unit.id, verification})
end

# GenServer receives closeout result
def handle_info({:closeout_complete, unit_id, verification}, state) do
  case verification do
    {:fail, _evidence} ->
      LedgerWriter.append(state.ledger_path, state.exec_id, :verification_failed, %{
        unit_id: unit_id
      })

    _ -> :ok
  end

  send(self(), :run_next)
  {:noreply, %{state | closeout_ref: nil, closeout_unit: nil}}
end
```

### 2.6 Verification Gate

**Command discovery** follows GSD's "first non-empty source wins" pattern:

```elixir
defmodule SymphonyElixir.VerificationGate do
  def run(workspace, issue, unit) do
    commands = discover_commands(workspace, unit)
    if commands == [], do: {:pass, nil}, else: execute_and_collect(commands, workspace, unit)
  end

  # GSD pattern: first-non-empty-wins (preferences → unit verify → package.json)
  defp discover_commands(workspace, unit) do
    cond do
      (cmds = Config.verification_commands()) != [] -> cmds
      (cmds = unit_verify_commands(unit)) != [] -> cmds
      (cmds = package_json_scripts(workspace)) != [] -> cmds
      true -> []
    end
    |> append_surface_commands(workspace)
  end

  # Surface-specific: only run commands for touched surfaces
  defp append_surface_commands(base_commands, workspace) do
    touched = git_diff_names(workspace)
    surface_cmds =
      Config.verification_surface_commands()
      |> Enum.filter(fn {glob, _cmd} -> Enum.any?(touched, &path_matches?(&1, glob)) end)
      |> Enum.map(fn {_glob, cmd} -> cmd end)

    base_commands ++ surface_cmds
  end

  # Sequential execution (matching GSD behavior), with per-command timeout
  defp execute_and_collect(commands, workspace, unit) do
    results = Enum.map(commands, &run_single_command(&1, workspace))

    evidence = %{
      schema_version: 1,
      unit_id: unit.id,
      unit_type: unit.type,
      attempt: unit.attempt,
      git_sha: current_git_sha(workspace),
      timestamp: DateTime.utc_now(),
      commands: results,
      touched_surfaces: git_diff_names(workspace)
    }

    evidence_path = write_evidence(workspace, unit, evidence)

    if Enum.all?(results, &(&1.exit_code == 0)) do
      {:pass, %{path: evidence_path}}
    else
      {:fail, %{path: evidence_path, output: format_failures(results)}}
    end
  end
end
```

**E2E Mutex** — acquired before E2E commands, via dedicated GenServer (unchanged from v3
Appendix C.3, with the addition of queue-based fairness):

```elixir
defmodule SymphonyElixir.E2EMutex do
  use GenServer

  # Queue-based: callers wait in FIFO order instead of getting immediate {:error, :busy}
  def acquire(issue_id, timeout \\ 300_000) do
    GenServer.call(__MODULE__, {:acquire, issue_id, self()}, timeout + 5_000)
  end
end
```

### 2.7 IssueExecution GenServer

```elixir
defmodule SymphonyElixir.IssueExecution do
  use GenServer

  # --- Init (non-blocking) ---

  def init({issue, opts}) do
    exec_id = "ex-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
    state = %State{
      issue: issue,
      exec_id: exec_id,
      codex_update_recipient: Keyword.get(opts, :codex_update_recipient),
      status: :initializing
    }
    {:ok, state, {:continue, :setup}}
  end

  def handle_continue(:setup, state) do
    case Workspace.create_for_issue(state.issue) do
      {:ok, workspace} ->
        ledger_path = LedgerWriter.path_for_issue(state.issue)
        Workspace.ensure_symphony_dir(workspace)

        # Issue-level timeout (2 hours)
        issue_timer = Process.send_after(self(), :issue_timeout, Config.issue_timeout_ms())

        state = %{state |
          workspace: workspace,
          ledger_path: ledger_path,
          issue_timer: issue_timer,
          status: :running
        }

        LedgerWriter.append(ledger_path, state.exec_id, :flow_routed, %{
          flow: StateResolver.route_flow(state.issue),
          issue_state: state.issue.state
        })

        send(self(), :run_next)
        {:noreply, state}

      {:error, reason} ->
        {:stop, {:workspace_setup_failed, reason}, state}
    end
  end

  # --- Main dispatch loop ---

  def handle_info(:run_next, %{status: s} = state) when s != :running, do: {:noreply, state}
  def handle_info(:run_next, %{current_unit: u} = state) when u != nil, do: {:noreply, state}
  def handle_info(:run_next, %{closeout_ref: r} = state) when r != nil, do: {:noreply, state}

  def handle_info(:run_next, state) do
    {:ok, derived} = StateResolver.derive(state.ledger_path, state.issue, state.workspace)

    case StuckDetector.check(derived.stuck_window) do
      {:stuck, reason} ->
        LedgerWriter.append(state.ledger_path, state.exec_id, :stuck_detected, %{reason: reason})
        escalate_to_human(state)
        {:stop, :normal, state}

      :ok ->
        case DispatchResolver.resolve(derived, state.issue, state.workspace) do
          {:dispatch, unit_spec} ->
            dispatch_unit(state, unit_spec)

          {:stop, reason} ->
            LedgerWriter.append(state.ledger_path, state.exec_id, :execution_stopped, %{reason: reason})
            {:stop, :normal, state}

          :skip ->
            Process.send_after(self(), :run_next, 5_000)
            {:noreply, state}
        end
    end
  end

  # --- Unit dispatch ---

  defp dispatch_unit(state, unit_spec) do
    LedgerWriter.append(state.ledger_path, state.exec_id, :unit_dispatched, %{
      unit_type: unit_spec.type, unit_id: unit_spec.id, attempt: unit_spec[:attempt] || 1
    })

    recipient = self()
    {:ok, pid} = Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      AgentRunner.run_unit(state.workspace, state.issue, unit_spec, recipient)
    end)
    ref = Process.monitor(pid)

    deadline = DateTime.add(DateTime.utc_now(), Config.unit_timeout_ms(unit_spec.type), :millisecond)
    unit_timer = Process.send_after(self(), {:unit_timeout, unit_spec.id}, Config.unit_timeout_ms(unit_spec.type))

    current_unit = %CurrentUnit{
      type: unit_spec.type,
      id: unit_spec.id,
      attempt: unit_spec[:attempt] || 1,
      worker_pid: pid,
      monitor_ref: ref,
      started_at: DateTime.utc_now(),
      deadline: deadline,
      exec_id: state.exec_id
    }

    {:noreply, %{state | current_unit: current_unit, unit_timer: unit_timer}}
  end

  # --- Issue state changes (from Orchestrator reconciliation) ---

  def handle_cast({:issue_state_changed, new_issue}, state) do
    LedgerWriter.append(state.ledger_path, state.exec_id, :issue_state_changed, %{
      old: state.issue.state, new: new_issue.state
    })

    cond do
      terminal_state?(new_issue.state) ->
        kill_current_unit_if_running(state)
        {:stop, :normal, %{state | issue: new_issue}}

      state.current_unit != nil ->
        # Unit running — flag for re-routing after it completes
        {:noreply, %{state | issue: new_issue, pending_reflow: true}}

      true ->
        send(self(), :run_next)
        {:noreply, %{state | issue: new_issue}}
    end
  end

  # --- Timeouts ---

  def handle_info({:unit_timeout, unit_id}, %{current_unit: %{id: ^unit_id}} = state) do
    LedgerWriter.append(state.ledger_path, state.exec_id, :unit_timeout, %{unit_id: unit_id})
    kill_current_unit_if_running(state)
    send(self(), :run_next)
    {:noreply, %{state | current_unit: nil}}
  end

  def handle_info(:issue_timeout, state) do
    LedgerWriter.append(state.ledger_path, state.exec_id, :issue_timeout, %{})
    kill_current_unit_if_running(state)
    escalate_to_human(state)
    {:stop, :normal, state}
  end

  # --- Codex updates (forwarded for dashboard) ---

  def handle_info({:codex_worker_update, _id, update}, state) do
    if state.codex_update_recipient do
      send(state.codex_update_recipient, {:codex_worker_update, state.issue.id, update})
    end
    {:noreply, state}
  end

  # --- Helpers ---

  defp kill_current_unit_if_running(%{current_unit: %{worker_pid: pid, monitor_ref: ref}}) do
    Process.demonitor(ref, [:flush])
    Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid)
  end
  defp kill_current_unit_if_running(_state), do: :ok
end
```

### 2.8 Ledger Trust Model

Under `danger-full-access`, the agent can read/write any path on the host. Path relocation
is not a privilege boundary. We accept this and use defense-in-depth:

1. **Dedicated LedgerWriter GenServer.** Only IssueExecution writes via `LedgerWriter.append/4`.
   The agent does not know the ledger API. Even if the agent finds and modifies the file, the
   next `StateResolver.derive` call validates entries.

2. **Entry validation.** Each entry has a monotonic `seq` and `exec_id`. `StateResolver.derive`
   validates:
   - `seq` values are monotonically increasing
   - `exec_id` matches the current execution (entries from prior crashed executions are accepted
     but flagged)
   - Event types are in the known set (unknown events logged and skipped)
   - Timestamps are monotonically non-decreasing

3. **Ledger storage.** `~/.symphony/ledgers/{safe_issue_id}/ledger.jsonl`. This is not a
   security boundary, but it reduces accidental corruption (agent won't `rm -rf` its own workspace
   and hit the ledger).

4. **Append discipline.** `LedgerWriter` uses `File.open!(..., [:append, :sync])` to ensure
   fsync after each write. Crash mid-write loses at most the last partial line; `read_ledger`
   skips lines that fail JSON decode.

5. **Accepted risk.** Under `danger-full-access`, a determined or hallucinating agent can tamper
   with anything. The real defense is that ledger tampering would require the agent to (a) know
   the ledger path, (b) understand the schema, (c) craft valid entries. This is unlikely via
   accidental hallucination. Deliberate tampering is out of scope for an unattended coding agent.

### 2.9 Workpad & Results — Two Sources of Truth

WORKFLOW-production.md requires two Linear comments: `## Codex Workpad` (scratch) and
`## Results` (polished final output). The design must not create a third source of truth.

**Authority model:**
- **Linear workpad** = human-facing progress. Agent updates it during execution.
- `.symphony/PLAN.md` = machine-parseable subtask list. Orchestrator reads it for dispatch.
- These overlap: the plan checklist appears in both. On conflict, PLAN.md wins for dispatch
  (orchestrator reads it), workpad wins for human visibility (agent writes it).

**Sync strategy:**
- `:plan` unit prompt instructs agent to write PLAN.md *and* update workpad with the same plan.
- `:handoff_push` unit prompt instructs agent to write `## Results` comment.
- Orchestrator never writes to Linear. All Linear writes are agent-owned.

### 2.10 Anchors — Auxiliary, Not Truth

Phase anchors are prompt quality aids, not state sources. The ledger is the source of truth for
"what happened." Anchors provide context for "why and what's next."

Written by orchestrator in closeout pipeline, from observable data:

```elixir
defp generate_anchor(workspace, unit) do
  %{
    unit_type: unit.type,
    completed_at: DateTime.utc_now(),
    git_summary: git_log_oneline(workspace, 5),
    files_changed: git_diff_names(workspace),
    verification_status: last_verification_status(workspace)
  }
end
```

Agent-authored content (intent, decisions, next_steps) is extracted from agent output if
available, but the anchor is valid without it. No agent cooperation required for anchor to work.

### 2.11 Crash Recovery

GSD pattern: lock file + session forensics + durable state re-derivation.

```elixir
# On IssueExecution startup (handle_continue :setup):
# 1. Check for crash lock from prior execution
case CrashLock.read(workspace) do
  {:ok, %{pid: old_pid, unit_id: last_unit}} ->
    if not CrashLock.process_alive?(old_pid) do
      Logger.info("Recovering from crash: last unit was #{last_unit}")
      # Lock exists, process dead → previous execution crashed
      # Ledger already has the dispatch entry; derive will find it incomplete
      CrashLock.clear(workspace)
    end
  _ -> :ok
end

# 2. Write new crash lock before each unit dispatch
CrashLock.write(workspace, %{pid: self(), unit_id: unit_spec.id, exec_id: state.exec_id})

# 3. Clear lock after closeout
CrashLock.clear(workspace)

# 4. On restart, StateResolver.derive reads ledger:
#    - Finds unit_dispatched without matching unit_completed → that unit needs re-dispatch
#    - DispatchResolver naturally re-dispatches it (same rules, same state)
```

### 2.12 Stuck Detection

(Unchanged from v3 §2.6 — sliding window, 4 rules.)

---

## 3. Module Summary

| Module | New/Modified | Responsibility |
|---|---|---|
| `StateResolver` | New (~150 LOC) | Derive state from ledger + issue + workspace |
| `DispatchResolver` | New (~300 LOC) | Rule table for 3 flows × ~12 unit types |
| `IssueExecution` | New (~350 LOC) | Per-issue GenServer: dispatch loop + unit lifecycle |
| `CurrentUnit` | New (~30 LOC) | Struct for exact unit tracking |
| `LedgerWriter` | New (~80 LOC) | Append-only JSONL with fsync + validation |
| `VerificationGate` | New (~200 LOC) | Multi-source discovery + surface-aware + evidence |
| `E2EMutex` | New (~60 LOC) | Global semaphore for exclusive E2E |
| `UnitPrompt` | New (~300 LOC) | Per-unit-type prompt construction |
| `StuckDetector` | New (~50 LOC) | Sliding window stuck detection |
| `CrashLock` | New (~40 LOC) | Lock file protocol for crash recovery |
| `SubtaskParser` | New (~50 LOC) | Parse plan checklist with lenient fallback |
| `Workspace` | Modified | `.symphony/` lifecycle, atomic_write, anchor storage |
| `Config` | Modified | verification schema, unit timeouts, surface_commands |
| `Orchestrator` | Modified | Replace AgentRunner.run with IssueExecution.start_link |

---

## 4. Definition of Done

| Capability | Acceptance criteria |
|---|---|
| Unit-level dispatch | 12 unit types dispatched correctly across 3 flows |
| Execution ledger | Append-only, validated, crash-recoverable |
| CurrentUnit bookkeeping | Completion always references dispatched unit, never derived state |
| Post-unit closeout | Artifact check + auto-commit check + anchor + verification |
| Subtask dispatch | Plan parsed, subtasks dispatched one at a time |
| Verification gate | Surface-aware, first-non-empty-wins discovery, evidence JSON |
| E2E mutex | Queue-based fairness, auto-release on crash/timeout |
| Stuck detection | 4-rule window, escalation to Human Input Needed |
| Crash recovery | Lock file + ledger re-derivation, correct unit re-dispatch |
| Flow routing | Normal/Merging/Rework as first-class flows |
| Workpad/Results sync | Agent writes both, orchestrator reads PLAN.md for dispatch |
| Unit timeouts | Per-unit + per-issue timers, enforced by GenServer |
| Backward compat | WORKFLOW.md without verification config → existing behavior |

---

## 5. Test Plan

### Unit Tests

**StateResolver:** empty ledger → bootstrap; after plan completed → plan_review; after rework
reset → rework_replan; crashed unit (dispatched without completed) → same unit re-dispatched.

**DispatchResolver:** normal flow 12-unit progression; merging → land → CI wait → done; rework →
replan → implement → handoff; verification failure → retry; all done → stop; subtask ordering.

**CurrentUnit:** dispatch creates unit; completion references exact unit_id; crash leaves unit in
ledger without completion; re-derive finds it.

**LedgerWriter:** append + read; seq validation; corrupt last line skipped; exec_id mismatch
flagged; concurrent read during write.

**VerificationGate:** first-non-empty-wins discovery; surface commands appended; sequential exec;
evidence written; E2E mutex acquired/released.

**StuckDetector:** same error 2x; same unit 3x; oscillation; normal → ok.

### Integration Tests

| Test | Description |
|---|---|
| Normal flow end-to-end | 12-unit progression with mocked Codex |
| Verification failure → retry → pass | Implement subtask fails verification, retried, passes |
| Crash recovery | Kill mid-implement; restart; re-derives; re-dispatches same subtask |
| Rework flow | Reaches handoff → human moves to Rework → re-plans with existing PR |
| Merging flow | Issue in Merging → land → CI wait → done |
| Stuck escalation | Same error 3 times → Human Input Needed |
| Issue state change mid-unit | Human moves to Done while implementing → unit killed, stop |
| Unit timeout | Implement subtask exceeds deadline → killed, next unit |
| Backward compat | No verification config → existing AgentRunner behavior |

### Before/After Pilot

1. Baseline (1 week): 10-15 issues on current system.
2. Treatment (1-2 weeks): Same on new system.
3. Per-issue qualitative review.

---

## 6. Implementation Plan

### Phase 1: Core Infrastructure (4-5 days)

1. `LedgerWriter` (JSONL with fsync, validation, GenServer)
2. `StateResolver` (derive from ledger + issue + workspace)
3. `DispatchResolver` (rule table, 3 flows, ~12 unit types)
4. `StuckDetector` (sliding window)
5. `SubtaskParser` (lenient parsing)
6. `CrashLock` (lock file protocol)
7. `Config` extensions (verification, surface_commands, unit timeouts)
8. Full unit tests

### Phase 2: Execution Layer (5-6 days)

1. `IssueExecution` GenServer + `CurrentUnit` + `IssueSupervisor`
2. `UnitPrompt` (per-unit-type prompt with anchor injection)
3. Post-unit closeout pipeline
4. `VerificationGate` (multi-source, surface-aware, evidence)
5. `E2EMutex` GenServer
6. `Workspace` extensions (.symphony/ lifecycle)
7. Wire into Orchestrator dispatch path
8. Unit + integration tests

### Phase 3: Integration + Pilot (1-2 weeks)

1. Update ptcg-centering WORKFLOW.md
2. Backward compat testing
3. Baseline collection → treatment → analysis

**Total: 9-11 days engineering + 1-2 weeks pilot.**

---

## 7. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Subtask parser fails on freeform plans | Fallback to single implement unit |
| Agent doesn't produce PLAN.md | `:plan` unit retried; max 2 attempts then escalate |
| Ledger tampering under danger-full-access | Accepted risk with validation heuristics |
| Closeout Task crash | Monitored; GenServer re-triggers :run_next |
| E2E mutex deadlock | Queue timeout + auto-release on process death |
| 12 unit types = many prompts to maintain | UnitPrompt uses composable sections, not monolithic strings |
| Workpad/PLAN.md diverge | Prompt enforces dual write; orchestrator only reads PLAN.md |
| Verification false positives on half-done work | Only runs after unit completion, not mid-turn |
