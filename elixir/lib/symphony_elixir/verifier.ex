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
    task = Task.async(fn ->
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
