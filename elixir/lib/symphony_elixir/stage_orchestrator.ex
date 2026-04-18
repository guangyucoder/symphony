defmodule SymphonyElixir.StageOrchestrator do
  @moduledoc false

  alias SymphonyElixir.{AgentRunner, Config, MarkerParser, Workflow}

  @region_regex ~r/<!--\s*SYMPHONY-MARKERS-BEGIN\s*-->(.*?)<!--\s*SYMPHONY-MARKERS-END\s*-->/ms
  @issue_identifier_regex ~r/^\s*issue_identifier:\s*(.+?)\s*$/m

  @type stage :: :review | :doc_fix | :implement | :stop

  @spec next_stage(String.t() | nil, String.t() | nil, Path.t()) :: stage()
  def next_stage(workpad, linear_state, workspace_path) do
    markers = parse_markers(workpad)
    latest_verdict = latest_code_review_verdict(markers)
    latest_review_sha = MarkerParser.latest_review_sha(markers)
    docs_checked_matches_review? = MarkerParser.docs_checked_matches_review?(markers)

    cond do
      linear_state == "Rework" ->
        :implement

      not active_issue_state?(linear_state) ->
        :stop

      MarkerParser.review_pending?(markers) ->
        :review

      latest_verdict == :findings ->
        :implement

      latest_verdict == :clean ->
        current_head = current_head(workspace_path)

        cond do
          latest_review_sha != current_head ->
            :review

          not docs_checked_matches_review? ->
            :doc_fix

          docs_checked_matches_review? and latest_review_sha == current_head ->
            :implement
        end

      true ->
        :implement
    end
  end

  @spec dispatch(SymphonyElixir.Linear.Issue.t(), stage()) :: :ok | no_return()
  def dispatch(_issue, :stop), do: :ok

  def dispatch(issue, stage) when stage in [:review, :doc_fix, :implement] do
    agent_runner_module().run(issue, nil, workflow_path: workflow_path_for(stage), max_turns: 1)
  end

  defp latest_code_review_verdict(markers) do
    case MarkerParser.latest_code_review(markers) do
      %{verdict: verdict} -> verdict
      _ -> nil
    end
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_state/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.any?(&(&1 == normalized_state))
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_state(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  # next_stage/3 only receives workpad text, so we pick the issue_identifier that
  # yields the largest internally-valid marker set inside the bounded marker region.
  defp parse_markers(workpad) when is_binary(workpad) do
    workpad
    |> candidate_issue_identifiers()
    |> Enum.reduce([], fn issue_identifier, best_markers ->
      parsed_markers = MarkerParser.parse(workpad, issue_identifier)
      if length(parsed_markers) > length(best_markers), do: parsed_markers, else: best_markers
    end)
  end

  defp parse_markers(_workpad), do: []

  defp candidate_issue_identifiers(workpad) do
    case Regex.run(@region_regex, workpad, capture: :all_but_first) do
      [region] ->
        Regex.scan(@issue_identifier_regex, region, capture: :all_but_first)
        |> Enum.map(fn [raw_issue_identifier] -> normalize_issue_identifier(raw_issue_identifier) end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp normalize_issue_identifier(raw_issue_identifier) do
    trimmed = String.trim(raw_issue_identifier)

    case trimmed do
      <<quote, rest::binary>> when quote in [?", ?'] and rest != "" ->
        if String.ends_with?(rest, <<quote>>) do
          String.trim_trailing(rest, <<quote>>)
        else
          trimmed
        end

      _ ->
        trimmed
    end
  end

  defp current_head(workspace_path) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: workspace_path, stderr_to_stdout: true) do
      {head, 0} -> String.trim(head)
      _ -> nil
    end
  end

  defp workflow_path_for(:implement), do: Workflow.workflow_file_path()

  defp workflow_path_for(:review) do
    Path.join(Path.dirname(Workflow.workflow_file_path()), "WORKFLOW-review.md")
  end

  defp workflow_path_for(:doc_fix) do
    Path.join(Path.dirname(Workflow.workflow_file_path()), "WORKFLOW-docfix.md")
  end

  defp agent_runner_module do
    Application.get_env(:symphony_elixir, :stage_orchestrator_agent_runner_module, AgentRunner)
  end
end
