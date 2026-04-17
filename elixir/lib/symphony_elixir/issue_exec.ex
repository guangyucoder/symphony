defmodule SymphonyElixir.IssueExec do
  @moduledoc """
  Reads and writes the per-issue durable execution state (`.symphony/issue_exec.json`).
  This is the orchestrator's view of where the issue stands in the unit-lite flow.
  """

  require Logger

  @state_file "issue_exec.json"

  @type t :: %{
          mode: String.t(),
          phase: String.t(),
          current_unit: map() | nil,
          last_accepted_unit: map() | nil,
          last_commit_sha: String.t() | nil,
          last_verified_sha: String.t() | nil,
          baseline_verify_failed: boolean(),
          baseline_verify_output: String.t() | nil,
          bootstrapped: boolean(),
          plan_version: non_neg_integer(),
          updated_at: String.t()
        }

  @default_state %{
    "mode" => "unit_lite",
    "phase" => "bootstrap",
    "current_unit" => nil,
    "last_accepted_unit" => nil,
    "last_commit_sha" => nil,
    "last_verified_sha" => nil,
    # Warm-session review loop — see docs/design/warm-session-review-loop.md.
    # implement_thread_id / review_thread_id let agent_runner resume warm
    # Codex threads across dispatches rather than spinning a cold session.
    # review_verdict / review_round / last_reviewed_sha drive the
    # implement↔review state machine in DispatchResolver.
    "implement_thread_id" => nil,
    "review_thread_id" => nil,
    "review_verdict" => nil,
    "review_round" => 0,
    "last_reviewed_sha" => nil,
    # Most recent closeout-rejection reason. Set by AgentRunner on
    # `{:retry, reason}`; consumed by PromptBuilder on the replay dispatch
    # so the agent sees exactly what to fix. Cleared on accept and on rework.
    "last_retry_reason" => nil,
    # Docs-impact pass already ran this review cycle. Set by doc_fix closeout,
    # read by pre_handoff_doc_fix_rule to avoid re-firing when a post-doc_fix
    # re-review shifts last_accepted_unit back to "code_review".
    "doc_fix_applied" => false,
    # Set by escalate_to_human/3 after the exec reset applies. While true,
    # DispatchResolver stops without dispatching so a failed Linear state
    # transition (escalate → reset → ticket still In Progress) can't loop
    # the orchestrator into re-running the same work. Cleared on rework
    # entry (human explicitly unblocked).
    "escalated" => false,
    "baseline_verify_failed" => false,
    "baseline_verify_output" => nil,
    "rework_fix_applied" => false,
    "bootstrapped" => false,
    "plan_version" => 0,
    "pending_workpad_mark" => nil,
    "verify_error" => nil,
    "verify_attempt" => 0,
    "verify_fix_count" => 0,
    "merge_conflict" => false,
    "merge_sync_count" => 0,
    "mergeability_unknown_count" => 0,
    "merge_needs_verify" => false,
    "updated_at" => nil
  }

  @doc "Read issue_exec.json from workspace, returning default state if missing."
  @spec read(Path.t()) :: {:ok, map()} | {:error, term()}
  def read(workspace) do
    path = state_path(workspace)

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, state} -> {:ok, Map.merge(@default_state, state)}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:error, :enoent} ->
        {:ok, @default_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Initialize issue_exec.json with default state."
  @spec init(Path.t()) :: :ok | {:error, term()}
  def init(workspace) do
    state = Map.put(@default_state, "updated_at", DateTime.utc_now() |> DateTime.to_iso8601())
    atomic_write(workspace, state)
  end

  @doc "Update specific fields in issue_exec.json atomically."
  @spec update(Path.t(), map()) :: :ok | {:error, term()}
  def update(workspace, changes) when is_map(changes) do
    with {:ok, current} <- read(workspace) do
      updated =
        current
        |> Map.merge(changes)
        |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

      atomic_write(workspace, updated)
    end
  end

  @doc "Record that a unit has started."
  @spec start_unit(Path.t(), map()) :: :ok | {:error, term()}
  def start_unit(workspace, unit) do
    update(workspace, %{
      "current_unit" => unit,
      "phase" => unit_to_phase(unit)
    })
  end

  @doc "Record that the current unit has been accepted."
  @spec accept_unit(Path.t()) :: :ok | {:error, term()}
  def accept_unit(workspace) do
    with {:ok, state} <- read(workspace) do
      update(workspace, %{
        "last_accepted_unit" => state["current_unit"],
        "current_unit" => nil
      })
    end
  end

  @doc "Set the last verified SHA."
  @spec set_verified_sha(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_verified_sha(workspace, sha) do
    update(workspace, %{"last_verified_sha" => sha})
  end

  # --- Warm-session review loop setters ---
  #
  # The four pieces of state below are the orchestrator's view of the
  # implement↔review loop. agent_runner sets thread_ids on first dispatch of
  # each role; code_review closeout writes verdict / bumps round / records
  # last_reviewed_sha. See docs/design/warm-session-review-loop.md.

  @doc "Record the Codex thread_id for the persistent implement session."
  @spec set_implement_thread_id(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_implement_thread_id(workspace, thread_id) when is_binary(thread_id) do
    update(workspace, %{"implement_thread_id" => thread_id})
  end

  @doc "Record the Codex thread_id for the persistent review session."
  @spec set_review_thread_id(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_review_thread_id(workspace, thread_id) when is_binary(thread_id) do
    update(workspace, %{"review_thread_id" => thread_id})
  end

  @doc false
  # Test-only single-field setters. Production (closeout.ex:commit_review_result)
  # writes review_verdict + last_reviewed_sha + review_round as ONE atomic
  # IssueExec.update/2 call so a mid-sequence failure can't leave
  # verdict=findings with last_reviewed_sha=nil (which would disable the
  # HEAD-advance guard in review_findings_implement_rule and livelock the
  # review loop). Do NOT use these setters from production code — use
  # IssueExec.update/2 with a combined map.
  @spec set_review_verdict(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_review_verdict(workspace, verdict)
      when verdict in ["findings", "clean"] do
    update(workspace, %{"review_verdict" => verdict})
  end

  @doc false
  @spec bump_review_round(Path.t()) :: :ok | {:error, term()}
  def bump_review_round(workspace) do
    with {:ok, state} <- read(workspace) do
      update(workspace, %{"review_round" => (state["review_round"] || 0) + 1})
    end
  end

  @doc false
  @spec set_last_reviewed_sha(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_last_reviewed_sha(workspace, sha) when is_binary(sha) do
    update(workspace, %{"last_reviewed_sha" => sha})
  end

  @doc """
  Record the most recent closeout rejection reason so the replay dispatch
  can surface it in the resumed agent's prompt. Overwrites any prior reason
  (the latest rejection is the one the agent must address next turn).
  """
  @spec set_last_retry_reason(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_last_retry_reason(workspace, reason) when is_binary(reason) do
    update(workspace, %{"last_retry_reason" => reason})
  end

  @doc "Clear last_retry_reason — call on accept so a stale reason never leaks into the next dispatch."
  @spec clear_last_retry_reason(Path.t()) :: :ok | {:error, term()}
  def clear_last_retry_reason(workspace) do
    update(workspace, %{"last_retry_reason" => nil})
  end

  @doc "Set the last commit SHA."
  @spec set_commit_sha(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_commit_sha(workspace, sha) do
    update(workspace, %{"last_commit_sha" => sha})
  end

  @doc "Mark bootstrap complete."
  @spec mark_bootstrapped(Path.t()) :: :ok | {:error, term()}
  def mark_bootstrapped(workspace) do
    update(workspace, %{"bootstrapped" => true})
  end

  @doc "Record a baseline verification failure for downstream units."
  @spec set_baseline_verify_failure(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_baseline_verify_failure(workspace, output) when is_binary(output) do
    update(workspace, %{
      "baseline_verify_failed" => true,
      "baseline_verify_output" => output
    })
  end

  @doc "Clear any recorded baseline verification failure."
  @spec clear_baseline_verify_failure(Path.t()) :: :ok | {:error, term()}
  def clear_baseline_verify_failure(workspace) do
    update(workspace, %{
      "baseline_verify_failed" => false,
      "baseline_verify_output" => nil
    })
  end

  @doc """
  Record that a regular plan-N subtask committed code but its Linear workpad
  mark failed. Closeout uses this on the next dispatch to recover the mark
  without requiring HEAD to advance again (the work is already in HEAD).

  Stores both the `subtask_id` and the `committed_sha` at set time. Recovery
  must verify current HEAD equals `committed_sha` before fast-pathing the
  accept — otherwise a stale sentinel that survives a replan / re-emission
  of the same plan-N could accept a new attempt without verifying its commit.
  """
  @spec set_pending_workpad_mark(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def set_pending_workpad_mark(workspace, subtask_id, committed_sha)
      when is_binary(subtask_id) and is_binary(committed_sha) do
    update(workspace, %{
      "pending_workpad_mark" => %{
        "subtask_id" => subtask_id,
        "committed_sha" => committed_sha
      }
    })
  end

  @doc "Clear the pending workpad mark sentinel after a successful retry."
  @spec clear_pending_workpad_mark(Path.t()) :: :ok | {:error, term()}
  def clear_pending_workpad_mark(workspace) do
    update(workspace, %{"pending_workpad_mark" => nil})
  end

  @doc "Bump plan version."
  @spec bump_plan_version(Path.t()) :: :ok | {:error, term()}
  def bump_plan_version(workspace) do
    with {:ok, state} <- read(workspace) do
      update(workspace, %{"plan_version" => (state["plan_version"] || 0) + 1})
    end
  end

  @doc "Set the verify error (verification failed, needs code fix)."
  @spec set_verify_error(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_verify_error(workspace, error) when is_binary(error) do
    update(workspace, %{"verify_error" => error})
  end

  @doc "Clear the verify error (fix applied, ready to re-verify)."
  @spec clear_verify_error(Path.t()) :: :ok | {:error, term()}
  def clear_verify_error(workspace) do
    update(workspace, %{"verify_error" => nil})
  end

  @doc """
  Reset for rework: clear subtask progress, keep bootstrapped.

  Currently has no production caller — `DispatchResolver.rework_reset_rule/1`
  drives a fresh `Unit.plan()` dispatch instead. The function is retained as
  a tested scaffold so when/if the rework flow is wired through it, the field
  list (especially `pending_workpad_mark`) is already correct. Until then,
  the sentinel-clear here is forward-defensive only; the same protection is
  enforced inside `recover_pending_workpad_mark/3` via the HEAD-pin guard.
  """
  @spec reset_for_rework(Path.t()) :: :ok | {:error, term()}
  def reset_for_rework(workspace) do
    update(workspace, rework_reset_updates())
  end

  @doc """
  Single source of truth for the field set cleared on rework entry.
  Consumed by `reset_for_rework/1` AND by `AgentRunner.plan_rework_entry_cleanup/1`;
  any new warm-session field must land here exactly once so the two call
  sites can't drift.
  """
  @spec rework_reset_updates() :: map()
  def rework_reset_updates do
    %{
      "phase" => "planning",
      "current_unit" => nil,
      "last_accepted_unit" => nil,
      "last_verified_sha" => nil,
      # The fresh-cycle flag that `rework_fix_rule` checks. Without resetting
      # this, a second human-triggered rework would skip dispatching rework-1
      # because the flag is still `true` from the prior cycle.
      "rework_fix_applied" => false,
      # Warm-session review loop: rework means a human rejected the PR. The
      # prior implement↔review threads were discussing code that the rework
      # may invalidate; start the next cycle with fresh sessions. Without
      # this, a resumed review thread would carry "clean" context from
      # pre-rework code into a ticket that no longer matches.
      "implement_thread_id" => nil,
      "review_thread_id" => nil,
      "review_verdict" => nil,
      "review_round" => 0,
      "last_reviewed_sha" => nil,
      "last_retry_reason" => nil,
      # Docs-impact pass runs once per cycle — reset here so the next cycle
      # gets to run doc_fix after its own code_review (see dispatch_resolver).
      "doc_fix_applied" => false,
      # Human's rework action IS the unblock signal — clear the escalation
      # sentinel so the new cycle can dispatch normally.
      "escalated" => false,
      "verify_error" => nil,
      "verify_attempt" => 0,
      "verify_fix_count" => 0,
      "merge_conflict" => false,
      "merge_sync_count" => 0,
      "mergeability_unknown_count" => 0,
      "merge_needs_verify" => false,
      # A new rework cycle invalidates any prior plan-N workpad-mark bookkeeping;
      # the new plan may re-emit plan-N with different content, and recovery
      # against a stale sentinel would mark the wrong work done on Linear.
      "pending_workpad_mark" => nil
    }
  end

  # --- Private ---

  defp state_path(workspace) do
    Path.join([workspace, ".symphony", @state_file])
  end

  defp atomic_write(workspace, state) do
    path = state_path(workspace)
    dir = Path.dirname(path)
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(dir),
         {:ok, json} <- Jason.encode(state, pretty: true),
         :ok <- File.write(tmp_path, json),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp unit_to_phase(%{"kind" => "bootstrap"}), do: "bootstrap"
  defp unit_to_phase(%{"kind" => "plan"}), do: "planning"
  defp unit_to_phase(%{"kind" => "implement_subtask"}), do: "implementing"
  defp unit_to_phase(%{"kind" => "doc_fix"}), do: "doc_fix"
  defp unit_to_phase(%{"kind" => "verify"}), do: "verifying"
  defp unit_to_phase(%{"kind" => "code_review"}), do: "code_review"
  defp unit_to_phase(%{"kind" => "handoff"}), do: "handoff"
  defp unit_to_phase(%{"kind" => "merge"}), do: "merging"
  defp unit_to_phase(_), do: "unknown"
end
