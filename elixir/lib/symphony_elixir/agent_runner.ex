defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Closeout, Config, DispatchResolver, IssueExec, Ledger, Linear.Adapter, Linear.Issue, PromptBuilder, Tracker, Unit, UnitLog, Verifier, Workspace}

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
    if Config.unit_lite?() do
      Workspace.prepare_for_dispatch(workspace, issue)
    else
      :ok
    end
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

    # For rework-* and verify-fix-* subtasks: snapshot HEAD (for closeout
    # zero-commit guard). For rework-* additionally fetch all Linear comments
    # (for prompt injection). Orchestrator-owned ingestion — do not rely on
    # the agent to fetch review context or self-report commit state.
    opts = enrich_opts_for_commit_guarded_subtask(workspace, issue, unit, opts)

    # Build prompt
    prompt = PromptBuilder.build_unit_prompt(issue, unit, opts)

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

    case AppServer.start_session(workspace, reasoning_effort: unit.reasoning_effort) do
      {:ok, session} ->
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
                  :rework_has_review_context
                ])

              unit_map = Unit.to_map(unit)

              unit_token_stats = read_token_counter(token_counter)

              closeout_result = Closeout.run(workspace, unit_map, issue, closeout_opts)
              UnitLog.log_closeout(unit_log_path, closeout_result, unit_token_stats)

              case closeout_result do
                :accepted ->
                  commit_sha = current_git_head(workspace)
                  IssueExec.accept_unit(workspace)

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

  defp with_dispatch_hooks(workspace, issue, fun) do
    try do
      with :ok <- Workspace.run_before_run_hook(workspace, issue) do
        fun.()
      end
    after
      Workspace.run_after_run_hook(workspace, issue)
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
          IssueExec.update(workspace, %{"current_unit" => nil, "verify_fix_count" => fix_count + 1})

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

    # Reset exec state so when a human moves the ticket back to active,
    # dispatch starts fresh — rework_fix_rule fires, verify counters are clean,
    # and circuit breaker is cleared.
    IssueExec.update(workspace, %{
      "current_unit" => nil,
      "rework_fix_applied" => false,
      "verify_error" => nil,
      "verify_attempt" => 0,
      "verify_fix_count" => 0,
      "merge_conflict" => false,
      "merge_sync_count" => 0,
      "mergeability_unknown_count" => 0,
      "merge_needs_verify" => false
    })

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
          k when k in ["verify", "doc_fix"] ->
            true

          "implement_subtask" ->
            is_binary(current["subtask_id"]) and
              String.starts_with?(current["subtask_id"], "rework-")

          _ ->
            false
        end

    stale? = current != nil and not rework_cycle_unit? and not fresh_rework?

    cond do
      fresh_rework? ->
        %{
          action: :fresh,
          updates: %{
            "current_unit" => nil,
            "rework_fix_applied" => false,
            "last_verified_sha" => nil,
            "verify_error" => nil,
            "verify_attempt" => 0,
            "verify_fix_count" => 0,
            "merge_conflict" => false,
            "merge_sync_count" => 0,
            "mergeability_unknown_count" => 0,
            "merge_needs_verify" => false
          }
        }

      stale? ->
        %{
          action: :stale,
          updates: %{
            "current_unit" => nil,
            "last_verified_sha" => nil
          }
        }

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

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    case Workspace.create_for_issue_with_status(issue) do
      {:ok, workspace, _created?} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue),
               :ok <- run_codex_turns(workspace, issue, codex_update_recipient, opts) do
            :ok
          else
            {:error, reason} ->
              Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")

              raise RuntimeError,
                    "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
          end
        after
          Workspace.run_after_run_hook(workspace, issue)
        end

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns())

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    dispatch_id = build_dispatch_id(issue, opts)

    with {:ok, session} <- start_or_resume_session(workspace, issue, dispatch_id) do
      try do
        do_run_codex_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          dispatch_id,
          1,
          max_turns
        )
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         dispatch_id,
         turn_number,
         max_turns
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      # Persist session meta eagerly after each turn so it survives
      # orchestrator kill on issue state change (race condition fix)
      persist_session_meta(workspace, app_session, dispatch_id, issue)

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          maybe_compact_thread(app_session, refreshed_issue)

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            dispatch_id,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state. Do not restart from scratch.
    - Read the workpad to determine which phase was last completed, then continue with the next phase.
    - The original task instructions and prior turn context are already present in this thread.
    - Follow the Yield Policy: end the turn after completing the current phase.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp maybe_compact_thread(app_session, issue) do
    if Config.codex_compact_between_turns?() do
      Logger.info("Compacting thread before continuation for #{issue_context(issue)}")

      case AppServer.compact_thread(app_session) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Thread compact failed for #{issue_context(issue)}: #{inspect(reason)}; continuing without compact")

          :ok
      end
    else
      :ok
    end
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp start_or_resume_session(workspace, issue, dispatch_id) do
    expanded_workspace = Path.expand(workspace)

    case Workspace.load_session_meta(workspace) do
      {:ok, %{thread_id: thread_id, cwd: saved_cwd}} when byte_size(thread_id) > 0 ->
        if saved_cwd != nil and Path.expand(saved_cwd) != expanded_workspace do
          Logger.warning("Session meta cwd mismatch for #{issue_context(issue)} saved=#{saved_cwd} current=#{expanded_workspace}; starting fresh")

          maybe_invalidate_stale_session_meta(workspace, issue, dispatch_id, :cwd_mismatch)
          start_fresh_session(workspace, issue, dispatch_id)
        else
          Logger.info("Starting Codex session via resume for #{issue_context(issue)} dispatch_id=#{dispatch_id} workspace=#{workspace} thread_id=#{thread_id}")

          case AppServer.resume_session(workspace, thread_id) do
            {:ok, session} ->
              {:ok, session}

            {:error, reason} ->
              Logger.warning("Codex session resume failed for #{issue_context(issue)} dispatch_id=#{dispatch_id} workspace=#{workspace} thread_id=#{thread_id}: #{inspect(reason)}")

              maybe_invalidate_stale_session_meta(workspace, issue, dispatch_id, reason)
              start_fresh_session(workspace, issue, dispatch_id)
          end
        end

      {:ok, %{thread_id: _}} ->
        Logger.warning("Session meta has empty thread_id for #{issue_context(issue)}; starting fresh")

        maybe_invalidate_stale_session_meta(workspace, issue, dispatch_id, :empty_thread_id)
        start_fresh_session(workspace, issue, dispatch_id)

      {:error, :enoent} ->
        start_fresh_session(workspace, issue, dispatch_id)

      {:error, reason} ->
        Logger.warning("Ignoring unreadable session metadata for #{issue_context(issue)} dispatch_id=#{dispatch_id} workspace=#{workspace}: #{inspect(reason)}")

        maybe_invalidate_stale_session_meta(workspace, issue, dispatch_id, reason)
        start_fresh_session(workspace, issue, dispatch_id)
    end
  end

  defp start_fresh_session(workspace, issue, dispatch_id) do
    Logger.info("Starting Codex session fresh for #{issue_context(issue)} dispatch_id=#{dispatch_id} workspace=#{workspace}")

    AppServer.start_session(workspace)
  end

  defp maybe_invalidate_stale_session_meta(workspace, issue, dispatch_id, reason) do
    case Workspace.invalidate_session_meta(workspace) do
      :ok ->
        :ok

      {:error, invalidate_reason} ->
        Logger.warning(
          "Failed to invalidate stale session metadata for #{issue_context(issue)} dispatch_id=#{dispatch_id} workspace=#{workspace} original_reason=#{inspect(reason)} invalidate_reason=#{inspect(invalidate_reason)}; overwriting with empty meta to prevent retry loop"
        )

        # If we can't delete the stale meta, overwrite it with an invalid one
        # to prevent the next dispatch from retrying the same stale thread_id
        File.write(Path.join(workspace, ".symphony_session.json"), "{}")
        :ok
    end
  end

  defp persist_session_meta(workspace, session, dispatch_id, issue) do
    session_meta = %{
      thread_id: session.thread_id,
      dispatch_id: dispatch_id,
      cwd: Path.expand(workspace),
      git_head: current_git_head(workspace),
      updated_at: DateTime.utc_now()
    }

    case Workspace.save_session_meta(workspace, session_meta) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist session metadata for #{issue_context(issue)} dispatch_id=#{dispatch_id} workspace=#{workspace}: #{inspect(reason)}")

        :ok
    end
  end

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

  defp enrich_opts_for_commit_guarded_subtask(_workspace, _issue, _unit, opts), do: opts

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

  defp build_dispatch_id(%Issue{id: issue_id, identifier: identifier}, opts) do
    dispatch_token = System.unique_integer([:positive, :monotonic])

    case Keyword.get(opts, :attempt) do
      attempt when is_integer(attempt) ->
        "#{issue_id || identifier || "dispatch"}-attempt-#{attempt}-#{dispatch_token}"

      _ ->
        "#{issue_id || identifier || "dispatch"}-#{dispatch_token}"
    end
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
