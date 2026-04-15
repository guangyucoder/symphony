defmodule SymphonyElixir.IssueExec do
  @moduledoc """
  Reads and writes the per-issue durable execution state (`.symphony/issue_exec.json`).
  This is the orchestrator's view of where the issue stands in the unit-lite flow.
  """

  require Logger

  @state_file "issue_exec.json"

  @type t :: %{
          mode: String.t(),
          phase: String.t(),
          current_unit: map() | nil,
          last_accepted_unit: map() | nil,
          last_commit_sha: String.t() | nil,
          last_verified_sha: String.t() | nil,
          baseline_verify_failed: boolean(),
          baseline_verify_output: String.t() | nil,
          bootstrapped: boolean(),
          plan_version: non_neg_integer(),
          updated_at: String.t()
        }

  @default_state %{
    "mode" => "unit_lite",
    "phase" => "bootstrap",
    "current_unit" => nil,
    "last_accepted_unit" => nil,
    "last_commit_sha" => nil,
    "last_verified_sha" => nil,
    "baseline_verify_failed" => false,
    "baseline_verify_output" => nil,
    "rework_fix_applied" => false,
    "bootstrapped" => false,
    "plan_version" => 0,
    "verify_error" => nil,
    "verify_attempt" => 0,
    "verify_fix_count" => 0,
    "merge_conflict" => false,
    "merge_sync_count" => 0,
    "mergeability_unknown_count" => 0,
    "merge_needs_verify" => false,
    "updated_at" => nil
  }

  @doc "Read issue_exec.json from workspace, returning default state if missing."
  @spec read(Path.t()) :: {:ok, map()} | {:error, term()}
  def read(workspace) do
    path = state_path(workspace)

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, state} -> {:ok, Map.merge(@default_state, state)}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:error, :enoent} ->
        {:ok, @default_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Initialize issue_exec.json with default state."
  @spec init(Path.t()) :: :ok | {:error, term()}
  def init(workspace) do
    state = Map.put(@default_state, "updated_at", DateTime.utc_now() |> DateTime.to_iso8601())
    atomic_write(workspace, state)
  end

  @doc "Update specific fields in issue_exec.json atomically."
  @spec update(Path.t(), map()) :: :ok | {:error, term()}
  def update(workspace, changes) when is_map(changes) do
    with {:ok, current} <- read(workspace) do
      updated =
        current
        |> Map.merge(changes)
        |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

      atomic_write(workspace, updated)
    end
  end

  @doc "Record that a unit has started."
  @spec start_unit(Path.t(), map()) :: :ok | {:error, term()}
  def start_unit(workspace, unit) do
    update(workspace, %{
      "current_unit" => unit,
      "phase" => unit_to_phase(unit)
    })
  end

  @doc "Record that the current unit has been accepted."
  @spec accept_unit(Path.t()) :: :ok | {:error, term()}
  def accept_unit(workspace) do
    with {:ok, state} <- read(workspace) do
      update(workspace, %{
        "last_accepted_unit" => state["current_unit"],
        "current_unit" => nil
      })
    end
  end

  @doc "Set the last verified SHA."
  @spec set_verified_sha(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_verified_sha(workspace, sha) do
    update(workspace, %{"last_verified_sha" => sha})
  end

  @doc "Set the last commit SHA."
  @spec set_commit_sha(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_commit_sha(workspace, sha) do
    update(workspace, %{"last_commit_sha" => sha})
  end

  @doc "Mark bootstrap complete."
  @spec mark_bootstrapped(Path.t()) :: :ok | {:error, term()}
  def mark_bootstrapped(workspace) do
    update(workspace, %{"bootstrapped" => true})
  end

  @doc "Record a baseline verification failure for downstream units."
  @spec set_baseline_verify_failure(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_baseline_verify_failure(workspace, output) when is_binary(output) do
    update(workspace, %{
      "baseline_verify_failed" => true,
      "baseline_verify_output" => output
    })
  end

  @doc "Clear any recorded baseline verification failure."
  @spec clear_baseline_verify_failure(Path.t()) :: :ok | {:error, term()}
  def clear_baseline_verify_failure(workspace) do
    update(workspace, %{
      "baseline_verify_failed" => false,
      "baseline_verify_output" => nil
    })
  end

  @doc "Bump plan version."
  @spec bump_plan_version(Path.t()) :: :ok | {:error, term()}
  def bump_plan_version(workspace) do
    with {:ok, state} <- read(workspace) do
      update(workspace, %{"plan_version" => (state["plan_version"] || 0) + 1})
    end
  end

  @doc "Set the verify error (verification failed, needs code fix)."
  @spec set_verify_error(Path.t(), String.t()) :: :ok | {:error, term()}
  def set_verify_error(workspace, error) when is_binary(error) do
    update(workspace, %{"verify_error" => error})
  end

  @doc "Clear the verify error (fix applied, ready to re-verify)."
  @spec clear_verify_error(Path.t()) :: :ok | {:error, term()}
  def clear_verify_error(workspace) do
    update(workspace, %{"verify_error" => nil})
  end

  @doc "Reset for rework: clear subtask progress, keep bootstrapped."
  @spec reset_for_rework(Path.t()) :: :ok | {:error, term()}
  def reset_for_rework(workspace) do
    update(workspace, %{
      "phase" => "planning",
      "current_unit" => nil,
      "last_accepted_unit" => nil,
      "last_verified_sha" => nil,
      "verify_error" => nil,
      "verify_attempt" => 0,
      "verify_fix_count" => 0,
      "merge_conflict" => false,
      "merge_sync_count" => 0,
      "mergeability_unknown_count" => 0,
      "merge_needs_verify" => false
    })
  end

  # --- Private ---

  defp state_path(workspace) do
    Path.join([workspace, ".symphony", @state_file])
  end

  defp atomic_write(workspace, state) do
    path = state_path(workspace)
    dir = Path.dirname(path)
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(dir),
         {:ok, json} <- Jason.encode(state, pretty: true),
         :ok <- File.write(tmp_path, json),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp unit_to_phase(%{"kind" => "bootstrap"}), do: "bootstrap"
  defp unit_to_phase(%{"kind" => "plan"}), do: "planning"
  defp unit_to_phase(%{"kind" => "implement_subtask"}), do: "implementing"
  defp unit_to_phase(%{"kind" => "doc_fix"}), do: "doc_fix"
  defp unit_to_phase(%{"kind" => "verify"}), do: "verifying"
  defp unit_to_phase(%{"kind" => "handoff"}), do: "handoff"
  defp unit_to_phase(%{"kind" => "merge"}), do: "merging"
  defp unit_to_phase(_), do: "unknown"
end
