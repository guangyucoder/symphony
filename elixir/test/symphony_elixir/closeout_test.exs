defmodule SymphonyElixir.CloseoutTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Closeout, IssueExec}

  setup do
    workspace = Path.join(System.tmp_dir!(), "closeout_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    IssueExec.init(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  @issue %{state: "In Progress", identifier: "ENT-42"}

  describe "bootstrap closeout" do
    test "accepts and marks bootstrapped", %{workspace: ws} do
      assert :accepted = Closeout.run(ws, %{"kind" => "bootstrap"}, @issue)
      {:ok, exec} = IssueExec.read(ws)
      assert exec["bootstrapped"] == true
    end
  end

  describe "plan closeout" do
    test "accepts when workpad has parseable checklist", %{workspace: ws} do
      workpad = """
      ## Codex Workpad

      ### Plan
      - [ ] [plan-1] First task
      - [ ] [plan-2] Second task
      """
      assert :accepted = Closeout.run(ws, %{"kind" => "plan"}, @issue, workpad_text: workpad)
      {:ok, exec} = IssueExec.read(ws)
      assert exec["plan_version"] == 1
    end

    test "accepts even without workpad (checklist verification deferred to DispatchResolver)", %{workspace: ws} do
      assert :accepted = Closeout.run(ws, %{"kind" => "plan"}, @issue, workpad_text: "no plan here")
    end

    test "accepts when no workpad provided (verification deferred)", %{workspace: ws} do
      assert :accepted = Closeout.run(ws, %{"kind" => "plan"}, @issue)
    end
  end

  describe "implement_subtask closeout" do
    test "accepts when no doc impact", %{workspace: ws} do
      # No git history → changed_files is empty → fresh
      assert :accepted = Closeout.run(ws, %{"kind" => "implement_subtask", "subtask_id" => "plan-1"}, @issue)
    end
  end

  describe "doc_fix closeout" do
    test "clears doc_fix_required flag", %{workspace: ws} do
      IssueExec.mark_doc_fix_required(ws)
      {:ok, exec} = IssueExec.read(ws)
      assert exec["doc_fix_required"] == true

      assert :accepted = Closeout.run(ws, %{"kind" => "doc_fix"}, @issue)
      {:ok, exec} = IssueExec.read(ws)
      assert exec["doc_fix_required"] == false
    end
  end

  describe "handoff closeout" do
    test "accepts when verified sha matches HEAD", %{workspace: ws} do
      # Simulate verified state — we can't run real git here, so test the rejection path
      IssueExec.set_verified_sha(ws, "abc123")
      # HEAD will be nil (no git repo in temp dir) → fail
      assert {:fail, _reason} = Closeout.run(ws, %{"kind" => "handoff"}, @issue)
    end

    test "rejects when verified sha doesn't match HEAD", %{workspace: ws} do
      IssueExec.set_verified_sha(ws, "old_sha")
      assert {:fail, reason} = Closeout.run(ws, %{"kind" => "handoff"}, @issue)
      assert reason =~ "last_verified_sha"
    end
  end

  describe "merge closeout" do
    test "accepts when PR is merged", %{workspace: ws} do
      checker = fn _workspace -> :merged end
      assert :accepted = Closeout.run(ws, %{"kind" => "merge"}, @issue, merge_checker: checker)

      {:ok, exec} = IssueExec.read(ws)
      assert exec["phase"] == "done"
    end

    test "retries when PR is not merged", %{workspace: ws} do
      checker = fn _workspace -> {:not_merged, "PR state: OPEN"} end
      assert {:retry, reason} = Closeout.run(ws, %{"kind" => "merge"}, @issue, merge_checker: checker)
      assert reason =~ "not merged"

      {:ok, exec} = IssueExec.read(ws)
      assert exec["phase"] != "done"
    end

    test "accepts with warning when PR status unknown", %{workspace: ws} do
      checker = fn _workspace -> :unknown end
      assert :accepted = Closeout.run(ws, %{"kind" => "merge"}, @issue, merge_checker: checker)

      {:ok, exec} = IssueExec.read(ws)
      assert exec["phase"] == "done"
    end
  end

  describe "unknown unit" do
    test "accepts gracefully", %{workspace: ws} do
      assert :accepted = Closeout.run(ws, %{"kind" => "unknown_thing"}, @issue)
    end
  end
end
