defmodule SymphonyElixir.DispatchResolver do
  @moduledoc """
  Determines the next unit to dispatch for an issue in unit-lite mode.

  Input: issue state + issue_exec state + parsed workpad + git HEAD
  Output: {:dispatch, Unit.t()} | {:stop, reason} | :skip

  Rules are ordered — first match wins.
  """

  alias SymphonyElixir.{Unit, WorkpadParser}

  @type resolve_context :: %{
          issue: map(),
          exec: map(),
          workpad_text: String.t() | nil,
          git_head: String.t() | nil
        }

  @type result :: {:dispatch, Unit.t()} | {:stop, atom()} | :skip

  @doc """
  Resolve the next unit to dispatch.

  The context map must contain:
  - `issue` — Linear issue (at minimum `%{state: "..."}`)
  - `exec` — current issue_exec.json state
  - `workpad_text` — raw workpad comment text (or nil)
  - `git_head` — current HEAD SHA (or nil)
  """
  @spec resolve(resolve_context()) :: result()
  def resolve(%{issue: issue} = ctx) do
    rules(flow(issue))
    |> Enum.find_value(fn rule -> rule.(ctx) end) ||
      {:stop, :no_matching_rule}
  end

  # --- Flow routing ---

  defp flow(%{state: state}) when is_binary(state) do
    case String.downcase(String.trim(state)) do
      "merging" -> :merging
      "rework" -> :rework
      _ -> :normal
    end
  end

  defp flow(_), do: :normal

  # --- Rule tables ---

  defp rules(:merging),
    do: [
      &replay_current_unit_rule/1,
      &verify_fix_rule/1,
      &merge_sync_rule/1,
      &merge_verify_rule/1,
      &merge_rule/1,
      &merge_done_rule/1
    ]

  defp rules(:rework),
    do: [
      &replay_current_unit_rule/1,
      &rework_fix_rule/1,
      &rework_reset_rule/1,
      &plan_rule/1,
      &implement_subtask_rule/1,
      &pre_verify_doc_check_rule/1,
      &verify_fix_rule/1,
      &verify_rule/1,
      &handoff_rule/1,
      &done_rule/1
    ]

  defp rules(:normal),
    do: [
      &replay_current_unit_rule/1,
      &done_rule/1,
      &bootstrap_rule/1,
      &plan_rule/1,
      &implement_subtask_rule/1,
      &pre_verify_doc_check_rule/1,
      &verify_fix_rule/1,
      &verify_rule/1,
      &handoff_rule/1
    ]

  # --- Rule implementations ---

  # If current_unit exists and was not accepted, replay it (crash recovery).
  # Circuit breaker: after Config.max_unit_attempts() consecutive crashes, stop
  # and escalate to human instead of burning tokens forever.
  @valid_unit_kinds ~w(bootstrap plan implement_subtask doc_fix verify handoff merge)
  @kind_atoms %{
    "bootstrap" => :bootstrap,
    "plan" => :plan,
    "implement_subtask" => :implement_subtask,
    "doc_fix" => :doc_fix,
    "verify" => :verify,
    "handoff" => :handoff,
    "merge" => :merge
  }

  defp replay_current_unit_rule(%{exec: %{"current_unit" => unit} = exec}) when not is_nil(unit) do
    kind_str = unit["kind"]
    attempt = (unit["attempt"] || 1) + 1

    cond do
      kind_str not in @valid_unit_kinds ->
        # Corrupted exec file — clear current_unit and let normal rules take over
        nil

      # Skip replay for verify when verify_error is set — let verify_fix_rule handle it
      kind_str == "verify" and is_binary(exec["verify_error"]) ->
        nil

      attempt > SymphonyElixir.Config.max_unit_attempts() ->
        # Circuit breaker: too many consecutive crashes on this unit
        {:stop, :circuit_breaker}

      true ->
        kind = Map.fetch!(@kind_atoms, kind_str)
        subtask_id = unit["subtask_id"]

        base_unit =
          case {kind, subtask_id} do
            {:implement_subtask, id} -> Unit.implement_subtask(id, replay_subtask_text(id, exec))
            {:bootstrap, _} -> Unit.bootstrap()
            {:plan, _} -> Unit.plan()
            {:doc_fix, _} -> Unit.doc_fix()
            {:verify, _} -> Unit.verify()
            {:handoff, _} -> Unit.handoff()
            {:merge, _} -> Unit.merge()
          end

        {:dispatch, %{base_unit | display_name: "replay:#{kind_str}#{if subtask_id, do: ":#{subtask_id}", else: ""}", attempt: attempt}}
    end
  end

  defp replay_current_unit_rule(_), do: nil

  # On replay, `Unit.to_map/1` does not persist `subtask_text`, so a
  # naive rebuild loses the dispatch-time payload. For verify-fix-* that
  # payload is the verify error output — without it the prompt shows
  # "(no error output captured)" and the agent retries blind. Re-inject
  # from the canonical source (`exec.verify_error`) when we're rebuilding
  # a verify-fix unit.
  defp replay_subtask_text(id, exec)
       when is_binary(id) do
    cond do
      String.starts_with?(id, "verify-fix-") and is_binary(exec["verify_error"]) ->
        exec["verify_error"]

      true ->
        nil
    end
  end

  defp replay_subtask_text(_id, _exec), do: nil

  # Merging flow: dispatch merge-sync when the PR has conflicts against main.
  # agent_runner.handle_merge_conflict sets merge_conflict=true and clears
  # current_unit when gh reports CONFLICTING mergeability; this rule then
  # dispatches an implement_subtask so the agent resolves it in-workspace.
  defp merge_sync_rule(%{exec: %{"merge_conflict" => true}}) do
    {:dispatch, Unit.implement_subtask("merge-sync-1", "Resolve merge conflicts against origin/main, then push.")}
  end

  defp merge_sync_rule(_), do: nil

  # After merge-sync closeout, merge_needs_verify=true signals that the merge
  # commit should be re-verified (full test suite) before the orchestrator
  # retries the programmatic merge.
  defp merge_verify_rule(%{exec: %{"merge_needs_verify" => true}}) do
    {:dispatch, Unit.verify()}
  end

  defp merge_verify_rule(_), do: nil

  # Merging flow: dispatch merge
  defp merge_rule(%{exec: exec}) do
    if exec["phase"] != "done" do
      {:dispatch, Unit.merge()}
    end
  end

  defp merge_done_rule(_), do: {:stop, :merge_complete}

  # Rework fast-path: if the workpad checklist is complete (all items done),
  # skip re-plan and go straight to fixing the review findings.
  # This saves the full exploration + planning overhead — the agent just reads
  # PR review comments and applies targeted fixes.
  defp rework_fix_rule(%{workpad_text: workpad_text, exec: exec}) do
    # Don't fire if rework fix was already applied this cycle.
    # Uses a persistent flag because last_accepted_unit gets overwritten
    # by subsequent doc_fix/verify units.
    if exec["rework_fix_applied"] do
      nil
    else
      if WorkpadParser.all_done?(workpad_text) do
        {:dispatch, Unit.implement_subtask("rework-1", "Fix review findings from PR comments")}
      end
    end
  end

  # Rework fallback: if workpad checklist is incomplete or missing, re-plan.
  # Skip if rework fix was already applied this cycle (the fix → doc_fix → verify
  # sequence should proceed without re-planning).
  defp rework_reset_rule(%{exec: %{"rework_fix_applied" => true}}), do: nil

  defp rework_reset_rule(%{exec: %{"last_accepted_unit" => %{"kind" => kind}}})
       when kind in ["handoff", "verify", "merge"] do
    {:dispatch, Unit.plan()}
  end

  defp rework_reset_rule(%{exec: %{"phase" => phase}})
       when phase in ["handoff", "verifying", "merging", "bootstrap"] do
    {:dispatch, Unit.plan()}
  end

  defp rework_reset_rule(_), do: nil

  # Bootstrap: not yet bootstrapped
  defp bootstrap_rule(%{exec: %{"bootstrapped" => false}}) do
    {:dispatch, Unit.bootstrap()}
  end

  defp bootstrap_rule(_), do: nil

  # Plan: no parseable checklist
  defp plan_rule(%{workpad_text: workpad_text}) do
    case parse_workpad(workpad_text) do
      {:error, _} -> {:dispatch, Unit.plan()}
      {:ok, _} -> nil
    end
  end

  # Implement subtask: next unchecked item
  defp implement_subtask_rule(%{workpad_text: workpad_text}) do
    case WorkpadParser.next_pending(workpad_text) do
      %{id: id, text: text} ->
        {:dispatch, Unit.implement_subtask(id, text)}

      nil ->
        nil
    end
  end

  # Pre-verify doc sweep: dispatch doc_fix exactly once, after all subtasks
  # are checked off, before verify runs. doc_fix is a mandatory pre-verify
  # documentation pass — the orchestrator does not try to predict whether
  # docs are stale (a previous DocImpact heuristic was removed because its
  # path-pattern signal had a near-100% false-positive rate, so plugging it
  # in produced behavior identical to "always dispatch doc_fix once").
  # The agent decides what (if anything) to update; closeout accepts a clean
  # no-op as a legitimate outcome.
  defp pre_verify_doc_check_rule(%{workpad_text: workpad_text, exec: exec, git_head: git_head})
       when is_binary(git_head) do
    if WorkpadParser.all_done?(workpad_text) do
      maybe_dispatch_doc_fix({:dispatch, Unit.doc_fix()}, exec)
    end
  end

  defp pre_verify_doc_check_rule(_), do: nil

  # Only dispatch doc_fix once — skip if we're already past the doc_fix point.
  # After doc_fix/verify/handoff/verify-fix accepted, don't re-dispatch doc_fix.
  defp maybe_dispatch_doc_fix(dispatch, exec) do
    last = exec["last_accepted_unit"]

    skip? =
      is_map(last) and
        (last["kind"] in ["doc_fix", "verify", "handoff"] or
           (is_binary(last["subtask_id"]) and String.starts_with?(last["subtask_id"], "verify-fix-")))

    if skip?, do: nil, else: dispatch
  end

  # Verify fix: if verify_error is set, dispatch implement_subtask to fix the code
  # rather than blindly retrying verify against the same broken code.
  defp verify_fix_rule(%{exec: %{"verify_error" => error}}) when is_binary(error) do
    {:dispatch, Unit.implement_subtask("verify-fix-1", error)}
  end

  defp verify_fix_rule(_), do: nil

  # Verify: all subtasks done but last_verified_sha != HEAD.
  # Max retry is enforced in Closeout (fails after 3 attempts → circuit breaker escalates).
  defp verify_rule(%{workpad_text: workpad_text, exec: exec, git_head: git_head}) do
    all_done = WorkpadParser.all_done?(workpad_text)
    verified = exec["last_verified_sha"]

    if all_done and git_head != nil and verified != git_head do
      {:dispatch, Unit.verify()}
    end
  end

  # Handoff: verified and all done
  defp handoff_rule(%{workpad_text: workpad_text, exec: exec, git_head: git_head}) do
    all_done = WorkpadParser.all_done?(workpad_text)
    verified = exec["last_verified_sha"]

    if all_done and git_head != nil and verified == git_head do
      {:dispatch, Unit.handoff()}
    end
  end

  # Done: handoff was the last accepted unit
  defp done_rule(%{exec: %{"last_accepted_unit" => %{"kind" => "handoff"}}}) do
    {:stop, :all_complete}
  end

  defp done_rule(_), do: nil

  # --- Helpers ---

  defp parse_workpad(nil), do: {:error, :no_workpad}
  defp parse_workpad(text), do: WorkpadParser.parse(text)
end
