defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Closeout, Config, DispatchResolver, IssueExec, Ledger, Linear.Adapter, Linear.Issue, PromptBuilder, Tracker, Unit, UnitLog, Workspace}

  @max_escalate_attempts 3

  @doc """
  Unit-lite mode: resolve the next unit, run a single fresh Codex session for it,
  then exit. The orchestrator will re-dispatch for the next unit.
  """
  @spec run_unit_lite(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run_unit_lite(issue, codex_update_recipient \\ nil, opts \\ []) do
    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        Workspace.ensure_symphony_dir(workspace)
        run_unit_lite_in_workspace(workspace, issue, codex_update_recipient, opts)

      {:error, reason} ->
        Logger.error("unit_lite: workspace creation failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "unit_lite workspace failed: #{inspect(reason)}"
    end
  end

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
          current = exec_check["current_unit"]
          last = exec_check["last_accepted_unit"]

          # 1. Fresh rework entry: last_accepted is handoff/merge from the
          #    previous cycle, current_unit is nil (clean exit). Clear
          #    rework_fix_applied so the fix rule fires for this new cycle.
          #    NOTE: "verify" is NOT included — verify can complete within a
          #    rework cycle (rework_fix → doc_fix → verify), and treating it
          #    as fresh entry causes an infinite rework loop.
          fresh_rework? = is_nil(current) and
                          is_map(last) and last["kind"] in ["handoff", "merge"]

          if fresh_rework? do
            IssueExec.update(workspace, %{
              "rework_fix_applied" => false,
              "last_verified_sha" => nil,
              "verify_error" => nil,
              "verify_attempt" => 0,
              "verify_fix_count" => 0
            })
          end

          # 2. Stale current_unit from previous cycle (e.g., handoff was
          #    in-flight). Clear it so DispatchResolver sees clean state.
          #    Do NOT clear verify/doc_fix/rework-* — these are part of the
          #    current rework cycle and need replay for circuit breaker.
          rework_cycle_unit? = current != nil and
            case current["kind"] do
              k when k in ["verify", "doc_fix"] -> true
              "implement_subtask" ->
                is_binary(current["subtask_id"]) and
                String.starts_with?(current["subtask_id"], "rework-")
              _ -> false
            end

          stale? = current != nil and not rework_cycle_unit?

          if stale? do
            IssueExec.update(workspace, %{
              "current_unit" => nil,
              "last_verified_sha" => nil
            })
          end

        _ ->
          Logger.warning("unit_lite: could not read exec for rework cleanup, skipping")
      end
    end

    # 1c. Clear stale non-merge current_unit when entering Merging state.
    # If a handoff/verify unit was in-flight when the issue was manually moved
    # to Merging, replaying it would be wrong (e.g., handoff could move the
    # ticket back to Human Review). Only merge units should replay in Merging.
    if issue_state == "merging" do
      case IssueExec.read(workspace) do
        {:ok, %{"current_unit" => %{"kind" => kind}}} when kind != "merge" and not is_nil(kind) ->
          Logger.info("unit_lite: clearing stale #{kind} current_unit on Merging entry")
          IssueExec.update(workspace, %{
            "current_unit" => nil,
            "verify_error" => nil,
            "verify_attempt" => 0,
            "verify_fix_count" => 0
          })

        _ ->
          :ok
      end
    end

    # 2. Read workpad text — from opts or fetch from Linear
    workpad_text =
      case Keyword.get(opts, :workpad_text) do
        text when is_binary(text) -> text
        _ -> fetch_workpad_from_linear(issue)
      end

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
        execute_merge_programmatic(workspace, issue, unit, codex_update_recipient)

      {:dispatch, unit} ->
        Logger.info("unit_lite: dispatching #{unit.display_name} (effort=#{unit.reasoning_effort}) for #{issue_context(issue)}")
        execute_unit(workspace, issue, unit, codex_update_recipient, opts)

      {:stop, :circuit_breaker} ->
        Logger.error("unit_lite: circuit breaker tripped for #{issue_context(issue)}")
        escalate_to_human(workspace, issue, "Circuit breaker: unit crashed #{@max_escalate_attempts}+ times consecutively")

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

    # Run before_run hook
    Workspace.run_before_run_hook(workspace, issue)

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

    try do
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
              closeout_opts = Keyword.take(opts, [:workpad_text])
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
    after
      Workspace.run_after_run_hook(workspace, issue)
    end
  end

  # Programmatic merge — no Codex session, no token burn.
  # Checks CI, merges PR, updates Linear. All shell commands.
  # Does NOT call start_unit until we know we're actually merging.
  defp execute_merge_programmatic(workspace, issue, unit, codex_update_recipient) do
    result = do_programmatic_merge(workspace, issue)

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
        # Actual merge failure — record for debugging
        IssueExec.start_unit(workspace, unit_map)
        Ledger.unit_started(workspace, unit_map)
        Ledger.unit_failed(workspace, unit_map, reason)
        Logger.warning("unit_lite: programmatic merge failed for #{issue_context(issue)}: #{reason}")
        :ok
    end
  end

  defp do_programmatic_merge(workspace, issue) do
    alias SymphonyElixir.Verifier

    # 0. Check if already merged (idempotency)
    case Verifier.check_pr_merged(workspace) do
      :merged ->
        move_issue_to_done(issue)
        :ok

      _ ->
        do_merge_with_ci_check(workspace, issue)
    end
  end

  defp do_merge_with_ci_check(workspace, issue) do
    alias SymphonyElixir.Verifier

    # 1. Check CI
    case Verifier.check_ci_status(workspace) do
      :pass ->
        # 2. Merge PR
        case Verifier.merge_pr(workspace) do
          :ok ->
            # 3. Move Linear to Done
            move_issue_to_done(issue)
            :ok

          {:error, output} ->
            {:error, "PR merge failed: #{output}"}
        end

      :pending ->
        {:skip, "CI pending"}

      {:fail, _reason} ->
        # CI test failure — get full output for verify-fix context
        ci_output = get_ci_failure_output(workspace)
        IssueExec.set_verify_error(workspace, ci_output)
        IssueExec.update(workspace, %{"current_unit" => nil})
        {:skip, "CI failed — verify-fix will be dispatched"}

      :unknown ->
        {:skip, "CI status unknown"}
    end
  end

  defp get_ci_failure_output(workspace) do
    task =
      Task.async(fn ->
        try do
          System.cmd("gh", ["pr", "checks"],
            cd: workspace, stderr_to_stdout: true)
        rescue
          _ -> {"(could not retrieve CI output)", 127}
        end
      end)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, _}} -> String.slice(output, 0, 1500)
      _ -> "(CI output unavailable)"
    end
  end

  defp move_issue_to_done(issue) do
    issue_id = case issue do
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
      input = first_integer(usage, ["inputTokens", "input_tokens", "prompt_tokens",
                                    :inputTokens, :input_tokens])
      output = first_integer(usage, ["outputTokens", "output_tokens", "completion_tokens",
                                     :outputTokens, :output_tokens])
      total = first_integer(usage, ["totalTokens", "total_tokens", "total",
                                    :totalTokens, :total_tokens, :total])

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
    issue_id = case issue do
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

      # Post reason as comment
      case Adapter.create_comment(issue_id, "**Symphony escalation**: #{reason}\n\nThis ticket needs human attention. Check `.symphony/ledger.jsonl` and `.symphony/units/` logs in the workspace for details.") do
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
      "verify_fix_count" => 0
    })
    Ledger.append(workspace, :escalated_to_human, %{"reason" => reason})
    :ok
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

    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
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
      Logger.info(
        "Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}"
      )

      # Persist session meta eagerly after each turn so it survives
      # orchestrator kill on issue state change (race condition fix)
      persist_session_meta(workspace, app_session, dispatch_id, issue)

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info(
            "Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}"
          )

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
          Logger.info(
            "Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator"
          )

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
        :ok -> :ok
        {:error, reason} ->
          Logger.warning(
            "Thread compact failed for #{issue_context(issue)}: #{inspect(reason)}; continuing without compact"
          )

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
          Logger.warning(
            "Session meta cwd mismatch for #{issue_context(issue)} saved=#{saved_cwd} current=#{expanded_workspace}; starting fresh"
          )

          maybe_invalidate_stale_session_meta(workspace, issue, dispatch_id, :cwd_mismatch)
          start_fresh_session(workspace, issue, dispatch_id)
        else
          Logger.info(
            "Starting Codex session via resume for #{issue_context(issue)} dispatch_id=#{dispatch_id} workspace=#{workspace} thread_id=#{thread_id}"
          )

          case AppServer.resume_session(workspace, thread_id) do
            {:ok, session} ->
              {:ok, session}

            {:error, reason} ->
              Logger.warning(
                "Codex session resume failed for #{issue_context(issue)} dispatch_id=#{dispatch_id} workspace=#{workspace} thread_id=#{thread_id}: #{inspect(reason)}"
              )

              maybe_invalidate_stale_session_meta(workspace, issue, dispatch_id, reason)
              start_fresh_session(workspace, issue, dispatch_id)
          end
        end

      {:ok, %{thread_id: _}} ->
        Logger.warning(
          "Session meta has empty thread_id for #{issue_context(issue)}; starting fresh"
        )

        maybe_invalidate_stale_session_meta(workspace, issue, dispatch_id, :empty_thread_id)
        start_fresh_session(workspace, issue, dispatch_id)

      {:error, :enoent} ->
        start_fresh_session(workspace, issue, dispatch_id)

      {:error, reason} ->
        Logger.warning(
          "Ignoring unreadable session metadata for #{issue_context(issue)} dispatch_id=#{dispatch_id} workspace=#{workspace}: #{inspect(reason)}"
        )

        maybe_invalidate_stale_session_meta(workspace, issue, dispatch_id, reason)
        start_fresh_session(workspace, issue, dispatch_id)
    end
  end

  defp start_fresh_session(workspace, issue, dispatch_id) do
    Logger.info(
      "Starting Codex session fresh for #{issue_context(issue)} dispatch_id=#{dispatch_id} workspace=#{workspace}"
    )

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
        Logger.warning(
          "Failed to persist session metadata for #{issue_context(issue)} dispatch_id=#{dispatch_id} workspace=#{workspace}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp current_git_head(workspace) do
    task = Task.async(fn ->
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