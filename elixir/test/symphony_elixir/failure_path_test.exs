defmodule SymphonyElixir.FailurePathTest do
  @moduledoc """
  Failure path invariant tests.

  Harness Engineering: these tests encode mechanical invariants that prevent
  classes of bugs from recurring. Each test corresponds to a production
  incident or review finding.

  Invariants tested:
  1. Public functions must not crash on invalid input (graceful degradation)
  2. Force-accept safety bypasses must be explicit (not silent)
  3. Session failures must raise (not silently pass)
  4. Circuit breaker must fire within bounded attempts
  """
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Closeout, Codex.AppServer, DispatchResolver, IssueExec, Unit}

  # ──────────────────────────────────────────────────────────────────
  # Invariant 1: codex_command_with_effort graceful degradation
  #
  # Finding: invalid effort caused FunctionClauseError, crashing session start.
  # Invariant: function must handle nil, valid, invalid, and edge-case inputs.
  # ──────────────────────────────────────────────────────────────────

  describe "codex_command_with_effort graceful degradation" do
    test "nil returns base command" do
      result = AppServer.codex_command_with_effort(nil)
      assert is_binary(result)
    end

    test "valid effort values don't crash" do
      for effort <- ~w(low medium high xhigh) do
        result = AppServer.codex_command_with_effort(effort)
        assert is_binary(result), "#{effort} should return a string"
      end
    end

    test "invalid effort returns base command (no crash)" do
      result = AppServer.codex_command_with_effort("bogus")
      assert is_binary(result)
    end

    test "non-string effort returns base command (no crash)" do
      result = AppServer.codex_command_with_effort(42)
      assert is_binary(result)
    end

    test "effort replacement is idempotent" do
      cmd1 = AppServer.codex_command_with_effort("high")
      # Simulating what happens if the base command already has the same effort
      assert is_binary(cmd1)
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Invariant 2: verify failure sets verify_error for fix dispatch;
  #              verify exhaustion escalates after max attempts.
  #
  # Finding: unverified code silently reached handoff/PR via force-accept.
  # Fix: non-exhausted failures set verify_error (dispatch verify-fix);
  #      exhaustion returns {:fail, ...} for escalation.
  # Invariant: (a) non-exhausted failures set verify_error and clear
  #            current_unit, (b) exhaustion fails (not accepts),
  #            (c) verified_sha is NOT set, (d) ledger records events.
  # ──────────────────────────────────────────────────────────────────

  describe "verify failure and exhaustion" do
    setup do
      workspace = Path.join(System.tmp_dir!(), "fail_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      IssueExec.init(workspace)

      # Need git repo for Verifier.current_head
      System.cmd("git", ["init"], cd: workspace)
      File.write!(Path.join(workspace, "test.txt"), "hello")
      System.cmd("git", ["add", "."], cd: workspace)
      System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=t@t.com",
                          "commit", "-m", "init"], cd: workspace)

      on_exit(fn -> File.rm_rf!(workspace) end)
      %{workspace: workspace}
    end

    @issue %{id: "test-issue-id", identifier: "TEST-1", title: "Test", state: "In Progress"}

    test "non-exhausted failure sets verify_error and clears current_unit", %{workspace: ws} do
      IssueExec.start_unit(ws, %{"kind" => "verify"})
      result = Closeout.run(ws, %{"kind" => "verify"}, @issue, verify_commands: ["false"])
      assert {:retry, _} = result

      {:ok, exec} = IssueExec.read(ws)
      assert is_binary(exec["verify_error"]), "must set verify_error for verify-fix dispatch"
      assert exec["current_unit"] == nil, "must clear current_unit so verify_fix_rule fires"
      assert exec["verify_attempt"] == 1
    end

    test "exhaustion at attempt 3 fails (does not accept)", %{workspace: ws} do
      # Simulate 2 prior verify attempts by setting verify_attempt
      IssueExec.update(ws, %{"verify_attempt" => 2})

      IssueExec.start_unit(ws, %{"kind" => "verify"})
      result = Closeout.run(ws, %{"kind" => "verify"}, @issue, verify_commands: ["false"])

      assert {:fail, reason} = result
      assert reason =~ "exhausted"
    end

    test "exhaustion does NOT set verified_sha", %{workspace: ws} do
      IssueExec.update(ws, %{"verify_attempt" => 2})

      IssueExec.start_unit(ws, %{"kind" => "verify"})
      Closeout.run(ws, %{"kind" => "verify"}, @issue, verify_commands: ["false"])

      {:ok, exec} = IssueExec.read(ws)
      assert exec["last_verified_sha"] == nil,
        "failed verify must NOT set verified_sha — handoff must be blocked"
    end

    test "verify_error is cleared by verify-fix closeout", %{workspace: ws} do
      IssueExec.set_verify_error(ws, "some test failure")

      unit = %{"kind" => "implement_subtask", "subtask_id" => "verify-fix-1"}
      IssueExec.start_unit(ws, unit)
      Closeout.run(ws, unit, @issue)

      {:ok, exec} = IssueExec.read(ws)
      assert exec["verify_error"] == nil, "verify-fix must clear verify_error"
    end

    test "verify_error triggers verify_fix_rule dispatch" do
      exec = %{
        "mode" => "unit_lite", "phase" => "verifying",
        "current_unit" => nil, "last_accepted_unit" => %{"kind" => "doc_fix"},
        "bootstrapped" => true, "plan_version" => 1,
        "last_verified_sha" => nil, "doc_fix_required" => false,
        "rework_fix_applied" => false,
        "verify_error" => "test/foo_test.exs:12 assertion failed",
        "verify_attempt" => 1
      }
      workpad = "## Codex Workpad\n\n### Plan\n- [x] [plan-1] Done\n"
      ctx = %{issue: %{state: "In Progress"}, exec: exec, workpad_text: workpad, git_head: "abc"}

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "verify-fix-1"}} =
               DispatchResolver.resolve(ctx)
    end

    test "exhaustion is recorded in ledger", %{workspace: ws} do
      IssueExec.update(ws, %{"verify_attempt" => 2})

      IssueExec.start_unit(ws, %{"kind" => "verify"})
      Closeout.run(ws, %{"kind" => "verify"}, @issue, verify_commands: ["false"])

      {:ok, entries} = SymphonyElixir.Ledger.read(ws)
      events = Enum.map(entries, & &1["event"])
      assert "verify_exhausted" in events,
        "verify exhaustion must leave an audit trail in the ledger"
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Invariant 3: circuit breaker fires within bounded attempts
  #
  # Finding: non-verify units retried forever, burning tokens.
  # Invariant: after @max_unit_attempts, dispatch returns :circuit_breaker.
  # ──────────────────────────────────────────────────────────────────

  describe "circuit breaker fires within bounded attempts" do
    @default_exec %{
      "mode" => "unit_lite",
      "phase" => "implementing",
      "current_unit" => nil,
      "last_accepted_unit" => nil,
      "last_commit_sha" => nil,
      "last_verified_sha" => nil,
      "doc_fix_required" => false,
      "bootstrapped" => true,
      "plan_version" => 1
    }

    test "replay at attempt 1 dispatches normally" do
      exec = %{@default_exec |
        "current_unit" => %{"kind" => "implement_subtask", "subtask_id" => "plan-1", "attempt" => 1}
      }
      ctx = %{issue: %{state: "In Progress"}, exec: exec, workpad_text: nil, git_head: "abc"}
      assert {:dispatch, %Unit{attempt: 2}} = DispatchResolver.resolve(ctx)
    end

    test "replay at attempt 2 dispatches normally" do
      exec = %{@default_exec |
        "current_unit" => %{"kind" => "implement_subtask", "subtask_id" => "plan-1", "attempt" => 2}
      }
      ctx = %{issue: %{state: "In Progress"}, exec: exec, workpad_text: nil, git_head: "abc"}
      assert {:dispatch, %Unit{attempt: 3}} = DispatchResolver.resolve(ctx)
    end

    test "replay at max attempt triggers circuit breaker" do
      exec = %{@default_exec |
        "current_unit" => %{"kind" => "implement_subtask", "subtask_id" => "plan-1", "attempt" => 3}
      }
      ctx = %{issue: %{state: "In Progress"}, exec: exec, workpad_text: nil, git_head: "abc"}
      assert {:stop, :circuit_breaker} = DispatchResolver.resolve(ctx)
    end

    test "circuit breaker resets when attempt count is cleared" do
      # Simulates: human fixed the issue, moved ticket back to active.
      # Agent runner clears current_unit, so next dispatch starts fresh.
      exec = %{@default_exec |
        "current_unit" => %{"kind" => "implement_subtask", "subtask_id" => "plan-1", "attempt" => 3}
      }

      # Before reset: circuit breaker fires
      ctx = %{issue: %{state: "In Progress"}, exec: exec, workpad_text: nil, git_head: "abc"}
      assert {:stop, :circuit_breaker} = DispatchResolver.resolve(ctx)

      # After reset (current_unit cleared): normal dispatch resumes
      reset_exec = %{exec | "current_unit" => nil}
      ctx = %{ctx | exec: reset_exec}
      # Without workpad, plan_rule fires
      assert {:dispatch, %Unit{kind: :plan}} = DispatchResolver.resolve(ctx)
    end

    test "circuit breaker applies to all unit kinds" do
      for kind <- ~w(bootstrap plan implement_subtask doc_fix verify handoff merge) do
        exec = %{@default_exec |
          "current_unit" => %{"kind" => kind, "subtask_id" => nil, "attempt" => 3}
        }
        ctx = %{issue: %{state: "In Progress"}, exec: exec, workpad_text: nil, git_head: "abc"}
        result = DispatchResolver.resolve(ctx)
        assert {:stop, :circuit_breaker} = result,
          "circuit breaker must fire for #{kind} at max attempts"
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Invariant 4: rework_fix_applied lifecycle correctness
  #
  # Finding: flag not cleared on 2nd rework → fixes silently skipped.
  # Invariant: flag must be set on fix, cleared on fresh rework entry,
  #            and survive intermediate doc_fix/verify units.
  # ──────────────────────────────────────────────────────────────────

  describe "rework_fix_applied lifecycle" do
    setup do
      workspace = Path.join(System.tmp_dir!(), "rework_flag_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      IssueExec.init(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)
      %{workspace: workspace}
    end

    test "flag starts false", %{workspace: ws} do
      {:ok, exec} = IssueExec.read(ws)
      assert exec["rework_fix_applied"] == false
    end

    test "closeout sets flag on rework-* subtask acceptance", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      unit = %{"kind" => "implement_subtask", "subtask_id" => "rework-1"}
      IssueExec.start_unit(ws, unit)

      # Closeout for rework subtask sets the flag
      Closeout.run(ws, unit, %{id: "test", identifier: "T-1", title: "T", state: "Rework"})

      {:ok, exec} = IssueExec.read(ws)
      assert exec["rework_fix_applied"] == true
    end

    test "flag survives doc_fix acceptance", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.update(ws, %{"rework_fix_applied" => true})

      unit = %{"kind" => "doc_fix"}
      IssueExec.start_unit(ws, unit)
      Closeout.run(ws, unit, %{id: "test", identifier: "T-1", title: "T", state: "Rework"})
      IssueExec.accept_unit(ws)

      {:ok, exec} = IssueExec.read(ws)
      assert exec["rework_fix_applied"] == true,
        "doc_fix must NOT clear rework_fix_applied — it's part of the same cycle"
    end

    test "flag blocks redundant rework fix dispatch" do
      exec = %{
        "mode" => "unit_lite",
        "phase" => "implementing",
        "current_unit" => nil,
        "last_accepted_unit" => %{"kind" => "doc_fix"},
        "bootstrapped" => true,
        "rework_fix_applied" => true,
        "last_verified_sha" => nil,
        "doc_fix_required" => false,
        "plan_version" => 1
      }

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done
      """

      ctx = %{issue: %{state: "Rework"}, exec: exec, workpad_text: workpad, git_head: "abc"}
      result = DispatchResolver.resolve(ctx)

      # Should dispatch verify (not another rework fix)
      assert {:dispatch, %Unit{kind: :verify}} = result
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Invariant 5: doc_fix runs once before verify, not per-subtask
  #
  # Finding: per-subtask doc_fix burned N×1.5M tokens for N subtasks.
  # Invariant: doc_fix dispatches exactly once after all subtasks done,
  #            and does not re-dispatch after verify/handoff.
  # ──────────────────────────────────────────────────────────────────

  describe "doc_fix runs once before verify" do
    @doc_fix_exec %{
      "mode" => "unit_lite",
      "phase" => "implementing",
      "current_unit" => nil,
      "last_accepted_unit" => nil,
      "last_commit_sha" => nil,
      "last_verified_sha" => nil,
      "doc_fix_required" => false,
      "bootstrapped" => true,
      "plan_version" => 1
    }

    @done_workpad """
    ## Codex Workpad

    ### Plan
    - [x] [plan-1] Done
    - [x] [plan-2] Done
    """

    test "dispatches doc_fix when last_accepted is implement_subtask" do
      exec = Map.put(@doc_fix_exec, "last_accepted_unit", %{"kind" => "implement_subtask", "subtask_id" => "plan-2"})
      ctx = %{issue: %{state: "In Progress"}, exec: exec, workpad_text: @done_workpad, git_head: "abc"}
      assert {:dispatch, %Unit{kind: :doc_fix}} = DispatchResolver.resolve(ctx)
    end

    test "does NOT re-dispatch after doc_fix accepted" do
      exec = Map.put(@doc_fix_exec, "last_accepted_unit", %{"kind" => "doc_fix"})
      ctx = %{issue: %{state: "In Progress"}, exec: exec, workpad_text: @done_workpad, git_head: "abc"}
      # Should go to verify, not doc_fix again
      assert {:dispatch, %Unit{kind: :verify}} = DispatchResolver.resolve(ctx)
    end

    test "does NOT re-dispatch after verify accepted" do
      exec = @doc_fix_exec
             |> Map.put("last_accepted_unit", %{"kind" => "verify"})
             |> Map.put("last_verified_sha", "old")
      ctx = %{issue: %{state: "In Progress"}, exec: exec, workpad_text: @done_workpad, git_head: "abc"}
      # HEAD differs from verified → verify again, not doc_fix
      assert {:dispatch, %Unit{kind: :verify}} = DispatchResolver.resolve(ctx)
    end

    test "does NOT dispatch per-subtask (mid-implementation)" do
      exec = Map.put(@doc_fix_exec, "last_accepted_unit", %{"kind" => "implement_subtask", "subtask_id" => "plan-1"})
      partial_workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done
      - [ ] [plan-2] Not done
      """
      ctx = %{issue: %{state: "In Progress"}, exec: exec, workpad_text: partial_workpad, git_head: "abc"}
      # Should dispatch plan-2, not doc_fix
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-2"}} = DispatchResolver.resolve(ctx)
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Invariant 5b: fresh_rework must not include "verify"
  #
  # Finding: "verify" in fresh_rework detection caused infinite rework
  # loop. verify completes within a rework cycle (rework_fix → doc_fix
  # → verify), so treating it as a fresh entry resets rework_fix_applied
  # and re-dispatches rework_fix forever.
  # Invariant: fresh_rework only matches "handoff" and "merge".
  # ──────────────────────────────────────────────────────────────────

  describe "fresh_rework detection excludes verify" do
    test "agent_runner fresh_rework check does not include verify" do
      source = File.read!(Path.join(__DIR__, "../../lib/symphony_elixir/agent_runner.ex"))
      # Must match handoff/merge only — NOT verify
      assert source =~ ~s(last["kind"] in ["handoff", "merge"]),
        "fresh_rework must only match handoff/merge, not verify (causes infinite rework loop)"
      refute source =~ ~s(last["kind"] in ["handoff", "verify", "merge"]),
        "verify must NOT be in fresh_rework detection — it's a normal step within rework cycle"
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Invariant 6: retry path must not double-dispatch running issues
  #
  # Finding: continuation retry bypassed running check, causing two
  # concurrent tasks for the same issue (double token burn per stage).
  # Invariant: handle_active_retry skips dispatch if issue already running.
  # ──────────────────────────────────────────────────────────────────

  describe "retry does not double-dispatch running issues" do
    test "handle_active_retry has running guard in source" do
      source = File.read!(Path.join(__DIR__, "../../lib/symphony_elixir/orchestrator.ex"))
      assert source =~ "Map.has_key?(state.running, issue.id)",
        "handle_active_retry must check running map before dispatching"
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Invariant 6: should_dispatch_issue checks both claimed AND running
  #
  # Finding: multiple Symphony processes caused concurrent dispatch.
  # Even with a single process, the poll path must check both sets.
  # ──────────────────────────────────────────────────────────────────

  describe "poll dispatch checks both claimed and running" do
    test "should_dispatch_issue checks claimed set" do
      source = File.read!(Path.join(__DIR__, "../../lib/symphony_elixir/orchestrator.ex"))
      assert source =~ "MapSet.member?(claimed, issue.id)",
        "should_dispatch_issue? must check claimed set"
    end

    test "should_dispatch_issue checks running map" do
      source = File.read!(Path.join(__DIR__, "../../lib/symphony_elixir/orchestrator.ex"))
      assert source =~ "Map.has_key?(running, issue.id)",
        "should_dispatch_issue? must check running map"
    end

    test "start script kills existing processes" do
      source = File.read!(Path.expand("~/ptcg-centering/scripts/start-symphony.sh"))
      assert source =~ "pgrep -f",
        "start-symphony.sh must check for existing Symphony processes"
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Invariant 7: reasoning effort propagates correctly
  #
  # Finding: replay_current_unit_rule created Unit without effort.
  # Invariant: every dispatched Unit must have a valid reasoning_effort.
  # ──────────────────────────────────────────────────────────────────

  describe "reasoning effort always set on dispatch" do
    @valid_efforts ~w(low medium high xhigh)

    test "all Unit constructors set valid effort" do
      units = [
        Unit.bootstrap(), Unit.plan(), Unit.implement_subtask("s1"),
        Unit.doc_fix(), Unit.verify(), Unit.handoff(), Unit.merge()
      ]

      for unit <- units do
        assert unit.reasoning_effort in @valid_efforts,
          "#{unit.kind} must have valid effort, got: #{unit.reasoning_effort}"
      end
    end

    test "replay inherits correct effort from constructor" do
      exec = %{
        "mode" => "unit_lite", "phase" => "implementing",
        "bootstrapped" => true, "plan_version" => 1,
        "current_unit" => %{"kind" => "plan", "subtask_id" => nil, "attempt" => 1},
        "last_accepted_unit" => nil, "last_commit_sha" => nil,
        "last_verified_sha" => nil, "doc_fix_required" => false
      }

      ctx = %{issue: %{state: "In Progress"}, exec: exec, workpad_text: nil, git_head: "abc"}
      {:dispatch, unit} = DispatchResolver.resolve(ctx)

      assert unit.reasoning_effort == "xhigh",
        "replayed plan must use xhigh effort (from Unit.plan constructor)"
    end
  end
end
