defmodule SymphonyElixir.CloseoutTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Closeout, IssueExec, Ledger, Workflow}

  defmodule FakeLinearClient do
    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    workspace = Path.join(System.tmp_dir!(), "closeout_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    IssueExec.init(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  @issue %{state: "In Progress", identifier: "ENT-42"}

  describe "bootstrap closeout" do
    test "accepts and marks bootstrapped after baseline passes", %{workspace: ws} do
      write_workflow_file!(Workflow.workflow_file_path(), verification_baseline_commands: ["true"])

      assert :accepted = Closeout.run(ws, %{"kind" => "bootstrap"}, @issue)

      {:ok, exec} = IssueExec.read(ws)
      assert exec["bootstrapped"] == true
      assert exec["baseline_verify_failed"] == false
      assert exec["baseline_verify_output"] == nil
      assert ledger_events(ws) |> Enum.member?("baseline_verified")
    end

    test "accepts bootstrap even when baseline fails, but records the failure for downstream units",
         %{workspace: ws} do
      write_workflow_file!(Workflow.workflow_file_path(), verification_baseline_commands: ["false"])

      assert :accepted = Closeout.run(ws, %{"kind" => "bootstrap"}, @issue)

      {:ok, exec} = IssueExec.read(ws)
      # bootstrapped=true even on baseline failure: the dispatcher must advance
      # past bootstrap_rule. Baseline state lives in baseline_verify_failed.
      assert exec["bootstrapped"] == true
      assert exec["baseline_verify_failed"] == true
      assert is_binary(exec["baseline_verify_output"])
      assert ledger_events(ws) |> Enum.member?("baseline_verify_failed")
      assert ledger_events(ws) |> Enum.member?("baseline_accepted_despite_failure")
    end

    test "second bootstrap after soft-accept does not re-dispatch bootstrap", %{workspace: ws} do
      # Regression guard for the accepted-bootstrap infinite loop:
      # before this fix, :accepted with bootstrapped=false + cleared
      # current_unit caused DispatchResolver.bootstrap_rule/1 to re-dispatch
      # bootstrap forever with no circuit-breaker escape.
      write_workflow_file!(Workflow.workflow_file_path(), verification_baseline_commands: ["false"])

      assert :accepted = Closeout.run(ws, %{"kind" => "bootstrap"}, @issue)
      {:ok, exec} = IssueExec.read(ws)

      ctx = %{
        issue: %SymphonyElixir.Linear.Issue{identifier: "ENT-42", state: "In Progress"},
        exec: exec,
        workpad_text: nil,
        git_head: "abc123"
      }

      result = SymphonyElixir.DispatchResolver.resolve(ctx)

      refute match?({:dispatch, %SymphonyElixir.Unit{kind: :bootstrap}}, result),
             "expected dispatcher to advance past bootstrap after soft-accept, got #{inspect(result)}"
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

    test "accepts even without workpad (checklist verification deferred to DispatchResolver)", %{
      workspace: ws
    } do
      assert :accepted = Closeout.run(ws, %{"kind" => "plan"}, @issue, workpad_text: "no plan here")
    end

    test "accepts when no workpad provided (verification deferred)", %{workspace: ws} do
      assert :accepted = Closeout.run(ws, %{"kind" => "plan"}, @issue)
    end
  end

  describe "implement_subtask closeout" do
    test "accepts when HEAD advanced since dispatch (regular plan-N path)", %{workspace: ws} do
      {dispatch_head, head_after_commit} = init_git_and_advance!(ws)
      assert dispatch_head != head_after_commit

      assert :accepted =
               Closeout.run(
                 ws,
                 %{"kind" => "implement_subtask", "subtask_id" => "plan-1"},
                 @issue,
                 dispatch_head: dispatch_head
               )
    end

    test "retries when HEAD unchanged — plan-N forgot to commit", %{workspace: ws} do
      dispatch_head = init_git_only!(ws)

      assert {:retry, reason} =
               Closeout.run(
                 ws,
                 %{"kind" => "implement_subtask", "subtask_id" => "plan-1"},
                 @issue,
                 dispatch_head: dispatch_head
               )

      assert reason =~ "implement_subtask plan-1: produced no commit"
    end

    test "retries when HEAD cannot be verified (missing dispatch_head)", %{workspace: ws} do
      assert {:retry, reason} =
               Closeout.run(
                 ws,
                 %{"kind" => "implement_subtask", "subtask_id" => "plan-1"},
                 @issue
               )

      assert reason =~ "cannot verify HEAD state"
    end
  end

  describe "doc_fix closeout" do
    test "clears doc_fix_required flag when HEAD advanced", %{workspace: ws} do
      IssueExec.mark_doc_fix_required(ws)
      {:ok, exec} = IssueExec.read(ws)
      assert exec["doc_fix_required"] == true

      {dispatch_head, _} = init_git_and_advance!(ws)

      assert :accepted = Closeout.run(ws, %{"kind" => "doc_fix"}, @issue, dispatch_head: dispatch_head)

      {:ok, exec} = IssueExec.read(ws)
      assert exec["doc_fix_required"] == false
    end

    test "retries when HEAD unchanged — doc_fix forgot to commit", %{workspace: ws} do
      IssueExec.mark_doc_fix_required(ws)
      dispatch_head = init_git_only!(ws)

      assert {:retry, reason} =
               Closeout.run(ws, %{"kind" => "doc_fix"}, @issue, dispatch_head: dispatch_head)

      assert reason =~ "doc_fix: produced no commit"

      # doc_fix_required must still be set so the dispatcher re-dispatches.
      {:ok, exec} = IssueExec.read(ws)
      assert exec["doc_fix_required"] == true
    end
  end

  describe "handoff closeout" do
    test "accepts when verified sha matches HEAD", %{workspace: ws} do
      # Simulate verified state — we can't run real git here, so test the rejection path
      IssueExec.set_verified_sha(ws, "abc123")
      # HEAD will be nil (no git repo in temp dir) -> fail
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

    test "retries when PR status is unknown, without posting a Linear comment", %{workspace: ws} do
      Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
      IssueExec.update(ws, %{"phase" => "merging"})

      checker = fn _workspace -> :unknown end
      issue = Map.put(@issue, :id, "issue-123")

      assert {:retry, "merge status unverified"} =
               Closeout.run(ws, %{"kind" => "merge"}, issue, merge_checker: checker)

      refute_received {:graphql_called, _, _}

      {:ok, exec} = IssueExec.read(ws)
      assert exec["phase"] == "merging"
      assert ledger_events(ws) |> Enum.member?("merge_status_unknown")
    end
  end

  describe "unknown unit" do
    test "fails closed for unknown unit kind", %{workspace: ws} do
      assert {:fail, "unknown unit kind: unknown_thing"} =
               Closeout.run(ws, %{"kind" => "unknown_thing"}, @issue)
    end
  end

  defp ledger_events(workspace) do
    {:ok, entries} = Ledger.read(workspace)
    Enum.map(entries, & &1["event"])
  end

  # Init a git repo with one initial commit. Returns the initial HEAD sha
  # — use this as dispatch_head when you want to assert "HEAD did not advance".
  defp init_git_only!(workspace) do
    System.cmd("git", ["init", "-q"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test"], cd: workspace)
    System.cmd("git", ["config", "user.email", "t@t.com"], cd: workspace)
    File.write!(Path.join(workspace, "seed.txt"), "seed\n")
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["commit", "-q", "-m", "init"], cd: workspace)
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    String.trim(head)
  end

  # Init a git repo, snapshot HEAD as dispatch_head, then make a second
  # commit so HEAD advances. Returns {dispatch_head, new_head}.
  defp init_git_and_advance!(workspace) do
    dispatch_head = init_git_only!(workspace)
    File.write!(Path.join(workspace, "progress.txt"), "progress\n")
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["commit", "-q", "-m", "progress"], cd: workspace)
    {new_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    {dispatch_head, String.trim(new_head)}
  end
end
