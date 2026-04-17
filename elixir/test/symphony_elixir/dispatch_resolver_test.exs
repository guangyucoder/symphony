defmodule SymphonyElixir.DispatchResolverTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{DispatchResolver, Unit}

  @default_exec %{
    "mode" => "unit_lite",
    "phase" => "bootstrap",
    "current_unit" => nil,
    "last_accepted_unit" => nil,
    "last_commit_sha" => nil,
    # Warm-session review loop state (see docs/design/warm-session-review-loop.md).
    # last_verified_sha stays around for backward-compat with other tests, but
    # the new flow keys its gate off review_verdict, not this.
    "last_verified_sha" => nil,
    "implement_thread_id" => nil,
    "review_thread_id" => nil,
    "review_verdict" => nil,
    "review_round" => 0,
    "last_reviewed_sha" => nil,
    "doc_fix_applied" => false,
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

      assert {:dispatch, %Unit{kind: :plan}} =
               DispatchResolver.resolve(
                 ctx(%{
                   exec: exec,
                   workpad_text: "## Codex Workpad\nJust some text"
                 })
               )
    end

    test "dispatches implement_subtask for next unchecked item" do
      exec = %{@default_exec | "bootstrapped" => true}

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_with_pending
          })
        )

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-2"}} = result
    end

    test "dispatches code_review when all subtasks done and no prior review" do
      # Warm-session flow: plan subtasks done → loop entry is code_review, not
      # doc_fix. doc_fix moves to a pre-handoff sweep (runs only after review
      # is clean). See docs/design/warm-session-review-loop.md.
      exec = %{@default_exec | "bootstrapped" => true}

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_all_done,
            git_head: "abc123"
          })
        )

      assert {:dispatch, %Unit{kind: :code_review}} = result
    end

    test "ignores stale pre-warm-session exec flags (doc_fix_required, verify_error)" do
      # Workspaces predating the warm-session refactor may carry stale flags
      # (doc_fix_required, verify_error). The new flow keys off review_verdict
      # and must not be hijacked by either.
      exec =
        @default_exec
        |> Map.merge(%{
          "bootstrapped" => true,
          "doc_fix_required" => true,
          "verify_error" => "stale error"
        })

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_all_done,
            git_head: "abc123"
          })
        )

      assert {:dispatch, %Unit{kind: :code_review}} = result

      # Mid-implementation (workpad has unchecked items): implement_subtask
      # still wins regardless of stale flags.
      mid_workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] One
      - [ ] [plan-2] Two
      """

      result_mid =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: mid_workpad,
            git_head: "abc123"
          })
        )

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-2"}} = result_mid
    end

    test "stops when handoff was last accepted" do
      exec = %{
        @default_exec
        | "bootstrapped" => true,
          "review_verdict" => "clean",
          "last_reviewed_sha" => "abc123",
          "last_accepted_unit" => %{"kind" => "handoff"}
      }

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_all_done,
            git_head: "abc123"
          })
        )

      assert {:stop, :all_complete} = result
    end
  end

  # Warm-session review loop — see docs/design/warm-session-review-loop.md.
  # The state machine below replaces the old verify → code_review gate chain:
  # after all plan subtasks are done, an implement↔review loop runs until the
  # reviewer writes Verdict: clean (or review_round exceeds the cap).
  describe "warm-session review loop" do
    @workpad_clean_verdict """
    ## Codex Workpad

    ### Plan
    - [x] [plan-1] done
    - [x] [plan-2] done

    ### Code Review
    - Reviewed SHA: abc123
    - Findings: none
    - Verdict: clean
    """

    @workpad_findings_verdict """
    ## Codex Workpad

    ### Plan
    - [x] [plan-1] done

    ### Code Review
    - Reviewed SHA: abc123
    - Findings: 2 HIGH
    - Verdict: findings
    """

    test "dispatches code_review (first round) after all plan subtasks done" do
      # Subtasks complete, no review ever ran. Loop entry point.
      exec = %{@default_exec | "bootstrapped" => true, "last_accepted_unit" => %{"kind" => "doc_fix"}}

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_all_done,
            git_head: "abc123"
          })
        )

      assert {:dispatch, %Unit{kind: :code_review}} = result
    end

    test "dispatches implement (resume) when review verdict is findings" do
      # Reviewer wrote findings on the last round. Loop kicks back to the
      # implement session; agent_runner will resume_session on the stored
      # thread_id. subtask_id "review-fix" distinguishes this from the plan-N
      # subtask cycle so PromptBuilder can inject the findings delta instead of
      # the full workpad.
      exec = %{
        @default_exec
        | "bootstrapped" => true,
          "review_verdict" => "findings",
          "review_round" => 1,
          "last_reviewed_sha" => "abc123",
          "implement_thread_id" => "thread-impl-1",
          "review_thread_id" => "thread-rev-1"
      }

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_findings_verdict,
            git_head: "abc123"
          })
        )

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "review-fix-1"}} = result
    end

    test "dispatches code_review (resume) when implement fixed the findings and HEAD advanced" do
      # Implement session just committed fixes after a "findings" verdict.
      # HEAD > last_reviewed_sha signals new code to examine; review_verdict
      # stays "findings" until the next review turn updates it.
      exec = %{
        @default_exec
        | "bootstrapped" => true,
          "review_verdict" => "findings",
          "review_round" => 1,
          "last_reviewed_sha" => "abc123",
          "implement_thread_id" => "thread-impl-1",
          "review_thread_id" => "thread-rev-1",
          "last_accepted_unit" => %{"kind" => "implement_subtask", "subtask_id" => "review-fix-1"}
      }

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_findings_verdict,
            git_head: "new_sha"
          })
        )

      assert {:dispatch, %Unit{kind: :code_review}} = result
    end

    test "dispatches doc_fix once review verdict is clean" do
      # Clean verdict releases the loop. doc_fix runs its one-time sweep, then
      # handoff.
      exec = %{
        @default_exec
        | "bootstrapped" => true,
          "review_verdict" => "clean",
          "review_round" => 2,
          "last_reviewed_sha" => "abc123",
          "last_accepted_unit" => %{"kind" => "code_review"}
      }

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_clean_verdict,
            git_head: "abc123"
          })
        )

      assert {:dispatch, %Unit{kind: :doc_fix}} = result
    end

    test "dispatches handoff once verdict is clean and doc_fix_applied is set" do
      exec = %{
        @default_exec
        | "bootstrapped" => true,
          "review_verdict" => "clean",
          "review_round" => 2,
          "last_reviewed_sha" => "abc123",
          # Flag is the authoritative gate: it survives a post-doc_fix
          # re-review that shifts last_accepted_unit back to "code_review".
          "doc_fix_applied" => true,
          "last_accepted_unit" => %{"kind" => "doc_fix"}
      }

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_clean_verdict,
            git_head: "abc123"
          })
        )

      assert {:dispatch, %Unit{kind: :handoff}} = result
    end

    test "handoff rule refuses to fire when review_verdict is not clean" do
      # Second gate (symmetric with handoff_rule pre-warm-session design): even
      # if some other rule would try to advance, handoff refuses without a
      # clean verdict.
      exec = %{
        @default_exec
        | "bootstrapped" => true,
          "review_verdict" => "findings",
          "last_reviewed_sha" => "abc123"
      }

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_findings_verdict,
            git_head: "abc123"
          })
        )

      refute match?({:dispatch, %Unit{kind: :handoff}}, result)
    end

    test "escalates to {:stop, :review_exhausted} when review_round exceeds max" do
      # If AI can't converge to clean within max_review_rounds, bail to human
      # input rather than burn tokens forever. The orchestrator translates
      # :review_exhausted to Human Input Needed upstream.
      #
      # Semantics: `max_review_rounds` = max FIX cycles. review_round bumps on
      # each accepted review; strict > stops. With cap=5, rounds 1..5 get
      # review-fix dispatch; round 6 → exhaustion. The test uses cap+1 to
      # pin the boundary.
      cap = SymphonyElixir.Config.max_review_rounds()

      exec = %{
        @default_exec
        | "bootstrapped" => true,
          "review_verdict" => "findings",
          "review_round" => cap + 1,
          "last_reviewed_sha" => "abc123"
      }

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_findings_verdict,
            git_head: "abc123"
          })
        )

      assert {:stop, :review_exhausted} = result
    end

    test "still dispatches review-fix at exactly max_review_rounds (boundary: N fix cycles allowed)" do
      # Pin the off-by-one invariant: review_round == cap still gets a fix
      # cycle. Exhaustion only at cap+1.
      cap = SymphonyElixir.Config.max_review_rounds()

      exec = %{
        @default_exec
        | "bootstrapped" => true,
          "review_verdict" => "findings",
          "review_round" => cap,
          "last_reviewed_sha" => "abc123"
      }

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_findings_verdict,
            git_head: "abc123"
          })
        )

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: id}} = result
      assert String.starts_with?(id, "review-fix-")
    end

    test "verify unit no longer appears in the :normal rule chain (regression guard)" do
      # verify used to dispatch when plan was done + last_verified_sha was nil.
      # Under warm-session, tests run inside the implement session and the
      # only gate after plan completion is code_review. Any resurrection of
      # the verify rule must surface here.
      exec = %{
        @default_exec
        | "bootstrapped" => true,
          "last_verified_sha" => nil,
          "last_accepted_unit" => %{"kind" => "doc_fix"}
      }

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_all_done,
            git_head: "abc123"
          })
        )

      refute match?({:dispatch, %Unit{kind: :verify}}, result)
    end

    test "verify-fix subtask is never dispatched under warm-session flow" do
      # Previously verify_fix_rule fired on any non-nil verify_error. Under
      # warm-session, verify failures are handled inside the implement session
      # itself (warm context), never as a cold verify-fix-* subtask dispatch.
      exec =
        @default_exec
        |> Map.merge(%{
          "bootstrapped" => true,
          "verify_error" => "some stale error text"
        })

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_all_done,
            git_head: "abc123"
          })
        )

      refute match?({:dispatch, %Unit{kind: :implement_subtask, subtask_id: "verify-fix-" <> _}}, result)
    end
  end

  describe "merging flow" do
    test "dispatches merge when issue is Merging" do
      result =
        DispatchResolver.resolve(
          ctx(%{
            issue: %{state: "Merging"},
            exec: @default_exec
          })
        )

      assert {:dispatch, %Unit{kind: :merge}} = result
    end

    test "dispatches merge-sync implement_subtask when merge_conflict is set" do
      exec = Map.put(@default_exec, "merge_conflict", true)

      result =
        DispatchResolver.resolve(
          ctx(%{
            issue: %{state: "Merging"},
            exec: exec
          })
        )

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "merge-sync-1"}} = result
    end

    test "does not dispatch merge-sync when merge_conflict is false" do
      # Baseline: plain merge dispatch, merge_sync_rule should not fire.
      result =
        DispatchResolver.resolve(
          ctx(%{
            issue: %{state: "Merging"},
            exec: @default_exec
          })
        )

      refute match?({:dispatch, %Unit{kind: :implement_subtask, subtask_id: "merge-sync-" <> _}}, result)
    end

    test "dispatches verify when merge_needs_verify is set (post merge-sync)" do
      exec = Map.put(@default_exec, "merge_needs_verify", true)

      result =
        DispatchResolver.resolve(
          ctx(%{
            issue: %{state: "Merging"},
            exec: exec
          })
        )

      assert {:dispatch, %Unit{kind: :verify}} = result
    end

    test "merge_sync wins over merge_verify when both flags are set" do
      # Defensive: if the state somehow has both flags (e.g., crash between
      # writes), resolve the conflict first before re-verifying.
      exec =
        @default_exec
        |> Map.put("merge_conflict", true)
        |> Map.put("merge_needs_verify", true)

      result =
        DispatchResolver.resolve(
          ctx(%{
            issue: %{state: "Merging"},
            exec: exec
          })
        )

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "merge-sync-1"}} = result
    end

    test "merge-sync wins even if stale verify_error lingers (warm-session: verify-fix never fires)" do
      # Under warm-session, verify_fix_rule is gone from every rule table.
      # A stale verify_error from an upgraded workspace must not hijack the
      # merge flow; merge-sync takes precedence and tests are handled inside
      # that session.
      exec =
        @default_exec
        |> Map.put("merge_conflict", true)
        |> Map.put("verify_error", "boom")

      result =
        DispatchResolver.resolve(
          ctx(%{
            issue: %{state: "Merging"},
            exec: exec
          })
        )

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "merge-sync-1"}} = result
    end
  end

  describe "rework flow" do
    test "dispatches rework fix when workpad is complete (skip re-plan)" do
      exec = %{@default_exec | "bootstrapped" => true, "phase" => "handoff", "last_accepted_unit" => %{"kind" => "handoff"}}

      result =
        DispatchResolver.resolve(
          ctx(%{
            issue: %{state: "Rework"},
            exec: exec,
            workpad_text: @workpad_all_done
          })
        )

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "rework-1"}} = result
    end

    test "dispatches plan for rework when workpad is missing" do
      exec = %{@default_exec | "bootstrapped" => true, "phase" => "handoff", "last_accepted_unit" => %{"kind" => "handoff"}}

      result =
        DispatchResolver.resolve(
          ctx(%{
            issue: %{state: "Rework"},
            exec: exec,
            workpad_text: nil
          })
        )

      assert {:dispatch, %Unit{kind: :plan}} = result
    end

    test "dispatches plan for rework when workpad has pending items" do
      exec = %{@default_exec | "bootstrapped" => true, "phase" => "implementing", "last_accepted_unit" => %{"kind" => "implement_subtask", "subtask_id" => "plan-1"}}

      result =
        DispatchResolver.resolve(
          ctx(%{
            issue: %{state: "Rework"},
            exec: exec,
            workpad_text: @workpad_with_pending
          })
        )

      # Workpad not complete → falls through to implement_subtask_rule for pending items
      assert {:dispatch, %Unit{kind: :implement_subtask}} = result
    end

    test "after rework fix accepted, dispatches code_review (warm-session replaces doc_fix→verify chain)" do
      # Warm-session: after rework fix lands, we go straight to code_review
      # (no interstitial doc_fix or verify). Tests were run inside the rework
      # session. Clean review eventually leads to doc_fix → handoff.
      exec =
        @default_exec
        |> Map.merge(%{
          "bootstrapped" => true,
          "phase" => "implementing",
          "last_accepted_unit" => %{"kind" => "implement_subtask", "subtask_id" => "rework-1"},
          "rework_fix_applied" => true
        })

      result =
        DispatchResolver.resolve(
          ctx(%{
            issue: %{state: "Rework"},
            exec: exec,
            workpad_text: @workpad_all_done,
            git_head: "abc123"
          })
        )

      assert {:dispatch, %Unit{kind: :code_review}} = result
    end
  end

  describe "crash recovery" do
    test "replays current unit if not accepted" do
      exec = %{@default_exec | "bootstrapped" => true, "current_unit" => %{"kind" => "implement_subtask", "subtask_id" => "plan-2", "attempt" => 1}}

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_with_pending
          })
        )

      assert {:dispatch, %Unit{kind: :implement_subtask, subtask_id: "plan-2", attempt: 2}} = result
    end

    test "circuit breaker trips after max attempts" do
      exec = %{@default_exec | "bootstrapped" => true, "current_unit" => %{"kind" => "implement_subtask", "subtask_id" => "plan-2", "attempt" => 3}}

      result =
        DispatchResolver.resolve(
          ctx(%{
            exec: exec,
            workpad_text: @workpad_with_pending
          })
        )

      assert {:stop, :circuit_breaker} = result
    end

    # Regression: verify-fix replay must re-inject verify_error as
    # subtask_text. Without this, `Unit.to_map/1` drops subtask_text on
    # write, replay rebuilds with text=nil, and PromptBuilder renders
    # "(no error output captured)" — leaving the agent blind on retry.
    test "replays verify-fix with verify_error re-injected as subtask_text" do
      exec =
        %{
          @default_exec
          | "bootstrapped" => true,
            "current_unit" => %{
              "kind" => "implement_subtask",
              "subtask_id" => "verify-fix-1",
              "attempt" => 1
            }
        }
        |> Map.put("verify_error", "FooTest line 42: assertion failed")

      assert {:dispatch,
              %Unit{
                kind: :implement_subtask,
                subtask_id: "verify-fix-1",
                subtask_text: "FooTest line 42: assertion failed",
                attempt: 2
              }} =
               DispatchResolver.resolve(
                 ctx(%{
                   exec: exec,
                   workpad_text: @workpad_with_pending
                 })
               )
    end
  end
end
