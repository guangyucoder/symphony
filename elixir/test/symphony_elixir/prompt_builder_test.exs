defmodule SymphonyElixir.PromptBuilderTest do
  use ExUnit.Case

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.Workflow

  import SymphonyElixir.TestSupport, only: [write_workflow_file!: 2]

  setup do
    workflow_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-prompt-builder-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workflow_root)
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    write_workflow_file!(workflow_file, prompt: "Default {{ issue.identifier }}")
    Workflow.set_workflow_file_path(workflow_file)

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
      File.rm_rf(workflow_root)
    end)

    {:ok, workflow_root: workflow_root}
  end

  test "uses current workflow and default fallback when workflow_path is absent" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    prompt = PromptBuilder.build_prompt(issue_fixture())

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-781"
  end

  test "loads prompt from the provided workflow_path", %{workflow_root: workflow_root} do
    stage_workflow_path = Path.join(workflow_root, "WORKFLOW-review.md")
    File.write!(stage_workflow_path, "Stage {{ issue.identifier }} attempt={{ attempt }}\n")

    assert PromptBuilder.build_prompt(issue_fixture(), attempt: 2, workflow_path: stage_workflow_path) ==
             "Stage MT-781 attempt=2"
  end

  test "raises when workflow_path resolves to a blank prompt body", %{workflow_root: workflow_root} do
    stage_workflow_path = Path.join(workflow_root, "WORKFLOW-review.md")
    File.write!(stage_workflow_path, "---\ntracker:\n  kind: linear\n---\n   \n")

    assert_raise RuntimeError, ~r/stage_workflow_empty_body/, fn ->
      PromptBuilder.build_prompt(issue_fixture(), workflow_path: stage_workflow_path)
    end
  end

  test "raises cleanly when workflow_path does not exist", %{workflow_root: workflow_root} do
    missing_path = Path.join(workflow_root, "MISSING_STAGE_WORKFLOW.md")

    assert_raise RuntimeError, ~r/workflow_unavailable: \{:missing_workflow_file, ".*MISSING_STAGE_WORKFLOW\.md", :enoent\}/, fn ->
      PromptBuilder.build_prompt(issue_fixture(), workflow_path: missing_path)
    end
  end

  defp issue_fixture do
    %Issue{
      identifier: "MT-781",
      title: "Stage workflow prompts",
      description: "Use an explicit workflow path when requested.",
      state: "In Progress",
      url: "https://example.org/issues/MT-781",
      labels: ["prompt"]
    }
  end
end
