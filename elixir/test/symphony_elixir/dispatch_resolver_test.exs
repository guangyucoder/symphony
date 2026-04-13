defmodule SymphonyElixir.DispatchResolverTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{DispatchResolver, Unit}

  @default_exec %{
    "mode" => "unit_lite",
    "phase" => "bootstrap",
    "current_unit" => nil,
    "last_accepted_unit" => nil,
    "last_commit_sha" => nil,
    "last_verified_sha" => nil,
    "doc_fix_required" => false,
    "bootstrapped" => false,
    "plan_version" => 0
  }

  @workpad_with_pending """
  ## Codex Workpad

  ### Plan
  - [x] [plan-1] Add component
  - [ ] [plan-2] Integrate
  - [ ] [plan-3] Test

  ### Notes
  """

  @workpad_all_done """
  ## Codex Workpad

  ### Plan
  - [x] [plan-1] Add component
  - [x] [plan-2] Integrate
  - [x] [plan-3] Test
  """

  defp ctx(overrides \\ %{}) do
    base = %{
      issue: %{state: "In Progress"},
      exec: @default_exec,
      workpad_text: nil,
      git_head: "abc123"
    }
    Map.merge(base, overrides)
  end

  describe "normal flow" do
    test "dispatches bootstrap when not bootstrapped" do
      assert {:dispatch, %Unit{kind: :bootstrap}} = DispatchResolver.resolve(ctx())
    end

    test "dispatches plan when bootstrapped but no workpad" do
      exec = %{@default_exec | "bootstrapped" => true}
      assert {:dispatch, %Unit{kind: :plan}} = DispatchResolver.resolve(ctx(%{exec: exec}))
    end

    test "dispatches plan when workpad has no checklist" do
      exec = %{@default_exec | "bootstrapped" => true}
      assert {:dispatch, %Unit{kind: :plan}} = DispatchResolver.resolve(ctx(%{
        exec: exec,
        workpad_text: "## Codex Workpad\nJust some text"
      }))
    end

    test "dispatches implement_subtask for next unchecked item" do
      exec = %{@default_exec | "bootstrapped" => true}
      result = DispatchResolver.resolve(ctx(%{
        exec: exec,
        workpad_text: @workpad_with_pending
      }))
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-2"}} = result
    end

    test "dispatches doc_fix before next subtask when doc_fix_required" do
      exec = %{@default_exec | "bootstrapped" => true, "doc_fix_required" => true}
      result = DispatchResolver.resolve(ctx(%{
        exec: exec,
        workpad_text: @workpad_with_pending
      }))
      assert {:dispatch, %Unit{kind: :doc_fix}} = result
    end

    test "dispatches doc_fix before verify when all subtasks done" do
      exec = %{@default_exec | "bootstrapped" => true, "last_verified_sha" => nil}
      result = DispatchResolver.resolve(ctx(%{
        exec: exec,
        workpad_text: @workpad_all_done,
        git_head: "abc123"
      }))
      assert {:dispatch, %Unit{kind: :doc_fix}} = result
    end

    test "dispatches verify after doc_fix when all subtasks done" do
      exec = %{@default_exec | "bootstrapped" => true, "last_verified_sha" => nil,
               "last_accepted_unit" => %{"kind" => "doc_fix"}}
      result = DispatchResolver.resolve(ctx(%{
        exec: exec,
        workpad_text: @workpad_all_done,
        git_head: "abc123"
      }))
      assert {:dispatch, %Unit{kind: :verify}} = result
    end

    test "dispatches verify when HEAD changed after verification" do
      exec = %{@default_exec | "bootstrapped" => true, "last_verified_sha" => "old_sha",
               "last_accepted_unit" => %{"kind" => "doc_fix"}}
      result = DispatchResolver.resolve(ctx(%{
        exec: exec,
        workpad_text: @workpad_all_done,
        git_head: "new_sha"
      }))
      assert {:dispatch, %Unit{kind: :verify}} = result
    end

    test "dispatches handoff when verified and all done" do
      exec = %{@default_exec | "bootstrapped" => true, "last_verified_sha" => "abc123",
               "last_accepted_unit" => %{"kind" => "doc_fix"}}
      result = DispatchResolver.resolve(ctx(%{
        exec: exec,
        workpad_text: @workpad_all_done,
        git_head: "abc123"
      }))
      assert {:dispatch, %Unit{kind: :handoff}} = result
    end

    test "stops when handoff was last accepted" do
      exec = %{@default_exec |
        "bootstrapped" => true,
        "last_verified_sha" => "abc123",
        "last_accepted_unit" => %{"kind" => "handoff"}
      }
      result = DispatchResolver.resolve(ctx(%{
        exec: exec,
        workpad_text: @workpad_all_done,
        git_head: "abc123"
      }))
      assert {:stop, :all_complete} = result
    end
  end

  describe "merging flow" do
    test "dispatches merge when issue is Merging" do
      result = DispatchResolver.resolve(ctx(%{
        issue: %{state: "Merging"},
        exec: @default_exec
      }))
      assert {:dispatch, %Unit{kind: :merge}} = result
    end

    test "dispatches merge-sync implement_subtask when merge_conflict is set" do
      exec = Map.put(@default_exec, "merge_conflict", true)
      result = DispatchResolver.resolve(ctx(%{
        issue: %{state: "Merging"},
        exec: exec
      }))
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "merge-sync-1"}} = result
    end

    test "does not dispatch merge-sync when merge_conflict is false" do
      # Baseline: plain merge dispatch, merge_sync_rule should not fire.
      result = DispatchResolver.resolve(ctx(%{
        issue: %{state: "Merging"},
        exec: @default_exec
      }))
      refute match?({:dispatch, %Unit{kind: :implement_subtask, subtask_id: "merge-sync-" <> _}}, result)
    end

    test "dispatches verify when merge_needs_verify is set (post merge-sync)" do
      exec = Map.put(@default_exec, "merge_needs_verify", true)
      result = DispatchResolver.resolve(ctx(%{
        issue: %{state: "Merging"},
        exec: exec
      }))
      assert {:dispatch, %Unit{kind: :verify}} = result
    end

    test "merge_sync wins over merge_verify when both flags are set" do
      # Defensive: if the state somehow has both flags (e.g., crash between
      # writes), resolve the conflict first before re-verifying.
      exec = @default_exec
             |> Map.put("merge_conflict", true)
             |> Map.put("merge_needs_verify", true)
      result = DispatchResolver.resolve(ctx(%{
        issue: %{state: "Merging"},
        exec: exec
      }))
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "merge-sync-1"}} = result
    end

    test "verify_fix wins over merge_sync when verify_error is set" do
      # After merge-sync lands, if verify_error is still live from an earlier
      # failure, fix the code first.
      exec = @default_exec
             |> Map.put("merge_conflict", true)
             |> Map.put("verify_error", "boom")
      result = DispatchResolver.resolve(ctx(%{
        issue: %{state: "Merging"},
        exec: exec
      }))
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "verify-fix-1"}} = result
    end
  end

  describe "rework flow" do
    test "dispatches rework fix when workpad is complete (skip re-plan)" do
      exec = %{@default_exec | "bootstrapped" => true, "phase" => "handoff",
               "last_accepted_unit" => %{"kind" => "handoff"}}
      result = DispatchResolver.resolve(ctx(%{
        issue: %{state: "Rework"},
        exec: exec,
        workpad_text: @workpad_all_done
      }))
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "rework-1"}} = result
    end

    test "dispatches plan for rework when workpad is missing" do
      exec = %{@default_exec | "bootstrapped" => true, "phase" => "handoff",
               "last_accepted_unit" => %{"kind" => "handoff"}}
      result = DispatchResolver.resolve(ctx(%{
        issue: %{state: "Rework"},
        exec: exec,
        workpad_text: nil
      }))
      assert {:dispatch, %Unit{kind: :plan}} = result
    end

    test "dispatches plan for rework when workpad has pending items" do
      exec = %{@default_exec | "bootstrapped" => true, "phase" => "implementing",
               "last_accepted_unit" => %{"kind" => "implement_subtask", "subtask_id" => "plan-1"}}
      result = DispatchResolver.resolve(ctx(%{
        issue: %{state: "Rework"},
        exec: exec,
        workpad_text: @workpad_with_pending
      }))
      # Workpad not complete → falls through to implement_subtask_rule for pending items
      assert {:dispatch, %Unit{kind: :implement_subtask}} = result
    end

    test "after rework fix accepted, dispatches doc_fix then verify (not another fix)" do
      # After rework fix → doc_fix first
      exec = @default_exec
             |> Map.merge(%{"bootstrapped" => true, "phase" => "implementing",
               "last_accepted_unit" => %{"kind" => "implement_subtask", "subtask_id" => "rework-1"},
               "rework_fix_applied" => true,
               "last_verified_sha" => nil})
      result = DispatchResolver.resolve(ctx(%{
        issue: %{state: "Rework"},
        exec: exec,
        workpad_text: @workpad_all_done,
        git_head: "abc123"
      }))
      assert {:dispatch, %Unit{kind: :doc_fix}} = result

      # After doc_fix → verify
      exec2 = Map.put(exec, "last_accepted_unit", %{"kind" => "doc_fix"})
      result2 = DispatchResolver.resolve(ctx(%{
        issue: %{state: "Rework"},
        exec: exec2,
        workpad_text: @workpad_all_done,
        git_head: "abc123"
      }))
      assert {:dispatch, %Unit{kind: :verify}} = result2
    end
  end

  describe "crash recovery" do
    test "replays current unit if not accepted" do
      exec = %{@default_exec |
        "bootstrapped" => true,
        "current_unit" => %{"kind" => "implement_subtask", "subtask_id" => "plan-2", "attempt" => 1}
      }
      result = DispatchResolver.resolve(ctx(%{
        exec: exec,
        workpad_text: @workpad_with_pending
      }))
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-2", attempt: 2}} = result
    end

    test "circuit breaker trips after max attempts" do
      exec = %{@default_exec |
        "bootstrapped" => true,
        "current_unit" => %{"kind" => "implement_subtask", "subtask_id" => "plan-2", "attempt" => 3}
      }
      result = DispatchResolver.resolve(ctx(%{
        exec: exec,
        workpad_text: @workpad_with_pending
      }))
      assert {:stop, :circuit_breaker} = result
    end
  end
end
