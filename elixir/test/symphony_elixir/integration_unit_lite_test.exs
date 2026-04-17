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

    # Need a real git repo + at least one commit so the commit-advancement
    # guard in Closeout can observe HEAD transitions. simulate_unit_complete
    # snapshots pre-closeout HEAD and synthesizes a new commit so the guard
    # sees :advanced.
    System.cmd("git", ["init", "-q"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test"], cd: workspace)
    System.cmd("git", ["config", "user.email", "t@t.com"], cd: workspace)
    File.write!(Path.join(workspace, "seed.txt"), "seed\n")
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["commit", "-q", "-m", "init"], cd: workspace)

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

    # Mutation-bearing units (implement_subtask, doc_fix, rework-*, verify-fix-*)
    # now require a dispatch_head snapshot + HEAD advance before closeout will
    # accept them. Synthesize a commit when the caller didn't supply an explicit
    # dispatch_head, so the integration flow models "agent ran and committed".
    opts =
      if Keyword.has_key?(opts, :dispatch_head) or not mutation_bearing?(unit_map) do
        opts
      else
        {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
        dispatch_head = String.trim(head)
        advance_head!(workspace, unit_map)
        Keyword.put(opts, :dispatch_head, dispatch_head)
      end

    result = Closeout.run(workspace, unit_map, issue, opts)

    if result == :accepted do
      IssueExec.accept_unit(workspace)
      Ledger.unit_accepted(workspace, unit_map)
    end

    result
  end

  defp mutation_bearing?(%{"kind" => "implement_subtask"}), do: true
  defp mutation_bearing?(%{"kind" => "doc_fix"}), do: true
  defp mutation_bearing?(_), do: false

  defp advance_head!(workspace, %{"kind" => kind} = unit_map) do
    tag = (unit_map["subtask_id"] || kind) |> to_string()
    marker = Path.join(workspace, "progress-#{tag}-#{System.unique_integer([:positive])}.txt")
    File.write!(marker, "progress\n")
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["commit", "-q", "-m", "simulate #{tag}"], cd: workspace)
    :ok
  end

  describe "Scenario A: normal ticket full flow (warm-session)" do
    test "bootstrap → plan → implement × 2 → code_review (clean) → doc_fix → handoff", %{workspace: ws} do
      # Step 1: resolve → bootstrap
      assert {:dispatch, %Unit{kind: :bootstrap}} = resolve(ws, @issue)
      assert :accepted = simulate_unit_complete(ws, %{"kind" => "bootstrap"}, @issue)

      # Step 2: resolve → plan (no workpad yet)
      assert {:dispatch, %Unit{kind: :plan}} = resolve(ws, @issue)

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
      assert :accepted = simulate_unit_complete(ws, %{"kind" => "implement_subtask", "subtask_id" => "plan-1"}, @issue)

      workpad_after_1 = String.replace(workpad, "- [ ] [plan-1]", "- [x] [plan-1]")

      # Step 4: resolve → implement_subtask(plan-2)
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-2"}} = resolve(ws, @issue, workpad_after_1)
      assert :accepted = simulate_unit_complete(ws, %{"kind" => "implement_subtask", "subtask_id" => "plan-2"}, @issue)

      workpad_after_2 = String.replace(workpad_after_1, "- [ ] [plan-2]", "- [x] [plan-2]")

      # Step 5: resolve → code_review (first round — warm-session loop entry)
      assert {:dispatch, %Unit{kind: :code_review}} = resolve(ws, @issue, workpad_after_2)

      # Simulate code_review accepting "clean" verdict — closeout sets verdict,
      # pins last_reviewed_sha, bumps round.
      IssueExec.start_unit(ws, %{"kind" => "code_review"})
      IssueExec.update(ws, %{
        "review_verdict" => "clean",
        "last_reviewed_sha" => "abc123",
        "review_round" => 1
      })
      IssueExec.accept_unit(ws)

      # Step 6: resolve → doc_fix (pre-handoff sweep now that review is clean)
      assert {:dispatch, %Unit{kind: :doc_fix}} = resolve(ws, @issue, workpad_after_2)
      assert :accepted = simulate_unit_complete(ws, %{"kind" => "doc_fix"}, @issue)

      # Step 7: resolve → handoff
      assert {:dispatch, %Unit{kind: :handoff}} = resolve(ws, @issue, workpad_after_2)

      {:ok, entries} = Ledger.read(ws)
      events = Enum.map(entries, & &1["event"])
      assert "unit_started" in events
      assert "unit_accepted" in events
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

      # Simulate subtask complete (no per-subtask doc_fix detection; doc_fix
      # runs once after all subtasks are done — see Scenario A)
      IssueExec.start_unit(ws, %{"kind" => "implement_subtask", "subtask_id" => "plan-1"})
      IssueExec.accept_unit(ws)

      workpad_after_1 = String.replace(workpad, "- [ ] [plan-1]", "- [x] [plan-1]")

      # Resolve → next implement, NOT doc_fix (doc_fix is a pre-verify sweep)
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

  describe "Scenario D: HEAD change invalidates review" do
    test "review clean at sha A, HEAD moves to sha B → re-review before handoff", %{workspace: ws} do
      # Warm-session equivalent of "verified sha doesn't match HEAD": if the
      # implement session committed something AFTER review accepted a clean
      # verdict, handoff must wait for the reviewer to look again at the new
      # diff. This guards against agents landing untested follow-up commits
      # between review and handoff.
      IssueExec.mark_bootstrapped(ws)
      IssueExec.bump_plan_version(ws)

      IssueExec.update(ws, %{
        "review_verdict" => "clean",
        "last_reviewed_sha" => "sha_A",
        "review_round" => 1,
        "last_accepted_unit" => %{"kind" => "code_review"}
      })

      workpad_all_done = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done
      - [x] [plan-2] Done

      ### Code Review
      - Verdict: clean
      """

      {:ok, exec} = IssueExec.read(ws)

      # HEAD moved past the reviewed sha. Under warm-session this is the
      # "clean verdict is stale" signal.
      ctx = %{
        issue: %{state: "In Progress"},
        exec: exec,
        workpad_text: workpad_all_done,
        git_head: "sha_B"
      }

      # handoff must not fire — the gate's HEAD-match check catches this.
      refute match?({:dispatch, %Unit{kind: :handoff}}, DispatchResolver.resolve(ctx))

      # Reviewer picks up sha_B with a fresh verdict.
      IssueExec.update(ws, %{
        "last_reviewed_sha" => "sha_B",
        "review_round" => 2
      })

      {:ok, exec} = IssueExec.read(ws)
      ctx = %{ctx | exec: exec}

      # With review now aligned to HEAD, doc_fix fires (pre-handoff sweep),
      # then handoff.
      assert {:dispatch, %Unit{kind: :doc_fix}} = DispatchResolver.resolve(ctx)

      # Simulate doc_fix closeout: flag is set AND last_accepted_unit transitions.
      # The authoritative gate is `doc_fix_applied` — without it the test would
      # pass via last_accepted_unit scraping, hiding the real regression.
      IssueExec.update(ws, %{
        "doc_fix_applied" => true,
        "last_accepted_unit" => %{"kind" => "doc_fix"}
      })

      {:ok, exec} = IssueExec.read(ws)
      ctx = %{ctx | exec: exec}

      assert {:dispatch, %Unit{kind: :handoff}} = DispatchResolver.resolve(ctx)
    end

    test "post-doc_fix real commit → re-review → doc_fix does NOT fire again", %{workspace: ws} do
      # The exact scenario Lens 1/3 flagged: first doc_fix commits real changes
      # → HEAD advances → code_review re-fires → last_accepted_unit shifts to
      # "code_review". Scrape-based gates would re-dispatch doc_fix. The flag
      # makes this impossible.
      IssueExec.mark_bootstrapped(ws)
      IssueExec.bump_plan_version(ws)

      IssueExec.update(ws, %{
        "review_verdict" => "clean",
        "last_reviewed_sha" => "sha_B",
        "review_round" => 2,
        # First doc_fix ran, committed changes, re-review ran clean on the new HEAD.
        "doc_fix_applied" => true,
        "last_accepted_unit" => %{"kind" => "code_review"}
      })

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done

      ### Code Review
      - Verdict: clean
      """

      {:ok, exec} = IssueExec.read(ws)

      ctx = %{
        issue: %{state: "In Progress"},
        exec: exec,
        workpad_text: workpad,
        git_head: "sha_B"
      }

      # Must fire handoff, NOT doc_fix. Regression guard: removing the flag
      # check makes this test fail because last_accepted_unit=="code_review"
      # is interpreted as "doc_fix hasn't run."
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

  describe "Scenario E: rework fix → code_review (warm-session)" do
    test "rework fix does NOT re-loop and does NOT detour through verify", %{workspace: ws} do
      # Under warm-session there's no verify unit between rework fix and code
      # review. Rework fix commits, then code_review is dispatched against
      # the new HEAD. doc_fix is a pre-handoff sweep now, not a pre-verify
      # one.
      IssueExec.mark_bootstrapped(ws)

      workpad_all_done = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Add caching
      - [x] [plan-2] Write tests
      """

      rework_issue = %{state: "Rework", identifier: "ENT-42", title: "Fix"}

      # Step 1: rework fix dispatches (workpad complete, rework_fix_applied=false)
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "rework-1"}} =
               resolve(ws, rework_issue, workpad_all_done)

      IssueExec.start_unit(ws, %{"kind" => "implement_subtask", "subtask_id" => "rework-1"})
      IssueExec.accept_unit(ws)
      IssueExec.update(ws, %{"rework_fix_applied" => true})

      # Step 2: next dispatch is code_review — NOT another rework fix, NOT
      # doc_fix (doc_fix only runs after clean verdict), NOT verify (deleted).
      assert {:dispatch, %Unit{kind: :code_review}} = resolve(ws, rework_issue, workpad_all_done)

      # Regression guard: rework_fix_applied stays true so the loop can't
      # re-dispatch rework-1.
      {:ok, exec} = IssueExec.read(ws)
      assert exec["rework_fix_applied"] == true
    end
  end

  describe "Scenario G: full rework cycle end-to-end" do
    test "normal flow → Rework → fix → code_review → doc_fix → handoff (warm-session flow)", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.bump_plan_version(ws)

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Implement feature
      """

      # Pretend a prior cycle handed off
      IssueExec.start_unit(ws, %{"kind" => "handoff"})
      IssueExec.accept_unit(ws)

      rework_issue = %{state: "Rework", identifier: "ENT-42", title: "Fix"}

      # Step 1: rework fix
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "rework-1"}} =
               resolve(ws, rework_issue, workpad)

      IssueExec.start_unit(ws, %{"kind" => "implement_subtask", "subtask_id" => "rework-1"})
      IssueExec.accept_unit(ws)
      IssueExec.update(ws, %{"rework_fix_applied" => true})

      # Step 2: code_review first round (replaces doc_fix → verify chain)
      assert {:dispatch, %Unit{kind: :code_review}} = resolve(ws, rework_issue, workpad)
      IssueExec.start_unit(ws, %{"kind" => "code_review"})
      IssueExec.update(ws, %{
        "review_verdict" => "clean",
        "last_reviewed_sha" => "abc123",
        "review_round" => 1
      })
      IssueExec.accept_unit(ws)

      # Step 3: doc_fix (pre-handoff sweep)
      assert {:dispatch, %Unit{kind: :doc_fix}} = resolve(ws, rework_issue, workpad)
      IssueExec.start_unit(ws, %{"kind" => "doc_fix"})
      # Simulate closeout setting the authoritative flag — scrape-based
      # tests would pass via last_accepted_unit="doc_fix" but the real gate
      # is `doc_fix_applied`.
      IssueExec.update(ws, %{"doc_fix_applied" => true})
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

  describe "Scenario N: warm-session rework cycle with agent_runner cleanup" do
    test "rework_fix → code_review → doc_fix → handoff (no re-dispatch of rework_fix)", %{workspace: ws} do
      # Covers Scenario G's ground but also invokes the agent_runner cleanup
      # between dispatches. The cleanup clears rework_fix_applied whenever we
      # re-enter a rework cycle from handoff/merge — it must not clear during
      # mid-cycle.
      IssueExec.mark_bootstrapped(ws)
      IssueExec.bump_plan_version(ws)

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Implement feature
      """

      IssueExec.update(ws, %{
        "last_accepted_unit" => %{"kind" => "handoff"},
        "rework_fix_applied" => false
      })

      rework_issue = %{state: "Rework", identifier: "ENT-42", title: "Fix review"}

      # Dispatch 1: cleanup + resolve → rework fix
      simulate_rework_cleanup(ws)

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "rework-1"}} =
               resolve(ws, rework_issue, workpad)

      IssueExec.start_unit(ws, %{"kind" => "implement_subtask", "subtask_id" => "rework-1"})
      IssueExec.accept_unit(ws)
      IssueExec.update(ws, %{"rework_fix_applied" => true})

      # Dispatch 2: cleanup + resolve → code_review (first review of fix)
      simulate_rework_cleanup(ws)
      assert {:dispatch, %Unit{kind: :code_review}} = resolve(ws, rework_issue, workpad)

      IssueExec.start_unit(ws, %{"kind" => "code_review"})
      IssueExec.update(ws, %{
        "review_verdict" => "clean",
        "last_reviewed_sha" => "abc123",
        "review_round" => 1
      })
      IssueExec.accept_unit(ws)

      # Dispatch 3: cleanup + resolve → doc_fix (pre-handoff sweep)
      simulate_rework_cleanup(ws)
      assert {:dispatch, %Unit{kind: :doc_fix}} = resolve(ws, rework_issue, workpad)

      IssueExec.start_unit(ws, %{"kind" => "doc_fix"})
      # Authoritative gate the real closeout sets.
      IssueExec.update(ws, %{"doc_fix_applied" => true})
      IssueExec.accept_unit(ws)

      # Dispatch 4: cleanup + resolve → handoff
      simulate_rework_cleanup(ws)

      assert {:dispatch, %Unit{kind: :handoff}} = resolve(ws, rework_issue, workpad),
             "After clean verdict + doc_fix, rework cycle exits to handoff"
    end
  end

  # Simulates the rework cleanup logic from agent_runner.ex. Must be called
  # before each resolve() in Rework tests to match production behavior.
  defp simulate_rework_cleanup(workspace) do
    case IssueExec.read(workspace) do
      {:ok, exec} ->
        current = exec["current_unit"]
        last = exec["last_accepted_unit"]

        fresh_rework? =
          is_nil(current) and
            is_map(last) and last["kind"] in ["handoff", "merge"]

        if fresh_rework? do
          IssueExec.update(workspace, %{
            "rework_fix_applied" => false,
            "last_verified_sha" => nil,
            "verify_error" => nil,
            "verify_attempt" => 0
          })
        end

      _ ->
        :ok
    end
  end

  # Scenarios O / P (verify-fix cold-session cycle) deleted under the
  # warm-session redesign. Verify failures are handled inside the implement
  # session's own multi-turn loop; no separate verify-fix-* dispatch exists.
  # The old tests asserted on verify_error state machines that no longer
  # apply. See docs/design/warm-session-review-loop.md.

  # ──────────────────────────────────────────────────────────────────
  # Scenario Q: programmatic merge — merge-sync vs merge, no verify-fix
  # ──────────────────────────────────────────────────────────────────

  describe "Scenario Q: programmatic merge dispatch paths" do
    test "merge dispatches regardless of stale verify_error (warm-session: no verify-fix hijack)", %{workspace: ws} do
      # Under warm-session, verify_fix_rule is gone. A stale verify_error
      # from a pre-warm-session upgrade must not prevent merge from firing.
      IssueExec.mark_bootstrapped(ws)
      IssueExec.update(ws, %{"phase" => "merging"})
      IssueExec.set_verify_error(ws, "FAIL: old error from pre-warm-session")

      merging_issue = %{state: "Merging"}
      {:ok, exec} = IssueExec.read(ws)
      ctx = %{issue: merging_issue, exec: exec, workpad_text: nil, git_head: "abc"}

      assert {:dispatch, %Unit{kind: :merge}} = DispatchResolver.resolve(ctx)
    end

    test "merge_rule fires when no conflict and no merge_needs_verify flag", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.update(ws, %{"phase" => "merging"})

      merging_issue = %{state: "Merging"}
      {:ok, exec} = IssueExec.read(ws)
      ctx = %{issue: merging_issue, exec: exec, workpad_text: nil, git_head: "abc"}
      assert {:dispatch, %Unit{kind: :merge}} = DispatchResolver.resolve(ctx)
    end

    test "merge_sync_rule wins when merge_conflict is set", %{workspace: ws} do
      IssueExec.mark_bootstrapped(ws)
      IssueExec.update(ws, %{"phase" => "merging", "merge_conflict" => true})

      merging_issue = %{state: "Merging"}
      {:ok, exec} = IssueExec.read(ws)
      ctx = %{issue: merging_issue, exec: exec, workpad_text: nil, git_head: "abc"}
      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "merge-sync-1"}} =
               DispatchResolver.resolve(ctx)
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
