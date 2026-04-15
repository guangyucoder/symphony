defmodule SymphonyElixir.IssueExecTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.IssueExec

  setup do
    workspace = Path.join(System.tmp_dir!(), "issue_exec_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  describe "init/1" do
    test "creates issue_exec.json with defaults", %{workspace: ws} do
      assert :ok = IssueExec.init(ws)
      {:ok, state} = IssueExec.read(ws)
      assert state["mode"] == "unit_lite"
      assert state["phase"] == "bootstrap"
      assert state["bootstrapped"] == false
      assert state["current_unit"] == nil
      assert state["plan_version"] == 0
      assert is_binary(state["updated_at"])
    end
  end

  describe "read/1" do
    test "returns defaults when file doesn't exist", %{workspace: ws} do
      {:ok, state} = IssueExec.read(ws)
      assert state["mode"] == "unit_lite"
      assert state["bootstrapped"] == false
    end
  end

  describe "update/2" do
    test "merges fields atomically", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      :ok = IssueExec.update(ws, %{"bootstrapped" => true, "phase" => "planning"})
      {:ok, state} = IssueExec.read(ws)
      assert state["bootstrapped"] == true
      assert state["phase"] == "planning"
      # preserved
      assert state["mode"] == "unit_lite"
    end
  end

  describe "start_unit/2" do
    test "sets current_unit and phase", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      unit = %{"kind" => "implement_subtask", "subtask_id" => "plan-2", "attempt" => 1}
      :ok = IssueExec.start_unit(ws, unit)
      {:ok, state} = IssueExec.read(ws)
      assert state["current_unit"] == unit
      assert state["phase"] == "implementing"
    end
  end

  describe "accept_unit/1" do
    test "moves current_unit to last_accepted_unit", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      unit = %{"kind" => "plan"}
      :ok = IssueExec.start_unit(ws, unit)
      :ok = IssueExec.accept_unit(ws)
      {:ok, state} = IssueExec.read(ws)
      assert state["current_unit"] == nil
      assert state["last_accepted_unit"] == unit
    end
  end

  describe "set_verified_sha/2" do
    test "updates last_verified_sha", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      :ok = IssueExec.set_verified_sha(ws, "abc123")
      {:ok, state} = IssueExec.read(ws)
      assert state["last_verified_sha"] == "abc123"
    end
  end

  describe "reset_for_rework/1" do
    test "resets to planning while keeping bootstrapped", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      :ok = IssueExec.mark_bootstrapped(ws)
      :ok = IssueExec.set_verified_sha(ws, "abc123")
      :ok = IssueExec.reset_for_rework(ws)
      {:ok, state} = IssueExec.read(ws)
      assert state["phase"] == "planning"
      assert state["current_unit"] == nil
      assert state["last_verified_sha"] == nil
      # preserved
      assert state["bootstrapped"] == true
    end
  end

  describe "crash recovery" do
    test "current_unit survives crash (file persists)", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      unit = %{"kind" => "implement_subtask", "subtask_id" => "plan-3", "attempt" => 1}
      :ok = IssueExec.start_unit(ws, unit)

      # Simulate crash: just re-read
      {:ok, state} = IssueExec.read(ws)
      assert state["current_unit"] == unit
      assert state["current_unit"]["subtask_id"] == "plan-3"
    end
  end
end
