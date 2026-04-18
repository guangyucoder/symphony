defmodule SymphonyElixir.StageOrchestratorTestAgentRunner do
  def run(issue, recipient, opts) do
    send(Process.get(:stage_orchestrator_test_pid), {:agent_runner_run, issue, recipient, opts})
    :ok
  end
end

defmodule SymphonyElixir.StageOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.MarkerParser
  alias SymphonyElixir.StageOrchestrator
  alias SymphonyElixir.Workflow

  @moduletag :tmp_dir

  @issue "ENT-187"

  setup context do
    tmp_dir =
      if context[:tmp_dir] do
        dir =
          Path.join(
            System.tmp_dir!(),
            "symphony-stage-orchestrator-test-#{System.unique_integer([:positive, :monotonic])}"
          )

        File.mkdir_p!(dir)
        on_exit(fn -> File.rm_rf(dir) end)
        dir
      end

    previous_runner_module =
      Application.get_env(:symphony_elixir, :stage_orchestrator_agent_runner_module)

    Application.put_env(
      :symphony_elixir,
      :stage_orchestrator_agent_runner_module,
      SymphonyElixir.StageOrchestratorTestAgentRunner
    )

    Process.put(:stage_orchestrator_test_pid, self())

    on_exit(fn ->
      Process.delete(:stage_orchestrator_test_pid)

      if is_nil(previous_runner_module) do
        Application.delete_env(:symphony_elixir, :stage_orchestrator_agent_runner_module)
      else
        Application.put_env(
          :symphony_elixir,
          :stage_orchestrator_agent_runner_module,
          previous_runner_module
        )
      end
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "next_stage short-circuits Rework to implement before other clauses" do
    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: sha("a"))
      ])

    assert StageOrchestrator.next_stage(workpad, "Rework", "/definitely/missing") == :implement
  end

  test "next_stage returns stop for non-active states before inspecting markers" do
    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: sha("a"))
      ])

    assert StageOrchestrator.next_stage(workpad, "Done", "/definitely/missing") == :stop
  end

  test "next_stage returns review when a review-request is pending" do
    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: sha("a"))
      ])

    assert StageOrchestrator.next_stage(workpad, "In Progress", "/definitely/missing") == :review
  end

  test "next_stage returns implement when latest code-review verdict is findings" do
    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: sha("a")),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: sha("a"),
          verdict: "findings"
        )
      ])

    assert StageOrchestrator.next_stage(workpad, "In Progress", "/definitely/missing") == :implement
  end

  test "next_stage returns review when latest clean review is stale", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    reviewed_sha = head!(repo)

    File.write!(Path.join(repo, "lib.txt"), "new implementation\n")
    commit_all!(repo, "advance head")

    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: reviewed_sha),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: reviewed_sha,
          verdict: "clean"
        )
      ])

    assert StageOrchestrator.next_stage(workpad, "In Progress", repo) == :review
  end

  test "next_stage returns doc_fix when clean review matches HEAD but docs are stale", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    head = head!(repo)

    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: head),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: head,
          verdict: "clean"
        )
      ])

    assert StageOrchestrator.next_stage(workpad, "In Progress", repo) == :doc_fix
  end

  test "next_stage returns implement when docs-checked matches the current clean review", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    head = head!(repo)

    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: head),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: head,
          verdict: "clean"
        ),
        marker(
          kind: "docs-checked",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: head,
          docfix_outcome: "no-updates"
        )
      ])

    assert StageOrchestrator.next_stage(workpad, "In Progress", repo) == :implement
  end

  test "next_stage falls back to implement for active issues without current-round review markers" do
    assert StageOrchestrator.next_stage(workpad([]), "Todo", "/definitely/missing") == :implement
  end

  test "dispatch uses the default workflow path for implement" do
    issue = issue_fixture()

    assert StageOrchestrator.dispatch(issue, :implement) == :ok

    assert_received {:agent_runner_run, ^issue, nil, opts}
    assert Keyword.get(opts, :workflow_path) == Workflow.workflow_file_path()
    assert Keyword.get(opts, :max_turns) == 1
  end

  test "dispatch uses WORKFLOW-review.md for review" do
    issue = issue_fixture()

    assert StageOrchestrator.dispatch(issue, :review) == :ok

    assert_received {:agent_runner_run, ^issue, nil, opts}

    assert Keyword.get(opts, :workflow_path) ==
             Path.join(Path.dirname(Workflow.workflow_file_path()), "WORKFLOW-review.md")

    assert Keyword.get(opts, :max_turns) == 1
  end

  test "dispatch uses WORKFLOW-docfix.md for doc_fix" do
    issue = issue_fixture()

    assert StageOrchestrator.dispatch(issue, :doc_fix) == :ok

    assert_received {:agent_runner_run, ^issue, nil, opts}

    assert Keyword.get(opts, :workflow_path) ==
             Path.join(Path.dirname(Workflow.workflow_file_path()), "WORKFLOW-docfix.md")

    assert Keyword.get(opts, :max_turns) == 1
  end

  test "dispatch does nothing for stop" do
    assert StageOrchestrator.dispatch(issue_fixture(), :stop) == :ok
    refute_received {:agent_runner_run, _, _, _}
  end

  defp init_repo!(tmp_dir) do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "README.md"), "# test\n")
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    repo
  end

  defp commit_all!(repo, message) do
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-m", message])
  end

  defp head!(repo) do
    git!(repo, ["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp issue_fixture do
    %Issue{
      id: "issue-1",
      identifier: @issue,
      title: "Stage orchestration",
      description: "Route the next workflow stage.",
      state: "In Progress"
    }
  end

  defp workpad(markers) do
    workpad = """
    Notes outside marker region.

    <!-- SYMPHONY-MARKERS-BEGIN -->
    #{Enum.map_join(markers, "\n", &marker_block/1)}
    <!-- SYMPHONY-MARKERS-END -->
    """

    if length(MarkerParser.parse(workpad, @issue)) != length(markers) do
      flunk("invalid marker fixture: #{inspect(markers)}")
    end

    workpad
  end

  defp marker(fields) do
    Keyword.put_new(fields, :issue_identifier, @issue)
  end

  defp marker_block(fields) do
    body =
      Enum.map_join(fields, "\n", fn {key, value} ->
        "#{key}: #{yaml_value(value)}"
      end)

    """
    ```symphony-marker
    #{body}
    ```
    """
  end

  defp yaml_value(value) when is_binary(value), do: value
  defp yaml_value(value) when is_integer(value), do: Integer.to_string(value)

  defp sha(char) when is_binary(char) and byte_size(char) == 1 do
    String.duplicate(char, 40)
  end
end
