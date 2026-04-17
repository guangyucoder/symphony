defmodule SymphonyElixir.Unit do
  @moduledoc """
  Lightweight struct representing a single dispatchable unit of work
  in unit-lite mode.
  """

  @type kind ::
          :bootstrap
          | :plan
          | :implement_subtask
          | :doc_fix
          | :verify
          | :code_review
          | :handoff
          | :merge

  @type reasoning_effort :: String.t()

  @type t :: %__MODULE__{
          kind: kind(),
          subtask_id: String.t() | nil,
          subtask_text: String.t() | nil,
          display_name: String.t(),
          attempt: pos_integer(),
          reasoning_effort: reasoning_effort()
        }

  @enforce_keys [:kind, :display_name]
  defstruct [
    :kind,
    :subtask_id,
    :subtask_text,
    display_name: "",
    attempt: 1,
    reasoning_effort: "high"
  ]

  def bootstrap, do: %__MODULE__{kind: :bootstrap, display_name: "bootstrap", reasoning_effort: "low"}
  def plan, do: %__MODULE__{kind: :plan, display_name: "plan", reasoning_effort: "xhigh"}

  def implement_subtask(subtask_id, subtask_text \\ nil) do
    %__MODULE__{
      kind: :implement_subtask,
      subtask_id: subtask_id,
      subtask_text: subtask_text,
      display_name: "implement_subtask:#{subtask_id}",
      reasoning_effort: "medium"
    }
  end

  def doc_fix, do: %__MODULE__{kind: :doc_fix, display_name: "doc_fix", reasoning_effort: "medium"}
  def verify, do: %__MODULE__{kind: :verify, display_name: "verify", reasoning_effort: "medium"}
  def code_review, do: %__MODULE__{kind: :code_review, display_name: "code_review", reasoning_effort: "high"}
  def handoff, do: %__MODULE__{kind: :handoff, display_name: "handoff", reasoning_effort: "low"}
  def merge, do: %__MODULE__{kind: :merge, display_name: "merge", reasoning_effort: "low"}

  @doc "Convert to a map suitable for issue_exec.json storage."
  def to_map(%__MODULE__{} = unit) do
    %{
      "kind" => to_string(unit.kind),
      "subtask_id" => unit.subtask_id,
      "attempt" => unit.attempt,
      "reasoning_effort" => unit.reasoning_effort
    }
  end
end
