defmodule SymphonyElixir.Verifier do
  @moduledoc """
  Runs verification commands in the workspace. Orchestrator-owned —
  the agent cannot bypass or influence the result.

  Two modes:
  - `:baseline` — lightweight check before any code changes
  - `:full` — complete validation before handoff
  """

  require Logger

  @default_timeout_ms 300_000

  @type result :: :pass | {:fail, String.t()}

  @doc """
  Run configured verification commands in the workspace.
  Returns `:pass` or `{:fail, output}`.
  """
  @spec run(Path.t(), keyword()) :: result()
  def run(workspace, opts \\ []) do
    commands = Keyword.get(opts, :commands, default_commands())
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    if commands == [] do
      :pass
    else
      run_commands(commands, workspace, timeout_ms)
    end
  end

  @doc "Run baseline validation (subset of commands, or same commands)."
  @spec run_baseline(Path.t(), keyword()) :: result()
  def run_baseline(workspace, opts \\ []) do
    commands = Keyword.get(opts, :commands, baseline_commands())
    run(workspace, Keyword.put(opts, :commands, commands))
  end

  @doc "Get the current git HEAD SHA."
  @spec current_head(Path.t()) :: String.t() | nil
  def current_head(workspace) do
    case run_git(workspace, ["rev-parse", "HEAD"], 5_000) do
      {:ok, sha} -> String.trim(sha)
      _ -> nil
    end
  end

  @doc "Return `git status -sb --porcelain=v1` output, or nil on failure. Diagnostic only."
  @spec git_status(Path.t()) :: String.t() | nil
  def git_status(workspace) do
    case run_git(workspace, ["status", "-sb", "--porcelain=v1"], 5_000) do
      {:ok, out} -> String.trim(out)
      _ -> nil
    end
  end

  @doc """
  Return true if the working tree has any uncommitted changes or untracked
  files. Used by closeout to distinguish legitimate no-op units from
  "agent forgot to commit". On git failure, returns true (fail-closed —
  treat as dirty so the dispatch retries rather than accepts).
  """
  @spec dirty_working_tree?(Path.t()) :: boolean()
  def dirty_working_tree?(workspace) do
    case run_git(workspace, ["status", "--porcelain=v1", "--untracked-files=all"], 5_000) do
      {:ok, out} -> String.trim(out) != ""
      _ -> true
    end
  end

  @doc "Return `git diff HEAD --stat` output, or nil on failure. Diagnostic only."
  @spec git_diff_stat(Path.t()) :: String.t() | nil
  def git_diff_stat(workspace) do
    case run_git(workspace, ["diff", "HEAD", "--stat"], 5_000) do
      {:ok, out} -> String.trim(out)
      _ -> nil
    end
  end

  @pr_check_timeout_ms 15_000
  @merge_timeout_ms 60_000

  @doc """
  Check CI status for the current branch's PR.
  Returns `:pass`, `:pending`, `{:fail, summary}`, or `:unknown`.
  """
  @spec check_ci_status(Path.t()) :: :pass | :pending | {:fail, String.t()} | :unknown
  def check_ci_status(workspace) do
    task =
      Task.async(fn ->
        try do
          jq = "[.[] | .state] | if length == 0 then \"none\" elif all(. == \"SUCCESS\" or . == \"SKIPPED\") then \"pass\" elif any(. == \"FAILURE\") then \"fail\" else \"pending\" end"
          System.cmd("gh", ["pr", "checks", "--json", "state", "--jq", jq], cd: workspace, stderr_to_stdout: true)
        rescue
          _ -> {"gh not available", 127}
        end
      end)

    case Task.yield(task, @pr_check_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        case String.trim(output) do
          "pass" -> :pass
          "pending" -> :pending
          "none" -> :pass
          "fail" -> {:fail, "CI checks failed"}
          other -> {:fail, "CI status: #{other}"}
        end

      {:ok, {_output, _}} ->
        :unknown

      nil ->
        :unknown
    end
  end

  @doc """
  Merge the PR for the current branch. Returns :ok or {:error, output}.
  """
  @spec merge_pr(Path.t()) :: :ok | {:error, String.t()}
  def merge_pr(workspace) do
    task =
      Task.async(fn ->
        try do
          System.cmd("gh", ["pr", "merge", "--squash", "--delete-branch"], cd: workspace, stderr_to_stdout: true)
        rescue
          _ -> {"gh not available", 127}
        end
      end)

    case Task.yield(task, @merge_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, _}} -> {:error, String.trim(output)}
      nil -> {:error, "merge timed out"}
    end
  end

  @doc """
  Check whether the PR for the current branch can be merged without conflicts.
  Returns `:mergeable`, `:conflicting`, or `:unknown`.

  GitHub computes mergeability asynchronously after a push; during that window
  `gh pr view` can report `UNKNOWN` for 10–60s. Callers should treat `:unknown`
  as transient and retry rather than escalate immediately.
  """
  @spec check_pr_mergeability(Path.t()) :: :mergeable | :conflicting | :unknown
  def check_pr_mergeability(workspace) do
    task =
      Task.async(fn ->
        try do
          System.cmd("gh", ["pr", "view", "--json", "mergeable", "--jq", ".mergeable"], cd: workspace, stderr_to_stdout: true)
        rescue
          _ -> {"gh not available", 127}
        end
      end)

    case Task.yield(task, @pr_check_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        case String.trim(output) do
          "MERGEABLE" -> :mergeable
          "CONFLICTING" -> :conflicting
          _ -> :unknown
        end

      {:ok, {output, _exit_code}} ->
        Logger.warning("Verifier: gh pr view (mergeable) failed: #{String.slice(output, 0, 200)}")
        :unknown

      nil ->
        Logger.warning("Verifier: gh pr view (mergeable) timed out")
        :unknown
    end
  end

  @doc """
  Check whether the PR for the current branch has been merged on the remote.
  Returns `:merged`, `{:not_merged, reason}`, or `:unknown`.
  """
  @spec check_pr_merged(Path.t()) :: :merged | {:not_merged, String.t()} | :unknown
  def check_pr_merged(workspace) do
    task =
      Task.async(fn ->
        try do
          System.cmd("gh", ["pr", "view", "--json", "state", "--jq", ".state"], cd: workspace, stderr_to_stdout: true)
        rescue
          _ -> {"gh not available", 127}
        end
      end)

    case Task.yield(task, @pr_check_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        case String.trim(output) do
          "MERGED" -> :merged
          state -> {:not_merged, "PR state: #{state}"}
        end

      {:ok, {output, _exit_code}} ->
        if String.contains?(output, "no pull requests found") do
          {:not_merged, "no PR found for current branch"}
        else
          Logger.warning("Verifier: gh pr view failed: #{String.slice(output, 0, 200)}")
          :unknown
        end

      nil ->
        Logger.warning("Verifier: gh pr view timed out")
        :unknown
    end
  end

  # --- Private ---

  defp run_commands(commands, workspace, timeout_ms) do
    results = Enum.map(commands, &run_single_command(&1, workspace, timeout_ms))

    case Enum.find(results, &match?({:fail, _}, &1)) do
      nil -> :pass
      failure -> failure
    end
  end

  defp run_single_command(command, workspace, timeout_ms) do
    Logger.info("Verifier: running `#{command}` in #{workspace}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} ->
        :pass

      {:ok, {output, status}} ->
        truncated = truncate(output, 4096)
        Logger.warning("Verifier: `#{command}` failed (exit #{status})")
        {:fail, "Command `#{command}` failed (exit #{status}):\n#{truncated}"}

      nil ->
        Logger.warning("Verifier: `#{command}` timed out after #{timeout_ms}ms")
        {:fail, "Command `#{command}` timed out after #{timeout_ms}ms"}
    end
  end

  defp run_git(workspace, args, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      _ -> :error
    end
  end

  defp default_commands do
    case SymphonyElixir.Config.verification_full_commands() do
      commands when is_list(commands) and commands != [] -> commands
      _ -> []
    end
  end

  defp baseline_commands do
    case SymphonyElixir.Config.verification_baseline_commands() do
      commands when is_list(commands) and commands != [] -> commands
      _ -> default_commands()
    end
  end

  defp truncate(text, max_chars) do
    binary = IO.iodata_to_binary(text)

    if String.length(binary) <= max_chars do
      binary
    else
      String.slice(binary, 0, max_chars) <> "\n... (truncated)"
    end
  end
end
