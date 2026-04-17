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

    test "fills new schema fields with defaults when on-disk file is missing them (upgrade path)", %{workspace: ws} do
      # Simulate an issue_exec.json written by an older Symphony build that
      # predates round-5 fields (e.g., `pending_workpad_mark`). After upgrade,
      # `read/1` must not lose these defaults, otherwise downstream code that
      # reads `exec["pending_workpad_mark"]` would explode on KeyError.
      legacy_state = %{
        "mode" => "unit_lite",
        "phase" => "implementing",
        "bootstrapped" => true,
        "plan_version" => 1
      }

      File.mkdir_p!(Path.join(ws, ".symphony"))
      File.write!(Path.join([ws, ".symphony", "issue_exec.json"]), Jason.encode!(legacy_state))

      {:ok, state} = IssueExec.read(ws)

      # Map.has_key? is the actual merge-direction guard: if `Map.merge(@default_state, state)`
      # were deleted, the key would simply be absent (and `state["..."]` returns nil for
      # missing string keys, so the value-only assertion below would pass vacuously).
      assert Map.has_key?(state, "pending_workpad_mark")
      assert state["pending_workpad_mark"] == nil
      assert state["baseline_verify_failed"] == false
      assert state["verify_attempt"] == 0
      # Pre-existing legacy values are preserved through the merge.
      assert state["bootstrapped"] == true
      assert state["plan_version"] == 1
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

  # --- Warm-session review loop fields ---
  # See docs/design/warm-session-review-loop.md. The orchestrator tracks:
  #   - two Codex thread IDs (one per persistent session: implement + review)
  #   - a verdict enum written by code_review closeout
  #   - a round counter bumped on each review dispatch
  #   - the HEAD SHA at the most recent review, used to detect "new diff since
  #     last review" and to gate handoff

  describe "implement/review thread ids" do
    test "defaults are nil", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      {:ok, state} = IssueExec.read(ws)
      assert state["implement_thread_id"] == nil
      assert state["review_thread_id"] == nil
    end

    test "set_implement_thread_id persists", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      :ok = IssueExec.set_implement_thread_id(ws, "thread-impl-xyz")
      {:ok, state} = IssueExec.read(ws)
      assert state["implement_thread_id"] == "thread-impl-xyz"
    end

    test "set_review_thread_id persists", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      :ok = IssueExec.set_review_thread_id(ws, "thread-rev-xyz")
      {:ok, state} = IssueExec.read(ws)
      assert state["review_thread_id"] == "thread-rev-xyz"
    end
  end

  describe "review verdict + round counters" do
    test "default review_verdict is nil and review_round is 0", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      {:ok, state} = IssueExec.read(ws)
      assert state["review_verdict"] == nil
      assert state["review_round"] == 0
      assert state["last_reviewed_sha"] == nil
    end

    test "set_review_verdict persists 'findings' or 'clean' (the only verdicts prod writes)", %{workspace: ws} do
      :ok = IssueExec.init(ws)

      for verdict <- ["findings", "clean"] do
        :ok = IssueExec.set_review_verdict(ws, verdict)
        {:ok, state} = IssueExec.read(ws)
        assert state["review_verdict"] == verdict
      end
    end

    test "bump_review_round increments by 1", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      :ok = IssueExec.bump_review_round(ws)
      :ok = IssueExec.bump_review_round(ws)
      {:ok, state} = IssueExec.read(ws)
      assert state["review_round"] == 2
    end

    test "set_last_reviewed_sha persists", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      :ok = IssueExec.set_last_reviewed_sha(ws, "sha-abc")
      {:ok, state} = IssueExec.read(ws)
      assert state["last_reviewed_sha"] == "sha-abc"
    end
  end

  # When closeout returns {:retry, reason}, the reason describes *why* the
  # previous turn was rejected (e.g. "workpad has no ### Code Review section").
  # The resumed agent needs to see this exact reason on the next dispatch so
  # it can address the rejection rather than acting on the resumed prompt's
  # default assumptions (which are wrong for retry-after-closeout scenarios).
  describe "last_retry_reason" do
    test "default last_retry_reason is nil", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      {:ok, state} = IssueExec.read(ws)
      assert state["last_retry_reason"] == nil
    end

    test "set_last_retry_reason persists the exact string", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      :ok = IssueExec.set_last_retry_reason(ws, "code_review: workpad has no `### Code Review` section")
      {:ok, state} = IssueExec.read(ws)
      assert state["last_retry_reason"] == "code_review: workpad has no `### Code Review` section"
    end

    test "latest set overwrites prior reason (only most recent rejection is relevant)", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      :ok = IssueExec.set_last_retry_reason(ws, "first failure")
      :ok = IssueExec.set_last_retry_reason(ws, "second failure")
      {:ok, state} = IssueExec.read(ws)
      assert state["last_retry_reason"] == "second failure"
    end

    test "clear_last_retry_reason resets to nil", %{workspace: ws} do
      :ok = IssueExec.init(ws)
      :ok = IssueExec.set_last_retry_reason(ws, "something")
      :ok = IssueExec.clear_last_retry_reason(ws)
      {:ok, state} = IssueExec.read(ws)
      assert state["last_retry_reason"] == nil
    end

    test "reset_for_rework clears last_retry_reason", %{workspace: ws} do
      # Rework starts a fresh cycle — a retry reason from the prior cycle must
      # not leak into the new run's prompts.
      :ok = IssueExec.init(ws)
      :ok = IssueExec.set_last_retry_reason(ws, "prior cycle leftover")
      :ok = IssueExec.reset_for_rework(ws)
      {:ok, state} = IssueExec.read(ws)
      assert state["last_retry_reason"] == nil
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

    test "reset_for_rework clears all warm-session review loop state", %{workspace: ws} do
      # Under warm-session, when a human moves the ticket back to Rework, the
      # prior review verdict + round + both thread ids + last_reviewed_sha +
      # rework/doc_fix flags + retry reason + escalation sentinel must ALL go.
      # The rework cycle must start a fresh implement↔review loop, not resume
      # the pre-handoff warm threads (they may have been talking about code
      # the rework is now invalidating) and not inherit any "applied" flags
      # (doc_fix_applied=true would silently skip the pre-handoff doc sweep
      # on cycle 2).
      :ok = IssueExec.init(ws)
      :ok = IssueExec.mark_bootstrapped(ws)
      :ok = IssueExec.set_implement_thread_id(ws, "thread-impl-old")
      :ok = IssueExec.set_review_thread_id(ws, "thread-rev-old")
      :ok = IssueExec.set_review_verdict(ws, "clean")
      :ok = IssueExec.bump_review_round(ws)
      :ok = IssueExec.bump_review_round(ws)
      :ok = IssueExec.set_last_reviewed_sha(ws, "sha-pre-rework")
      :ok = IssueExec.set_last_retry_reason(ws, "leftover from prior cycle")
      # Pre-seed the applied-flags AND escalation so the test proves the reset
      # actually clears them (not just that they were default-false).
      :ok =
        IssueExec.update(ws, %{
          "rework_fix_applied" => true,
          "doc_fix_applied" => true,
          "escalated" => true
        })

      :ok = IssueExec.reset_for_rework(ws)
      {:ok, state} = IssueExec.read(ws)

      assert state["implement_thread_id"] == nil
      assert state["review_thread_id"] == nil
      assert state["review_verdict"] == nil
      assert state["review_round"] == 0
      assert state["last_reviewed_sha"] == nil
      assert state["last_retry_reason"] == nil
      assert state["rework_fix_applied"] == false, "rework_fix_applied must reset or 2nd rework skips fix dispatch"
      assert state["doc_fix_applied"] == false, "doc_fix_applied must reset or 2nd cycle skips doc sweep"
      assert state["escalated"] == false, "escalated must reset — human moving to Rework is the unblock signal"
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
