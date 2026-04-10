defmodule SymphonyElixir.Ledger do
  @moduledoc """
  Append-only JSONL event ledger for unit-lite execution history.
  Each line is a self-contained JSON event. Crash-safe: partial last line
  is skipped on read.
  """

  require Logger

  @ledger_file "ledger.jsonl"

  @doc "Append an event to the ledger."
  @spec append(Path.t(), atom() | String.t(), map()) :: :ok | {:error, term()}
  def append(workspace, event, payload \\ %{}) when is_binary(workspace) do
    path = ledger_path(workspace)
    dir = Path.dirname(path)

    entry = %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "event" => to_string(event),
      "payload" => payload
    }

    with :ok <- File.mkdir_p(dir),
         {:ok, json} <- Jason.encode(entry) do
      File.write(path, json <> "\n", [:append])
    end
  end

  @doc "Read all ledger entries. Skips corrupt/partial lines."
  @spec read(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def read(workspace) do
    path = ledger_path(workspace)

    case File.read(path) do
      {:ok, contents} ->
        entries =
          contents
          |> String.split("\n", trim: true)
          |> Enum.reduce([], fn line, acc ->
            case Jason.decode(line) do
              {:ok, entry} -> [entry | acc]
              {:error, _} ->
                Logger.warning("Ledger: skipping corrupt line in #{path}")
                acc
            end
          end)
          |> Enum.reverse()

        {:ok, entries}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Convenience: append unit_started event."
  @spec unit_started(Path.t(), map()) :: :ok | {:error, term()}
  def unit_started(workspace, unit) do
    append(workspace, :unit_started, Map.take(unit, ["kind", "subtask_id"]))
  end

  @doc "Convenience: append unit_accepted event with optional token stats."
  @spec unit_accepted(Path.t(), map(), map()) :: :ok | {:error, term()}
  def unit_accepted(workspace, unit, extra \\ %{}) do
    payload = Map.take(unit, ["kind", "subtask_id"]) |> Map.merge(extra)
    append(workspace, :unit_accepted, payload)
  end

  @doc "Convenience: append unit_tokens event (token usage for a completed unit)."
  @spec unit_tokens(Path.t(), map(), map()) :: :ok | {:error, term()}
  def unit_tokens(workspace, unit, token_stats) do
    payload = Map.take(unit, ["kind", "subtask_id"]) |> Map.merge(%{
      "input_tokens" => token_stats[:input_tokens] || 0,
      "output_tokens" => token_stats[:output_tokens] || 0,
      "total_tokens" => token_stats[:total_tokens] || 0
    })
    append(workspace, :unit_tokens, payload)
  end

  @doc "Convenience: append unit_failed event."
  @spec unit_failed(Path.t(), map(), String.t()) :: :ok | {:error, term()}
  def unit_failed(workspace, unit, reason) do
    payload = Map.take(unit, ["kind", "subtask_id"]) |> Map.put("reason", reason)
    append(workspace, :unit_failed, payload)
  end

  @doc "Convenience: append verify_passed event."
  @spec verify_passed(Path.t(), String.t()) :: :ok | {:error, term()}
  def verify_passed(workspace, sha) do
    append(workspace, :verify_passed, %{"sha" => sha})
  end

  @doc "Convenience: append doc_fix_required event."
  @spec doc_fix_required(Path.t(), String.t()) :: :ok | {:error, term()}
  def doc_fix_required(workspace, reason) do
    append(workspace, :doc_fix_required, %{"reason" => reason})
  end

  # --- Private ---

  defp ledger_path(workspace) do
    Path.join([workspace, ".symphony", @ledger_file])
  end
end
