defmodule SymphonyElixir.Closeout do
  @moduledoc """
  Post-unit acceptance logic. Called by the orchestrator after a worker
  exits normally. Determines whether the unit is accepted or needs retry.

  Closeout behavior per unit kind:
  - `bootstrap`: run baseline verify; mark bootstrapped either way so the
    dispatcher advances past bootstrap_rule. Baseline pass/fail is carried
    separately by `baseline_verify_failed` / `baseline_verify_output` fields
    in `issue_exec.json`; downstream units can consume that signal.
  - `plan`: check workpad has parseable checklist, bump plan_version
  - `implement_subtask`: check subtask marked done, doc-impact check
  - `doc_fix`: mandatory pre-verify documentation pass; accept clean no-op
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
        # Mark bootstrapped even on baseline failure. Without this, the
        # dispatcher's bootstrap_rule (matches on bootstrapped==false) keeps
        # re-firing forever on an :accepted unit that clears current_unit,
        # with no circuit-breaker escape. The baseline state lives in
        # baseline_verify_failed / baseline_verify_output; downstream units
        # read those to decide whether to fix the baseline before their own work.
        IssueExec.mark_bootstrapped(workspace)
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
        # Regular plan-N and merge-sync-* — require HEAD advance so uncommitted
        # work isn't silently destroyed by the next dispatch's workspace reset.
        # Parallel to the rework / verify-fix guards.
        #
        # First check pending_workpad_mark: if a prior attempt committed the work
        # but its Linear mark failed, the new dispatch's dispatch_head is the
        # post-commit HEAD and the agent will produce no further commit. Without
        # this fast-path, the :unchanged guard would loop to the circuit breaker
        # without ever retrying the mark.
        case recover_pending_workpad_mark(workspace, subtask_id, issue) do
          :recovered ->
            post_accept_implement_subtask(workspace, subtask_id)

          {:still_pending, reason} ->
            {:retry, reason}

          :no_pending ->
            case commit_advancement_state(workspace, opts) do
              :advanced ->
                accept_implement_subtask(workspace, subtask_id, issue)

              :unchanged ->
                Logger.warning("Closeout: implement_subtask #{subtask_id || "(nil)"} produced no commit (HEAD unchanged since dispatch) — fix edits may be sitting as uncommitted WIP")

                {:retry, "implement_subtask #{subtask_id || "(nil)"}: produced no commit (edits likely uncommitted WIP)"}

              :cannot_verify ->
                Logger.warning("Closeout: implement_subtask #{subtask_id || "(nil)"} cannot verify HEAD state (git lookup returned nil)")

                {:retry, "implement_subtask #{subtask_id || "(nil)"}: cannot verify HEAD state"}
            end
        end
    end
  end

  defp do_closeout("doc_fix", workspace, _unit, _issue, opts) do
    # doc_fix differs from other mutation-bearing units: DispatchResolver
    # dispatches it unconditionally before verify, and the prompt asks the
    # agent to "update any docs that no longer match" — an empty outcome
    # is legitimate when docs are already accurate. A strict HEAD-advance
    # guard would retry every no-op until the circuit breaker fires, which
    # is the same failure mode the bootstrap soft-accept fix eliminated.
    #
    # Instead: differentiate "forgot to commit" (dirty tree, HEAD unchanged
    # → data-loss risk, retry) from "nothing to do" (clean tree, HEAD
    # unchanged → acceptable no-op).
    case commit_advancement_state(workspace, opts) do
      :advanced ->
        :accepted

      :unchanged ->
        case Verifier.dirty_working_tree?(workspace) do
          true ->
            Logger.warning("Closeout: doc_fix HEAD unchanged but tree is dirty — edits likely uncommitted WIP")

            {:retry, "doc_fix: produced no commit but tree is dirty (edits likely uncommitted WIP)"}

          false ->
            Logger.info("Closeout: doc_fix accepted as no-op (clean tree, no doc updates needed)")
            :accepted
        end

      :cannot_verify ->
        Logger.warning("Closeout: doc_fix cannot verify HEAD state (git lookup returned nil)")

        {:retry, "doc_fix: cannot verify HEAD state"}
    end
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

        # Reset all verify counters on success. Also clear any baseline
        # failure flag/output: a passing full-verify implies the baseline
        # red state from bootstrap is now repaired (or wasn't truly red).
        # Without this, the flag becomes stale historical telemetry that
        # could mislead future readers (e.g., a planner prompt added later
        # that thinks the baseline is currently broken).
        IssueExec.clear_baseline_verify_failure(workspace)

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
    # 1. Mark subtask done on Linear workpad (orchestrator-owned, no agent
    # compliance needed). If this fails, retry the unit so the next dispatch
    # gets another chance to sync — accepting locally would split-brain
    # the workpad (Linear shows `[ ] [plan-N]`) from the code (already
    # committed). Next dispatch would then re-derive plan-N as still pending,
    # re-send the agent who has nothing to do, no commit advance, retry loop
    # to circuit breaker. A few replay attempts via the circuit breaker is
    # cheap; permanent split-brain is the failure mode we're avoiding.
    #
    # We only treat the marker call as fatal for "regular" plan-N subtasks
    # whose dispatch is derived from the workpad checklist. The synthetic
    # subtask kinds (rework-* / verify-fix-* / merge-sync-*) are not
    # dispatched from the checklist, so their workpad mark is bookkeeping
    # only and a failure does not create the same split-brain.
    case maybe_mark_subtask_done(subtask_id, issue) do
      :ok ->
        post_accept_implement_subtask(workspace, subtask_id)

      {:retry, reason} ->
        # The work is committed but the workpad mark failed. Persist a
        # sentinel so the next closeout entry can retry the mark without
        # requiring HEAD to advance again (no further commit is coming).
        if regular_plan_subtask?(subtask_id) do
          IssueExec.set_pending_workpad_mark(workspace, subtask_id)
        end

        {:retry, reason}
    end
  end

  # Fast-path: if a previous closeout already committed the work and only the
  # Linear mark failed, retry the mark here. No HEAD advance is required.
  # Returns :recovered (mark succeeded; caller should run post-accept),
  # {:still_pending, reason} (mark still failing; caller should retry the unit),
  # or :no_pending (no recovery applies; caller should run normal flow).
  defp recover_pending_workpad_mark(workspace, subtask_id, issue) do
    with true <- regular_plan_subtask?(subtask_id),
         {:ok, exec} <- IssueExec.read(workspace),
         pending when is_binary(pending) <- exec["pending_workpad_mark"],
         true <- pending == subtask_id,
         issue_id when is_binary(issue_id) <- issue_id(issue) do
      case Adapter.mark_subtask_done(issue_id, subtask_id) do
        :ok ->
          IssueExec.clear_pending_workpad_mark(workspace)
          Logger.info("Closeout: recovered pending Linear workpad mark for #{subtask_id}")
          :recovered

        {:error, reason} ->
          Logger.warning("Closeout: pending workpad mark for #{subtask_id} still failing: #{inspect(reason)}")

          {:still_pending, "implement_subtask #{subtask_id}: workpad sync still failing (#{inspect(reason)})"}
      end
    else
      _ -> :no_pending
    end
  end

  defp maybe_mark_subtask_done(subtask_id, issue) do
    cond do
      not (is_binary(subtask_id) and is_binary(issue_id(issue))) ->
        :ok

      not regular_plan_subtask?(subtask_id) ->
        # Best-effort for non-plan subtasks: log warning, do not fail closeout.
        case Adapter.mark_subtask_done(issue_id(issue), subtask_id) do
          :ok ->
            Logger.info("Closeout: marked #{subtask_id} done on Linear workpad")
            :ok

          {:error, reason} ->
            Logger.warning("Closeout: failed to mark non-plan #{subtask_id} on workpad: #{inspect(reason)} (continuing — next dispatch is not derived from this checkbox)")

            :ok
        end

      true ->
        # Regular plan-N: must succeed before local accept, else split-brain.
        case Adapter.mark_subtask_done(issue_id(issue), subtask_id) do
          :ok ->
            Logger.info("Closeout: marked #{subtask_id} done on Linear workpad")
            :ok

          {:error, reason} ->
            Logger.warning("Closeout: Linear workpad mark failed for #{subtask_id} (#{inspect(reason)}); returning {:retry,_} to avoid workpad/code split-brain")

            {:retry, "implement_subtask #{subtask_id}: workpad sync failed (#{inspect(reason)})"}
        end
    end
  end

  # Whitelist on the workpad-derived "plan-N" prefix: every subtask Linear
  # actually owns a checkbox for matches `plan-<integer>`. Any other shape
  # (synthetic kinds rework-/verify-fix-/merge-sync-, future variants, empty
  # strings, whitespace) is NOT a plan-N, so a Linear-mark failure is at most
  # bookkeeping noise and must not promote to a unit retry — that would
  # circuit-break a synthetic dispatch over a checkbox the workpad never had.
  defp regular_plan_subtask?(subtask_id) when is_binary(subtask_id) do
    Regex.match?(~r/^plan-\d+$/, subtask_id)
  end

  defp regular_plan_subtask?(_), do: false

  defp post_accept_implement_subtask(workspace, subtask_id) do
    # 1a. Clear any pending workpad mark sentinel — by reaching post-accept the
    # workpad is in sync (either via normal flow or recovered via fast-path).
    IssueExec.clear_pending_workpad_mark(workspace)

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

    :accepted
  end

  # Returns :advanced (HEAD moved since dispatch) | :unchanged (same sha)
  # | :cannot_verify (either current HEAD or dispatch_head is missing).
  # The caller uses :cannot_verify to fail-closed (retry) so transient git
  # lookup failures cannot silently disable the zero-commit guard.
  #
  # Used by every mutation-bearing unit — rework-*, verify-fix-*, regular
  # plan-N / merge-sync-* implement_subtask, and doc_fix. All require a
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
