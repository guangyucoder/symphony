defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

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
        with :ok <-
               do_run_codex_turns(
                 session,
                 workspace,
                 issue,
                 codex_update_recipient,
                 opts,
                 issue_state_fetcher,
                 1,
                 max_turns
               ) do
          persist_session_meta(workspace, session, dispatch_id, issue)
          :ok
        end
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

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info(
            "Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}"
          )

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
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
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
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