defmodule SymphonyElixir.Closeout do
  @moduledoc """
  Post-unit acceptance logic. Called by the orchestrator after a worker
  exits normally. Determines whether the unit is accepted or needs retry.

  Closeout behavior per unit kind:
  - `bootstrap`: check workspace ready, run baseline verify, mark bootstrapped on pass;
    on baseline failure, still accept but record baseline_verify_failed flag + output
    for downstream visibility
  - `plan`: check workpad has parseable checklist, bump plan_version
  - `implement_subtask`: check subtask marked done, doc-impact check
  - `doc_fix`: clear doc_fix_required flag
  - `verify`: run full verification, set last_verified_sha
  - `handoff`: check last_verified_sha == HEAD
  - `merge`: check PR actually merged on remote before marking done
  """

  require Logger

  alias SymphonyElixir.{Config, IssueExec, Ledger, Linear.Adapter, Verifier}

  @type result :: :accepted | {:retry, String.t()} | {:fail, String.t()}

  @doc """
  Run closeout for a completed unit. Returns :accepted, {:retry, reason}, or {:fail, reason}.
  """
  @spec run(Path.t(), map(), map(), keyword()) :: result()
  def run(workspace, unit, issue, opts \\ []) do
    kind = unit["kind"] || to_string(unit[:kind])
    do_closeout(kind, workspace, unit, issue, opts)
  end

  # --- Per-unit closeout ---

  defp do_closeout("bootstrap", workspace, _unit, _issue, _opts) do
    # Run baseline verification if commands are configured
    case Verifier.run_baseline(workspace) do
      :pass ->
        IssueExec.clear_baseline_verify_failure(workspace)
        IssueExec.mark_bootstrapped(workspace)
        Ledger.append(workspace, :baseline_verified, %{})
        :accepted

      {:fail, output} ->
        truncated_output = truncate(output, 2048)
        Logger.warning("Closeout: baseline verification failed")
        IssueExec.set_baseline_verify_failure(workspace, truncated_output)
        Ledger.append(workspace, :baseline_verify_failed, %{"output" => truncated_output})
        Ledger.append(workspace, :baseline_accepted_despite_failure, %{"output" => truncated_output})
        :accepted
    end
  end

  defp do_closeout("plan", workspace, _unit, _issue, _opts) do
    # Plan acceptance: agent wrote the plan to Linear workpad. We can't verify
    # the workpad content here (it's on Linear, not local). Instead, we accept
    # the plan unit and let DispatchResolver verify the checklist is parseable
    # on the NEXT dispatch cycle (when workpad text will be fetched from Linear).
    # If the checklist isn't parseable, resolver will re-dispatch :plan.
    IssueExec.bump_plan_version(workspace)
    :accepted
  end

  defp do_closeout("implement_subtask", workspace, unit, issue, opts) do
    subtask_id = unit["subtask_id"]

    cond do
      is_binary(subtask_id) and String.starts_with?(subtask_id, "rework-") ->
        handle_rework_closeout(workspace, subtask_id, issue, opts)

      is_binary(subtask_id) and String.starts_with?(subtask_id, "verify-fix-") ->
        handle_verify_fix_closeout(workspace, subtask_id, issue, opts)

      true ->
        accept_implement_subtask(workspace, subtask_id, issue)
    end
  end

  defp do_closeout("doc_fix", workspace, _unit, _issue, _opts) do
    IssueExec.clear_doc_fix_required(workspace)
    :accepted
  end

  defp do_closeout("verify", workspace, _unit, issue, opts) do
    max_verify_attempts = Config.max_verify_attempts()
    max_verify_fix_cycles = Config.max_verify_fix_cycles()

    # Use persistent attempt counter that survives verify-fix cycles.
    # The unit's "attempt" field tracks crash-replays; this tracks
    # verification runs across fix cycles.
    {:ok, exec} = IssueExec.read(workspace)
    attempt = (exec["verify_attempt"] || 0) + 1
    IssueExec.update(workspace, %{"verify_attempt" => attempt})

    verify_opts = if cmds = Keyword.get(opts, :verify_commands), do: [commands: cmds], else: []

    case Verifier.run(workspace, verify_opts) do
      :pass ->
        head = Verifier.current_head(workspace)

        if head do
          IssueExec.set_verified_sha(workspace, head)
          Ledger.verify_passed(workspace, head)
        end

        # Reset all verify counters on success
        IssueExec.update(workspace, %{
          "verify_attempt" => 0,
          "verify_error" => nil,
          "verify_fix_count" => 0,
          "merge_needs_verify" => false
        })

        :accepted

      {:fail, output} when attempt >= max_verify_attempts ->
        # Escalate — exhausted all attempts including verify-fix cycles.
        Logger.warning("Closeout: verify exhausted #{attempt} attempts, failing")

        Ledger.append(workspace, :verify_exhausted, %{
          "attempt" => attempt,
          "last_error" => truncate(output, 512)
        })

        issue_id = issue_id(issue)

        if is_binary(issue_id) do
          Adapter.create_comment(
            issue_id,
            "**Verification failed**: exhausted #{attempt} attempts.\nLast error: #{truncate(output, 256)}\n\nEscalating — code will NOT proceed to handoff."
          )
        end

        # Clear verify_error but keep current_unit set so replay_current_unit_rule
        # increments the attempt and triggers circuit_breaker → escalation.
        IssueExec.update(workspace, %{"verify_error" => nil})
        {:fail, "Verification exhausted #{attempt} attempts: #{truncate(output, 512)}"}

      {:fail, output} ->
        # Dispatch verify-fix if we haven't exhausted fix cycles.
        # After max_verify_fix_cycles, fall back to plain retry → exhaust.
        {:ok, exec_state} = IssueExec.read(workspace)
        fix_count = exec_state["verify_fix_count"] || 0

        if fix_count < max_verify_fix_cycles do
          truncated_error = truncate(output, 1500)
          IssueExec.set_verify_error(workspace, truncated_error)

          IssueExec.update(workspace, %{
            "current_unit" => nil,
            "verify_fix_count" => fix_count + 1
          })

          Ledger.append(workspace, :verify_failed_will_fix, %{
            "attempt" => attempt,
            "fix_cycle" => fix_count + 1,
            "error" => truncate(output, 512)
          })

          {:retry, "Verification failed (verify-fix ##{fix_count + 1} will be dispatched): #{truncate(output, 1024)}"}
        else
          # No more fix cycles — plain retry, will exhaust on next attempt
          {:retry, "Verification failed (fix cycles exhausted): #{truncate(output, 1024)}"}
        end
    end
  end

  defp do_closeout("handoff", workspace, _unit, _issue, _opts) do
    case IssueExec.read(workspace) do
      {:ok, exec} ->
        head = Verifier.current_head(workspace)

        if exec["last_verified_sha"] == head and head != nil do
          :accepted
        else
          {:fail, "Handoff rejected: last_verified_sha (#{exec["last_verified_sha"]}) != HEAD (#{head})"}
        end

      {:error, reason} ->
        {:fail, "Handoff rejected: cannot read exec state: #{inspect(reason)}"}
    end
  end

  defp do_closeout("merge", workspace, _unit, _issue, opts) do
    checker = Keyword.get(opts, :merge_checker, &Verifier.check_pr_merged/1)

    case checker.(workspace) do
      :merged ->
        IssueExec.update(workspace, %{
          "phase" => "done",
          "merge_conflict" => false,
          "merge_sync_count" => 0,
          "mergeability_unknown_count" => 0,
          "merge_needs_verify" => false
        })

        :accepted

      {:not_merged, reason} ->
        Logger.warning("Closeout: merge not confirmed: #{reason}")
        {:retry, "PR not merged: #{reason}"}

      :unknown ->
        Logger.warning("Closeout: cannot verify PR merge status, retrying")
        Ledger.append(workspace, :merge_status_unknown, %{})
        {:retry, "merge status unverified"}
    end
  end

  defp do_closeout(kind, _workspace, _unit, _issue, _opts) do
    Logger.warning("Closeout: unknown unit kind #{kind}")
    {:fail, "unknown unit kind: #{kind}"}
  end

  # --- Helpers ---

  # Rework acceptance requires THREE structural conditions. All three are
  # orchestrator-observable (no agent self-report) and fail closed to {:retry, _}
  # so the existing replay_current_unit_rule + @max_unit_attempts circuit
  # breaker handle eventual escalation.
  #
  #   1. Linear API fetch succeeded at dispatch time. Otherwise the agent ran
  #      with no <ticket_comments> block at all.
  #   2. At least one review comment (i.e., a comment other than Symphony's
  #      own Codex Workpad) was present in the fetched set. Otherwise filtering
  #      leaves the agent effectively blind even though the fetch succeeded.
  #   3. git HEAD advanced since dispatch (agent produced at least one commit).
  #
  # Both (1) and (2) are computed upstream in
  # `agent_runner.enrich_opts_for_commit_guarded_subtask` (which delegates to
  # the rework-specific enricher) and passed through the closeout opts. They
  # are split into two flags so the ledger's retry reason stays diagnostically
  # useful.
  defp handle_rework_closeout(workspace, subtask_id, issue, opts) do
    cond do
      Keyword.get(opts, :linear_fetch_ok, true) == false ->
        Logger.warning("Closeout: rework #{subtask_id} dispatched without fresh Linear comments — will retry")

        {:retry, "rework #{subtask_id}: linear comment fetch failed at dispatch"}

      Keyword.get(opts, :rework_has_review_context, true) == false ->
        Logger.warning("Closeout: rework #{subtask_id} had no review context (only workpad or empty) — will retry")

        {:retry, "rework #{subtask_id}: no review context in Linear comments"}

      true ->
        case commit_advancement_state(workspace, opts) do
          :unchanged ->
            Logger.warning("Closeout: rework #{subtask_id} produced no commit (head unchanged since dispatch)")

            {:retry, "rework #{subtask_id}: produced no commit"}

          :cannot_verify ->
            Logger.warning("Closeout: rework #{subtask_id} cannot verify HEAD state (git lookup returned nil)")

            {:retry, "rework #{subtask_id}: cannot verify HEAD state"}

          :advanced ->
            accept_implement_subtask(workspace, subtask_id, issue)
        end
    end
  end

  # Verify-fix acceptance requires the agent to have advanced HEAD. Without
  # this guard, a unit where the agent edited files but never committed (an
  # observed Codex failure mode) is silently accepted at the stale SHA; the
  # next `verify` sees the same broken code, fails identically, and Symphony
  # burns attempts until the circuit breaker trips — losing the uncommitted
  # WIP in the process. Parallel to the zero-commit guard on rework-*.
  defp handle_verify_fix_closeout(workspace, subtask_id, issue, opts) do
    case commit_advancement_state(workspace, opts) do
      :unchanged ->
        Logger.warning(
          "Closeout: verify-fix #{subtask_id} produced no commit (HEAD unchanged since dispatch) — " <>
            "fix edits may be sitting as uncommitted WIP"
        )

        {:retry, "verify-fix #{subtask_id}: produced no commit (edits likely uncommitted WIP)"}

      :cannot_verify ->
        Logger.warning("Closeout: verify-fix #{subtask_id} cannot verify HEAD state (git lookup returned nil)")

        {:retry, "verify-fix #{subtask_id}: cannot verify HEAD state"}

      :advanced ->
        accept_implement_subtask(workspace, subtask_id, issue)
    end
  end

  defp accept_implement_subtask(workspace, subtask_id, issue) do
    # 1. Mark subtask done on Linear workpad (orchestrator-owned, no agent compliance needed)
    if subtask_id && issue_id(issue) do
      case Adapter.mark_subtask_done(issue_id(issue), subtask_id) do
        :ok ->
          Logger.info("Closeout: marked #{subtask_id} done on Linear workpad")

        {:error, reason} ->
          Logger.warning("Closeout: failed to mark #{subtask_id} on workpad: #{inspect(reason)}")
      end
    end

    # 1b. Set rework_fix_applied flag for rework-* subtasks
    if is_binary(subtask_id) and String.starts_with?(subtask_id, "rework-") do
      IssueExec.update(workspace, %{"rework_fix_applied" => true})
    end

    # 1c. Clear verify_error and reset verify_attempt for verify-fix-* subtasks.
    # Resetting the attempt gives verify a fresh shot after the fix — the
    # circuit breaker on verify-fix crashes (via replay) prevents infinite loops.
    if is_binary(subtask_id) and String.starts_with?(subtask_id, "verify-fix-") do
      IssueExec.update(workspace, %{"verify_error" => nil, "verify_attempt" => 0})
    end

    # 1d. Clear merge_conflict for merge-sync-* subtasks.
    # Set merge_needs_verify so the orchestrator re-verifies the merge commit
    # before programmatic merge retries.
    if is_binary(subtask_id) and String.starts_with?(subtask_id, "merge-sync-") do
      IssueExec.update(workspace, %{
        "merge_conflict" => false,
        "merge_needs_verify" => true
      })
    end

    # 2. Doc impact check deferred — runs once before verify, not after every subtask.
    # This avoids N×doc_fix sessions for N subtasks (was burning ~1.5M tokens each).
    :accepted
  end

  # Returns :advanced (HEAD moved since dispatch) | :unchanged (same sha)
  # | :cannot_verify (either current HEAD or dispatch_head is missing).
  # The caller uses :cannot_verify to fail-closed (retry) so transient git
  # lookup failures cannot silently disable the zero-commit guard.
  #
  # Used by both rework-* and verify-fix-* subtasks — both require a
  # dispatch_head snapshot captured upstream in agent_runner.
  defp commit_advancement_state(workspace, opts) do
    case {Verifier.current_head(workspace), Keyword.get(opts, :dispatch_head)} do
      {head, dispatch} when is_binary(head) and is_binary(dispatch) ->
        if head == dispatch, do: :unchanged, else: :advanced

      _ ->
        :cannot_verify
    end
  end

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "..."
  end

  defp truncate(text, max), do: truncate(IO.iodata_to_binary(text), max)

  defp issue_id(%{id: id}) when is_binary(id), do: id
  defp issue_id(%{"id" => id}) when is_binary(id), do: id
  defp issue_id(_), do: nil
end
