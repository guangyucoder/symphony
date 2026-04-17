defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Closeout, Config, DispatchResolver, IssueExec, Ledger, Linear.Adapter, Linear.Issue, PromptBuilder, Unit, UnitLog, Verifier, WorkpadParser, Workspace}

  @doc """
  Unit-lite mode: resolve the next unit, run a single fresh Codex session for it,
  then exit. The orchestrator will re-dispatch for the next unit.
  """
  @spec run_unit_lite(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run_unit_lite(issue, codex_update_recipient \\ nil, opts \\ []) do
    case Workspace.create_for_issue_with_status(issue) do
      {:ok, workspace, created?} ->
        with :ok <- maybe_prepare_workspace_for_dispatch(workspace, issue, created?),
             :ok <- Workspace.ensure_symphony_dir(workspace),
             :ok <- run_unit_lite_in_workspace(workspace, issue, codex_update_recipient, opts) do
          :ok
        else
          {:error, reason} ->
            Logger.error("unit_lite: run failed for #{issue_context(issue)}: #{inspect(reason)}")
            raise RuntimeError, "unit_lite run failed: #{inspect(reason)}"
        end

      {:error, reason} ->
        Logger.error("unit_lite: workspace creation failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "unit_lite workspace failed: #{inspect(reason)}"
    end
  end

  defp maybe_prepare_workspace_for_dispatch(workspace, issue, false) do
    Workspace.prepare_for_dispatch(workspace, issue)
  end

  defp maybe_prepare_workspace_for_dispatch(_workspace, _issue, true), do: :ok

  defp run_unit_lite_in_workspace(workspace, issue, codex_update_recipient, opts) do
    # 1. Initialize issue_exec if needed
    case IssueExec.read(workspace) do
      {:ok, %{"mode" => "unit_lite"}} -> :ok
      {:ok, _} -> IssueExec.init(workspace)
      {:error, _} -> IssueExec.init(workspace)
    end

    # 1b. Clear stale exec state when entering Rework.
    # The previous cycle may have left current_unit set (e.g., "handoff" was
    # in-flight when the issue moved to Rework). We clear it so DispatchResolver
    # sees a clean state. Also invalidate last_verified_sha so verify is
    # required after fixes.
    issue_state = issue_state_string(issue)

    if issue_state == "rework" do
      case IssueExec.read(workspace) do
        {:ok, exec_check} when is_map(exec_check) ->
          case plan_rework_entry_cleanup(exec_check) do
            %{action: :none} ->
              :ok

            %{updates: updates} when map_size(updates) > 0 ->
              IssueExec.update(workspace, updates)
          end

        _ ->
          Logger.warning("unit_lite: could not read exec for rework cleanup, skipping")
      end
    end

    # 1c. Clear stale non-merge current_unit when entering Merging state.
    # If a handoff/verify unit was in-flight when the issue was manually moved
    # to Merging, replaying it would be wrong (e.g., handoff could move the
    # ticket back to Human Review). Only merge units, in-flight merge-sync-*
    # subtasks, and verify runs covering merge-sync commits should replay.
    if issue_state == "merging" do
      case IssueExec.read(workspace) do
        {:ok, exec_check} when is_map(exec_check) ->
          current = exec_check["current_unit"]
          merge_cycle? = merge_cycle_unit?(current, exec_check)

          if is_map(current) and not is_nil(current["kind"]) and current["kind"] != "merge" and
               not merge_cycle? do
            Logger.info("unit_lite: clearing stale #{current["kind"]} current_unit on Merging entry")

            IssueExec.update(workspace, %{
              "current_unit" => nil,
              "verify_error" => nil,
              "verify_attempt" => 0,
              "verify_fix_count" => 0,
              "merge_conflict" => false,
              "merge_sync_count" => 0,
              "mergeability_unknown_count" => 0,
              "merge_needs_verify" => false
            })
          end

        _ ->
          :ok
      end
    end

    # 1d. Idempotency short-circuit for externally-merged PRs.
    # merge_sync_rule / merge_verify_rule run before merge_rule in
    # rules(:merging), so an externally-merged PR with merge_conflict or
    # merge_needs_verify still set would otherwise keep dispatching
    # conflict-resolution work until the cycle caps exhaust. This check
    # fires only when those flags are set — the plain merge_rule path
    # already has its own idempotency via do_programmatic_merge.
    if issue_state == "merging" and short_circuit_if_merged(workspace, issue, opts) do
      :ok
    else
      dispatch_next_unit(workspace, issue, codex_update_recipient, opts)
    end
  end

  defp dispatch_next_unit(workspace, issue, codex_update_recipient, opts) do
    # 2. Read workpad text — from opts or fetch from Linear
    workpad_text =
      case Keyword.get(opts, :workpad_text) do
        text when is_binary(text) -> text
        _ -> fetch_workpad_from_linear(issue)
      end

    # Forward workpad_text into opts so PromptBuilder's implement_subtask
    # context injection sees the same value we resolved here. Without this,
    # PromptBuilder would only see workpad_text when the caller already put
    # it in opts — and the local fetch above would be wasted. Closeout's
    # Keyword.take forwards this through too, so any future closeout check
    # that wants the workpad text can read it without refetching; currently
    # Closeout does not read it.
    opts = Keyword.put(opts, :workpad_text, workpad_text)

    # 3. Get git HEAD
    git_head = current_git_head(workspace)

    # 5. Read exec state and resolve next unit
    {:ok, exec} = IssueExec.read(workspace)

    ctx = %{
      issue: issue_to_dispatch_map(issue),
      exec: exec,
      workpad_text: workpad_text,
      git_head: git_head
    }

    case DispatchResolver.resolve(ctx) do
      {:dispatch, %Unit{kind: :merge} = unit} ->
        with_dispatch_hooks(workspace, issue, fn ->
          execute_merge_programmatic(workspace, issue, unit, codex_update_recipient, opts)
        end)

      {:dispatch, unit} ->
        Logger.info("unit_lite: dispatching #{unit.display_name} (effort=#{unit.reasoning_effort}) for #{issue_context(issue)}")

        with_dispatch_hooks(workspace, issue, fn ->
          execute_unit(workspace, issue, unit, codex_update_recipient, opts)
        end)

      {:stop, :circuit_breaker} ->
        Logger.error("unit_lite: circuit breaker tripped for #{issue_context(issue)}")
        escalate_to_human(workspace, issue, "Circuit breaker: unit crashed #{Config.max_unit_attempts()}+ times consecutively")

      {:stop, :no_matching_rule} ->
        Logger.warning("unit_lite: no matching rule for #{issue_context(issue)} — possible infrastructure issue (git_head=nil?)")
        escalate_to_human(workspace, issue, "No matching dispatch rule — check workspace git state")

      {:stop, :review_exhausted} ->
        Logger.warning("unit_lite: review-round cap reached for #{issue_context(issue)} — escalating to human")
        escalate_to_human(
          workspace,
          issue,
          "Code review exhausted #{Config.max_review_rounds()} rounds without converging on clean verdict — human needs to unblock"
        )

      {:stop, :already_escalated} ->
        # Escalation sentinel is set; ticket is waiting for explicit human
        # action (move to Rework to retry). Log quietly and do nothing — the
        # poller will call us again next tick but we keep short-circuiting
        # until the sentinel clears.
        Logger.info("unit_lite: escalated sentinel set for #{issue_context(issue)} — waiting for human to move ticket to Rework")
        :ok

      {:stop, reason} ->
        Logger.info("unit_lite: stopping for #{issue_context(issue)} reason=#{inspect(reason)}")
        :ok

      :skip ->
        Logger.info("unit_lite: skip for #{issue_context(issue)}")
        :ok
    end
  end

  # If the PR was merged externally (or by a prior run) while merge_conflict
  # or merge_needs_verify is still set, short-circuit to Done. Returns true
  # when we took that path; false means the caller should continue dispatch.
  defp short_circuit_if_merged(workspace, issue, opts) do
    case IssueExec.read(workspace) do
      {:ok, exec} ->
        has_flag? = exec["merge_conflict"] == true or exec["merge_needs_verify"] == true

        if has_flag? do
          pr_checker = Keyword.get(opts, :pr_checker, &Verifier.check_pr_merged/1)

          case pr_checker.(workspace) do
            :merged ->
              Logger.info("unit_lite: PR already merged on Merging entry for #{issue_context(issue)} — moving to Done")

              IssueExec.update(workspace, %{
                "phase" => "done",
                "merge_conflict" => false,
                "merge_sync_count" => 0,
                "mergeability_unknown_count" => 0,
                "merge_needs_verify" => false
              })

              move_issue_to_done(issue)
              Ledger.append(workspace, :merge_short_circuited, %{"reason" => "pr_already_merged"})
              true

            _ ->
              false
          end
        else
          false
        end

      _ ->
        false
    end
  end

  defp execute_unit(workspace, issue, unit, codex_update_recipient, opts) do
    # Record unit start
    IssueExec.start_unit(workspace, Unit.to_map(unit))
    Ledger.unit_started(workspace, Unit.to_map(unit))

    # Notify orchestrator/dashboard of unit dispatch
    send_codex_update(codex_update_recipient, issue, %{
      event: :unit_dispatched,
      timestamp: DateTime.utc_now(),
      unit_kind: to_string(unit.kind),
      unit_display_name: unit.display_name,
      reasoning_effort: unit.reasoning_effort
    })

    # Warm-session review loop (docs/design/warm-session-review-loop.md):
    # decide whether to resume a persistent Codex thread or spin a cold
    # session. The decision flows into both the session-open path and the
    # prompt builder — resumed prompts carry only the delta (new findings /
    # new diff) rather than re-injecting the full workpad.
    {:ok, pre_exec} = IssueExec.read(workspace)
    session_decision = session_decision_for_unit(unit, pre_exec)

    # Open the session FIRST so `opts[:is_resumed_session]` reflects the
    # actual session state (warm vs cold) rather than the intended decision.
    # If resume fails and we fall back to cold, the agent has no conversation
    # history — rendering a delta-only "resumed" prompt into it leaves the
    # agent blind. `actual_opened` drives both the prompt flag and the
    # thread-id persist decision below.
    {session_result, actual_opened} =
      case session_decision do
        {:resume, thread_id} ->
          # Thread reasoning_effort through resume too — otherwise warm sessions
          # silently fall back to Codex's default effort after round 1, which
          # is a silent quality regression especially for code_review (high).
          case AppServer.resume_session(workspace, thread_id, reasoning_effort: unit.reasoning_effort) do
            {:ok, _} = ok ->
              Logger.info("unit_lite: resumed thread #{String.slice(thread_id, 0, 12)} for #{unit.display_name}")
              {ok, :resumed}

            {:error, reason} ->
              Logger.warning("unit_lite: resume failed for #{unit.display_name} (#{inspect(reason)}) — falling back to cold start")
              fallback = AppServer.start_session(workspace, reasoning_effort: unit.reasoning_effort)
              {fallback, :cold_fallback}
          end

        :start_cold ->
          {AppServer.start_session(workspace, reasoning_effort: unit.reasoning_effort), :cold}
      end

    {prompt, opts} = build_dispatch_prompt(workspace, issue, unit, pre_exec, actual_opened, opts)

    # Per-unit debug log
    {:ok, unit_log_path} = UnitLog.open(workspace, unit)
    UnitLog.log_prompt(unit_log_path, prompt)

    # Token counter — accumulates from codex events during this unit
    token_counter = :counters.new(3, [:atomics])
    # indices: 1=input, 2=output, 3=total

    token_tracking_handler = fn message ->
      # Forward to orchestrator for dashboard
      send_codex_update(codex_update_recipient, issue, message)
      # Also accumulate locally for per-unit ledger entry
      track_unit_tokens(token_counter, message)
      # Per-unit debug log
      UnitLog.log_codex_event(unit_log_path, message)
    end

    case session_result do
      {:ok, session} ->
        # Record the new thread_id for any freshly-started session AND for
        # resumed sessions that came back with a different thread_id than
        # the one we asked for (some AppServer versions return a fresh id
        # after merging/forking). Without persisting, the next dispatch
        # keeps re-sending a dead id and warm-session savings are lost.
        # :cold and :cold_fallback always need persist; :resumed needs it
        # only if the id changed.
        if actual_opened in [:cold, :cold_fallback] or
             (actual_opened == :resumed and resumed_thread_id_changed?(pre_exec, unit, session)) do
          persist_thread_id_for_unit(workspace, unit, session)
        end

        try do
          case AppServer.run_turn(
                 session,
                 prompt,
                 issue,
                 on_message: token_tracking_handler
               ) do
            {:ok, _turn_session} ->
              Logger.info("unit_lite: worker finished #{unit.display_name} for #{issue_context(issue)}")

              # Run closeout — this is where verification, doc-impact, and
              # acceptance checks actually happen. Without this, all protection
              # mechanisms are dead code.
              closeout_opts =
                Keyword.take(opts, [
                  :workpad_text,
                  :dispatch_head,
                  :linear_fetch_ok,
                  :rework_has_review_context,
                  # code_review closeout uses :workpad_fetcher to re-fetch the
                  # workpad post-turn (the snapshot at dispatch time is stale).
                  # Without forwarding it, production would fall back to the
                  # default `Adapter.fetch_workpad_text/1` — the desired path —
                  # but tests that pass a stub fetcher can't exercise closeout
                  # through run_unit_lite. Forwarding keeps the test contract.
                  :workpad_fetcher
                ])

              unit_map = Unit.to_map(unit)

              unit_token_stats = read_token_counter(token_counter)

              closeout_result = Closeout.run(workspace, unit_map, issue, closeout_opts)
              UnitLog.log_closeout(unit_log_path, closeout_result, unit_token_stats)

              case closeout_result do
                :accepted ->
                  commit_sha = current_git_head(workspace)
                  IssueExec.accept_unit(workspace)
                  # Clear any prior closeout-rejection reason so the next
                  # dispatch's prompt doesn't re-surface a stale message.
                  IssueExec.clear_last_retry_reason(workspace)

                  if commit_sha do
                    IssueExec.set_commit_sha(workspace, commit_sha)
                  end

                  Ledger.unit_accepted(workspace, unit_map, %{"commit" => commit_sha})
                  Ledger.unit_tokens(workspace, unit_map, unit_token_stats)

                  # Notify orchestrator so dashboard shows completed stage history
                  send_codex_update(codex_update_recipient, issue, %{
                    event: :unit_completed,
                    timestamp: DateTime.utc_now(),
                    unit_kind: to_string(unit.kind),
                    unit_display_name: unit.display_name,
                    reasoning_effort: unit.reasoning_effort,
                    unit_tokens: unit_token_stats,
                    closeout_result: :accepted
                  })

                  Logger.info("unit_lite: accepted #{unit.display_name} tokens=#{unit_token_stats[:total_tokens]}")
                  :ok

                {:retry, reason} ->
                  Logger.warning("unit_lite: closeout retry for #{unit.display_name}: #{reason}")
                  Ledger.unit_failed(workspace, unit_map, reason)
                  # Persist the exact rejection reason so the next dispatch
                  # can surface it in the resumed agent's prompt.
                  IssueExec.set_last_retry_reason(workspace, reason)

                  send_codex_update(codex_update_recipient, issue, %{
                    event: :unit_completed,
                    timestamp: DateTime.utc_now(),
                    unit_kind: to_string(unit.kind),
                    unit_display_name: unit.display_name,
                    reasoning_effort: unit.reasoning_effort,
                    unit_tokens: unit_token_stats,
                    closeout_result: {:retry, reason}
                  })

                  :ok

                {:fail, reason} ->
                  Logger.error("unit_lite: closeout rejected #{unit.display_name}: #{reason}")
                  Ledger.unit_failed(workspace, unit_map, reason)
                  # Fail paths escape this unit's retry loop; clear the stale
                  # rejection reason so it doesn't leak into whatever unit
                  # runs next (escalation reset, merge fallback, etc.).
                  IssueExec.clear_last_retry_reason(workspace)

                  send_codex_update(codex_update_recipient, issue, %{
                    event: :unit_completed,
                    timestamp: DateTime.utc_now(),
                    unit_kind: to_string(unit.kind),
                    unit_display_name: unit.display_name,
                    reasoning_effort: unit.reasoning_effort,
                    unit_tokens: unit_token_stats,
                    closeout_result: {:fail, reason}
                  })

                  raise RuntimeError, "unit_lite closeout rejected: #{reason}"
              end

            {:error, reason} ->
              Logger.error("unit_lite: turn failed for #{unit.display_name}: #{inspect(reason)}")
              UnitLog.log_error(unit_log_path, inspect(reason))
              Ledger.unit_failed(workspace, Unit.to_map(unit), inspect(reason))
              raise RuntimeError, "unit_lite turn failed: #{inspect(reason)}"
          end
        after
          AppServer.stop_session(session)
        end

      {:error, reason} ->
        Logger.error("unit_lite: session start failed for #{unit.display_name}: #{inspect(reason)}")
        UnitLog.log_error(unit_log_path, "session_start_failed: #{inspect(reason)}")
        Ledger.unit_failed(workspace, Unit.to_map(unit), "session_start_failed: #{inspect(reason)}")
        raise RuntimeError, "unit_lite session start failed: #{inspect(reason)}"
    end
  end

  # Run the dispatch body inside before_run / after_run hooks.
  #
  # Contract: after_run fires only when the dispatch actually started —
  # i.e., before_run succeeded. If before_run fails, the attempt never
  # ran and a cleanup hook would be lying about the state; SPEC.md treats
  # before_run failure as fatal and shows after_run only on the dispatch
  # success path. The try/after preserves the happy-path guarantee that
  # after_run fires even when `fun.()` raises.
  defp with_dispatch_hooks(workspace, issue, fun) do
    case Workspace.run_before_run_hook(workspace, issue) do
      :ok ->
        try do
          fun.()
        after
          Workspace.run_after_run_hook(workspace, issue)
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Programmatic merge — no Codex session, no token burn.
  # Checks CI, merges PR, updates Linear. All shell commands.
  # Does NOT call start_unit until we know we're actually merging.
  defp execute_merge_programmatic(workspace, issue, unit, codex_update_recipient, opts) do
    result = do_programmatic_merge(workspace, issue, opts)

    unit_map = Unit.to_map(unit)

    case result do
      :ok ->
        # Only record unit start/accept for actual merges
        IssueExec.start_unit(workspace, unit_map)
        Ledger.unit_started(workspace, unit_map)
        IssueExec.update(workspace, %{"phase" => "done"})
        IssueExec.accept_unit(workspace)
        Ledger.unit_accepted(workspace, unit_map, %{"merge" => "programmatic"})
        Ledger.unit_tokens(workspace, unit_map, %{input_tokens: 0, output_tokens: 0, total_tokens: 0})

        send_codex_update(codex_update_recipient, issue, %{
          event: :unit_completed,
          timestamp: DateTime.utc_now(),
          unit_kind: "merge",
          unit_display_name: "merge:programmatic",
          reasoning_effort: "low",
          unit_tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
          closeout_result: :accepted
        })

        Logger.info("unit_lite: programmatic merge completed for #{issue_context(issue)}")
        :ok

      {:skip, reason} ->
        # CI pending/unknown — silently skip, no ledger noise, retry on next poll
        Logger.debug("unit_lite: merge skipped (#{reason}) for #{issue_context(issue)}")
        :ok

      {:error, reason} ->
        # Actual merge failure — record, then escalate so the ticket moves to
        # Human Input Needed and the exec state resets. Otherwise the error
        # surface is only a log line and the ticket stays in Merging forever.
        IssueExec.start_unit(workspace, unit_map)
        Ledger.unit_started(workspace, unit_map)
        Ledger.unit_failed(workspace, unit_map, reason)
        Logger.warning("unit_lite: programmatic merge failed for #{issue_context(issue)}: #{reason}")
        escalate_to_human(workspace, issue, "Programmatic merge failed: #{reason}")
    end
  end

  defp do_programmatic_merge(workspace, issue, opts) do
    pr_checker = Keyword.get(opts, :pr_checker, &Verifier.check_pr_merged/1)

    # 0. Check if already merged (idempotency)
    case pr_checker.(workspace) do
      :merged ->
        move_issue_to_done(issue)
        :ok

      _ ->
        do_merge_with_ci_check(workspace, issue, opts)
    end
  end

  @max_merge_sync_cycles 2
  @max_mergeability_unknown 10

  defp do_merge_with_ci_check(workspace, issue, opts) do
    ci_checker = Keyword.get(opts, :ci_checker, &Verifier.check_ci_status/1)
    pr_merger = Keyword.get(opts, :pr_merger, &Verifier.merge_pr/1)
    ci_output_getter = Keyword.get(opts, :ci_output_getter, &get_ci_failure_output/1)
    mergeability_checker = Keyword.get(opts, :mergeability_checker, &Verifier.check_pr_mergeability/1)

    # 1. Check CI
    case ci_checker.(workspace) do
      :pass ->
        # 1.5 Check mergeability before attempting merge
        case mergeability_checker.(workspace) do
          :mergeable ->
            # Reset unknown counter on success
            IssueExec.update(workspace, %{"mergeability_unknown_count" => 0})

            # 2. Merge PR
            case pr_merger.(workspace) do
              :ok ->
                move_issue_to_done(issue)
                :ok

              {:error, output} ->
                {:error, "PR merge failed: #{output}"}
            end

          :conflicting ->
            # Reset unknown counter — a confirmed :conflicting answer means
            # GitHub's mergeability computation completed.
            IssueExec.update(workspace, %{"mergeability_unknown_count" => 0})
            handle_merge_conflict(workspace)

          :unknown ->
            handle_mergeability_unknown(workspace)
        end

      :pending ->
        {:skip, "CI pending"}

      {:fail, _reason} ->
        # CI test failure — dispatch verify-fix if within cycle cap
        {:ok, exec_state} = IssueExec.read(workspace)
        fix_count = exec_state["verify_fix_count"] || 0
        max_fix_cycles = Config.max_verify_fix_cycles()

        if fix_count < max_fix_cycles do
          ci_output = ci_output_getter.(workspace)
          IssueExec.set_verify_error(workspace, ci_output)
          # `verify_fix_rule` is gated on `merge_needs_verify == true` to
          # distinguish an active merge-verify cycle from a stale pre-warm-
          # session `verify_error` sentinel. A live CI failure during merge
          # IS an active cycle: set the flag so the gate opens. Without this
          # the verify-fix dispatch never happens; merge_rule retries the
          # merge itself, CI fails again, and we exhaust `verify_fix_count`
          # without ever running a repair subtask. (Iter7 Lens3 HIGH.)
          IssueExec.update(workspace, %{
            "current_unit" => nil,
            "verify_fix_count" => fix_count + 1,
            "merge_needs_verify" => true
          })

          Ledger.append(workspace, :ci_failed_will_fix, %{
            "fix_cycle" => fix_count + 1,
            "error" => String.slice(ci_output, 0, 512)
          })

          {:skip, "CI failed — verify-fix ##{fix_count + 1} will be dispatched"}
        else
          {:error, "CI failed after #{fix_count} fix cycles — escalating"}
        end

      :unknown ->
        {:skip, "CI status unknown"}
    end
  end

  defp handle_merge_conflict(workspace) do
    {:ok, exec_state} = IssueExec.read(workspace)
    sync_count = exec_state["merge_sync_count"] || 0

    if sync_count < @max_merge_sync_cycles do
      IssueExec.update(workspace, %{
        "merge_conflict" => true,
        "current_unit" => nil,
        "merge_sync_count" => sync_count + 1
      })

      Ledger.append(workspace, :merge_conflict_will_sync, %{
        "sync_cycle" => sync_count + 1
      })

      {:skip, "PR has conflicts — merge-sync ##{sync_count + 1} will be dispatched"}
    else
      {:error, "PR has conflicts after #{sync_count} sync cycles — escalating"}
    end
  end

  defp handle_mergeability_unknown(workspace) do
    {:ok, exec_state} = IssueExec.read(workspace)
    count = (exec_state["mergeability_unknown_count"] || 0) + 1
    IssueExec.update(workspace, %{"mergeability_unknown_count" => count})

    if count >= @max_mergeability_unknown do
      {:error, "PR mergeability unknown for #{count} consecutive checks — escalating"}
    else
      {:skip, "PR mergeability unknown — waiting for GitHub (#{count}/#{@max_mergeability_unknown})"}
    end
  end

  defp get_ci_failure_output(workspace) do
    # Try to get actual failure details from the failed CI job log,
    # not just the pass/fail summary from `gh pr checks`.
    task =
      Task.async(fn ->
        try do
          # 1. Find the failed run ID
          {run_json, 0} = System.cmd("gh", ["pr", "checks", "--json", "link,state,name", "--jq", "[.[] | select(.state == \"FAILURE\")] | first | .link"], cd: workspace, stderr_to_stdout: true)

          run_url = String.trim(run_json)

          if run_url != "" and String.contains?(run_url, "/jobs/") do
            # Extract job ID from URL like .../jobs/70825851812
            job_id = run_url |> String.split("/jobs/") |> List.last() |> String.trim()

            # 2. Get the job log and extract failure details
            {log, _} = System.cmd("gh", ["api", "repos/{owner}/{repo}/actions/jobs/#{job_id}/logs"], cd: workspace, stderr_to_stdout: true)

            # Extract the useful part: failed test names + error messages
            lines = String.split(log, "\n")

            failure_lines =
              lines
              |> Enum.filter(fn l ->
                String.contains?(l, "failed") or String.contains?(l, "×") or
                  String.contains?(l, "Error:") or String.contains?(l, "✘") or
                  String.contains?(l, "e2e/") or String.contains?(l, "FAIL")
              end)
              |> Enum.map(&String.replace(&1, ~r/^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s*/, ""))
              |> Enum.uniq()

            if failure_lines != [] do
              Enum.join(failure_lines, "\n")
            else
              # Fallback: last 40 lines of log
              lines |> Enum.take(-40) |> Enum.join("\n")
            end
          else
            # Fallback to pr checks summary
            {output, _} = System.cmd("gh", ["pr", "checks"], cd: workspace, stderr_to_stdout: true)
            output
          end
        rescue
          _ -> "(could not retrieve CI output)"
        end
      end)

    case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, _exit}} when is_binary(output) -> String.slice(output, 0, 1500)
      {:ok, output} when is_binary(output) -> String.slice(output, 0, 1500)
      _ -> "(CI output unavailable)"
    end
  end

  defp move_issue_to_done(issue) do
    issue_id =
      case issue do
        %Issue{id: id} -> id
        %{id: id} -> id
        _ -> nil
      end

    if is_binary(issue_id) do
      case Adapter.update_issue_state(issue_id, "Done") do
        :ok -> Logger.info("unit_lite: moved issue to Done")
        {:error, err} -> Logger.warning("unit_lite: failed to move to Done: #{inspect(err)}")
      end
    end
  end

  # Track token usage from Codex on_message events.
  # Codex reports tokens via "thread/tokenUsage/updated" events.
  # Values are CUMULATIVE (not deltas), so we use :counters.put.
  # We search multiple paths to match what the orchestrator does in extract_token_usage.
  defp track_unit_tokens(counter, message) when is_map(message) do
    usage = extract_usage_from_message(message)

    if is_map(usage) do
      input = first_integer(usage, ["inputTokens", "input_tokens", "prompt_tokens", :inputTokens, :input_tokens])
      output = first_integer(usage, ["outputTokens", "output_tokens", "completion_tokens", :outputTokens, :output_tokens])
      total = first_integer(usage, ["totalTokens", "total_tokens", "total", :totalTokens, :total_tokens, :total])

      # Cumulative values — put (not add)
      if is_integer(input) and input > 0, do: :counters.put(counter, 1, input)
      if is_integer(output) and output > 0, do: :counters.put(counter, 2, output)
      if is_integer(total) and total > 0, do: :counters.put(counter, 3, total)
    end
  end

  defp track_unit_tokens(_counter, _message), do: :ok

  # Search all known paths where Codex puts token usage
  defp extract_usage_from_message(msg) do
    # Path priority (matching orchestrator's absolute_token_usage_from_payload):
    # 1. payload.params.tokenUsage.total (raw JSON-RPC in payload)
    # 2. payload.tokenUsage.total
    # 3. params.tokenUsage.total (if emit_message merged params)
    # 4. payload.params.msg.payload.info.total_token_usage (legacy)
    # 5. :usage top-level (if AppServer's maybe_set_usage found "usage" key)
    # 6. payload.usage (turn/completed with inline usage)
    dig(msg, [:payload, "params", "tokenUsage", "total"]) ||
      dig(msg, [:payload, "tokenUsage", "total"]) ||
      dig(msg, ["params", "tokenUsage", "total"]) ||
      dig(msg, [:payload, "params", "msg", "payload", "info", "total_token_usage"]) ||
      Map.get(msg, :usage) ||
      Map.get(msg, "usage") ||
      dig(msg, [:payload, "usage"]) ||
      dig(msg, [:details, "tokenUsage", "total"])
  end

  defp dig(map, []) when is_map(map), do: map

  defp dig(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nil -> nil
      val -> dig(val, rest)
    end
  end

  defp dig(_, _), do: nil

  defp first_integer(map, keys) when is_map(map) do
    Enum.find_value(keys, fn k ->
      case Map.get(map, k) do
        v when is_integer(v) -> v
        _ -> nil
      end
    end)
  end

  defp read_token_counter(counter) do
    %{
      input_tokens: :counters.get(counter, 1),
      output_tokens: :counters.get(counter, 2),
      total_tokens: :counters.get(counter, 3)
    }
  end

  defp fetch_workpad_from_linear(%Issue{id: issue_id}) when is_binary(issue_id) do
    case Adapter.fetch_workpad_text(issue_id) do
      {:ok, text} ->
        Logger.info("unit_lite: fetched workpad from Linear for issue_id=#{issue_id}")
        text

      {:error, reason} ->
        Logger.debug("unit_lite: no workpad found for issue_id=#{issue_id}: #{inspect(reason)}")
        nil
    end
  end

  defp fetch_workpad_from_linear(_issue), do: nil

  defp escalate_to_human(workspace, issue, reason) do
    issue_id =
      case issue do
        %Issue{id: id} -> id
        %{id: id} -> id
        _ -> nil
      end

    if is_binary(issue_id) do
      # Move ticket to Human Input Needed
      case Adapter.update_issue_state(issue_id, "Human Input Needed") do
        :ok ->
          Logger.info("unit_lite: escalated #{issue_context(issue)} to Human Input Needed")

        {:error, err} ->
          Logger.warning("unit_lite: failed to escalate #{issue_context(issue)}: #{inspect(err)}")
      end

      # Post reason + diagnostic snapshot as comment. Snapshot is best-effort:
      # any section that can't be read is omitted rather than blocking escalation.
      case Adapter.create_comment(issue_id, build_escalation_comment(workspace, reason)) do
        :ok -> :ok
        {:error, err} -> Logger.warning("unit_lite: escalation comment failed for #{issue_id}: #{inspect(err)}")
      end
    end

    # Reset exec state AND set the escalated sentinel in one write.
    # The sentinel is critical: if `Adapter.update_issue_state` above failed
    # (Linear API blip), the ticket is still in its active Linear state, the
    # poller will dispatch this workspace again on the next tick, and without
    # the sentinel the orchestrator would re-run the same work from scratch
    # (review_round reset to 0 → code_review fires round 1 again → 5 more
    # rounds → escalate → reset → loop). The sentinel makes DispatchResolver
    # stop silently until the human explicitly moves the ticket to Rework
    # (which clears it via rework_reset_updates/0).
    IssueExec.update(
      workspace,
      Map.put(IssueExec.rework_reset_updates(), "escalated", true)
    )

    Ledger.append(workspace, :escalated_to_human, %{"reason" => reason})
    :ok
  end

  # Maximum characters for each diagnostic section in the escalation comment.
  # Linear has a ~64 KB per-comment hard cap; sections are kept small so the
  # total stays well under it and the human-facing summary is readable.
  @escalation_section_chars 1500
  @escalation_ledger_tail_lines 12

  # Build the escalation comment body. The reason is mandatory; every
  # diagnostic section is best-effort and omitted if unreadable.
  defp build_escalation_comment(workspace, reason) do
    head = Verifier.current_head(workspace)
    verify_error = read_verify_error(workspace)
    status = Verifier.git_status(workspace)
    diff_stat = Verifier.git_diff_stat(workspace)
    ledger_tail = read_ledger_tail(workspace, @escalation_ledger_tail_lines)

    sections = [
      "**Symphony escalation**: #{reason}",
      "This ticket needs human attention. The diagnostic snapshot below is from the moment of escalation — full logs remain in `.symphony/ledger.jsonl` and `.symphony/units/`.",
      escalation_section("Workspace HEAD", head),
      escalation_section("Last verify error", verify_error),
      escalation_section("git status -sb", status),
      escalation_section("git diff HEAD --stat", diff_stat),
      escalation_section("Recent ledger events", ledger_tail)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp escalation_section(_title, nil), do: nil
  defp escalation_section(_title, ""), do: nil

  defp escalation_section(title, content) when is_binary(content) do
    truncated =
      if String.length(content) > @escalation_section_chars do
        String.slice(content, 0, @escalation_section_chars) <> "\n… [truncated]"
      else
        content
      end

    "### #{title}\n\n```\n#{truncated}\n```"
  end

  defp read_verify_error(workspace) do
    case IssueExec.read(workspace) do
      {:ok, exec} -> exec["verify_error"]
      _ -> nil
    end
  end

  defp read_ledger_tail(workspace, n) do
    case Ledger.read(workspace) do
      {:ok, entries} when is_list(entries) and entries != [] ->
        entries
        |> Enum.take(-n)
        |> Enum.map(&format_ledger_entry/1)
        |> Enum.join("\n")

      _ ->
        nil
    end
  end

  # Keys kept from a ledger payload in the escalation snapshot. `error` and
  # `last_error` matter for :verify_failed_will_fix / :verify_exhausted events,
  # which often carry the only surviving copy of the verify output by the time
  # escalation runs (closeout clears `exec.verify_error` on verify exhaustion).
  @ledger_payload_keys ["subtask_id", "kind", "reason", "attempt", "fix_cycle", "error", "last_error"]
  @ledger_value_chars 160

  defp format_ledger_entry(%{"event" => event, "ts" => ts} = entry) do
    payload = entry["payload"] || %{}
    summary = payload |> Map.take(@ledger_payload_keys) |> format_payload()
    "#{ts} #{event}#{summary}"
  end

  defp format_ledger_entry(entry), do: inspect(entry, limit: 120)

  defp format_payload(payload) when map_size(payload) == 0, do: ""

  defp format_payload(payload) do
    pairs =
      payload
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.map(fn {k, v} -> "#{k}=#{format_payload_value(v)}" end)

    if pairs == [], do: "", else: " " <> Enum.join(pairs, " ")
  end

  defp format_payload_value(v) when is_binary(v) do
    if String.length(v) > @ledger_value_chars do
      inspect(String.slice(v, 0, @ledger_value_chars) <> "…")
    else
      inspect(v)
    end
  end

  defp format_payload_value(v), do: inspect(v, limit: 60)

  # A unit counts as a merge-cycle unit (shouldn't be wiped on Merging entry) if
  # it's either a merge-sync-* subtask, or a verify triggered by merge_needs_verify.
  defp merge_cycle_unit?(%{"kind" => "implement_subtask", "subtask_id" => subtask_id}, _exec)
       when is_binary(subtask_id),
       do: String.starts_with?(subtask_id, "merge-sync-")

  defp merge_cycle_unit?(%{"kind" => "verify"}, %{"merge_needs_verify" => true}), do: true
  defp merge_cycle_unit?(_unit, _exec), do: false

  @doc """
  Decide how to clean up exec state when (re-)entering the Rework lane.

  Returns `%{action: :fresh | :stale | :none, updates: map()}`. The caller
  applies `updates` via `IssueExec.update/2` only when `map_size(updates) > 0`.

  Two "fresh" shapes reset the full rework-cycle flag set so
  `rework_fix_rule` fires again on the next dispatch:

    * clean prior cycle — `current_unit` is nil and `last_accepted_unit.kind`
      is `handoff` or `merge`.
    * handoff/merge race — `current_unit.kind` is `handoff` or `merge`
      because the orchestrator's state-transition poller killed the Task
      before `Closeout` + `IssueExec.accept_unit/1` ran. The agent
      completed the work that mattered (flipped Linear state), but exec
      looks in-flight. Without this branch, the stale handoff blocks
      `fresh_rework`, `rework_fix_applied` stays `true` forever, and every
      subsequent rework cycle silently skips `rework-1` (→ no new commits,
      infinite verify/handoff/kill loop).

  `verify` is deliberately excluded from both shapes — verify completes
  within a rework cycle (`rework-1 → doc_fix → verify`), so treating it as
  a fresh entry would reset `rework_fix_applied` and re-dispatch
  `rework-1` forever. See Invariant 5b in `failure_path_test.exs`.

  A narrower `:stale` action only clears `current_unit` + `last_verified_sha`
  when `current_unit` is an unexpected kind (neither a fresh handoff/merge
  race nor a mid-cycle verify/doc_fix/rework-* unit). Defensive cleanup for
  corrupted exec state.
  """
  @spec plan_rework_entry_cleanup(map()) ::
          %{action: :fresh | :stale | :none, updates: map()}
  def plan_rework_entry_cleanup(exec_check) when is_map(exec_check) do
    current = exec_check["current_unit"]
    last = exec_check["last_accepted_unit"]

    fresh_rework? =
      (is_nil(current) and is_map(last) and last["kind"] in ["handoff", "merge"]) or
        (is_map(current) and current["kind"] in ["handoff", "merge"])

    rework_cycle_unit? =
      current != nil and
        case current["kind"] do
          # `verify` stays here for the merge flow (no Rework transitions in
          # :merging). `code_review` / `doc_fix` were previously here but a
          # human-triggered rework move while code_review or doc_fix is
          # in-flight is by definition a NEW cycle — preserving the current
          # code_review unit meant replay_current_unit_rule would replay the
          # stale review (prior cycle's warm thread + context) and could
          # emit a bogus clean verdict on rejected code. They must reset.
          "verify" ->
            true

          "implement_subtask" ->
            # Only `rework-*` is a true mid-rework-cycle unit whose state
            # must be preserved across replays. `review-fix-*` was formerly
            # here — but review-fix-N is dispatched in BOTH :normal and
            # :rework flows; if a human moves a ticket to Rework mid-normal-
            # review-fix, keeping current_unit preserved means replay runs
            # review-fix-N against stale (pre-rework) warm-session threads.
            # Let it fall through to :stale so `rework_reset_updates/0`
            # re-runs — the small cost of re-dispatching review-fix is
            # dwarfed by the cost of reviewing the rejected code.
            is_binary(current["subtask_id"]) and
              String.starts_with?(current["subtask_id"], "rework-")

          _ ->
            false
        end

    stale? = current != nil and not rework_cycle_unit? and not fresh_rework?
    escalated_resume? = exec_check["escalated"] == true

    cond do
      fresh_rework? ->
        # Single source of truth for the field set: IssueExec.rework_reset_updates/0.
        # A human-triggered rework invalidates the prior implement↔review threads
        # and their verdict; without full reset, a stale "clean" verdict survives
        # and handoff_rule either mis-dispatches against a stale SHA or freezes
        # at :no_matching_rule.
        %{action: :fresh, updates: IssueExec.rework_reset_updates()}

      stale? ->
        # Stale `current_unit` at Rework entry means the prior cycle was
        # interrupted at an unexpected spot — safest to reset everything the
        # :fresh branch would, so the warm-session threads / verdict / flags
        # from the prior cycle can't poison the new one.
        %{action: :stale, updates: IssueExec.rework_reset_updates()}

      escalated_resume? ->
        # Ticket was escalated (current_unit / last_accepted_unit both
        # cleared by escalate_to_human/3). Human moving it back to Rework IS
        # the unblock signal — without this branch, fresh_rework? can't fire
        # (last_accepted_unit was nulled) and the escalated sentinel stays
        # true forever, permanently wedging the ticket.
        %{action: :fresh, updates: IssueExec.rework_reset_updates()}

      true ->
        %{action: :none, updates: %{}}
    end
  end

  defp issue_to_dispatch_map(%Issue{} = issue) do
    %{state: issue.state || "Unknown"}
  end

  defp issue_to_dispatch_map(issue) when is_map(issue) do
    %{state: Map.get(issue, :state) || Map.get(issue, "state") || "Unknown"}
  end

  defp issue_state_string(%Issue{state: state}) when is_binary(state) do
    state |> String.trim() |> String.downcase()
  end

  defp issue_state_string(issue) when is_map(issue) do
    state = Map.get(issue, :state) || Map.get(issue, "state") || ""
    state |> to_string() |> String.trim() |> String.downcase()
  end

  defp issue_state_string(_), do: ""

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp current_git_head(workspace) do
    task =
      Task.async(fn ->
        System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        case String.trim(output) do
          "" -> nil
          git_head -> git_head
        end

      _ ->
        nil
    end
  end

  # For rework-* subtasks, snapshot the git HEAD at dispatch time and fetch
  # all Linear comments on the ticket so the prompt can inject them verbatim.
  # Non-rework units pass through unchanged.
  #
  # Two separate boolean flags are passed through to closeout:
  #   `:linear_fetch_ok`            — the Linear API call itself succeeded
  #   `:rework_has_review_context`  — after excluding the Symphony-owned
  #                                    workpad, at least one review comment
  #                                    remains for the agent to read
  # Both must be true for closeout to accept rework. If either is false, the
  # agent ran (or would run) effectively blind, so we return {:retry, ...}
  # and let the circuit breaker eventually escalate. The two flags are split
  # so retry reasons in the ledger stay diagnostically useful.
  defp enrich_opts_for_commit_guarded_subtask(
         workspace,
         _issue,
         %Unit{subtask_id: "verify-fix-" <> _},
         opts
       ) do
    # verify-fix units only need the HEAD snapshot — they have no Linear
    # review-context contract, and the verify error is already injected via
    # exec state by the dispatch resolver / prompt builder.
    Keyword.put(opts, :dispatch_head, current_git_head(workspace))
  end

  defp enrich_opts_for_commit_guarded_subtask(
         workspace,
         issue,
         %Unit{subtask_id: "rework-" <> _} = unit,
         opts
       ) do
    enrich_opts_for_rework(workspace, issue, unit, opts)
  end

  # Regular plan-N and merge-sync-* implement_subtask units, plus doc_fix,
  # are also mutation-bearing: the per-dispatch workspace reset destroys
  # uncommitted work, so closeout must be able to verify that HEAD
  # advanced since dispatch. Snapshot it here.
  defp enrich_opts_for_commit_guarded_subtask(
         workspace,
         _issue,
         %Unit{kind: :implement_subtask},
         opts
       ) do
    Keyword.put_new(opts, :dispatch_head, current_git_head(workspace))
  end

  defp enrich_opts_for_commit_guarded_subtask(
         workspace,
         _issue,
         %Unit{kind: :doc_fix},
         opts
       ) do
    Keyword.put_new(opts, :dispatch_head, current_git_head(workspace))
  end

  # code_review is REVIEW-ONLY: closeout's `reviewer_committed?` gate compares
  # `dispatch_head` to HEAD at closeout time and rejects if HEAD advanced
  # (reviewer committed code). Without snapshotting dispatch_head here, that
  # gate silently short-circuits to false and the review-only invariant is
  # unenforced. See `Closeout.do_closeout("code_review", ...)`.
  defp enrich_opts_for_commit_guarded_subtask(
         workspace,
         _issue,
         %Unit{kind: :code_review},
         opts
       ) do
    Keyword.put_new(opts, :dispatch_head, current_git_head(workspace))
  end

  defp enrich_opts_for_commit_guarded_subtask(_workspace, _issue, _unit, opts), do: opts

  # Public seam for the full opts→prompt pipeline used by execute_unit.
  # Runs enrichment (dispatch_head / rework comments / subtask contract)
  # and renders the prompt. Returns {prompt, enriched_opts} so execute_unit
  # can pass the enriched opts through to Closeout.
  #
  # Tests assert this function produces a prompt containing <subtask_contract>
  # for a plan-N unit. If a future merge silently drops an enrichment step
  # inside this function, the test fails — which is the regression the
  # old per-helper test could NOT catch (helper tested in isolation, not
  # through the chain).
  @doc false
  @spec build_unit_prompt_for_dispatch(Path.t(), map(), Unit.t(), keyword()) ::
          {String.t(), keyword()}
  def build_unit_prompt_for_dispatch(workspace, issue, %Unit{} = unit, opts) do
    opts = enrich_opts_for_commit_guarded_subtask(workspace, issue, unit, opts)
    opts = maybe_attach_current_subtask_contract(unit, opts)
    prompt = PromptBuilder.build_unit_prompt(issue, unit, opts)
    {prompt, opts}
  end

  @doc """
  Full dispatch-prompt pipeline: read exec, apply session-outcome wiring
  (`dispatch_opts_from_exec/3`), enrich, render prompt. This is the function
  `execute_unit/5` uses, and the one tests must exercise — NOT
  `build_unit_prompt_for_dispatch/4` directly, because that skips the exec→opts
  wiring which is where retry_reason / last_reviewed_sha / is_resumed_session
  actually flow from the persisted state into the prompt.

  Named as a public seam so that:
    (a) a missing or renamed `Keyword.put(:retry_reason, ...)` in the wiring
        surfaces here rather than hiding behind production-only code paths;
    (b) future changes to execute_unit cannot drop the wiring step without
        this function losing its contract — tests pin "exec retry_reason →
        prompt shows reason" via this one call.
  """
  @spec build_dispatch_prompt(Path.t(), map(), Unit.t(), map(), :resumed | :cold | :cold_fallback, keyword()) ::
          {String.t(), keyword()}
  def build_dispatch_prompt(workspace, issue, %Unit{} = unit, exec, actual_opened, base_opts \\ []) do
    opts = dispatch_opts_from_exec(base_opts, exec, actual_opened)
    build_unit_prompt_for_dispatch(workspace, issue, unit, opts)
  end

  # Parse the workpad once here (workpad_text is already fetched by the
  # caller before prompt build) and attach the active subtask's structured
  # contract to opts as :current_subtask. PromptBuilder renders that into
  # a sanitized <subtask_contract> block. Rework/verify-fix/merge-sync
  # subtasks are skipped: they have their own prompt shape and the planner
  # contract doesn't apply to them.
  #
  # Public (with @doc false) so tests can pin the wiring without mocking
  # the whole AppServer / dispatch chain.
  @doc false
  def maybe_attach_current_subtask_contract(
        %Unit{kind: :implement_subtask, subtask_id: subtask_id},
        opts
      ) do
    if regular_implement_subtask_id?(subtask_id) do
      with workpad_text when is_binary(workpad_text) <- Keyword.get(opts, :workpad_text),
           {:ok, subtasks} <- WorkpadParser.parse(workpad_text),
           %{} = current_subtask <- Enum.find(subtasks, &(&1.id == subtask_id)) do
        Keyword.put(opts, :current_subtask, current_subtask)
      else
        _ -> opts
      end
    else
      opts
    end
  end

  def maybe_attach_current_subtask_contract(_unit, opts), do: opts

  defp regular_implement_subtask_id?(subtask_id) when is_binary(subtask_id) do
    not String.starts_with?(subtask_id, "rework-") and
      not String.starts_with?(subtask_id, "verify-fix-") and
      not String.starts_with?(subtask_id, "merge-sync-") and
      not String.starts_with?(subtask_id, "review-fix-")
  end

  defp regular_implement_subtask_id?(_), do: false

  # --- Warm-session review loop: session decision ---
  #
  # Pure function that decides whether a dispatch should resume a persistent
  # Codex thread (warm context, fast re-entry) or spin a cold session. Kept
  # separate from AppServer I/O so callers can test it without stubbing the
  # JSON-RPC port protocol.
  #
  # See docs/design/warm-session-review-loop.md.
  @doc """
  Thread exec-state into the PromptBuilder opts. Named (vs inlined in
  execute_unit) so tests can pin the wiring contract — a renamed exec key or
  a silently-dropped Keyword.put is caught by failing assertions on the
  helper's output rather than being invisible behind a whole dispatch.
  """
  @spec dispatch_opts_from_exec(keyword(), map(), :resumed | :cold | :cold_fallback) :: keyword()
  def dispatch_opts_from_exec(opts, exec, actual_opened) when is_map(exec) do
    opts
    |> Keyword.put(:is_resumed_session, actual_opened == :resumed)
    |> Keyword.put(:last_reviewed_sha, exec["last_reviewed_sha"])
    # retry_reason is non-nil when the prior dispatch's closeout returned
    # {:retry, reason}. PromptBuilder routes retry-aware prompts so the
    # agent addresses the rejection instead of acting on stale framing.
    |> Keyword.put(:retry_reason, exec["last_retry_reason"])
  end

  @doc false
  @spec session_decision_for_unit(Unit.t(), map()) :: :start_cold | {:resume, String.t()}
  def session_decision_for_unit(%Unit{} = unit, exec) when is_map(exec) do
    case target_thread_key(unit) do
      nil ->
        :start_cold

      key ->
        case Map.get(exec, key) do
          thread_id when is_binary(thread_id) and byte_size(thread_id) > 0 ->
            {:resume, thread_id}

          _ ->
            :start_cold
        end
    end
  end

  # Which persistent thread does this unit live in?
  #   - code_review → review_thread_id (session B)
  #   - implement_subtask (plan-N, review-fix-*, rework-*) → implement_thread_id (session A)
  #   - verify-fix-*, merge-sync-* → nil (one-shot, cold)
  #   - everything else (bootstrap, plan, doc_fix, handoff, merge) → nil
  defp target_thread_key(%Unit{kind: :code_review}), do: "review_thread_id"

  defp target_thread_key(%Unit{kind: :implement_subtask, subtask_id: id}) when is_binary(id) do
    cond do
      String.starts_with?(id, "verify-fix-") -> nil
      String.starts_with?(id, "merge-sync-") -> nil
      # plan-N, review-fix-N, rework-N all ride on the implement session
      true -> "implement_thread_id"
    end
  end

  defp target_thread_key(_), do: nil

  # Has a successful resume_session returned a DIFFERENT thread_id than what
  # we stored? Some AppServer paths (thread merge, version forks, transient
  # resumption that produces a new logical thread) return a fresh id. If we
  # don't re-persist, every future dispatch re-sends the stale id and resume
  # either fails or wastes a round trip.
  defp resumed_thread_id_changed?(pre_exec, unit, session) do
    key = target_thread_key(unit)

    with true <- is_binary(key),
         id when is_binary(id) <- Map.get(session, :thread_id),
         stored <- Map.get(pre_exec, key) do
      stored != id
    else
      _ -> false
    end
  end

  # After a cold session starts, record its thread_id so the next dispatch
  # targeting the same persistent role can resume instead of going cold.
  # Resumed sessions already share the stored id, so this is a no-op for them.
  defp persist_thread_id_for_unit(workspace, unit, session) do
    case target_thread_key(unit) do
      nil ->
        :ok

      "implement_thread_id" ->
        case session.thread_id do
          id when is_binary(id) ->
            IssueExec.set_implement_thread_id(workspace, id)

          _ ->
            :ok
        end

      "review_thread_id" ->
        case session.thread_id do
          id when is_binary(id) ->
            IssueExec.set_review_thread_id(workspace, id)

          _ ->
            :ok
        end
    end
  end

  defp enrich_opts_for_rework(workspace, issue, %Unit{subtask_id: "rework-" <> _}, opts) do
    dispatch_head = current_git_head(workspace)

    {comments, fetch_ok} =
      case extract_issue_id(issue) do
        id when is_binary(id) ->
          case Adapter.fetch_issue_comments(id) do
            {:ok, list} ->
              {list, true}

            {:error, reason} ->
              Logger.warning("unit_lite: failed to fetch Linear comments for rework #{issue_context(issue)}: #{inspect(reason)}")

              {[], false}
          end

        _ ->
          Logger.warning("unit_lite: cannot extract issue id for rework #{issue_context(issue)}; skipping comment fetch")

          {[], false}
      end

    has_review_context = fetch_ok and Enum.any?(comments, &review_comment?/1)

    opts
    |> Keyword.put(:dispatch_head, dispatch_head)
    |> Keyword.put(:linear_comments, comments)
    |> Keyword.put(:linear_fetch_ok, fetch_ok)
    |> Keyword.put(:rework_has_review_context, has_review_context)
  end

  # A "review comment" is any Linear comment that is not Symphony's own
  # Codex Workpad artifact. Keeping the predicate here (instead of only in
  # PromptBuilder) ensures closeout has the same view of "does the agent have
  # review context?" — a ticket whose only comment is the workpad must fail
  # closed in closeout even though the fetch itself succeeded.
  defp review_comment?(comment) when is_map(comment) do
    body = comment["body"] || ""
    body != "" and not workpad_comment_body?(body)
  end

  defp review_comment?(_), do: false

  defp workpad_comment_body?(body) when is_binary(body) do
    String.contains?(body, "## Codex Workpad") and String.contains?(body, "### Plan")
  end

  defp workpad_comment_body?(_), do: false

  defp extract_issue_id(%{id: id}) when is_binary(id), do: id
  defp extract_issue_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_issue_id(_), do: nil

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
