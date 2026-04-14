defmodule SymphonyElixir.UnitLog do
  @moduledoc """
  Per-unit debug log writer.

  Writes structured JSONL events to `.symphony/units/<kind>-<attempt>-<timestamp>.jsonl`.
  One file per unit execution. Only logs operationally meaningful events:
  tool calls, command executions, file changes, reasoning summaries, errors.

  Not logged: streaming token deltas, raw JSON-RPC, dashboard renders.
  """

  require Logger

  @units_dir "units"

  @doc "Open a log file for a unit. Returns {:ok, path} or {:error, reason}."
  @spec open(Path.t(), map()) :: {:ok, Path.t()} | {:error, term()}
  def open(workspace, unit) do
    dir = Path.join([workspace, ".symphony", @units_dir])
    File.mkdir_p(dir)

    kind = unit.display_name |> String.replace(~r/[^a-zA-Z0-9_:-]/, "_")
    attempt = unit.attempt || 1
    ts = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:.]+/, "") |> String.slice(0, 15)
    filename = "#{kind}-#{attempt}-#{ts}.jsonl"
    path = Path.join(dir, filename)

    {:ok, path}
  end

  @doc "Write the full prompt that was sent to the agent, verbatim."
  @spec log_prompt(Path.t(), String.t()) :: :ok
  def log_prompt(path, prompt) do
    append(path, "prompt", %{text: prompt})
  end

  @doc "Write closeout result."
  @spec log_closeout(Path.t(), atom() | tuple(), map()) :: :ok
  def log_closeout(path, result, token_stats) do
    result_str = case result do
      :accepted -> "accepted"
      {:retry, reason} -> "retry: #{reason}"
      {:fail, reason} -> "fail: #{reason}"
    end

    append(path, "closeout", %{
      result: result_str,
      input_tokens: token_stats[:input_tokens],
      output_tokens: token_stats[:output_tokens],
      total_tokens: token_stats[:total_tokens]
    })
  end

  @doc "Write an error."
  @spec log_error(Path.t(), String.t()) :: :ok
  def log_error(path, message) do
    append(path, "error", %{message: String.slice(to_string(message), 0, 2000)})
  end

  @doc """
  Extract and log interesting events from a Codex on_message callback.
  Filters out noise (streaming deltas, token updates) and keeps:
  tool calls, command executions, file changes, reasoning summaries.
  """
  @spec log_codex_event(Path.t(), map()) :: :ok
  def log_codex_event(path, message) when is_map(message) do
    case classify_event(message) do
      {:tool_call, data} -> append(path, "tool_call", data)
      {:command, data} -> append(path, "command", data)
      {:file_change, data} -> append(path, "file_change", data)
      {:reasoning, data} -> append(path, "reasoning", data)
      {:turn_event, data} -> append(path, "turn_event", data)
      :skip -> :ok
    end
  end

  def log_codex_event(_path, _message), do: :ok

  # --- Event classification ---

  defp classify_event(%{event: :tool_call_completed} = msg) do
    params = get_in_path(msg, [:payload, "params"]) || %{}
    {:tool_call, %{
      name: tool_name(params),
      args: truncate(inspect(tool_args(params)), 200)
    }}
  end

  defp classify_event(%{event: :tool_call_failed} = msg) do
    params = get_in_path(msg, [:payload, "params"]) || %{}
    {:tool_call, %{
      name: tool_name(params),
      args: truncate(inspect(tool_args(params)), 200),
      failed: true
    }}
  end

  defp classify_event(%{event: :approval_auto_approved} = msg) do
    payload = msg[:payload] || %{}
    method = payload["method"] || ""

    cond do
      String.contains?(method, "commandExecution") ->
        params = payload["params"] || %{}
        cmd = get_in_path(params, ["command", "command"]) ||
              get_in_path(params, ["commandLine"]) ||
              inspect(params)
        {:command, %{cmd: truncate(to_string(cmd), 500)}}

      String.contains?(method, "fileChange") ->
        params = payload["params"] || %{}
        file = params["path"] || params["filePath"] || "unknown"
        {:file_change, %{path: file}}

      true ->
        :skip
    end
  end

  defp classify_event(%{event: event})
       when event in [:turn_completed, :turn_failed, :turn_cancelled] do
    {:turn_event, %{event: event}}
  end

  # Reasoning summary (not streaming deltas)
  defp classify_event(%{payload: %{"method" => method}} = msg)
       when method in ["item/reasoning/summaryPartAdded"] do
    params = get_in_path(msg, [:payload, "params"]) || %{}
    text = get_in_path(params, ["part", "text"]) ||
           get_in_path(params, ["text"]) || ""

    if byte_size(text) > 10 do
      {:reasoning, %{summary: truncate(text, 500)}}
    else
      :skip
    end
  end

  defp classify_event(_), do: :skip

  # --- Helpers ---

  defp append(path, event_type, data) do
    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      type: event_type
    }
    |> Map.merge(data)

    line = Jason.encode!(entry) <> "\n"

    case File.write(path, line, [:append, :utf8]) do
      :ok -> :ok
      {:error, reason} ->
        Logger.debug("UnitLog: write failed #{reason}")
        :ok
    end
  end

  defp tool_name(params) when is_map(params) do
    Map.get(params, "tool") || Map.get(params, "name") || "unknown"
  end

  defp tool_name(_), do: "unknown"

  defp tool_args(params) when is_map(params) do
    Map.get(params, "arguments") || %{}
  end

  defp tool_args(_), do: %{}

  defp get_in_path(map, []) when is_map(map), do: map
  defp get_in_path(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nil -> nil
      val -> get_in_path(val, rest)
    end
  end
  defp get_in_path(_, _), do: nil

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "..."
  end

  defp truncate(text, max), do: truncate(to_string(text), max)
end
