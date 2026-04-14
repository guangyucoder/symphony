defmodule SymphonyElixir.IntegrationUnitLiteTest do
  @moduledoc """
  Integration tests for the unit-lite flow. These test the full
  dispatch → closeout → re-dispatch cycle without a real Codex session,
  by simulating workspace state changes between steps.
  """
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Closeout, DispatchResolver, IssueExec, Ledger, Unit}

  setup do
    workspace = Path.join(System.tmp_dir!(), "integration_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    IssueExec.init(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  @issue %{state: "In Progress", identifier: "ENT-42", title: "Add feature"}

  defp resolve(workspace, issue, workpad_text \\ nil) do
    {:ok, exec} = IssueExec.read(workspace)
    ctx = %{
      issue: %{state: issue[:state] || issue.state},
      exec: exec,
      workpad_text: workpad_text,
      git_head: "abc123"
    }
    DispatchResolver.resolve(ctx)
  end

  defp simulate_unit_complete(workspace, unit_map, issue, opts \\ []) do
    IssueExec.start_unit(workspace, unit_map)
    Ledger.unit_started(workspace, unit_map)
    result = Closeout.run(workspace, unit_map, issue, opts)
    if result == :accepted do
      IssueExec.accept_unit(workspace)
      Ledger.unit_accepted(workspace, unit_map)
    end
    result
  end

  describe "Scenario A: normal ticket full flow" do
    test "bootstrap → plan → implement × 2 → verify → handoff", %{workspace: ws} do
      # Step 1: resolve → bootstrap
      assert {:dispatch, %Unit{kind: :bootstrap}} = resolve(ws, @issue)

      # Simulate bootstrap complete
      assert :accepted = simulate_unit_complete(ws, %{"kind" => "bootstrap"}, @issue)

      # Step 2: resolve → plan (no workpad yet)
      assert {:dispatch, %Unit{kind: :plan}} = resolve(ws, @issue)

      # Simulate plan complete with workpad
      workpad = """
      ## Codex Workpad
      `host:dir@abc123`

      ### Plan
      - [ ] [plan-1] Add component
      - [ ] [plan-2] Write tests
      """
      assert :accepted = simulate_unit_complete(ws, %{"kind" => "plan"}, @issue, workpad_text: workpad)

      # Step 3: resolve → implement_subtask(plan-1)
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-1"}} = resolve(ws, @issue, workpad)

      # Simulate subtask-1 complete
      assert :accepted = simulate_unit_complete(ws, %{"kind" => "implement_subtask", "subtask_id" => "plan-1"}, @issue)

      # Update workpad (mark plan-1 done)
      workpad_after_1 = String.replace(workpad, "- [ ] [plan-1]", "- [x] [plan-1]")

      # Step 4: resolve → implement_subtask(plan-2)
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-2"}} = resolve(ws, @issue, workpad_after_1)

      # Simulate subtask-2 complete
      assert :accepted = simulate_unit_complete(ws, %{"kind" => "implement_subtask", "subtask_id" => "plan-2"}, @issue)

      # Update workpad (mark plan-2 done)
      workpad_after_2 = String.replace(workpad_after_1, "- [ ] [plan-2]", "- [x] [plan-2]")

      # Step 5: resolve → doc_fix (one-time before verify)
      assert {:dispatch, %Unit{kind: :doc_fix}} = resolve(ws, @issue, workpad_after_2)
      assert :accepted = simulate_unit_complete(ws, %{"kind" => "doc_fix"}, @issue)

      # Step 6: resolve → verify
      assert {:dispatch, %Unit{kind: :verify}} = resolve(ws, @issue, workpad_after_2)

      # Simulate verify
      IssueExec.start_unit(ws, %{"kind" => "verify"})
      IssueExec.set_verified_sha(ws, "abc123")
      IssueExec.accept_unit(ws)
      Ledger.verify_passed(ws, "abc123")

      # Step 7: resolve → handoff
      assert {:dispatch, %Unit{kind: :handoff}} = resolve(ws, @issue, workpad_after_2)

      # Verify ledger has full history
      {:ok, entries} = Ledger.read(ws)
      events = Enum.map(entries, & &1["event"])
      assert "unit_started" in events
      assert "unit_accepted" in events
      assert "verify_passed" in events
    end
  end

  describe "Scenario B: doc-impact triggers doc_fix" do
    test "implement → doc_fix → implement continues", %{workspace: ws} do
      # Setup: bootstrapped + planned
      IssueExec.mark_bootstrapped(ws)
      IssueExec.bump_plan_version(ws)

      workpad = """
      ## Codex Workpad

      ### Plan
      - [ ] [plan-1] Change architecture
      - [ ] [plan-2] Update tests
      """

      # Step 1: implement plan-1
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-1"}} = resolve(ws, @issue, workpad)

      # Simulate subtask complete + doc impact detected
      IssueExec.start_unit(ws, %{"kind" => "implement_subtask", "subtask_id" => "plan-1"})
      IssueExec.accept_unit(ws)
      IssueExec.mark_doc_fix_required(ws, "architecture_doc_stale")
      Ledger.doc_fix_required(ws, "architecture_doc_stale")

      workpad_after_1 = String.replace(workpad, "- [ ] [plan-1]", "- [x] [plan-1]")

      # Step 2: resolve → doc_fix (NOT plan-2!)
      assert {:dispatch, %Unit{kind: :doc_fix}} = resolve(ws, @issue, workpad_after_1)

      # Simulate doc_fix complete
      assert :accepted = simulate_unit_complete(ws, %{"kind" => "doc_fix"}, @issue)

      # Step 3: resolve → implement plan-2 (doc_fix cleared)
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-2"}} = resolve(ws, @issue, workpad_after_1)
    end
  end

  describe "Scenario C: crash recovery" do
    test "crash during implement → replay same subtask", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.bump_plan_version(ws)

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done
      - [ ] [plan-2] In progress when crash happened
      - [ ] [plan-3] Not started
      """

      # Simulate: unit was started but NOT accepted (crash)
      IssueExec.start_unit(ws, %{"kind" => "implement_subtask", "subtask_id" => "plan-2", "attempt" => 1})
      Ledger.unit_started(ws, %{"kind" => "implement_subtask", "subtask_id" => "plan-2"})

      # After restart, resolve should replay plan-2
      result = resolve(ws, @issue, workpad)
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-2", attempt: 2}} = result
    end
  end

  describe "Scenario D: HEAD change invalidates verification" do
    test "verified at sha A, HEAD moves to sha B → re-verify", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.bump_plan_version(ws)
      IssueExec.set_verified_sha(ws, "sha_A")
      # Doc fix already done in this cycle
      IssueExec.update(ws, %{"last_accepted_unit" => %{"kind" => "verify"}})

      workpad_all_done = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done
      - [x] [plan-2] Done
      """

      # HEAD is now sha_B (different from verified sha_A)
      {:ok, exec} = IssueExec.read(ws)
      ctx = %{
        issue: %{state: "In Progress"},
        exec: exec,
        workpad_text: workpad_all_done,
        git_head: "sha_B"
      }

      # Should dispatch verify, NOT handoff
      assert {:dispatch, %Unit{kind: :verify}} = DispatchResolver.resolve(ctx)

      # After re-verification at sha_B
      IssueExec.set_verified_sha(ws, "sha_B")
      {:ok, exec} = IssueExec.read(ws)
      ctx = %{ctx | exec: exec}

      # Now should dispatch handoff
      assert {:dispatch, %Unit{kind: :handoff}} = DispatchResolver.resolve(ctx)
    end
  end

  describe "Merging flow" do
    test "Merging → merge unit", %{workspace: ws} do
      assert {:dispatch, %Unit{kind: :merge}} = resolve(ws, %{state: "Merging"})
    end
  end

  describe "Rework flow" do
    test "Rework with stale phase and no workpad → plan", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.update(ws, %{"phase" => "handoff", "last_accepted_unit" => %{"kind" => "handoff"}})

      assert {:dispatch, %Unit{kind: :plan}} = resolve(ws, %{state: "Rework"})
    end
  end

  describe "Scenario E: rework fix does NOT loop through doc_fix" do
    test "rework fix → doc_fix → verify (not another rework fix)", %{workspace: ws} do
      # Setup: completed normal cycle, now in Rework
      IssueExec.mark_bootstrapped(ws)

      workpad_all_done = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Add caching
      - [x] [plan-2] Write tests
      """

      rework_issue = %{state: "Rework", identifier: "ENT-42", title: "Fix"}

      # Step 1: resolve → rework fix (workpad complete, rework_fix_applied=false)
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "rework-1"}} =
               resolve(ws, rework_issue, workpad_all_done)

      # Simulate rework fix accepted (sets rework_fix_applied flag via closeout)
      IssueExec.start_unit(ws, %{"kind" => "implement_subtask", "subtask_id" => "rework-1"})
      IssueExec.accept_unit(ws)
      IssueExec.update(ws, %{"rework_fix_applied" => true})

      # Simulate doc_fix triggered
      IssueExec.mark_doc_fix_required(ws, "arch files changed")

      # Step 2: resolve → doc_fix (NOT another rework fix!)
      assert {:dispatch, %Unit{kind: :doc_fix}} = resolve(ws, rework_issue, workpad_all_done)

      # Simulate doc_fix accepted
      IssueExec.start_unit(ws, %{"kind" => "doc_fix"})
      IssueExec.accept_unit(ws)
      IssueExec.clear_doc_fix_required(ws)

      # Step 3: resolve → verify (NOT rework fix again!)
      assert {:dispatch, %Unit{kind: :verify}} = resolve(ws, rework_issue, workpad_all_done)

      # Verify rework_fix_applied flag blocked re-dispatch
      {:ok, exec} = IssueExec.read(ws)
      assert exec["rework_fix_applied"] == true
    end
  end

  describe "Scenario F: verify failure dispatches verify-fix (not blind retry)" do
    test "verify fails → sets verify_error → verify-fix dispatched", %{workspace: ws} do
      # Need a git repo for Verifier.current_head
      System.cmd("git", ["init"], cd: ws)
      File.write!(Path.join(ws, "test.txt"), "hello")
      System.cmd("git", ["add", "."], cd: ws)
      System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=t@t.com", "commit", "-m", "init"], cd: ws)

      IssueExec.mark_bootstrapped(ws)
      IssueExec.set_verified_sha(ws, nil)
      IssueExec.update(ws, %{"last_accepted_unit" => %{"kind" => "doc_fix"}})

      workpad_all_done = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done
      """

      # Verify fails (non-exhausted, attempt 1)
      IssueExec.start_unit(ws, %{"kind" => "verify"})
      result = Closeout.run(ws, %{"kind" => "verify"}, @issue, verify_commands: ["false"])
      assert {:retry, _} = result

      # verify_error set, current_unit cleared, verify_attempt=1
      {:ok, exec} = IssueExec.read(ws)
      assert is_binary(exec["verify_error"])
      assert exec["current_unit"] == nil
      assert exec["verify_attempt"] == 1

      # verified_sha NOT set
      assert exec["last_verified_sha"] == nil

      # Next dispatch: verify_fix_rule fires (NOT replay verify)
      {:ok, head_sha} = case System.cmd("git", ["rev-parse", "HEAD"], cd: ws) do
        {sha, 0} -> {:ok, String.trim(sha)}
        _ -> {:ok, "abc"}
      end

      ctx = %{
        issue: %{state: @issue.state},
        exec: exec,
        workpad_text: workpad_all_done,
        git_head: head_sha
      }
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "verify-fix-1"}} =
               DispatchResolver.resolve(ctx)
    end
  end

  describe "Scenario G: full rework cycle end-to-end" do
    test "normal flow → Rework → fix → doc_fix → verify → handoff", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.bump_plan_version(ws)

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Implement feature
      """

      # Verify + handoff
      IssueExec.set_verified_sha(ws, "abc123")
      IssueExec.start_unit(ws, %{"kind" => "handoff"})
      IssueExec.accept_unit(ws)

      rework_issue = %{state: "Rework", identifier: "ENT-42", title: "Fix"}

      # Step 1: rework fix
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "rework-1"}} =
               resolve(ws, rework_issue, workpad)

      IssueExec.start_unit(ws, %{"kind" => "implement_subtask", "subtask_id" => "rework-1"})
      IssueExec.accept_unit(ws)
      IssueExec.update(ws, %{"rework_fix_applied" => true, "last_verified_sha" => nil})
      IssueExec.mark_doc_fix_required(ws, "docs stale")

      # Step 2: doc_fix
      assert {:dispatch, %Unit{kind: :doc_fix}} = resolve(ws, rework_issue, workpad)
      IssueExec.start_unit(ws, %{"kind" => "doc_fix"})
      IssueExec.accept_unit(ws)
      IssueExec.clear_doc_fix_required(ws)

      # Step 3: verify
      assert {:dispatch, %Unit{kind: :verify}} = resolve(ws, rework_issue, workpad)
      IssueExec.start_unit(ws, %{"kind" => "verify"})
      IssueExec.set_verified_sha(ws, "abc123")
      IssueExec.accept_unit(ws)

      # Step 4: handoff
      assert {:dispatch, %Unit{kind: :handoff}} = resolve(ws, rework_issue, workpad)
    end
  end

  describe "Scenario H: 2nd rework cycle must re-apply fixes (P0 bug)" do
    test "rework_fix_applied is cleared when entering second rework cycle", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Feature
      """

      # First rework cycle: fix → verify → handoff
      IssueExec.update(ws, %{
        "rework_fix_applied" => true,
        "last_verified_sha" => "abc123",
        "last_accepted_unit" => %{"kind" => "handoff"}
      })

      # Simulate: issue goes back to active, then enters Rework AGAIN.
      # The rework cleanup should clear rework_fix_applied because
      # last_accepted is "handoff" (fresh rework entry).
      rework_issue = %{state: "Rework", identifier: "ENT-42", title: "Fix"}

      # Simulate the cleanup that agent_runner does on rework entry
      {:ok, exec} = IssueExec.read(ws)
      current = exec["current_unit"]
      last = exec["last_accepted_unit"]

      # current_unit is nil (clean handoff), last is handoff → fresh rework
      assert is_nil(current)
      assert last["kind"] == "handoff"

      # Apply the same cleanup logic as agent_runner
      IssueExec.update(ws, %{"rework_fix_applied" => false, "last_verified_sha" => nil})

      # NOW dispatch should give us rework fix, not skip it
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "rework-1"}} =
               resolve(ws, rework_issue, workpad)
    end
  end

  describe "Scenario I: git_head=nil stuck state" do
    test "all done + git_head=nil → no verify or handoff dispatched", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done
      """

      {:ok, exec} = IssueExec.read(ws)
      ctx = %{
        issue: %{state: "In Progress"},
        exec: exec,
        workpad_text: workpad,
        git_head: nil
      }

      # Neither verify nor handoff should dispatch — both guard on git_head != nil
      result = DispatchResolver.resolve(ctx)
      assert {:stop, :no_matching_rule} = result
    end
  end

  describe "Scenario J: circuit breaker on repeated crashes" do
    test "replay dispatches up to max attempts, then trips circuit breaker", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done
      - [ ] [plan-2] In progress
      """

      # Attempt 2: still replays
      IssueExec.start_unit(ws, %{
        "kind" => "implement_subtask",
        "subtask_id" => "plan-2",
        "attempt" => 2
      })
      result = resolve(ws, @issue, workpad)
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-2", attempt: 3}} = result

      # Attempt 3: circuit breaker trips
      IssueExec.start_unit(ws, %{
        "kind" => "implement_subtask",
        "subtask_id" => "plan-2",
        "attempt" => 3
      })
      result = resolve(ws, @issue, workpad)
      assert {:stop, :circuit_breaker} = result
    end
  end

  describe "Scenario K: rework from mid-implementation" do
    test "incomplete workpad + rework → falls through to implement old subtasks", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.bump_plan_version(ws)
      IssueExec.update(ws, %{
        "last_accepted_unit" => %{"kind" => "implement_subtask", "subtask_id" => "plan-1"},
        "phase" => "implementing"
      })

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done
      - [ ] [plan-2] Not done yet
      """

      rework_issue = %{state: "Rework", identifier: "ENT-42", title: "Fix"}

      # rework_fix_rule won't fire (workpad not all_done)
      # rework_reset_rule won't fire (last_accepted is implement_subtask, not handoff/verify/merge)
      # Falls through to implement_subtask_rule → picks up old plan-2
      result = resolve(ws, rework_issue, workpad)
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-2"}} = result
    end
  end

  describe "Scenario L: merge closeout checks PR state" do
    test "merge sets phase to done when PR is merged", %{workspace: ws} do
      IssueExec.update(ws, %{"phase" => "merging"})

      merged_checker = fn _ws -> :merged end
      assert :accepted = simulate_unit_complete(ws, %{"kind" => "merge"}, @issue, merge_checker: merged_checker)

      {:ok, exec} = IssueExec.read(ws)
      assert exec["phase"] == "done"

      # merge_rule checks phase != "done" → should NOT fire
      merging_issue = %{state: "Merging", identifier: "ENT-42", title: "Merge"}
      result = resolve(ws, merging_issue)
      assert {:stop, :merge_complete} = result
    end

    test "merge retries when PR is still open", %{workspace: ws} do
      IssueExec.update(ws, %{"phase" => "merging"})

      open_checker = fn _ws -> {:not_merged, "PR state: OPEN"} end
      unit_map = %{"kind" => "merge"}
      IssueExec.start_unit(ws, unit_map)
      result = Closeout.run(ws, unit_map, @issue, merge_checker: open_checker)

      assert {:retry, reason} = result
      assert reason =~ "not merged"

      # phase should NOT be "done"
      {:ok, exec} = IssueExec.read(ws)
      assert exec["phase"] != "done"

      # current_unit still set → replay_current_unit_rule fires on next dispatch
      {:ok, exec} = IssueExec.read(ws)
      ctx = %{issue: %{state: "Merging"}, exec: exec, workpad_text: nil, git_head: "abc"}
      assert {:dispatch, %Unit{kind: :merge, attempt: 2}} = DispatchResolver.resolve(ctx)
    end
  end

  describe "Scenario M: plan loop with no version cap" do
    test "unparseable plan accepted → plan re-dispatched", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)

      # Plan was accepted but workpad has no parseable checklist
      IssueExec.bump_plan_version(ws)
      IssueExec.start_unit(ws, %{"kind" => "plan"})
      IssueExec.accept_unit(ws)

      bad_workpad = """
      ## Codex Workpad
      Just some freeform text, no ### Plan section
      """

      # plan_rule fires again because workpad is not parseable
      result = resolve(ws, @issue, bad_workpad)
      assert {:dispatch, %Unit{kind: :plan}} = result

      # plan_version keeps incrementing
      {:ok, exec} = IssueExec.read(ws)
      assert exec["plan_version"] >= 1
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Scenario N: rework cycle with agent_runner cleanup simulation
  #
  # Finding: Scenario G tested DispatchResolver only, bypassing the
  # agent_runner fresh_rework cleanup that runs before every dispatch.
  # The cleanup was resetting rework_fix_applied after verify, causing
  # an infinite rework loop. This test simulates the full cycle including
  # the cleanup logic at each dispatch boundary.
  # ──────────────────────────────────────────────────────────────────

  describe "Scenario N: rework cycle does not loop (with agent_runner cleanup)" do
    test "rework_fix → doc_fix → verify → handoff (no re-dispatch of rework_fix)", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.bump_plan_version(ws)

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Implement feature
      """

      # Simulate: previous cycle completed handoff, supervisor moved to Rework
      IssueExec.update(ws, %{
        "last_accepted_unit" => %{"kind" => "handoff"},
        "last_verified_sha" => "old_sha",
        "rework_fix_applied" => false
      })

      rework_issue = %{state: "Rework", identifier: "ENT-42", title: "Fix review"}

      # --- Dispatch 1: simulate agent_runner rework cleanup, then resolve ---
      # This is what agent_runner.ex:44-61 does before every dispatch in Rework.
      simulate_rework_cleanup(ws)

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "rework-1"}} =
               resolve(ws, rework_issue, workpad)

      # Simulate rework-1 completion (closeout sets rework_fix_applied)
      IssueExec.start_unit(ws, %{"kind" => "implement_subtask", "subtask_id" => "rework-1"})
      IssueExec.accept_unit(ws)
      IssueExec.update(ws, %{"rework_fix_applied" => true, "last_verified_sha" => nil})

      # --- Dispatch 2: cleanup + resolve → doc_fix ---
      simulate_rework_cleanup(ws)
      assert {:dispatch, %Unit{kind: :doc_fix}} = resolve(ws, rework_issue, workpad)

      IssueExec.start_unit(ws, %{"kind" => "doc_fix"})
      IssueExec.accept_unit(ws)
      IssueExec.clear_doc_fix_required(ws)

      # --- Dispatch 3: cleanup + resolve → verify ---
      simulate_rework_cleanup(ws)
      assert {:dispatch, %Unit{kind: :verify}} = resolve(ws, rework_issue, workpad)

      IssueExec.start_unit(ws, %{"kind" => "verify"})
      IssueExec.set_verified_sha(ws, "abc123")
      IssueExec.accept_unit(ws)

      # --- Dispatch 4: cleanup + resolve → handoff (NOT rework-1 again!) ---
      simulate_rework_cleanup(ws)

      result = resolve(ws, rework_issue, workpad)
      assert {:dispatch, %Unit{kind: :handoff}} = result,
        "After verify in rework cycle, should dispatch handoff — not loop back to rework_fix"
    end
  end

  # Simulates the rework cleanup logic from agent_runner.ex:44-61.
  # Must be called before each resolve() in Rework tests to match
  # production behavior.
  defp simulate_rework_cleanup(workspace) do
    case IssueExec.read(workspace) do
      {:ok, exec} ->
        current = exec["current_unit"]
        last = exec["last_accepted_unit"]

        fresh_rework? = is_nil(current) and
                        is_map(last) and last["kind"] in ["handoff", "merge"]

        if fresh_rework? do
          IssueExec.update(workspace, %{
            "rework_fix_applied" => false,
            "last_verified_sha" => nil,
            "verify_error" => nil,
            "verify_attempt" => 0
          })
        end

      _ -> :ok
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Scenario O: verify fails → verify-fix → re-verify passes
  # ──────────────────────────────────────────────────────────────────

  describe "Scenario O: verify-fix dispatches on verification failure" do
    test "verify fails → verify-fix → verify passes → handoff", %{workspace: ws} do
      System.cmd("git", ["init"], cd: ws)
      File.write!(Path.join(ws, "test.txt"), "hello")
      System.cmd("git", ["add", "."], cd: ws)
      System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=t@t.com", "commit", "-m", "init"], cd: ws)

      IssueExec.mark_bootstrapped(ws)
      IssueExec.update(ws, %{"last_accepted_unit" => %{"kind" => "doc_fix"}})

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done
      """

      # Step 1: verify dispatched
      assert {:dispatch, %Unit{kind: :verify}} = resolve(ws, @issue, workpad)

      # Simulate verify failure (non-exhausted)
      IssueExec.start_unit(ws, %{"kind" => "verify"})
      result = Closeout.run(ws, %{"kind" => "verify"}, @issue, verify_commands: ["false"])
      assert {:retry, _} = result

      # verify_error set, current_unit cleared
      {:ok, exec} = IssueExec.read(ws)
      assert is_binary(exec["verify_error"])
      assert exec["current_unit"] == nil
      assert exec["verify_attempt"] == 1

      # Step 2: dispatch → verify-fix (NOT verify replay)
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "verify-fix-1"}} =
               resolve(ws, @issue, workpad)

      # Simulate verify-fix accepted — agent commits a real fix so the
      # commit-advancement guard clears verify_error.
      simulate_verify_fix_done(ws)
      IssueExec.update(ws, %{"last_accepted_unit" => %{"kind" => "doc_fix"}})

      # verify_error cleared
      {:ok, exec} = IssueExec.read(ws)
      assert exec["verify_error"] == nil

      # Step 3: verify again (passes this time)
      assert {:dispatch, %Unit{kind: :verify}} = resolve(ws, @issue, workpad)

      IssueExec.start_unit(ws, %{"kind" => "verify"})
      result = Closeout.run(ws, %{"kind" => "verify"}, @issue, verify_commands: ["true"])
      assert :accepted = result
      IssueExec.accept_unit(ws)
      # Align verified_sha with the hardcoded git_head used by resolve/3
      IssueExec.set_verified_sha(ws, "abc123")

      # Step 4: handoff
      assert {:dispatch, %Unit{kind: :handoff}} = resolve(ws, @issue, workpad)
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Scenario P: verify-fix cycle exhausts after max attempts
  # ──────────────────────────────────────────────────────────────────

  describe "Scenario P: verify-fix cycle cap and eventual exhaustion" do
    test "after 2 fix cycles, 3rd failure stops dispatching fixes and exhausts", %{workspace: ws} do
      System.cmd("git", ["init"], cd: ws)
      File.write!(Path.join(ws, "test.txt"), "hello")
      System.cmd("git", ["add", "."], cd: ws)
      System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=t@t.com", "commit", "-m", "init"], cd: ws)

      IssueExec.mark_bootstrapped(ws)
      IssueExec.update(ws, %{"last_accepted_unit" => %{"kind" => "doc_fix"}})

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done
      """

      # Fix cycle 1: verify fails → sets verify_error → verify-fix dispatched
      IssueExec.start_unit(ws, %{"kind" => "verify"})
      assert {:retry, _} = Closeout.run(ws, %{"kind" => "verify"}, @issue, verify_commands: ["false"])
      {:ok, exec} = IssueExec.read(ws)
      assert exec["verify_fix_count"] == 1
      assert is_binary(exec["verify_error"])

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "verify-fix-1"}} =
               resolve(ws, @issue, workpad)
      simulate_verify_fix_done(ws)
      IssueExec.update(ws, %{"last_accepted_unit" => %{"kind" => "doc_fix"}})

      # Fix cycle 2: verify fails → fix again
      IssueExec.start_unit(ws, %{"kind" => "verify"})
      assert {:retry, _} = Closeout.run(ws, %{"kind" => "verify"}, @issue, verify_commands: ["false"])
      {:ok, exec} = IssueExec.read(ws)
      assert exec["verify_fix_count"] == 2
      assert is_binary(exec["verify_error"])

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "verify-fix-1"}} =
               resolve(ws, @issue, workpad)
      simulate_verify_fix_done(ws)
      IssueExec.update(ws, %{"last_accepted_unit" => %{"kind" => "doc_fix"}})

      # 3rd verify failure: fix_count >= 2 → no verify_error, plain retry
      IssueExec.start_unit(ws, %{"kind" => "verify"})
      result = Closeout.run(ws, %{"kind" => "verify"}, @issue, verify_commands: ["false"])
      assert {:retry, _} = result

      {:ok, exec} = IssueExec.read(ws)
      assert exec["verify_error"] == nil, "should NOT set verify_error when fix cycles exhausted"

      # Next retries will accumulate verify_attempt until @max_verify_attempts → exhaustion
      IssueExec.start_unit(ws, %{"kind" => "verify"})
      result = Closeout.run(ws, %{"kind" => "verify"}, @issue, verify_commands: ["false"])
      assert {:retry, _} = result

      IssueExec.start_unit(ws, %{"kind" => "verify"})
      result = Closeout.run(ws, %{"kind" => "verify"}, @issue, verify_commands: ["false"])
      assert {:fail, reason} = result
      assert reason =~ "exhausted"
    end
  end

  defp simulate_verify_fix_done(ws) do
    # Snapshot HEAD, simulate an agent commit, then run closeout with the
    # dispatch_head so the commit-advancement guard sees HEAD advanced.
    {dispatch_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: ws)
    dispatch_head = String.trim(dispatch_head)

    fix_file = "verify_fix_#{System.unique_integer([:positive])}.txt"
    File.write!(Path.join(ws, fix_file), "fix\n")
    System.cmd("git", ["add", "."], cd: ws)
    System.cmd(
      "git",
      ["-c", "user.name=Test", "-c", "user.email=t@t.com", "commit", "-m", "verify-fix"],
      cd: ws
    )

    IssueExec.start_unit(ws, %{"kind" => "implement_subtask", "subtask_id" => "verify-fix-1"})

    Closeout.run(
      ws,
      %{"kind" => "implement_subtask", "subtask_id" => "verify-fix-1"},
      @issue,
      dispatch_head: dispatch_head
    )

    IssueExec.accept_unit(ws)
  end

  # ──────────────────────────────────────────────────────────────────
  # Scenario Q: programmatic merge — CI pass, pending, fail paths
  # ──────────────────────────────────────────────────────────────────

  describe "Scenario Q: programmatic merge dispatch paths" do
    test "CI fail during merge → verify_error set, verify-fix dispatched", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.update(ws, %{"phase" => "merging"})

      # Simulate what do_merge_with_ci_check does on CI failure
      IssueExec.set_verify_error(ws, "FAIL: board-actions.test.ts:222")
      IssueExec.update(ws, %{"current_unit" => nil, "verify_fix_count" => 1})

      # Dispatch in Merging state should give verify-fix (not merge)
      merging_issue = %{state: "Merging"}
      {:ok, exec} = IssueExec.read(ws)
      ctx = %{issue: merging_issue, exec: exec, workpad_text: nil, git_head: "abc"}
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "verify-fix-1"}} =
               DispatchResolver.resolve(ctx)
    end

    test "after verify-fix clears error → merge_rule fires again", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.update(ws, %{"phase" => "merging", "verify_error" => nil})

      merging_issue = %{state: "Merging"}
      {:ok, exec} = IssueExec.read(ws)
      ctx = %{issue: merging_issue, exec: exec, workpad_text: nil, git_head: "abc"}
      assert {:dispatch, %Unit{kind: :merge}} = DispatchResolver.resolve(ctx)
    end

    test "verify_fix_count caps prevent infinite CI-fail loop", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.update(ws, %{"phase" => "merging", "verify_fix_count" => 2})

      # With fix_count at cap (2), CI failure should NOT set verify_error
      # Simulating the agent_runner CI-fail logic:
      {:ok, exec_state} = IssueExec.read(ws)
      fix_count = exec_state["verify_fix_count"] || 0
      assert fix_count >= 2, "fix_count should be at cap"

      # merge_rule fires (no verify_error set), CI fails, returns :error → replay → circuit breaker
      merging_issue = %{state: "Merging"}
      {:ok, exec} = IssueExec.read(ws)
      ctx = %{issue: merging_issue, exec: exec, workpad_text: nil, git_head: "abc"}
      # Should dispatch merge (not verify-fix, since no verify_error)
      assert {:dispatch, %Unit{kind: :merge}} = DispatchResolver.resolve(ctx)
    end

    test "merge closeout accepts when PR merged", %{workspace: ws} do
      merged_checker = fn _ws -> :merged end
      assert :accepted = Closeout.run(ws, %{"kind" => "merge"}, @issue, merge_checker: merged_checker)
      {:ok, exec} = IssueExec.read(ws)
      assert exec["phase"] == "done"
    end

    test "merge closeout retries when PR not merged", %{workspace: ws} do
      open_checker = fn _ws -> {:not_merged, "PR OPEN"} end
      IssueExec.start_unit(ws, %{"kind" => "merge"})
      assert {:retry, _} = Closeout.run(ws, %{"kind" => "merge"}, @issue, merge_checker: open_checker)
      {:ok, exec} = IssueExec.read(ws)
      assert exec["phase"] != "done"
    end
  end
end
