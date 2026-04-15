defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.

  Per-dispatch cleanup uses `git clean -fd` (tracked + untracked non-ignored
  files) plus an explicit list of gitignored transient caches (`@excluded_entries`).
  We do NOT use `-fdx` because it would also delete bootstrap-installed
  dependencies (`node_modules`, `deps`, `_build`) whose `after_create` hook is
  one-shot.
  """

  require Logger
  alias SymphonyElixir.{Config, Ledger}

  # `git clean -fd` does NOT remove gitignored paths, so stale transient caches
  # (e.g. Next.js `.next`, Android `build`/`.gradle`, `node_modules/.cache`) accumulate
  # across dispatches unless we wipe them explicitly here. We intentionally DO NOT
  # use `-fdx`: that would also destroy bootstrap-installed outputs (`node_modules`,
  # `deps/`, `_build/`) whose `after_create` hook is one-shot, leaving subsequent
  # dispatches without dependencies. The list below targets transient build outputs
  # only; add entries here for new consumer-repo caches that should be nuked per
  # dispatch.
  @excluded_entries [
    # Elixir transient state
    ".elixir_ls",
    "tmp",
    # Next.js build artifacts
    "apps/web/.next",
    "apps/admin/.next",
    # React Native native build caches
    "mobile-app/ios/build",
    "mobile-app/android/.gradle",
    "mobile-app/android/build",
    # JS package-manager caches (keep node_modules itself)
    "node_modules/.cache"
  ]
  @env_staleness_warning_table :symphony_workspace_env_staleness_warnings
  @max_discarded_wip_files 10

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    case create_for_issue_with_status(issue_or_identifier) do
      {:ok, workspace, _created?} -> {:ok, workspace}
      {:error, _reason} = error -> error
    end
  end

  @spec create_for_issue_with_status(map() | String.t() | nil) ::
          {:ok, Path.t(), boolean()} | {:error, term()}
  def create_for_issue_with_status(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      workspace = workspace_path_for_issue(safe_id)

      with :ok <- validate_workspace_path(workspace),
           {:ok, created?} <- ensure_workspace(workspace),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?) do
        {:ok, workspace, created?}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")

        {:error, error}
    end
  end

  @doc """
  Reset an existing workspace to a clean per-dispatch baseline without rerunning bootstrap.

  ALL uncommitted changes are destroyed on every dispatch; this is observable via
  the `:workspace_wip_discarded` ledger event. Agents must commit before yielding.

  Before the reset destroys them, discarded changes are archived under
  `.symphony/discarded_wip/<iso-timestamp>*`:

  - `<ts>.patch` — `git diff --binary HEAD` output (tracked-file edits).
    Recover with `git apply <path>` from the workspace root.
  - `<ts>.untracked.txt` — porcelain listing of untracked entries (for audit).
  - `<ts>.untracked/` — mirrored tree of brand-new untracked regular files
    that `git diff` cannot represent. Recover with `cp -r <path>/* <workspace>/`.
    Absent when there were no untracked regular files.

  The archive survives the reset because `.symphony/` is excluded from
  `git clean -fd`.

  KNOWN LIMITATION: `.env.sh` is preserved for local bootstrap compatibility and
  is NOT refreshed per dispatch.
  """
  @spec prepare_for_dispatch(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def prepare_for_dispatch(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    with :ok <- validate_workspace_path(workspace),
         :ok <- maybe_warn_env_snapshot_staleness(workspace),
         :ok <- ensure_git_dispatch_baseline(workspace, issue_context) do
      clean_tmp_artifacts(workspace)
      :ok
    end
  end

  defp ensure_workspace(workspace) do
    cond do
      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, true}
  end

  @doc "Ensure the .symphony/ control directory exists inside a workspace."
  @spec ensure_symphony_dir(Path.t()) :: :ok | {:error, term()}
  def ensure_symphony_dir(workspace) when is_binary(workspace) do
    File.mkdir_p(Path.join(workspace, ".symphony"))
  end

  @doc "Return the .symphony/ directory path for a workspace."
  @spec symphony_dir(Path.t()) :: Path.t()
  def symphony_dir(workspace) when is_binary(workspace) do
    Path.join(workspace, ".symphony")
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    workspace = Path.join(Config.workspace_root(), safe_id)

    remove(workspace)
    :ok
  end

  def remove_issue_workspaces(_identifier) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:before_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run")
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:after_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run")
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Path.join(Config.workspace_root(), safe_id)
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(@excluded_entries, fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?) do
    case created? do
      true ->
        case Config.workspace_hooks()[:after_create] do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create")
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace) do
    case File.dir?(workspace) do
      true ->
        case Config.workspace_hooks()[:before_remove] do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.workspace_hooks()[:timeout_ms]

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp ensure_git_dispatch_baseline(workspace, issue_context) do
    case git_workspace_status(workspace) do
      :git_repo ->
        with :ok <- fetch_origin_if_present(workspace, issue_context),
             :ok <- maybe_record_discarded_wip(workspace, issue_context),
             :ok <- maybe_reset_workspace_head(workspace, issue_context),
             :ok <-
               run_git_step(
                 workspace,
                 ["clean", "-fd", "-e", ".symphony/", "-e", ".env.sh"],
                 "clean_untracked",
                 issue_context
               ) do
          :ok
        end

      :not_git_repo ->
        Logger.warning("Workspace prepare skipped git reset because workspace is not a git repo #{issue_log_context(issue_context)} workspace=#{workspace}")

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp git_workspace_status(workspace) do
    case run_git_command(workspace, ["rev-parse", "--is-inside-work-tree"]) do
      {:ok, output} ->
        case String.trim(output) do
          "true" -> :git_repo
          _ -> {:error, {:workspace_prepare_failed, "rev_parse", 0, output}}
        end

      {:error, {:workspace_prepare_failed, "rev_parse", status, output}} ->
        if String.contains?(String.downcase(output), "not a git repository") do
          :not_git_repo
        else
          {:error, {:workspace_prepare_failed, "rev_parse", status, output}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_origin_if_present(workspace, issue_context) do
    case run_git_command(workspace, ["fetch", "origin", "--prune"]) do
      {:ok, _output} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Workspace prepare: git fetch failed; continuing with reset to local HEAD: #{format_workspace_prepare_reason(reason)} #{issue_log_context(issue_context)} workspace=#{workspace}"
        )

        :ok
    end
  end

  defp maybe_record_discarded_wip(workspace, issue_context) do
    case run_git_command(workspace, ["status", "--porcelain=v1"]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> summarize_discarded_wip()
        |> log_discarded_wip(workspace, issue_context)

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_reset_workspace_head(workspace, issue_context) do
    case run_git_command(workspace, ["rev-parse", "--verify", "HEAD"]) do
      {:ok, _output} ->
        run_git_step(workspace, ["reset", "--hard", "HEAD"], "reset_hard", issue_context)

      {:error, {:workspace_prepare_failed, "verify_head", _status, _output}} ->
        Logger.warning("Workspace prepare skipped git reset because HEAD is unset (empty repo) #{issue_log_context(issue_context)} workspace=#{workspace}")

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp summarize_discarded_wip([]), do: nil

  defp summarize_discarded_wip(lines) do
    files =
      lines
      |> Enum.map(&porcelain_path/1)
      |> Enum.reject(&(&1 == ""))

    truncated_files = Enum.take(files, @max_discarded_wip_files)
    hidden_count = max(length(files) - length(truncated_files), 0)

    summary =
      truncated_files
      |> Enum.join(", ")
      |> append_hidden_count(hidden_count)
      |> sanitize_hook_output_for_log(512)

    %{
      files: truncated_files,
      file_count: length(files),
      summary: summary
    }
  end

  defp log_discarded_wip(nil, _workspace, _issue_context), do: :ok

  defp log_discarded_wip(%{summary: summary} = discarded, workspace, issue_context) do
    Logger.warning("Workspace prepare will discard uncommitted changes #{issue_log_context(issue_context)} workspace=#{workspace} files=#{inspect(summary)}")

    stash_paths = stash_discarded_wip(workspace, discarded, issue_context)

    payload =
      %{
        "issue_identifier" => issue_context.issue_identifier,
        "files" => discarded.files,
        "file_count" => discarded.file_count,
        "summary" => discarded.summary
      }
      |> Map.merge(stash_paths)

    case Ledger.append(workspace, :workspace_wip_discarded, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Workspace prepare could not record discarded WIP in ledger #{issue_log_context(issue_context)} workspace=#{workspace} error=#{inspect(reason)}")

        :ok
    end
  end

  # Best-effort capture of uncommitted work before the reset destroys it.
  # Writes both a binary-aware diff and the raw untracked-file list into
  # .symphony/discarded_wip/<iso-ts>.{patch,untracked.txt}. On any failure
  # we warn + return empty paths; the ledger entry still records the file
  # list, and the dispatch continues (do not abort on stash failure).
  defp stash_discarded_wip(workspace, %{file_count: count}, issue_context) when count > 0 do
    timestamp =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
      |> String.replace(":", "-")

    dir = Path.join([workspace, ".symphony", "discarded_wip"])
    patch_rel = Path.join([".symphony", "discarded_wip", "#{timestamp}.patch"])
    untracked_rel = Path.join([".symphony", "discarded_wip", "#{timestamp}.untracked.txt"])
    untracked_content_rel = Path.join([".symphony", "discarded_wip", "#{timestamp}.untracked"])
    patch_abs = Path.join(workspace, patch_rel)
    untracked_abs = Path.join(workspace, untracked_rel)
    untracked_content_abs = Path.join(workspace, untracked_content_rel)

    # Capture git state BEFORE creating any stash directories so the
    # porcelain output doesn't accidentally include the artifacts we're
    # about to write. File.mkdir_p comes after the capture for the same
    # reason.
    with {:ok, diff_output} <- run_git_command(workspace, ["diff", "--binary", "HEAD"]),
         {:ok, porcelain_output} <-
           run_git_command(workspace, ["status", "--porcelain=v1", "--untracked-files=all"]),
         :ok <- File.mkdir_p(dir),
         :ok <- File.write(patch_abs, diff_output),
         :ok <- File.write(untracked_abs, porcelain_output),
         {:ok, untracked_saved} <-
           copy_untracked_contents(workspace, porcelain_output, untracked_content_abs) do
      paths = %{"patch_path" => patch_rel, "untracked_list_path" => untracked_rel}

      if untracked_saved > 0 do
        Map.put(paths, "untracked_content_path", untracked_content_rel)
      else
        paths
      end
    else
      error ->
        Logger.warning("Workspace prepare could not stash discarded WIP #{issue_log_context(issue_context)} workspace=#{workspace} error=#{inspect(error)}")

        %{}
    end
  end

  defp stash_discarded_wip(_workspace, _discarded, _issue_context), do: %{}

  # Mirror untracked files' contents into `.symphony/discarded_wip/<ts>.untracked/`
  # so a brand-new file (never `git add`'d, hence absent from `git diff`) isn't
  # permanently lost when `git clean -fd` runs in the next reset step.
  # Returns {:ok, count_copied}. On any per-file error, skip that file and
  # keep going — partial recovery is better than none.
  defp copy_untracked_contents(workspace, porcelain_output, dest_root) do
    untracked_rel_paths =
      porcelain_output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "?? "))
      |> Enum.map(&String.slice(&1, 3..-1//1))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case untracked_rel_paths do
      [] ->
        {:ok, 0}

      _ ->
        with :ok <- File.mkdir_p(dest_root) do
          saved =
            Enum.reduce(untracked_rel_paths, 0, fn rel, acc ->
              if safe_relative_path?(rel) do
                src = Path.join(workspace, rel)
                dest = Path.join(dest_root, rel)

                case File.stat(src) do
                  {:ok, %File.Stat{type: :regular}} ->
                    case File.mkdir_p(Path.dirname(dest)) do
                      :ok ->
                        case File.cp(src, dest) do
                          :ok -> acc + 1
                          _ -> acc
                        end

                      _ ->
                        acc
                    end

                  _ ->
                    acc
                end
              else
                acc
              end
            end)

          {:ok, saved}
        end
    end
  end

  # Untracked paths come from `git status --porcelain` — they should never
  # contain `..` or absolute paths, but defend against filesystem escape.
  defp safe_relative_path?(path) when is_binary(path) do
    segments = Path.split(path)
    not (String.starts_with?(path, "/") or Enum.any?(segments, &(&1 == "..")))
  end

  defp safe_relative_path?(_), do: false

  defp porcelain_path(line) when is_binary(line) and byte_size(line) > 3 do
    line
    |> binary_part(3, byte_size(line) - 3)
    |> String.trim()
    |> String.split(" -> ")
    |> List.last()
  end

  defp porcelain_path(_line), do: ""

  defp append_hidden_count("", 0), do: ""
  defp append_hidden_count(summary, 0), do: summary
  defp append_hidden_count("", hidden_count), do: "(+#{hidden_count} more)"
  defp append_hidden_count(summary, hidden_count), do: "#{summary} ... (+#{hidden_count} more)"

  defp maybe_warn_env_snapshot_staleness(workspace) do
    env_snapshot = Path.join(workspace, ".env.sh")

    if is_nil(Config.workspace_hooks()[:before_run]) and File.exists?(env_snapshot) and
         mark_env_snapshot_warning_emitted(workspace) do
      Logger.warning("Workspace prepare: .env.sh is preserved and may be stale until refreshed by a before_run hook workspace=#{workspace}")
    end

    :ok
  end

  defp mark_env_snapshot_warning_emitted(workspace) do
    :ets.insert_new(ensure_env_warning_table(), {Path.expand(workspace), true})
  end

  defp ensure_env_warning_table do
    case :ets.whereis(@env_staleness_warning_table) do
      :undefined ->
        try do
          :ets.new(@env_staleness_warning_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> @env_staleness_warning_table
        end

      table ->
        table
    end
  end

  defp run_git_step(workspace, args, step, issue_context) do
    case run_git_command(workspace, args) do
      {:ok, _output} ->
        :ok

      {:error, {:workspace_prepare_failed, _raw_step, status, output}} ->
        sanitized_output = sanitize_hook_output_for_log(output)

        Logger.warning("Workspace prepare failed step=#{step} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

        {:error, {:workspace_prepare_failed, step, status, output}}

      {:error, {:workspace_prepare_exec_failed, _raw_step, reason}} ->
        Logger.warning("Workspace prepare failed step=#{step} #{issue_log_context(issue_context)} workspace=#{workspace} error=#{inspect(reason)}")

        {:error, {:workspace_prepare_exec_failed, step, reason}}

      {:error, {:workspace_prepare_timeout, _raw_step, timeout_ms}} ->
        {:error, {:workspace_prepare_timeout, step, timeout_ms}}
    end
  end

  defp run_git_command(workspace, args) do
    step = raw_git_step(args)
    timeout_ms = Config.workspace_hooks()[:timeout_ms]

    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd("git", args, cd: workspace, stderr_to_stdout: true)}
        rescue
          error in ErlangError ->
            {:error, Exception.message(error)}
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:ok, {output, 0}}} ->
        {:ok, output}

      {:ok, {:ok, {output, status}}} ->
        {:error, {:workspace_prepare_failed, step, status, output}}

      {:ok, {:error, reason}} ->
        {:error, {:workspace_prepare_exec_failed, step, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace prepare timed out step=#{step} workspace=#{workspace} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_prepare_timeout, step, timeout_ms}}
    end
  end

  defp format_workspace_prepare_reason({:workspace_prepare_failed, step, status, output}) do
    "#{step} exited #{status}: #{inspect(sanitize_hook_output_for_log(output))}"
  end

  defp format_workspace_prepare_reason({:workspace_prepare_exec_failed, step, reason}) do
    "#{step} exec failed: #{inspect(reason)}"
  end

  defp format_workspace_prepare_reason({:workspace_prepare_timeout, step, timeout_ms}) do
    "#{step} timed out after #{timeout_ms}ms"
  end

  defp format_workspace_prepare_reason(reason), do: inspect(reason)

  defp raw_git_step(["rev-parse", "--verify" | _rest]), do: "verify_head"
  defp raw_git_step(["rev-parse" | _rest]), do: "rev_parse"
  defp raw_git_step(["status" | _rest]), do: "status_porcelain"
  defp raw_git_step(["fetch" | _rest]), do: "fetch_origin"
  defp raw_git_step(["reset" | _rest]), do: "reset_hard"
  defp raw_git_step(["clean" | _rest]), do: "clean_untracked"
  defp raw_git_step(args), do: Enum.join(args, "_")

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())
    root_prefix = root <> "/"

    cond do
      expanded_workspace == root ->
        {:error, {:workspace_equals_root, expanded_workspace, root}}

      String.starts_with?(expanded_workspace <> "/", root_prefix) ->
        ensure_no_symlink_components(expanded_workspace, root)

      true ->
        {:error, {:workspace_outside_root, expanded_workspace, root}}
    end
  end

  defp ensure_no_symlink_components(workspace, root) do
    workspace
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current_path ->
      next_path = Path.join(current_path, segment)

      case File.lstat(next_path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:workspace_symlink_escape, next_path, root}}}

        {:ok, _stat} ->
          {:cont, next_path}

        {:error, :enoent} ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, {:workspace_path_unreadable, next_path, reason}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _reason} = error -> error
      _final_path -> :ok
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
