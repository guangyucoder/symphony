defmodule SymphonyElixir.Closeout do
  @moduledoc """
  Post-unit acceptance logic. Called by the orchestrator after a worker
  exits normally. Determines whether the unit is accepted or needs retry.

  Closeout behavior per unit kind (warm-session review loop):
  - `bootstrap`: run baseline verify; mark bootstrapped either way so the
    dispatcher advances past bootstrap_rule. Baseline pass/fail is carried
    separately by `baseline_verify_failed` / `baseline_verify_output` fields
    in `issue_exec.json`; downstream units can consume that signal.
  - `plan`: check workpad has parseable checklist, bump plan_version
  - `implement_subtask` (plan-N / review-fix-N / rework-N): check subtask
    marked done, HEAD advanced, workpad sync, doc-impact. Verification runs
    inside the implement session (`./scripts/verify-changed.sh`) so no
    separate verify dispatch is required in the normal flow.
  - `code_review`: re-fetch workpad from Linear (post-turn, not the
    pre-dispatch snapshot), parse latest `### Code Review` section, verify
    `Reviewed SHA:` matches current HEAD (stale-section guard), atomically
    set `review_verdict` + `last_reviewed_sha` + bump `review_round`.
  - `doc_fix`: pre-handoff documentation sweep; accept clean no-op; sets
    `doc_fix_applied = true` so `pre_handoff_doc_fix_rule` doesn't re-fire
    after a post-doc_fix re-review flips last_accepted_unit.
  - `verify`: only in the `:merging` flow now — full verification of the
    merged tree, sets `verify_error` on failure so `verify_fix_rule` can
    dispatch a repair subtask.
  - `handoff`: check `review_verdict == "clean"` AND `last_reviewed_sha ==
    HEAD` (the reviewed-HEAD invariant) AND `doc_fix_applied` true.
  - `merge`: check PR actually merged on remote before marking done.
  """

  require Logger

  alias SymphonyElixir.{Config, IssueExec, Ledger, Linear.Adapter, Verifier, WorkpadParser}

  @type result :: :accepted | {:retry, String.t()} | {:fail, String.t()}

  @doc """
  Run closeout for a completed unit. Returns :accepted, {:retry, reason}, or {:fail, reason}.
  """
  @spec run(Path.t(), map(), map(), keyword()) :: result()
  def run(workspace, unit, issue, opts \\ []) do
    kind = unit["kind"] || to_string(unit[:kind])
    do_closeout(kind, workspace, unit, issue, opts)
  end

  # --- Per-unit closeout ---

  defp do_closeout("bootstrap", workspace, _unit, _issue, _opts) do
    # Run baseline verification if commands are configured
    case Verifier.run_baseline(workspace) do
      :pass ->
        IssueExec.clear_baseline_verify_failure(workspace)
        IssueExec.mark_bootstrapped(workspace)
        Ledger.append(workspace, :baseline_verified, %{})
        :accepted

      {:fail, output} ->
        Logger.warning("Closeout: baseline verification failed")
        IssueExec.set_baseline_verify_failure(workspace, output)
        # Mark bootstrapped even on baseline failure. Without this, the
        # dispatcher's bootstrap_rule (matches on bootstrapped==false) keeps
        # re-firing forever on an :accepted unit that clears current_unit,
        # with no circuit-breaker escape. The baseline state lives in
        # baseline_verify_failed / baseline_verify_output; downstream units
        # read those to decide whether to fix the baseline before their own work.
        IssueExec.mark_bootstrapped(workspace)
        Ledger.append(workspace, :baseline_verify_failed, %{"output" => output})
        Ledger.append(workspace, :baseline_accepted_despite_failure, %{"output" => output})
        :accepted
    end
  end

  defp do_closeout("plan", workspace, _unit, _issue, _opts) do
    # Plan acceptance: agent wrote the plan to Linear workpad. We can't verify
    # the workpad content here (it's on Linear, not local). Instead, we accept
    # the plan unit and let DispatchResolver verify the checklist is parseable
    # on the NEXT dispatch cycle (when workpad text will be fetched from Linear).
    # If the checklist isn't parseable, resolver will re-dispatch :plan.
    IssueExec.bump_plan_version(workspace)
    :accepted
  end

  defp do_closeout("implement_subtask", workspace, unit, issue, opts) do
    subtask_id = unit["subtask_id"]

    cond do
      is_binary(subtask_id) and String.starts_with?(subtask_id, "rework-") ->
        handle_rework_closeout(workspace, subtask_id, issue, opts)

      is_binary(subtask_id) and String.starts_with?(subtask_id, "verify-fix-") ->
        handle_verify_fix_closeout(workspace, subtask_id, issue, opts)

      true ->
        # Regular plan-N and merge-sync-* — require HEAD advance so uncommitted
        # work isn't silently destroyed by the next dispatch's workspace reset.
        # Parallel to the rework / verify-fix guards.
        #
        # First check pending_workpad_mark: if a prior attempt committed the work
        # but its Linear mark failed, the new dispatch's dispatch_head is the
        # post-commit HEAD and the agent will produce no further commit. Without
        # this fast-path, the :unchanged guard would loop to the circuit breaker
        # without ever retrying the mark.
        case recover_pending_workpad_mark(workspace, subtask_id, issue) do
          :recovered ->
            post_accept_implement_subtask(workspace, subtask_id)

          {:still_pending, reason} ->
            {:retry, reason}

          :no_pending ->
            case commit_advancement_state(workspace, opts) do
              :advanced ->
                accept_implement_subtask(workspace, subtask_id, issue)

              :unchanged ->
                Logger.warning("Closeout: implement_subtask #{subtask_id || "(nil)"} produced no commit (HEAD unchanged since dispatch) — fix edits may be sitting as uncommitted WIP")

                {:retry, "implement_subtask #{subtask_id || "(nil)"}: produced no commit (edits likely uncommitted WIP)"}

              :cannot_verify ->
                Logger.warning("Closeout: implement_subtask #{subtask_id || "(nil)"} cannot verify HEAD state (git lookup returned nil)")

                {:retry, "implement_subtask #{subtask_id || "(nil)"}: cannot verify HEAD state"}
            end
        end
    end
  end

  defp do_closeout("doc_fix", workspace, _unit, _issue, opts) do
    # doc_fix differs from other mutation-bearing units: DispatchResolver
    # dispatches it unconditionally before verify, and the prompt asks the
    # agent to "update any docs that no longer match" — an empty outcome
    # is legitimate when docs are already accurate. A strict HEAD-advance
    # guard would retry every no-op until the circuit breaker fires, which
    # is the same failure mode the bootstrap soft-accept fix eliminated.
    #
    # Instead: differentiate "forgot to commit" (dirty tree, HEAD unchanged
    # → data-loss risk, retry) from "nothing to do" (clean tree, HEAD
    # unchanged → acceptable no-op).
    case commit_advancement_state(workspace, opts) do
      :advanced ->
        # Mark doc_fix as run for THIS review cycle so pre_handoff_doc_fix_rule
        # doesn't re-fire after the re-review that the doc commit triggers
        # (re-review moves last_accepted_unit from "doc_fix" to "code_review",
        # which would otherwise make a scraping-based gate think doc_fix never ran).
        IssueExec.update(workspace, %{"doc_fix_applied" => true})
        :accepted

      :unchanged ->
        case Verifier.dirty_working_tree?(workspace) do
          true ->
            Logger.warning("Closeout: doc_fix HEAD unchanged but tree is dirty — edits likely uncommitted WIP")

            {:retry, "doc_fix: produced no commit but tree is dirty (edits likely uncommitted WIP)"}

          false ->
            Logger.info("Closeout: doc_fix accepted as no-op (clean tree, no doc updates needed)")
            IssueExec.update(workspace, %{"doc_fix_applied" => true})
            :accepted
        end

      :cannot_verify ->
        Logger.warning("Closeout: doc_fix cannot verify HEAD state (git lookup returned nil)")

        {:retry, "doc_fix: cannot verify HEAD state"}
    end
  end

  defp do_closeout("verify", workspace, _unit, issue, opts) do
    max_verify_attempts = Config.max_verify_attempts()
    max_verify_fix_cycles = Config.max_verify_fix_cycles()

    # Use persistent attempt counter that survives verify-fix cycles.
    # The unit's "attempt" field tracks crash-replays; this tracks
    # verification runs across fix cycles.
    {:ok, exec} = IssueExec.read(workspace)
    attempt = (exec["verify_attempt"] || 0) + 1
    IssueExec.update(workspace, %{"verify_attempt" => attempt})

    verify_opts = if cmds = Keyword.get(opts, :verify_commands), do: [commands: cmds], else: []

    case Verifier.run(workspace, verify_opts) do
      :pass ->
        head = Verifier.current_head(workspace)

        if head do
          IssueExec.set_verified_sha(workspace, head)
          Ledger.verify_passed(workspace, head)
        end

        # Reset all verify counters on success. Also clear any baseline
        # failure flag/output: a passing full-verify implies the baseline
        # red state from bootstrap is now repaired (or wasn't truly red).
        # Without this, the flag becomes stale historical telemetry that
        # could mislead future readers (e.g., a planner prompt added later
        # that thinks the baseline is currently broken).
        IssueExec.clear_baseline_verify_failure(workspace)

        IssueExec.update(workspace, %{
          "verify_attempt" => 0,
          "verify_error" => nil,
          "verify_fix_count" => 0,
          "merge_needs_verify" => false
        })

        :accepted

      {:fail, output} when attempt >= max_verify_attempts ->
        # Escalate — exhausted all attempts including verify-fix cycles.
        Logger.warning("Closeout: verify exhausted #{attempt} attempts, failing")

        Ledger.append(workspace, :verify_exhausted, %{
          "attempt" => attempt,
          "last_error" => output
        })

        issue_id = issue_id(issue)

        if is_binary(issue_id) do
          Adapter.create_comment(
            issue_id,
            "**Verification failed**: exhausted #{attempt} attempts.\nLast error: #{output}\n\nEscalating — code will NOT proceed to handoff."
          )
        end

        # Clear verify_error but keep current_unit set so replay_current_unit_rule
        # increments the attempt and triggers circuit_breaker → escalation.
        IssueExec.update(workspace, %{"verify_error" => nil})
        {:fail, "Verification exhausted #{attempt} attempts: #{output}"}

      {:fail, output} ->
        # Dispatch verify-fix if we haven't exhausted fix cycles.
        # After max_verify_fix_cycles, fall back to plain retry → exhaust.
        {:ok, exec_state} = IssueExec.read(workspace)
        fix_count = exec_state["verify_fix_count"] || 0

        if fix_count < max_verify_fix_cycles do
          IssueExec.set_verify_error(workspace, output)

          IssueExec.update(workspace, %{
            "current_unit" => nil,
            "verify_fix_count" => fix_count + 1
          })

          Ledger.append(workspace, :verify_failed_will_fix, %{
            "attempt" => attempt,
            "fix_cycle" => fix_count + 1,
            "error" => output
          })

          {:retry, "Verification failed (verify-fix ##{fix_count + 1} will be dispatched): #{output}"}
        else
          # No more fix cycles — plain retry, will exhaust on next attempt
          {:retry, "Verification failed (fix cycles exhausted): #{output}"}
        end
    end
  end

  # code_review closeout (warm-session loop gate). Accept only if the workpad
  # now carries a `### Code Review` section with a parseable `Verdict:` line
  # (the agent's structured output) AND we can snapshot HEAD. On accept:
  #   - review_verdict is updated to "clean" | "findings"
  #   - review_round is bumped (this dispatch counts as one round)
  #   - last_reviewed_sha is pinned to current HEAD — dispatch resolver uses
  #     this to detect "agent committed fixes; reviewer should re-look"
  #
  # Workpad is re-fetched from Linear rather than using opts[:workpad_text]
  # because the snapshot was captured pre-dispatch, before the agent wrote the
  # section. A Linear fetch failure fails closed (retry) so a network blip
  # cannot silently unlock the handoff gate. See
  # docs/design/warm-session-review-loop.md.
  defp do_closeout("code_review", workspace, _unit, issue, opts) do
    fetcher = Keyword.get(opts, :workpad_fetcher, &Adapter.fetch_workpad_text/1)
    dispatch_head = Keyword.get(opts, :dispatch_head)
    issue_id = issue_id(issue)

    cond do
      not is_binary(issue_id) ->
        {:fail, "code_review: issue id missing"}

      # Machine gate: the reviewer must NOT commit code — fixes belong to
      # `review-fix-N` on the implement thread (where `verify-changed.sh`
      # gates every commit). If HEAD advanced during the review turn the
      # reviewer wrote code that never went through verification. Reject
      # with a concrete message so the ledger shows why.
      reviewer_committed?(workspace, dispatch_head) ->
        Logger.warning("Closeout: code_review reviewer committed during the turn — rejecting, fixes must go through review-fix-N")

        {:fail,
         "code_review: reviewer committed code during the review turn (HEAD advanced) — review units are review-only; record findings instead and let the implement thread fix via review-fix-N"}

      true ->
        case fetcher.(issue_id) do
          {:ok, fresh_workpad} ->
            case WorkpadParser.code_review_verdict(fresh_workpad) do
              verdict when verdict in ["clean", "findings"] ->
                # Verify the workpad section claims to have reviewed the CURRENT
                # HEAD. Without this, a stale section left over from a prior
                # round (round 1 said "findings" against SHA A; implement committed
                # B; review turn did nothing) would bless B as reviewed. That
                # breaks the "handoff only on reviewed HEAD" invariant.
                accept_review_if_fresh(workspace, verdict, fresh_workpad)

              :missing ->
                Logger.warning("Closeout: code_review produced no `### Code Review` workpad section — agent likely skipped the skill")

                {:retry, "code_review: workpad has no `### Code Review` section (skill not invoked or findings not recorded)"}

              :invalid ->
                Logger.warning("Closeout: code_review section present but Verdict: line is missing or unrecognized")

                {:retry, "code_review: `### Code Review` section has no parseable `Verdict:` line (expected `Verdict: clean` or `Verdict: findings`)"}
            end

          {:error, reason} ->
            Logger.warning("Closeout: code_review workpad fetch failed: #{inspect(reason)}")

            {:retry, "code_review: workpad fetch failed (#{inspect(reason)})"}
        end
    end
  end

  defp do_closeout("handoff", workspace, _unit, _issue, _opts) do
    case IssueExec.read(workspace) do
      {:ok, exec} ->
        head = Verifier.current_head(workspace)
        verdict = exec["review_verdict"]
        reviewed_sha = exec["last_reviewed_sha"]
        doc_fix_applied = exec["doc_fix_applied"] == true

        cond do
          is_nil(head) ->
            {:fail, "Handoff rejected: cannot read current HEAD"}

          verdict != "clean" ->
            {:fail, "Handoff rejected: review_verdict is #{inspect(verdict)} (expected \"clean\")"}

          reviewed_sha != head ->
            {:fail, "Handoff rejected: last_reviewed_sha (#{reviewed_sha}) != HEAD (#{head}) — new commits since last review"}

          # Symmetry with `handoff_rule` in DispatchResolver: both gates must
          # check the same invariant. Without this, a crash-replay or a stale
          # `current_unit=handoff` could skip the pre-handoff doc sweep even
          # when resolver already short-circuited doc_fix on `doc_fix_applied`
          # from a PRIOR cycle (pre-rework state leak).
          not doc_fix_applied ->
            {:fail, "Handoff rejected: doc_fix_applied is false — pre-handoff doc sweep has not run in this cycle"}

          true ->
            :accepted
        end

      {:error, reason} ->
        {:fail, "Handoff rejected: cannot read exec state: #{inspect(reason)}"}
    end
  end

  defp do_closeout("merge", workspace, _unit, _issue, opts) do
    checker = Keyword.get(opts, :merge_checker, &Verifier.check_pr_merged/1)

    case checker.(workspace) do
      :merged ->
        IssueExec.update(workspace, %{
          "phase" => "done",
          "merge_conflict" => false,
          "merge_sync_count" => 0,
          "mergeability_unknown_count" => 0,
          "merge_needs_verify" => false
        })

        :accepted

      {:not_merged, reason} ->
        Logger.warning("Closeout: merge not confirmed: #{reason}")
        {:retry, "PR not merged: #{reason}"}

      :unknown ->
        Logger.warning("Closeout: cannot verify PR merge status, retrying")
        Ledger.append(workspace, :merge_status_unknown, %{})
        {:retry, "merge status unverified"}
    end
  end

  defp do_closeout(kind, _workspace, _unit, _issue, _opts) do
    Logger.warning("Closeout: unknown unit kind #{kind}")
    {:fail, "unknown unit kind: #{kind}"}
  end

  # --- code_review closeout helpers (moved here so the do_closeout/5 clauses
  # above stay contiguous; Elixir warns on interrupted same-name/arity
  # defps) ---

  # True when HEAD advanced between dispatch and closeout — a reviewer that
  # committed code during the turn. Returns false when dispatch_head is nil
  # (upgrade path / tests that don't pass it): we err on letting the turn
  # through rather than breaking legacy code, and accept_review_if_fresh
  # is the backup SHA-match gate.
  defp reviewer_committed?(workspace, dispatch_head) when is_binary(dispatch_head) do
    case Verifier.current_head(workspace) do
      head when is_binary(head) -> head != dispatch_head
      _ -> false
    end
  end

  defp reviewer_committed?(_workspace, _dispatch_head), do: false

  # Cross-check the workpad's `Reviewed SHA:` against current git HEAD and the
  # prior `exec.last_reviewed_sha`. The review MUST name the HEAD it reviewed,
  # and that HEAD must match what's actually checked out — otherwise the
  # section is stale and closeout would silently mark unreviewed code as "ok".
  defp accept_review_if_fresh(workspace, verdict, workpad) do
    current_head = Verifier.current_head(workspace)
    claimed_sha = WorkpadParser.code_review_reviewed_sha(workpad)
    {:ok, exec} = IssueExec.read(workspace)

    cond do
      not is_binary(current_head) ->
        Logger.warning("Closeout: code_review cannot read HEAD to pin last_reviewed_sha")
        {:retry, "code_review: cannot verify HEAD state"}

      claimed_sha == :invalid or claimed_sha == :missing ->
        {:retry, "code_review: `### Code Review` section missing `Reviewed SHA:` line (can't verify the review actually ran on current HEAD)"}

      not heads_match?(claimed_sha, current_head) ->
        Logger.warning("Closeout: code_review section claims SHA #{inspect(claimed_sha)} but HEAD is #{inspect(current_head)} — likely a stale section")
        {:retry, "code_review: `Reviewed SHA: #{claimed_sha}` does not match current HEAD #{String.slice(current_head, 0, 12)} (stale section or agent reviewed the wrong HEAD)"}

      exec["last_reviewed_sha"] == current_head and exec["review_verdict"] == verdict ->
        # Nothing advanced — no HEAD change and the verdict matches what was
        # already accepted. This would re-bump `review_round` for no reason
        # and can livelock the review loop.
        {:retry, "code_review: workpad not updated since last accepted review (same HEAD, same verdict)"}

      exec["last_reviewed_sha"] == current_head and
        exec["review_verdict"] == "findings" and verdict == "clean" ->
        # Hard invariant: once a HEAD was accepted as `findings`, it CANNOT
        # later be blessed as `clean` at the same HEAD without at least one
        # commit in between. This prevents the "agent runs an empty-diff
        # review, concludes all-clean, flips the verdict" bypass — the
        # findings-to-clean flip must be paid for with actual fix commits.
        Logger.warning("Closeout: code_review attempted findings→clean flip at unchanged HEAD — rejecting to preserve reviewed-HEAD invariant")

        {:fail, "code_review: cannot flip verdict from findings to clean at the same HEAD (#{String.slice(current_head, 0, 12)}) — fix findings on review-fix-N first so HEAD advances"}

      true ->
        commit_review_result(workspace, verdict, current_head)
    end
  end

  # Accept full SHA or any common abbreviation (>= 7 chars) by prefix match.
  defp heads_match?(claimed, current) do
    claimed = String.downcase(String.trim(claimed))
    current = String.downcase(current)
    byte_size(claimed) >= 7 and String.starts_with?(current, claimed)
  end

  # Single atomic write so a mid-sequence failure can't leave verdict=findings
  # with last_reviewed_sha=nil (which would disable the HEAD-advance guard in
  # review_findings_implement_rule and livelock the review loop).
  defp commit_review_result(workspace, verdict, sha) when is_binary(sha) do
    {:ok, exec} = IssueExec.read(workspace)
    next_round = (exec["review_round"] || 0) + 1

    case IssueExec.update(workspace, %{
           "review_verdict" => verdict,
           "last_reviewed_sha" => sha,
           "review_round" => next_round
         }) do
      :ok ->
        Ledger.append(workspace, :code_review_accepted, %{
          "verdict" => verdict,
          "sha" => sha,
          "round" => next_round
        })

        :accepted

      {:error, reason} ->
        Logger.warning("Closeout: code_review exec write failed: #{inspect(reason)}")
        {:retry, "code_review: exec write failed (#{inspect(reason)})"}
    end
  end

  # --- Helpers ---

  # Rework acceptance requires THREE structural conditions. All three are
  # orchestrator-observable (no agent self-report) and fail closed to {:retry, _}
  # so the existing replay_current_unit_rule + @max_unit_attempts circuit
  # breaker handle eventual escalation.
  #
  #   1. Linear API fetch succeeded at dispatch time. Otherwise the agent ran
  #      with no <ticket_comments> block at all.
  #   2. At least one review comment (i.e., a comment other than Symphony's
  #      own Codex Workpad) was present in the fetched set. Otherwise filtering
  #      leaves the agent effectively blind even though the fetch succeeded.
  #   3. git HEAD advanced since dispatch (agent produced at least one commit).
  #
  # Both (1) and (2) are computed upstream in
  # `agent_runner.enrich_opts_for_commit_guarded_subtask` (which delegates to
  # the rework-specific enricher) and passed through the closeout opts. They
  # are split into two flags so the ledger's retry reason stays diagnostically
  # useful.
  defp handle_rework_closeout(workspace, subtask_id, issue, opts) do
    cond do
      Keyword.get(opts, :linear_fetch_ok, true) == false ->
        Logger.warning("Closeout: rework #{subtask_id} dispatched without fresh Linear comments — will retry")

        {:retry, "rework #{subtask_id}: linear comment fetch failed at dispatch"}

      Keyword.get(opts, :rework_has_review_context, true) == false ->
        Logger.warning("Closeout: rework #{subtask_id} had no review context (only workpad or empty) — will retry")

        {:retry, "rework #{subtask_id}: no review context in Linear comments"}

      true ->
        case commit_advancement_state(workspace, opts) do
          :unchanged ->
            Logger.warning("Closeout: rework #{subtask_id} produced no commit (head unchanged since dispatch)")

            {:retry, "rework #{subtask_id}: produced no commit"}

          :cannot_verify ->
            Logger.warning("Closeout: rework #{subtask_id} cannot verify HEAD state (git lookup returned nil)")

            {:retry, "rework #{subtask_id}: cannot verify HEAD state"}

          :advanced ->
            accept_implement_subtask(workspace, subtask_id, issue)
        end
    end
  end

  # Verify-fix acceptance requires the agent to have advanced HEAD. Without
  # this guard, a unit where the agent edited files but never committed (an
  # observed Codex failure mode) is silently accepted at the stale SHA; the
  # next `verify` sees the same broken code, fails identically, and Symphony
  # burns attempts until the circuit breaker trips — losing the uncommitted
  # WIP in the process. Parallel to the zero-commit guard on rework-*.
  defp handle_verify_fix_closeout(workspace, subtask_id, issue, opts) do
    case commit_advancement_state(workspace, opts) do
      :unchanged ->
        Logger.warning(
          "Closeout: verify-fix #{subtask_id} produced no commit (HEAD unchanged since dispatch) — " <>
            "fix edits may be sitting as uncommitted WIP"
        )

        {:retry, "verify-fix #{subtask_id}: produced no commit (edits likely uncommitted WIP)"}

      :cannot_verify ->
        Logger.warning("Closeout: verify-fix #{subtask_id} cannot verify HEAD state (git lookup returned nil)")

        {:retry, "verify-fix #{subtask_id}: cannot verify HEAD state"}

      :advanced ->
        accept_implement_subtask(workspace, subtask_id, issue)
    end
  end

  defp accept_implement_subtask(workspace, subtask_id, issue) do
    # 1. Mark subtask done on Linear workpad (orchestrator-owned, no agent
    # compliance needed). If this fails, retry the unit so the next dispatch
    # gets another chance to sync — accepting locally would split-brain
    # the workpad (Linear shows `[ ] [plan-N]`) from the code (already
    # committed). Next dispatch would then re-derive plan-N as still pending,
    # re-send the agent who has nothing to do, no commit advance, retry loop
    # to circuit breaker. A few replay attempts via the circuit breaker is
    # cheap; permanent split-brain is the failure mode we're avoiding.
    #
    # We only treat the marker call as fatal for "regular" plan-N subtasks
    # whose dispatch is derived from the workpad checklist. The synthetic
    # subtask kinds (rework-* / verify-fix-* / merge-sync-*) are not
    # dispatched from the checklist, so their workpad mark is bookkeeping
    # only and a failure does not create the same split-brain.
    case maybe_mark_subtask_done(subtask_id, issue) do
      :ok ->
        post_accept_implement_subtask(workspace, subtask_id)

      {:retry, reason} ->
        # The work is committed but the workpad mark failed. Persist a sentinel
        # (subtask_id + the post-commit HEAD) so the next closeout entry can
        # retry the mark without requiring HEAD to advance again. The HEAD pin
        # is essential: without it, a stale sentinel that survives a replan
        # could fast-path-accept a new attempt whose work hasn't actually
        # committed.
        if regular_plan_subtask?(subtask_id) do
          case Verifier.current_head(workspace) do
            sha when is_binary(sha) ->
              IssueExec.set_pending_workpad_mark(workspace, subtask_id, sha)

            _ ->
              # Can't capture HEAD → don't set a sentinel that recovery can't validate.
              :ok
          end
        end

        {:retry, reason}
    end
  end

  # Fast-path: if a previous closeout already committed the work and only the
  # Linear mark failed, retry the mark here. No HEAD advance is required, but
  # we DO require HEAD to still equal the committed_sha captured at sentinel-set
  # time — otherwise the sentinel has been invalidated by intervening commits
  # / resets / replans and falling through to the normal HEAD-advance check is
  # the safe move.
  #
  # Returns :recovered (mark succeeded; caller should run post-accept),
  # {:still_pending, reason} (mark still failing; caller should retry the unit),
  # or :no_pending (no recovery applies; caller should run normal flow). On
  # stale-sentinel detection we clear the sentinel and return :no_pending so
  # the caller's normal flow runs and can take a fresh decision.
  defp recover_pending_workpad_mark(workspace, subtask_id, issue) do
    with true <- regular_plan_subtask?(subtask_id),
         {:ok, exec} <- IssueExec.read(workspace),
         pending = exec["pending_workpad_mark"],
         :ok <- maybe_clear_legacy_sentinel(workspace, pending),
         %{"subtask_id" => pending_id, "committed_sha" => pending_sha} when is_binary(pending_id) and is_binary(pending_sha) <-
           pending,
         true <- pending_id == subtask_id,
         issue_id when is_binary(issue_id) <- issue_id(issue) do
      # Distinguish "git lookup failed" (nil HEAD — defer recovery, sentinel
      # still valid) from "HEAD moved past the captured sha" (sentinel stale —
      # clear it, fall through). Mirrors the is_binary(sha) guard at sentinel
      # set time, where we refuse to write a sentinel we can't validate.
      case Verifier.current_head(workspace) do
        nil ->
          Logger.warning("Closeout: cannot read HEAD to validate pending workpad mark for #{subtask_id}; deferring recovery")

          {:still_pending, "implement_subtask #{subtask_id}: cannot validate sentinel (git HEAD unavailable)"}

        ^pending_sha ->
          case Adapter.mark_subtask_done(issue_id, subtask_id) do
            :ok ->
              IssueExec.clear_pending_workpad_mark(workspace)
              Logger.info("Closeout: recovered pending Linear workpad mark for #{subtask_id}")
              :recovered

            {:error, reason} ->
              Logger.warning("Closeout: pending workpad mark for #{subtask_id} still failing: #{inspect(reason)}")

              {:still_pending, "implement_subtask #{subtask_id}: workpad sync still failing (#{inspect(reason)})"}
          end

        _other_sha ->
          Logger.info("Closeout: clearing stale pending workpad mark for #{subtask_id} (HEAD has moved past the captured commit)")

          IssueExec.clear_pending_workpad_mark(workspace)
          :no_pending
      end
    else
      _ -> :no_pending
    end
  end

  # The round-5 sentinel was a bare binary subtask_id. Round-5b switched to a
  # `%{subtask_id, committed_sha}` map so recovery can pin against HEAD. An
  # in-flight workspace upgraded across releases may still have the old shape
  # on disk — clear it and log once, otherwise the next dispatch silently
  # falls through to `:no_pending` and burns a retry attempt before the next
  # writer overwrites the field. Returning :ok lets the with-chain continue;
  # the cleared sentinel will then fail the map-shape match below as a no-op.
  defp maybe_clear_legacy_sentinel(workspace, pending) when is_binary(pending) do
    Logger.info("Closeout: discarding legacy-shape pending_workpad_mark sentinel (binary #{inspect(pending)}); upgrade in progress")

    IssueExec.clear_pending_workpad_mark(workspace)
    :ok
  end

  defp maybe_clear_legacy_sentinel(_workspace, _pending), do: :ok

  defp maybe_mark_subtask_done(subtask_id, issue) do
    cond do
      not (is_binary(subtask_id) and is_binary(issue_id(issue))) ->
        :ok

      synthetic_subtask_no_workpad_checkbox?(subtask_id) ->
        # Synthetic subtasks the workpad never has a checkbox for. Skip the
        # Linear API call entirely — every previous `mark_subtask_done` on
        # these produced a failure log + wasted round-trip per dispatch.
        :ok

      not regular_plan_subtask?(subtask_id) ->
        # Best-effort for non-plan subtasks: log warning, do not fail closeout.
        case Adapter.mark_subtask_done(issue_id(issue), subtask_id) do
          :ok ->
            Logger.info("Closeout: marked #{subtask_id} done on Linear workpad")
            :ok

          {:error, reason} ->
            Logger.warning("Closeout: failed to mark non-plan #{subtask_id} on workpad: #{inspect(reason)} (continuing — next dispatch is not derived from this checkbox)")

            :ok
        end

      true ->
        # Regular plan-N: must succeed before local accept, else split-brain.
        case Adapter.mark_subtask_done(issue_id(issue), subtask_id) do
          :ok ->
            Logger.info("Closeout: marked #{subtask_id} done on Linear workpad")
            :ok

          {:error, reason} ->
            Logger.warning("Closeout: Linear workpad mark failed for #{subtask_id} (#{inspect(reason)}); returning {:retry,_} to avoid workpad/code split-brain")

            {:retry, "implement_subtask #{subtask_id}: workpad sync failed (#{inspect(reason)})"}
        end
    end
  end

  # Whitelist on the workpad-derived "plan-N" prefix: every subtask Linear
  # actually owns a checkbox for matches `plan-<integer>`. Any other shape
  # (synthetic kinds rework-/verify-fix-/merge-sync-, future variants, empty
  # strings, whitespace) is NOT a plan-N, so a Linear-mark failure is at most
  # bookkeeping noise and must not promote to a unit retry — that would
  # circuit-break a synthetic dispatch over a checkbox the workpad never had.
  #
  # The planner prompt (see `prompt_builder.ex` plan unit instructions) is the
  # source of truth for subtask-id shape — it instructs the agent to emit
  # `[plan-N]` checkboxes and only those. WorkpadParser will accept other
  # explicit ids (`plan-db`, `cleanup-1`, etc.) for forward-compat, but
  # those are downgraded to warn-only here on the same theory: if the planner
  # prompt ever loosens, this regex must loosen with it (or we silently lose
  # split-brain protection for the new id shapes).
  defp regular_plan_subtask?(subtask_id) when is_binary(subtask_id) do
    Regex.match?(~r/^plan-\d+$/, subtask_id)
  end

  defp regular_plan_subtask?(_), do: false

  # Subtasks the workpad never emits a checkbox for — skip the Linear
  # mark_subtask_done call entirely to avoid guaranteed-404 round-trips +
  # noise logs. `rework-*` / `verify-fix-*` / `merge-sync-*` / `review-fix-*`
  # are all planner-never-emits kinds.
  defp synthetic_subtask_no_workpad_checkbox?(subtask_id) when is_binary(subtask_id) do
    String.starts_with?(subtask_id, "rework-") or
      String.starts_with?(subtask_id, "verify-fix-") or
      String.starts_with?(subtask_id, "merge-sync-") or
      String.starts_with?(subtask_id, "review-fix-")
  end

  defp synthetic_subtask_no_workpad_checkbox?(_), do: false

  defp post_accept_implement_subtask(workspace, subtask_id) do
    # 1a. Clear any pending workpad mark sentinel — by reaching post-accept the
    # workpad is in sync (either via normal flow or recovered via fast-path).
    IssueExec.clear_pending_workpad_mark(workspace)

    # 1b. Set rework_fix_applied flag for rework-* subtasks
    if is_binary(subtask_id) and String.starts_with?(subtask_id, "rework-") do
      IssueExec.update(workspace, %{"rework_fix_applied" => true})
    end

    # 1c. Clear verify_error and reset verify_attempt for verify-fix-* subtasks.
    # Resetting the attempt gives verify a fresh shot after the fix — the
    # circuit breaker on verify-fix crashes (via replay) prevents infinite loops.
    if is_binary(subtask_id) and String.starts_with?(subtask_id, "verify-fix-") do
      IssueExec.update(workspace, %{"verify_error" => nil, "verify_attempt" => 0})
    end

    # 1d. Clear merge_conflict for merge-sync-* subtasks.
    # Set merge_needs_verify so the orchestrator re-verifies the merge commit
    # before programmatic merge retries.
    if is_binary(subtask_id) and String.starts_with?(subtask_id, "merge-sync-") do
      IssueExec.update(workspace, %{
        "merge_conflict" => false,
        "merge_needs_verify" => true
      })
    end

    :accepted
  end

  # Returns :advanced (HEAD moved since dispatch) | :unchanged (same sha)
  # | :cannot_verify (either current HEAD or dispatch_head is missing).
  # The caller uses :cannot_verify to fail-closed (retry) so transient git
  # lookup failures cannot silently disable the zero-commit guard.
  #
  # Used by every mutation-bearing unit — rework-*, verify-fix-*, regular
  # plan-N / merge-sync-* implement_subtask, and doc_fix. All require a
  # dispatch_head snapshot captured upstream in agent_runner.
  defp commit_advancement_state(workspace, opts) do
    case {Verifier.current_head(workspace), Keyword.get(opts, :dispatch_head)} do
      {head, dispatch} when is_binary(head) and is_binary(dispatch) ->
        if head == dispatch, do: :unchanged, else: :advanced

      _ ->
        :cannot_verify
    end
  end

  defp issue_id(%{id: id}) when is_binary(id), do: id
  defp issue_id(%{"id" => id}) when is_binary(id), do: id
  defp issue_id(_), do: nil
end
