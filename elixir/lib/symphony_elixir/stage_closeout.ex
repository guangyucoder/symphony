defmodule SymphonyElixir.StageCloseout do
  @moduledoc false

  alias SymphonyElixir.MarkerParser
  alias SymphonyElixir.MarkerParser.Marker

  @spec check_review(Path.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def check_review(workspace_path, workpad_text, dispatch_head_sha, issue_identifier) do
    markers = MarkerParser.parse(workpad_text, issue_identifier)

    with {:ok, head} <- current_head(workspace_path),
         :ok <- ensure_dispatch_head_matches(dispatch_head_sha, head),
         :ok <- ensure_marker_matches_head_and_clean_tree(workspace_path, markers, :code_review, head),
         :ok <- ensure_no_findings_to_clean_flip(markers) do
      :ok
    end
  end

  @spec check_doc_fix(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def check_doc_fix(workspace_path, workpad_text, issue_identifier) do
    markers = MarkerParser.parse(workpad_text, issue_identifier)

    with {:ok, head} <- current_head(workspace_path),
         :ok <- ensure_marker_matches_head_and_clean_tree(workspace_path, markers, :docs_checked, head),
         :ok <- ensure_only_docs_changed(workspace_path, markers) do
      :ok
    end
  end

  @spec check_implement(term(), term(), term()) :: :ok
  def check_implement(_, _, _), do: :ok

  defp ensure_dispatch_head_matches(dispatch_head_sha, dispatch_head_sha), do: :ok

  defp ensure_dispatch_head_matches(old_head, new_head) do
    {:error, {:reviewer_committed, old: old_head, new: new_head}}
  end

  defp ensure_marker_matches_head_and_clean_tree(workspace_path, markers, kind, head) do
    case latest_marker_of_kind(markers, kind) do
      nil ->
        {:error, {:missing_marker, kind}}

      %Marker{reviewed_sha: reviewed_sha} when reviewed_sha != head ->
        {:error, {:reviewed_sha_mismatch, marker: kind, reviewed_sha: reviewed_sha, head: head}}

      %Marker{} ->
        case status_lines(workspace_path) do
          {:ok, []} -> :ok
          {:ok, lines} -> {:error, {:working_tree_dirty, lines}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ensure_no_findings_to_clean_flip(markers) do
    case current_round(markers)
         |> Enum.filter(&(&1.kind == :code_review))
         |> Enum.take(-2) do
      [
        %Marker{verdict: :findings, reviewed_sha: reviewed_sha},
        %Marker{verdict: :clean, reviewed_sha: reviewed_sha}
      ] ->
        {:error, {:findings_to_clean_flip_same_head, reviewed_sha}}

      _ ->
        :ok
    end
  end

  defp ensure_only_docs_changed(workspace_path, markers) do
    case MarkerParser.latest_review_sha(markers) do
      nil ->
        {:error, {:missing_marker, :code_review}}

      reviewed_sha ->
        with {:ok, paths} <- diff_paths(workspace_path, reviewed_sha) do
          case Enum.reject(paths, &docs_path?/1) do
            [] -> :ok
            non_docs_paths -> {:error, {:non_docs_paths, non_docs_paths}}
          end
        end
    end
  end

  defp latest_marker_of_kind(markers, kind) do
    current_round(markers)
    |> Enum.filter(&(&1.kind == kind))
    |> List.last()
  end

  defp current_round(markers) do
    round_id = markers |> Enum.map(& &1.round_id) |> Enum.max(fn -> 0 end)
    Enum.filter(markers, &(&1.round_id == round_id))
  end

  defp docs_path?(path) do
    String.ends_with?(path, ".md") or String.starts_with?(path, "docs/")
  end

  defp current_head(workspace_path) do
    with {:ok, head} <- git(workspace_path, ["rev-parse", "HEAD"]) do
      {:ok, String.trim(head)}
    end
  end

  defp status_lines(workspace_path) do
    with {:ok, output} <- git(workspace_path, ["status", "--porcelain"]) do
      {:ok, String.split(output, "\n", trim: true)}
    end
  end

  defp diff_paths(workspace_path, reviewed_sha) do
    with {:ok, output} <- git(workspace_path, ["diff", "#{reviewed_sha}..HEAD", "--name-only"]) do
      {:ok, String.split(output, "\n", trim: true)}
    end
  end

  defp git(workspace_path, args) do
    case System.cmd("git", args, cd: workspace_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, args, status, String.trim_trailing(output)}}
    end
  end
end
