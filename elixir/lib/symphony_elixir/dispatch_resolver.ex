defmodule SymphonyElixir.DispatchResolver do
  @moduledoc """
  Determines the next unit to dispatch for an issue in unit-lite mode.

  Input: issue state + issue_exec state + parsed workpad + git HEAD
  Output: {:dispatch, Unit.t()} | {:stop, reason} | :skip

  Rules are ordered — first match wins.
  """

  alias SymphonyElixir.{Unit, WorkpadParser}

  @type resolve_context :: %{
          issue: map(),
          exec: map(),
          workpad_text: String.t() | nil,
          git_head: String.t() | nil
        }

  @type result :: {:dispatch, Unit.t()} | {:stop, atom()} | :skip

  @doc """
  Resolve the next unit to dispatch.

  The context map must contain:
  - `issue` — Linear issue (at minimum `%{state: "..."}`)
  - `exec` — current issue_exec.json state
  - `workpad_text` — raw workpad comment text (or nil)
  - `git_head` — current HEAD SHA (or nil)
  """
  @spec resolve(resolve_context()) :: result()
  def resolve(%{issue: issue} = ctx) do
    rules(flow(issue))
    |> Enum.find_value(fn rule -> rule.(ctx) end) ||
      {:stop, :no_matching_rule}
  end

  # --- Flow routing ---

  defp flow(%{state: state}) when is_binary(state) do
    case String.downcase(String.trim(state)) do
      "merging" -> :merging
      "rework" -> :rework
      _ -> :normal
    end
  end

  defp flow(_), do: :normal

  # --- Rule tables ---

  # Merging flow is scoped separately from the warm-session review loop: it
  # covers externally-created conflicts (merge-sync) and verifying the merge
  # commit before the programmatic merge completes. `merge_verify_rule` still
  # dispatches a `verify` unit because, for a merge commit, the merge-sync
  # session may already be gone; rerunning the workflow's full verification
  # suite inside Symphony is still the correct gate there.
  defp rules(:merging),
    do: [
      &escalated_short_circuit_rule/1,
      &replay_current_unit_rule/1,
      &merge_sync_rule/1,
      # verify_fix_rule must run BEFORE merge_verify_rule — when a merge-time
      # verify fails, closeout sets verify_error and clears current_unit
      # expecting a verify-fix dispatch. Without this rule, merge_verify_rule
      # re-fires Unit.verify() forever and the repair path is dead.
      &verify_fix_rule/1,
      &merge_verify_rule/1,
      &merge_rule/1,
      &merge_done_rule/1
    ]

  defp rules(:rework),
    do: [
      &escalated_short_circuit_rule/1,
      &replay_current_unit_rule/1,
      &rework_fix_rule/1,
      &rework_reset_rule/1,
      &plan_rule/1,
      &implement_subtask_rule/1,
      &review_exhausted_rule/1,
      &review_findings_implement_rule/1,
      &code_review_rule/1,
      &pre_handoff_doc_fix_rule/1,
      &handoff_rule/1,
      &done_rule/1
    ]

  defp rules(:normal),
    do: [
      &escalated_short_circuit_rule/1,
      &replay_current_unit_rule/1,
      &done_rule/1,
      &bootstrap_rule/1,
      &plan_rule/1,
      &implement_subtask_rule/1,
      &review_exhausted_rule/1,
      &review_findings_implement_rule/1,
      &code_review_rule/1,
      &pre_handoff_doc_fix_rule/1,
      &handoff_rule/1
    ]

  # Escalation sentinel: set by AgentRunner.escalate_to_human/3 so that a
  # failed Linear state transition can't loop the orchestrator into re-running
  # the same work. Only cleared when the human explicitly moves the ticket
  # to Rework (rework_reset_updates/0 zeroes it). First in every rule chain
  # so no other rule can preempt it.
  defp escalated_short_circuit_rule(%{exec: %{"escalated" => true}}) do
    {:stop, :already_escalated}
  end

  defp escalated_short_circuit_rule(_), do: nil

  # --- Rule implementations ---

  # If current_unit exists and was not accepted, replay it (crash recovery).
  # Circuit breaker: after Config.max_unit_attempts() consecutive crashes, stop
  # and escalate to human instead of burning tokens forever.
  # Warm-session review loop removed `verify` and `verify-fix-*` from the
  # dispatchable set — tests now run inside the implement session itself.
  # They remain legal here only so stale exec files from the pre-warm-session
  # era don't crash-loop when replayed; those cases fall through to
  # replay_current_unit_rule's guard ("corrupted exec file — clear
  # current_unit and let normal rules take over") and the fresh rules below.
  # "verify" is kept in the valid set so that a crash-replay of a
  # merge_verify_rule dispatch (the only path that still dispatches Unit.verify())
  # increments `attempt` through the circuit breaker rather than being
  # silently cleared via the corrupted-exec branch.
  @valid_unit_kinds ~w(bootstrap plan implement_subtask doc_fix verify code_review handoff merge)
  @kind_atoms %{
    "bootstrap" => :bootstrap,
    "plan" => :plan,
    "implement_subtask" => :implement_subtask,
    "doc_fix" => :doc_fix,
    "verify" => :verify,
    "code_review" => :code_review,
    "handoff" => :handoff,
    "merge" => :merge
  }

  defp replay_current_unit_rule(%{exec: %{"current_unit" => unit} = exec}) when not is_nil(unit) do
    kind_str = unit["kind"]
    attempt = (unit["attempt"] || 1) + 1

    cond do
      kind_str not in @valid_unit_kinds ->
        # Corrupted exec file — clear current_unit and let normal rules take over
        nil

      attempt > SymphonyElixir.Config.max_unit_attempts() ->
        # Circuit breaker: too many consecutive crashes on this unit
        {:stop, :circuit_breaker}

      true ->
        kind = Map.fetch!(@kind_atoms, kind_str)
        subtask_id = unit["subtask_id"]

        base_unit =
          case {kind, subtask_id} do
            {:implement_subtask, id} -> Unit.implement_subtask(id, replay_subtask_text(id, exec))
            {:bootstrap, _} -> Unit.bootstrap()
            {:plan, _} -> Unit.plan()
            {:doc_fix, _} -> Unit.doc_fix()
            {:verify, _} -> Unit.verify()
            {:code_review, _} -> Unit.code_review()
            {:handoff, _} -> Unit.handoff()
            {:merge, _} -> Unit.merge()
          end

        {:dispatch, %{base_unit | display_name: "replay:#{kind_str}#{if subtask_id, do: ":#{subtask_id}", else: ""}", attempt: attempt}}
    end
  end

  defp replay_current_unit_rule(_), do: nil

  # On replay, `Unit.to_map/1` does not persist `subtask_text`, so a
  # naive rebuild loses the dispatch-time payload. For verify-fix-* that
  # payload is the verify error output — without it the prompt shows
  # "(no error output captured)" and the agent retries blind. Re-inject
  # from the canonical source (`exec.verify_error`) when we're rebuilding
  # a verify-fix unit.
  defp replay_subtask_text(id, exec)
       when is_binary(id) do
    cond do
      String.starts_with?(id, "verify-fix-") and is_binary(exec["verify_error"]) ->
        exec["verify_error"]

      true ->
        nil
    end
  end

  defp replay_subtask_text(_id, _exec), do: nil

  # Merging flow: dispatch merge-sync when the PR has conflicts against main.
  # agent_runner.handle_merge_conflict sets merge_conflict=true and clears
  # current_unit when gh reports CONFLICTING mergeability; this rule then
  # dispatches an implement_subtask so the agent resolves it in-workspace.
  defp merge_sync_rule(%{exec: %{"merge_conflict" => true}}) do
    {:dispatch, Unit.implement_subtask("merge-sync-1", "Resolve merge conflicts against origin/main, then push.")}
  end

  defp merge_sync_rule(_), do: nil

  # Merge-time verify failed and closeout set `verify_error`. Dispatch a
  # verify-fix subtask so the agent can repair the merged tree. This rule
  # only lives in the :merging flow — normal-flow verify is now folded into
  # the warm implement session, so verify-fix is a merge-specific recovery.
  #
  # The `merge_needs_verify` gate distinguishes an active merge-verify cycle
  # (where `verify_error` means "just failed, please fix") from a stale
  # `verify_error` sentinel left over from a pre-warm-session upgrade
  # (where the merge should proceed as if it weren't there).
  defp verify_fix_rule(%{exec: %{"verify_error" => err, "merge_needs_verify" => true} = exec})
       when is_binary(err) and err != "" do
    fix_count = exec["verify_fix_count"] || 0
    {:dispatch, Unit.implement_subtask("verify-fix-#{fix_count}", err)}
  end

  defp verify_fix_rule(_), do: nil

  # After merge-sync closeout, merge_needs_verify=true signals that the merge
  # commit should be re-verified (full test suite) before the orchestrator
  # retries the programmatic merge.
  defp merge_verify_rule(%{exec: %{"merge_needs_verify" => true}}) do
    {:dispatch, Unit.verify()}
  end

  defp merge_verify_rule(_), do: nil

  # Merging flow: dispatch merge
  defp merge_rule(%{exec: exec}) do
    if exec["phase"] != "done" do
      {:dispatch, Unit.merge()}
    end
  end

  defp merge_done_rule(_), do: {:stop, :merge_complete}

  # Rework fast-path: if the workpad checklist is complete (all items done),
  # skip re-plan and go straight to fixing the review findings.
  # This saves the full exploration + planning overhead — the agent just reads
  # PR review comments and applies targeted fixes.
  defp rework_fix_rule(%{workpad_text: workpad_text, exec: exec}) do
    # Don't fire if rework fix was already applied this cycle.
    # Uses a persistent flag because last_accepted_unit gets overwritten
    # by subsequent doc_fix/verify units.
    if exec["rework_fix_applied"] do
      nil
    else
      if WorkpadParser.all_done?(workpad_text) do
        {:dispatch, Unit.implement_subtask("rework-1", "Fix review findings from PR comments")}
      end
    end
  end

  # Rework fallback: if workpad checklist is incomplete or missing, re-plan.
  # Skip if rework fix was already applied this cycle (the fix → code_review →
  # doc_fix → handoff sequence should proceed without re-planning).
  defp rework_reset_rule(%{exec: %{"rework_fix_applied" => true}}), do: nil

  # Trigger list includes `code_review` and `doc_fix` so a mid-cycle rework
  # (human moved the ticket back while review or doc_fix was the last
  # accepted unit) correctly re-plans rather than falling through to nil.
  defp rework_reset_rule(%{exec: %{"last_accepted_unit" => %{"kind" => kind}}})
       when kind in ["handoff", "verify", "merge", "code_review", "doc_fix"] do
    {:dispatch, Unit.plan()}
  end

  defp rework_reset_rule(%{exec: %{"phase" => phase}})
       when phase in ["handoff", "verifying", "merging", "bootstrap", "code_review", "doc_fix"] do
    {:dispatch, Unit.plan()}
  end

  defp rework_reset_rule(_), do: nil

  # Bootstrap: not yet bootstrapped
  defp bootstrap_rule(%{exec: %{"bootstrapped" => false}}) do
    {:dispatch, Unit.bootstrap()}
  end

  defp bootstrap_rule(_), do: nil

  # Plan: no parseable checklist
  defp plan_rule(%{workpad_text: workpad_text}) do
    case parse_workpad(workpad_text) do
      {:error, _} -> {:dispatch, Unit.plan()}
      {:ok, _} -> nil
    end
  end

  # Implement subtask: next unchecked item
  defp implement_subtask_rule(%{workpad_text: workpad_text}) do
    case WorkpadParser.next_pending(workpad_text) do
      %{id: id, text: text} ->
        {:dispatch, Unit.implement_subtask(id, text)}

      nil ->
        nil
    end
  end

  # --- Warm-session review loop rules ---
  #
  # State transitions (see docs/design/warm-session-review-loop.md):
  #
  #   plan subtasks done + verdict=nil         → code_review (first round)
  #   verdict="findings"                       → implement_subtask "review-fix-N" (resume A)
  #   verdict="findings" + HEAD advanced after
  #     review-fix commit                      → code_review (resume B)
  #   verdict="clean" + doc_fix not yet run    → doc_fix
  #   verdict="clean" + doc_fix already ran    → handoff
  #   verdict="findings" + round >= max        → {:stop, :review_exhausted}

  # Circuit breaker: too many review rounds — escalate to Human Input Needed.
  # Fires before the implement/review dispatch rules so an exhausted ticket
  # can't sneak in another round just because HEAD happened to advance.
  #
  # Semantics: `max_review_rounds` is the max number of FIX cycles the agent
  # gets. review_round is bumped on each accepted review, so when it STRICTLY
  # EXCEEDS the cap we stop. Example with cap=5:
  #   round 1..5 findings → dispatch review-fix-N (5 fix cycles)
  #   round 6 findings    → {:stop, :review_exhausted}
  # A `>=` check here would only yield cap−1 fix cycles (off-by-one).
  defp review_exhausted_rule(%{exec: exec}) do
    if exec["review_verdict"] == "findings" and
         (exec["review_round"] || 0) > SymphonyElixir.Config.max_review_rounds() do
      {:stop, :review_exhausted}
    end
  end

  # Review flagged MEDIUM+ findings. Dispatch the implement session (warm,
  # resume thread A) with a review-fix-N subtask. subtask_id "review-fix-N"
  # both distinguishes this from plan-N dispatches and carries the round
  # counter, so PromptBuilder's rework-style delta-injection path sees a
  # unique id per round.
  #
  # This rule should not fire if the implement side has ALREADY advanced HEAD
  # past last_reviewed_sha — in that case the reviewer needs to look again
  # (handled by code_review_rule below, which sees HEAD > last_reviewed_sha).
  defp review_findings_implement_rule(%{exec: exec, workpad_text: workpad_text, git_head: git_head}) do
    # Symmetric with code_review_rule: local all_done guard. Today the
    # ordering of implement_subtask_rule before this rule already prevents
    # misfire, but the invariant should be local so a future rule reorder
    # can't silently dispatch review-fix over an incomplete plan.
    if exec["review_verdict"] == "findings" and git_head != nil and
         not head_advanced_since_last_review?(exec, git_head) and
         WorkpadParser.all_done?(workpad_text) do
      # Use the round counter the reviewer JUST wrote — subtask id names
      # the round whose findings we're fixing, not the round after. The
      # counter bumps inside code_review closeout when the next review
      # starts.
      round = exec["review_round"] || 1
      {:dispatch, Unit.implement_subtask("review-fix-#{round}", "Apply review findings from the latest ### Code Review section")}
    end
  end

  # Code review dispatch. Fires whenever all subtasks are done AND either:
  #   1. No prior verdict (first review round), or
  #   2. HEAD has advanced past last_reviewed_sha — regardless of prior verdict.
  #      Covers both "findings → implement pushed fixes → re-review" and
  #      "clean → doc_fix committed real changes → re-review the shipping HEAD".
  # The invariant is "handoff only on a reviewed HEAD"; any new commit after
  # the last review invalidates the verdict. Without the `clean + advanced`
  # case, a doc_fix that modifies files wedges the ticket at :no_matching_rule.
  defp code_review_rule(%{workpad_text: workpad_text, exec: exec, git_head: git_head}) do
    all_done = WorkpadParser.all_done?(workpad_text)
    verdict = exec["review_verdict"]

    cond do
      not (all_done and git_head != nil) ->
        nil

      is_nil(verdict) ->
        {:dispatch, Unit.code_review()}

      head_advanced_since_last_review?(exec, git_head) ->
        # Note: after round N returns findings + fix-N commits, we always
        # dispatch round N+1 to see if the fix converged. That's one extra
        # review turn past max_review_rounds FIX cycles (e.g., cap=5 = 5 fix
        # cycles + up to 6 reviews). Lens1 Iter6 flagged this as a token-cost
        # issue but the 6th review is load-bearing: if fix-5 actually worked,
        # we want a clean verdict, not an escalation.
        {:dispatch, Unit.code_review()}

      true ->
        nil
    end
  end

  # Pre-handoff doc sweep: dispatch doc_fix once review is clean and doc_fix
  # hasn't run yet this cycle. Under warm-session, docs are reviewed by the
  # human reviewer (or skipped — doc_fix closeout accepts a clean no-op), so
  # this is a last-stop check between "code is reviewed clean" and handoff.
  #
  # Uses the persistent `doc_fix_applied` flag rather than scraping
  # `last_accepted_unit`. When doc_fix commits real changes → HEAD advances →
  # code_review re-fires → last_accepted_unit becomes "code_review", which
  # would otherwise make a scraping-based gate mis-think doc_fix never ran.
  # `doc_fix_applied` is reset on rework / escalation (see rework_reset_updates).
  defp pre_handoff_doc_fix_rule(%{exec: exec, workpad_text: workpad_text, git_head: git_head}) do
    # Defense-in-depth: today verdict=="clean" can only be set via
    # code_review_rule (which already gates on all_done + git_head). But the
    # invariant is not local — adding guards here means a future rule that
    # sets verdict elsewhere can't sneak doc_fix past an incomplete workpad.
    if exec["review_verdict"] == "clean" and not doc_fix_already_ran?(exec) and
         is_binary(git_head) and WorkpadParser.all_done?(workpad_text) do
      {:dispatch, Unit.doc_fix()}
    end
  end

  defp doc_fix_already_ran?(exec) do
    exec["doc_fix_applied"] == true or
      case exec["last_accepted_unit"] do
        # last_accepted_unit == "handoff" shouldn't reach this rule in practice
        # (handoff_rule comes after), but keep as belt-and-suspenders.
        %{"kind" => "handoff"} -> true
        _ -> false
      end
  end

  # Handoff: review is clean at the reviewed SHA AND doc_fix has run AND the
  # workpad checklist is actually complete. Machine gate — refuses to fire
  # without a clean verdict AND all_done, so even if another rule (or a
  # future schema change) sets `verdict=clean` on an incomplete workpad,
  # this rule still holds.
  defp handoff_rule(%{exec: exec, workpad_text: workpad_text, git_head: git_head}) do
    if exec["review_verdict"] == "clean" and
         is_binary(git_head) and
         exec["last_reviewed_sha"] == git_head and
         doc_fix_already_ran?(exec) and
         WorkpadParser.all_done?(workpad_text) do
      {:dispatch, Unit.handoff()}
    end
  end

  # Has the implement session committed something since the last review pass?
  # Distinguishes "reviewer needs to look again" (HEAD advanced) from
  # "reviewer already saw this diff" (HEAD == last_reviewed_sha).
  defp head_advanced_since_last_review?(exec, git_head) do
    last = exec["last_reviewed_sha"]
    is_binary(last) and is_binary(git_head) and last != git_head
  end

  # Done: handoff was the last accepted unit
  defp done_rule(%{exec: %{"last_accepted_unit" => %{"kind" => "handoff"}}}) do
    {:stop, :all_complete}
  end

  defp done_rule(_), do: nil

  # --- Helpers ---

  defp parse_workpad(nil), do: {:error, :no_workpad}
  defp parse_workpad(text), do: WorkpadParser.parse(text)
end
