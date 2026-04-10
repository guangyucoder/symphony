defmodule SymphonyElixir.DocImpact do
  @moduledoc """
  Lightweight doc-impact check. Determines if code changes may have
  made documentation stale.

  First version uses heuristic rules:
  - Changed architecture-sensitive files without docs changes → :stale
  - Changed only tests/styles/minor files → :fresh
  """

  @doc_sensitive_patterns [
    ~r/^AGENTS\.md$/,
    ~r/^CLAUDE\.md$/,
    ~r/^docs\//,
    ~r/^WORKFLOW\.md$/
  ]

  @architecture_sensitive_patterns [
    ~r/^src\/screens\//,
    ~r/^src\/store\//,
    ~r/^src\/utils\//,
    ~r/^src\/types\//,
    ~r/^apps\//,
    ~r/^mobile-app\/src\//,
    ~r/^lib\//,
    ~r/^scripts\//
  ]

  @type result :: {:ok, :fresh} | {:ok, {:stale, String.t()}} | {:error, term()}

  @doc """
  Check if changed files suggest docs may be stale.
  """
  @spec check(Path.t(), [String.t()]) :: result()
  def check(_workspace, []), do: {:ok, :fresh}

  def check(_workspace, changed_files) when is_list(changed_files) do
    has_doc_changes = Enum.any?(changed_files, &matches_any?(&1, @doc_sensitive_patterns))
    has_arch_changes = Enum.any?(changed_files, &matches_any?(&1, @architecture_sensitive_patterns))

    cond do
      has_arch_changes and not has_doc_changes ->
        {:ok, {:stale, "Architecture-sensitive files changed without doc updates: #{inspect(Enum.take(changed_files, 3))}"}}

      true ->
        {:ok, :fresh}
    end
  end

  def check(_workspace, _), do: {:ok, :fresh}

  defp matches_any?(file, patterns) do
    Enum.any?(patterns, &Regex.match?(&1, file))
  end
end
