defmodule SymphonyElixir.MarkerParser do
  @moduledoc false

  defmodule Marker do
    @enforce_keys [:kind, :round_id, :stage_round, :reviewed_sha, :issue_identifier]
    defstruct @enforce_keys ++ [:verdict, :findings, :docfix_outcome]
  end

  @region_regex ~r/<!--\s*SYMPHONY-MARKERS-BEGIN\s*-->(.*?)<!--\s*SYMPHONY-MARKERS-END\s*-->/ms
  @marker_regex ~r/^[ \t]*```symphony-marker[ \t]*\R(.*?)^[ \t]*```[ \t]*$/ms
  @sha_regex ~r/^[0-9a-f]{40}$/
  @kinds %{
    "review-request" => :review_request,
    "code-review" => :code_review,
    "docs-checked" => :docs_checked
  }
  @verdicts %{"clean" => :clean, "findings" => :findings}
  @docfix_outcomes %{"no-updates" => :no_updates, "updated" => :updated}
  @severities %{"high" => :high, "medium" => :medium, "low" => :low}

  def parse(workpad, issue_identifier) when is_binary(workpad) and is_binary(issue_identifier) do
    case Regex.run(@region_regex, workpad, capture: :all_but_first) do
      [region] ->
        Regex.scan(@marker_regex, region, capture: :all_but_first)
        |> Enum.reduce([], fn [yaml], acc ->
          case parse_marker(yaml) do
            %Marker{issue_identifier: ^issue_identifier} = marker -> [marker | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  def review_pending?(markers) do
    case current_round(markers)
         |> Enum.filter(&(&1.kind in [:review_request, :code_review]))
         |> List.last() do
      %Marker{kind: :review_request} -> true
      _ -> false
    end
  end

  def latest_code_review(markers) do
    current_round(markers)
    |> Enum.filter(&match?(%Marker{kind: :code_review}, &1))
    |> List.last()
  end

  def latest_review_sha(markers) do
    case latest_code_review(markers) do
      %Marker{verdict: :clean, reviewed_sha: reviewed_sha} -> reviewed_sha
      _ -> nil
    end
  end

  def docs_checked_matches_review?(markers) do
    case latest_review_sha(markers) do
      nil ->
        false

      reviewed_sha ->
        case current_round(markers) |> Enum.filter(&(&1.kind == :docs_checked)) |> List.last() do
          %Marker{reviewed_sha: ^reviewed_sha} -> true
          _ -> false
        end
    end
  end

  defp parse_marker(yaml) do
    with {:ok, decoded} <- YamlElixir.read_from_string(yaml),
         true <- is_map(decoded),
         {:ok, common} <- parse_common(decoded),
         {:ok, kind_fields} <- parse_kind_fields(decoded, common.kind) do
      struct(Marker, Map.merge(common, kind_fields))
    else
      _ -> nil
    end
  end

  defp parse_common(decoded) do
    with {:ok, kind} <- enum(@kinds, field(decoded, "kind")),
         {:ok, round_id} <- positive_integer(field(decoded, "round_id")),
         {:ok, stage_round} <- positive_integer(field(decoded, "stage_round")),
         {:ok, reviewed_sha} <- sha(field(decoded, "reviewed_sha")),
         {:ok, issue_identifier} <- non_empty(field(decoded, "issue_identifier")) do
      {:ok,
       %{
         kind: kind,
         round_id: round_id,
         stage_round: stage_round,
         reviewed_sha: reviewed_sha,
         issue_identifier: issue_identifier
       }}
    else
      _ -> :error
    end
  end

  defp parse_kind_fields(_decoded, :review_request), do: {:ok, %{}}

  defp parse_kind_fields(decoded, :code_review) do
    with {:ok, verdict} <- enum(@verdicts, field(decoded, "verdict")) do
      # findings is optional + informational; malformed findings must not drop the marker
      findings =
        case parse_findings(field(decoded, "findings")) do
          {:ok, parsed} -> parsed
          :error -> nil
        end

      {:ok, %{verdict: verdict, findings: findings}}
    else
      _ -> :error
    end
  end

  defp parse_kind_fields(decoded, :docs_checked) do
    with {:ok, docfix_outcome} <- enum(@docfix_outcomes, field(decoded, "docfix_outcome")) do
      {:ok, %{docfix_outcome: docfix_outcome}}
    else
      _ -> :error
    end
  end

  defp parse_findings(nil), do: {:ok, nil}

  defp parse_findings(findings) when is_list(findings) do
    Enum.reduce_while(findings, {:ok, []}, fn finding, {:ok, acc} ->
      with true <- is_map(finding),
           {:ok, severity} <- enum(@severities, field(finding, "severity")),
           summary when is_binary(summary) <- field(finding, "summary") do
        {:cont, {:ok, [%{severity: severity, summary: summary} | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      _ -> :error
    end
  end

  defp parse_findings(_), do: :error

  defp current_round(markers) do
    current_round = markers |> Enum.map(& &1.round_id) |> Enum.max(fn -> 0 end)
    Enum.filter(markers, &(&1.round_id == current_round))
  end

  defp field(map, key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {atom_key, value} when is_atom(atom_key) ->
          if Atom.to_string(atom_key) == key, do: value

        _ ->
          nil
      end)
  end

  defp enum(mapping, value) do
    case mapping[value] do
      nil -> :error
      parsed -> {:ok, parsed}
    end
  end

  defp positive_integer(value) when is_integer(value) and value >= 1, do: {:ok, value}
  defp positive_integer(_), do: :error

  defp sha(value) when is_binary(value) do
    if String.match?(value, @sha_regex), do: {:ok, value}, else: :error
  end

  defp sha(_), do: :error

  defp non_empty(value) when is_binary(value) do
    if String.trim(value) != "", do: {:ok, value}, else: :error
  end

  defp non_empty(_), do: :error
end
