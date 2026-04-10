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
          done: boolean()
        }

  # Matches: - [x] [plan-1] text  OR  - [ ] [plan-1] text
  @explicit_id_pattern ~r/^-\s+\[([ xX])\]\s+\[([^\]]+)\]\s+(.+)$/
  # Matches: - [x] text  OR  - [ ] text (no explicit ID)
  @implicit_id_pattern ~r/^-\s+\[([ xX])\]\s+(.+)$/

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
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "- ["))
    |> Enum.with_index(1)
    |> Enum.map(&parse_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_item({line, index}) do
    cond do
      # Try explicit ID first: - [x] [plan-1] text
      match = Regex.run(@explicit_id_pattern, line) ->
        [_, check, id, text] = match
        %{id: id, text: String.trim(text), done: checked?(check)}

      # Fall back to implicit ID: - [x] text
      match = Regex.run(@implicit_id_pattern, line) ->
        [_, check, text] = match
        %{id: "plan-#{index}", text: String.trim(text), done: checked?(check)}

      true ->
        nil
    end
  end

  defp checked?(check), do: check in ["x", "X"]
end
