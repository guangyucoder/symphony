defmodule SymphonyElixir.WorkpadParser do
  @moduledoc """
  Parses the `### Plan` section from a Codex Workpad comment to extract
  a structured checklist of subtasks for unit-lite dispatch.

  Expected format (from WORKFLOW-production.md):

      ### Plan
      - [x] [plan-1] Completed item
      - [ ] [plan-2] Current item ← HERE
      - [ ] [plan-3] Remaining item

  Falls back to positional IDs (plan-1, plan-2, ...) when explicit IDs
  are missing.
  """

  @type subtask :: %{
          id: String.t(),
          text: String.t(),
          done: boolean(),
          touch: [String.t()],
          accept: String.t() | nil
        }

  # Matches: - [x] [plan-1] text  OR  * [ ] [plan-1] text
  @explicit_id_pattern ~r/^\s*[-*]\s+\[([ xX])\]\s+\[([^\]]+)\]\s+(.+)$/
  # Matches: - [x] text  OR  * [ ] text (no explicit ID)
  @implicit_id_pattern ~r/^\s*[-*]\s+\[([ xX])\]\s+(.+)$/
  @continuation_pattern ~r/^\s+[-*]\s+([[:alpha:]]+)\s*:\s*(.*?)\s*$/

  @doc """
  Parse workpad text and extract subtask checklist from the `### Plan` section.
  Returns {:ok, subtasks} or {:error, reason}.
  """
  @spec parse(String.t()) :: {:ok, [subtask()]} | {:error, atom()}
  def parse(workpad_text) when is_binary(workpad_text) do
    case extract_plan_section(workpad_text) do
      nil ->
        {:error, :no_plan_section}

      plan_text ->
        subtasks = parse_checklist(plan_text)

        if subtasks == [] do
          {:error, :no_checklist_items}
        else
          {:ok, subtasks}
        end
    end
  end

  def parse(_), do: {:error, :invalid_input}

  @doc "Return only pending (unchecked) subtasks."
  @spec pending(String.t()) :: {:ok, [subtask()]} | {:error, atom()}
  def pending(workpad_text) do
    case parse(workpad_text) do
      {:ok, subtasks} -> {:ok, Enum.filter(subtasks, &(not &1.done))}
      error -> error
    end
  end

  @doc "Return the next unchecked subtask, or nil."
  @spec next_pending(String.t()) :: subtask() | nil
  def next_pending(workpad_text) do
    case pending(workpad_text) do
      {:ok, [next | _]} -> next
      _ -> nil
    end
  end

  @doc "Check if all subtasks are done."
  @spec all_done?(String.t()) :: boolean()
  def all_done?(workpad_text) do
    case parse(workpad_text) do
      {:ok, subtasks} -> Enum.all?(subtasks, & &1.done)
      _ -> false
    end
  end

  # --- Private ---

  defp extract_plan_section(text) do
    # Find ### Plan header, capture until next ### or end
    case Regex.run(~r/###\s*Plan\s*\n(.*?)(?=\n###|\z)/s, text) do
      [_, section] -> String.trim(section)
      _ -> nil
    end
  end

  defp parse_checklist(plan_text) do
    plan_text
    |> String.split("\n")
    |> Enum.reduce({[], nil, 1}, &collect_checklist_line/2)
    |> finalize_checklist_groups()
    |> Enum.map(&parse_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp collect_checklist_line(line, {items, current_item, index}) do
    cond do
      checklist_item_line?(line) ->
        {
          maybe_push_item(items, current_item),
          %{line: line, index: index, continuation_lines: []},
          index + 1
        }

      heading_line?(line) ->
        {maybe_push_item(items, current_item), nil, index}

      current_item && continuation_line?(line) ->
        continuation_lines = current_item.continuation_lines ++ [line]
        {items, %{current_item | continuation_lines: continuation_lines}, index}

      true ->
        {items, current_item, index}
    end
  end

  defp finalize_checklist_groups({items, current_item, _index}) do
    items
    |> maybe_push_item(current_item)
    |> Enum.reverse()
  end

  defp maybe_push_item(items, nil), do: items
  defp maybe_push_item(items, item), do: [item | items]

  defp parse_item(%{line: line, index: index, continuation_lines: continuation_lines}) do
    contract = parse_contract(continuation_lines)

    cond do
      # Try explicit ID first: - [x] [plan-1] text
      match = Regex.run(@explicit_id_pattern, line) ->
        [_, check, id, text] = match

        %{id: id, text: String.trim(text), done: checked?(check)}
        |> Map.merge(contract)

      # Fall back to implicit ID: - [x] text
      match = Regex.run(@implicit_id_pattern, line) ->
        [_, check, text] = match

        %{id: "plan-#{index}", text: String.trim(text), done: checked?(check)}
        |> Map.merge(contract)

      true ->
        nil
    end
  end

  defp parse_contract(lines) do
    Enum.reduce(lines, %{touch: [], accept: nil}, fn line, acc ->
      case parse_continuation_line(line) do
        {:touch, paths} ->
          %{acc | touch: acc.touch ++ paths}

        {:accept, nil} ->
          acc

        {:accept, accept} ->
          %{acc | accept: accept}

        nil ->
          acc
      end
    end)
  end

  defp parse_continuation_line(line) do
    case Regex.run(@continuation_pattern, line) do
      [_, key, value] ->
        case String.downcase(key) do
          "touch" ->
            {:touch, split_touch_paths(value)}

          "accept" ->
            {:accept, normalized_value(value)}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp split_touch_paths(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalized_value(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp checklist_item_line?(line) do
    Regex.match?(@explicit_id_pattern, line) or Regex.match?(@implicit_id_pattern, line)
  end

  defp continuation_line?(line), do: Regex.match?(@continuation_pattern, line)
  defp heading_line?(line), do: Regex.match?(~r/^\s*###/, line)

  defp checked?(check), do: check in ["x", "X"]
end
