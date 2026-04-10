defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @comments_query """
  query SymphonyFetchComments($issueId: String!) {
    issue(id: $issueId) {
      comments(first: 50) {
        nodes {
          id
          body
          user { name }
          createdAt
        }
      }
    }
  }
  """

  @spec fetch_issue_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(issue_id) when is_binary(issue_id) do
    case client_module().graphql(@comments_query, %{issueId: issue_id}) do
      {:ok, response} ->
        comments = get_in(response, ["data", "issue", "comments", "nodes"]) || []
        {:ok, comments}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Fetch the Codex Workpad comment body for an issue, if it exists."
  @spec fetch_workpad_text(String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch_workpad_text(issue_id) when is_binary(issue_id) do
    case fetch_issue_comments(issue_id) do
      {:ok, comments} ->
        workpad =
          comments
          |> Enum.find(fn c ->
            body = c["body"] || ""
            String.contains?(body, "## Codex Workpad") or String.contains?(body, "### Plan")
          end)

        case workpad do
          %{"body" => body} -> {:ok, body}
          _ -> {:error, :workpad_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @update_comment_mutation """
  mutation SymphonyUpdateComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
    }
  }
  """

  @doc """
  Mark a subtask as done in the workpad checklist on Linear.
  Finds the workpad comment, replaces `- [ ] [subtask_id]` with `- [x] [subtask_id]`,
  and updates the comment via API. Orchestrator-owned — agent compliance not required.
  """
  @spec mark_subtask_done(String.t(), String.t()) :: :ok | {:error, term()}
  def mark_subtask_done(issue_id, subtask_id) when is_binary(issue_id) and is_binary(subtask_id) do
    with {:ok, comments} <- fetch_issue_comments(issue_id),
         {:ok, comment} <- find_workpad_comment(comments),
         {:ok, updated_body} <- check_off_subtask(comment["body"], subtask_id),
         :ok <- update_comment(comment["id"], updated_body) do
      :ok
    end
  end

  defp find_workpad_comment(comments) do
    case Enum.find(comments, fn c ->
      body = c["body"] || ""
      String.contains?(body, "## Codex Workpad") or String.contains?(body, "### Plan")
    end) do
      nil -> {:error, :workpad_not_found}
      comment -> {:ok, comment}
    end
  end

  defp check_off_subtask(body, subtask_id) when is_binary(body) do
    pattern = ~r/- \[ \] \[#{Regex.escape(subtask_id)}\]/
    if Regex.match?(pattern, body) do
      {:ok, Regex.replace(pattern, body, "- [x] [#{subtask_id}]")}
    else
      # Already checked or not found — not an error
      {:ok, body}
    end
  end

  defp update_comment(comment_id, body) when is_binary(comment_id) and is_binary(body) do
    case client_module().graphql(@update_comment_mutation, %{commentId: comment_id, body: body}) do
      {:ok, response} ->
        if get_in(response, ["data", "commentUpdate", "success"]) == true do
          :ok
        else
          {:error, :comment_update_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
