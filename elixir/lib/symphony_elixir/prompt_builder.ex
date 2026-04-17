defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.Unit

  @doc """
  Build a focused prompt for a single unit in unit-lite mode.
  Each unit type gets a narrow prompt — the agent only sees instructions
  for its current unit.
  """
  @spec build_unit_prompt(map(), Unit.t(), keyword()) :: String.t()
  def build_unit_prompt(issue, %Unit{} = unit, opts \\ []) do
    [
      unit_header(issue, unit),
      retry_preamble(unit, opts),
      unit_context(unit, opts),
      unit_instructions(unit, opts),
      unit_guardrails(unit)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # When the prior dispatch's closeout returned `{:retry, reason}`, the resumed
  # agent MUST see the reason verbatim — otherwise it acts on the base prompt's
  # default framing and repeats the rejected behavior. code_review handles retry
  # internally via `code_review_retry_prefix/1`; other kinds get this preamble.
  defp retry_preamble(%Unit{kind: :code_review}, _opts), do: nil

  defp retry_preamble(_unit, opts) do
    case Keyword.get(opts, :retry_reason) do
      reason when is_binary(reason) and reason != "" ->
        """
        ## Previous attempt rejected

        The orchestrator rejected your prior turn:

            #{reason}

        Address this rejection directly before anything else. If the rejection
        is about missing / malformed output (e.g. no commit, no workpad mark),
        fix the output — do not start over from scratch.
        """

      _ ->
        nil
    end
  end

  # Orchestrator-injected context for rework-* subtasks: Linear comments on
  # the ticket, rendered verbatim inside a <ticket_comments> block. Agent
  # identifies what's a review finding, distinguishes addressed from outstanding,
  # and uses timestamps to reason about order. Orchestrator does not filter by
  # author or anchor on any header, but it does:
  #   - sanitize bodies so untrusted text cannot break out of the block tag
  #   - exclude the Codex Workpad comment (Symphony's own artifact, not review)
  #   - cap per-comment and total size so prompts stay bounded
  defp unit_context(%Unit{kind: :implement_subtask, subtask_id: "rework-" <> _}, opts) do
    case Keyword.get(opts, :linear_comments, []) do
      [] ->
        nil

      comments when is_list(comments) ->
        render_ticket_comments(comments)
    end
  end

  # Specialized implement_subtask kinds that carry their own context:
  #   - rework-*      : handled above; Linear comments are injected verbatim
  #   - verify-fix-*  : error output is injected by `unit_instructions`
  #   - merge-sync-*  : conflict state lives in the working tree
  # No workpad injection for these — their prompts are already focused.
  defp unit_context(%Unit{kind: :implement_subtask, subtask_id: "verify-fix-" <> _}, _opts), do: nil
  defp unit_context(%Unit{kind: :implement_subtask, subtask_id: "merge-sync-" <> _}, _opts), do: nil

  # review-fix-N: the review thread and the implement thread are DIFFERENT
  # persistent Codex threads, so the implement agent cannot see findings via
  # its own conversation history even when resumed. Always inject the LATEST
  # `### Code Review` findings — small enough (1-3KB) to not defeat warm
  # discipline; load-bearing because "what to fix" is the whole point.
  #
  # On cold-fallback (resume failed), additionally inject the full workpad so
  # the memory-less agent also sees plan/notes.
  defp unit_context(%Unit{kind: :implement_subtask, subtask_id: "review-fix-" <> _}, opts) do
    if Keyword.get(opts, :is_resumed_session, false) do
      render_findings_delta(Keyword.get(opts, :workpad_text))
    else
      render_workpad_context(Keyword.get(opts, :workpad_text))
    end
  end

  # code_review on a resumed session: same principle — reviewer already has
  # conversation context, don't re-inject.
  # Cold code_review needs workpad context (Plan + prior Notes) so the reviewer
  # understands what the implement sessions were aiming at. Resumed sessions
  # already have that context in conversation history — skipping the re-inject
  # keeps resumed turns small (warm-session delta discipline).
  defp unit_context(%Unit{kind: :code_review}, opts) do
    if Keyword.get(opts, :is_resumed_session, false) do
      nil
    else
      render_workpad_context(Keyword.get(opts, :workpad_text))
    end
  end

  # Regular implement_subtask: inject the current Codex Workpad comment so the
  # agent sees sibling subtasks' status, prior continuation notes, and the
  # overall plan shape without having to make a Linear API call at turn start.
  # This is the structured-note-taking pattern: one agent writes a continuation
  # note under `### Notes`, the next reads it from the prompt.
  defp unit_context(%Unit{kind: :implement_subtask}, opts) do
    render_workpad_context(Keyword.get(opts, :workpad_text))
  end

  defp unit_context(_unit, _opts), do: nil

  # Inject just the latest `### Code Review` section as findings context —
  # used on warm review-fix-N dispatch since findings come from a different
  # thread than the one we're resuming.
  defp render_findings_delta(workpad_text) when is_binary(workpad_text) do
    case SymphonyElixir.WorkpadParser.latest_code_review_section(workpad_text) do
      nil ->
        nil

      section ->
        """
        <review_findings>
        ### Code Review
        #{sanitize_findings_body(section)}
        </review_findings>
        """
    end
  end

  defp render_findings_delta(_), do: nil

  # Defense-in-depth against a review thread writing `</review_findings>` in
  # the section body and breaking out of the wrapper to inject top-level
  # instructions into the implement thread's prompt. Neutralize the wrapper
  # tags including whitespace + case variants.
  defp sanitize_findings_body(body) when is_binary(body) do
    body
    |> neutralize_wrapper_tag("review_findings")
    |> neutralize_wrapper_tag("workpad")
  end

  defp sanitize_findings_body(_), do: ""

  # Generic tag neutralizer — matches `<tag...>` or `</tag ...>` with
  # arbitrary whitespace/attributes and ANY case (LLMs love case variants).
  # Replaces with `<tag_filtered...>` / `</tag_filtered ...>`. Safer than
  # the plain String.replace-exact-literal pattern, which was bypassable
  # by `</review_findings >` (trailing space), `</WORKPAD>`, etc.
  defp neutralize_wrapper_tag(body, tag) when is_binary(body) and is_binary(tag) do
    # Match `</TAG...>` (closing) — case-insensitive, any attrs/whitespace.
    close_re = ~r/<\/(#{Regex.escape(tag)})([^>]*)>/i
    # Match `<TAG...>` or `<TAG ...>` (opening).
    open_re = ~r/<(#{Regex.escape(tag)})(\s[^>]*|)>/i

    body
    |> then(&Regex.replace(close_re, &1, "</\\1_filtered\\2>"))
    |> then(&Regex.replace(open_re, &1, "<\\1_filtered\\2>"))
  end

  # Cap in BYTES (not graphemes — CJK content would ~3× a grapheme cap and
  # blow the prompt budget). Real-world workpads on this project sit at
  # 2–5 KB; the cap is generous enough that it almost never fires, and
  # when it does the agent still has the ticket description and its own
  # subtask text, and can fall back to Linear for anything else.
  @max_workpad_bytes 12_288

  defp render_workpad_context(text) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      nil
    else
      # Section-aware truncation: protects `### Plan` + latest `### Code Review`
      # from head-cut, drops oldest Notes continuations first. The naive head
      # cut used previously could silently slice the latest review findings
      # mid-line, blinding a resumed implement session to what it must fix.
      rendered = SymphonyElixir.WorkpadParser.truncate_preserving_sections(trimmed, @max_workpad_bytes)

      """
      <workpad>
      #{sanitize_workpad_body(rendered)}
      </workpad>
      """
    end
  end

  defp render_workpad_context(_), do: nil

  # Still used for non-section content (e.g., ticket description) where the
  # simpler head-cut is fine because there's no internal structure to protect.
  defp take_head_bytes(text, byte_cap) when byte_size(text) <= byte_cap, do: text

  defp take_head_bytes(text, byte_cap) do
    text |> binary_part(0, byte_cap) |> trim_invalid_utf8_tail()
  end

  defp trim_invalid_utf8_tail(<<>>), do: <<>>

  defp trim_invalid_utf8_tail(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_invalid_utf8_tail(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  # The workpad is Symphony's own artifact, but humans and agents edit it over
  # time and it may contain user-pasted content in Notes. Defense-in-depth:
  # neutralize any literal `</workpad>` (including whitespace / case variants)
  # so the block can't be closed early.
  defp sanitize_workpad_body(body) do
    neutralize_wrapper_tag(body, "workpad")
  end

  # Size budget: total ticket_comments block is capped at 10KB, and on overflow
  # we drop oldest comments first (newer comments supersede older ones per the
  # rework instructions). Per-comment cap is set just below the total so a
  # single huge comment still fits with a truncation marker rather than being
  # silently dropped by the total-budget check (which counts rendered size
  # including the `<comment ...>` wrapper). Supervisor review comments are
  # naturally information-dense (multi-finding lists with file:line refs) and
  # routinely run 5-8KB, so a previous 2KB per-comment cap was slicing the
  # actionable tail — see ENT-171 round 4 where the `scan-workbench.test.ts`
  # file:line references were cut mid-enumeration and silently missed.
  # Per-comment cap is in BYTES to match @max_ticket_comments_bytes — otherwise
  # CJK-heavy bodies (3 bytes/char) could inflate a nominally "9K" comment to
  # ~27KB, overflow the total cap, and get wholesale-skipped by the reducer
  # below. Must stay just below the total so a single huge comment still fits
  # with a truncation marker rather than being silently dropped.
  @max_comment_body_bytes 9_216
  @max_ticket_comments_bytes 10_240

  defp render_ticket_comments(comments) do
    sorted =
      comments
      |> Enum.reject(&workpad_comment?/1)
      |> Enum.sort_by(&(&1["createdAt"] || ""))

    # Render newest-to-oldest, keep while within budget, then reverse back to
    # chronological order for the agent. Threads the running byte total through
    # the accumulator so budget check is O(1) per comment instead of O(n).
    {kept_reversed, _total, dropped?} =
      sorted
      |> Enum.reverse()
      |> Enum.map(&render_single_comment/1)
      |> Enum.reduce({[], 0, false}, fn rendered, {acc, total, dropped?} ->
        size = byte_size(rendered)

        if total + size > @max_ticket_comments_bytes do
          {acc, total, true}
        else
          {[rendered | acc], total + size, dropped?}
        end
      end)

    body = Enum.join(kept_reversed, "\n")
    trunc_note = if dropped?, do: "<!-- older comments omitted to fit size budget -->\n", else: ""

    """
    <ticket_comments>
    #{trunc_note}#{body}
    </ticket_comments>
    """
  end

  defp render_single_comment(comment) do
    author = sanitize_attr(get_in(comment, ["user", "name"]) || "unknown")
    created_at = sanitize_attr(comment["createdAt"] || "unknown")
    body = comment["body"] || ""

    """
    <comment author="#{author}" created_at="#{created_at}">
    #{sanitize_body(body)}
    </comment>
    """
  end

  # Defense-in-depth: prevent a Linear comment body from closing the wrapper
  # tag and injecting top-level instructions. Replace (not drop) so the agent
  # can still see that something was there — avoids silent content loss.
  defp sanitize_body(body) when is_binary(body) do
    # Use BYTE-based cap (matching @max_ticket_comments_bytes) — CJK bodies at
    # a grapheme cap could inflate to 3× the byte cap and get wholesale-
    # skipped by the total-bytes reducer in render_ticket_comments/1.
    # take_head_bytes trims at the last valid UTF-8 boundary so the output is
    # always valid UTF-8.
    truncated =
      if byte_size(body) > @max_comment_body_bytes do
        take_head_bytes(body, @max_comment_body_bytes) <> "\n…(comment body truncated)"
      else
        body
      end

    truncated
    |> neutralize_wrapper_tag("ticket_comments")
    |> neutralize_wrapper_tag("comment")
  end

  defp sanitize_body(_), do: ""

  defp sanitize_attr(value) when is_binary(value) do
    value
    |> String.replace("\"", "'")
    |> String.replace("\n", " ")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp sanitize_attr(_), do: "unknown"

  # The Codex Workpad is Symphony's own artifact (task checklist / env stamp),
  # not review context. Require BOTH markers so a legitimate supervisor comment
  # that happens to use a `### Plan` sub-header (e.g., "### Plan to fix") is
  # not silently dropped. `Linear.Adapter.fetch_workpad_text/1` uses an OR
  # heuristic because it's searching for the workpad; here we're excluding it,
  # so the stricter AND check is correct.
  defp workpad_comment?(comment) do
    body = comment["body"] || ""
    String.contains?(body, "## Codex Workpad") and String.contains?(body, "### Plan")
  end

  # Description caps are per-unit-kind. Only plan and implement_subtask
  # materially benefit from the full ticket spec (Goal/Why/Scope/Constraints/
  # Done When/Proof Required). Procedural units (bootstrap, doc_fix, verify,
  # handoff, merge) are orchestrator-driven and mostly need identifier +
  # title — giving them the full spec regresses the unit-lite narrow-prompt
  # contract and multiplies token burn across every dispatch. Caps are in
  # BYTES so CJK content can't silently inflate past the budget.
  @max_description_bytes_full 15_000
  @max_description_bytes_procedural 1_024

  defp unit_header(issue, unit) do
    raw_desc = Map.get(issue, :description) || Map.get(issue, "description")
    cap = description_cap_for(unit)

    desc =
      if is_binary(raw_desc) && String.trim(raw_desc) != "" do
        truncated =
          if byte_size(raw_desc) > cap do
            take_head_bytes(raw_desc, cap) <> "\n…(description truncated to fit prompt budget)"
          else
            raw_desc
          end

        "\n\nDescription:\n#{truncated}"
      else
        ""
      end

    """
    You are working on Linear ticket `#{issue.identifier || "unknown"}`: #{issue.title || ""}
    Current unit: **#{unit.display_name}**
    Read AGENTS.md for project conventions before making changes.
    #{desc}
    """
  end

  defp description_cap_for(%Unit{kind: :plan}), do: @max_description_bytes_full
  defp description_cap_for(%Unit{kind: :implement_subtask}), do: @max_description_bytes_full
  defp description_cap_for(_unit), do: @max_description_bytes_procedural

  # Bootstrap: goal-oriented, no step-by-step needed for low-effort unit
  defp unit_instructions(%Unit{kind: :bootstrap}, _opts) do
    """
    ## Instructions — Bootstrap
    Set up the workspace for this ticket. Your goal:
    - Move the Linear issue to `In Progress` (if Todo).
    - Find or create the `## Codex Workpad` comment with ONLY the environment stamp (`<host>:<path>@<sha>`). Leave `### Plan` empty.
    - Run baseline validation if ticket touches app code.

    **CRITICAL**: Do NOT write a plan, create subtasks, or implement anything. The workpad must contain ONLY the environment stamp — no `### Plan` checklist items. Planning and implementation happen in separate sessions.
    """
  end

  defp unit_instructions(%Unit{kind: :plan}, _opts) do
    """
    ## Instructions — Plan
    1. Read the full issue description and any existing comments/PR feedback.
    2. Search the codebase for existing related code.
    3. Write a checklist in the workpad under `### Plan`. Each subtask MUST use
       the structured three-line form so the implementer knows exactly what to
       touch and how success is judged:
       ```
       ### Plan
       - [ ] [plan-1] <short imperative title>
         - touch: <files/paths this subtask will edit, comma-separated>
         - accept: <how to verify — test command, visible behavior, or artifact>
       - [ ] [plan-2] <short imperative title>
         - touch: ...
         - accept: ...
       ```
    4. Also scaffold a `### Notes` section — downstream subtasks append their
       continuation summaries here, and subsequent subtasks read them as context:
       ```
       ### Notes
       - branch: feature/<issue-id>-<slug>
       - key decision: <top-level rationale the whole plan hangs on>
       ```
       Leave a blank line under Notes; do NOT pre-fill `#### [plan-N] continuation`
       entries — each implementer writes their own.
    5. Each item must be small enough to implement in one session.
    6. Self-check: verify each item is independently implementable and testable,
       and that `touch` + `accept` together are specific enough that a fresh
       agent reading only that entry could act.

    Do NOT implement — a separate session handles each subtask. Your job is only the plan.
    """
  end

  defp unit_instructions(%Unit{kind: :implement_subtask, subtask_id: "verify-fix-" <> _, subtask_text: error_text}, _opts) do
    """
    ## Instructions — Verify Fix
    Verification failed after implementation. The orchestrator's test suite reported errors.
    Your job: fix the code so the failing tests pass.

    ### Verification Error Output
    ```
    #{error_text || "(no error output captured)"}
    ```

    ### Steps
    1. Read the error output above. Identify the failing test file(s) and assertion(s).
    2. Read the failing test to understand what it expects.
    3. Read the source code under test. Determine root cause.
    4. Fix whichever side is wrong:
       - If the **code** has a bug → fix the code.
       - If the **test expectations** are stale (e.g., UI text/flow changed intentionally) → update the tests.
    5. **Run the failing test to verify your fix.** Iterate until it passes.
    6. Commit only after the test passes.

    Do NOT skip, disable, or delete tests — fix or update them.
    Do NOT do handoff or create a PR — the orchestrator handles the rest.

    ### When NOT to keep trying
    If the failure does not look like a code or test bug — for example: CI
    infrastructure outage, GitHub Actions / runner unreachable, a dependency
    that cannot be downloaded, a permission/billing/auth error from an
    external service, a network timeout — do NOT keep editing code. The
    environment, not the code, is broken, and "fix the env" is not your job
    here. Instead: post a short Linear comment summarising what you observed
    and why you believe it is an infrastructure / human-ops issue, then exit.
    Closeout requires HEAD to advance before it will accept this unit, so
    after exiting Symphony will replay the dispatch up to a few times; once
    the circuit breaker trips on max attempts the orchestrator escalates to
    Human Input Needed. Those replays are cheap compared to code damage from
    forcing edits onto a green codebase.
    """
  end

  defp unit_instructions(%Unit{kind: :implement_subtask, subtask_id: "merge-sync-" <> _, subtask_text: _}, _opts) do
    """
    ## Instructions — Merge Sync (Conflict Resolution)
    The PR branch has merge conflicts with `main`. Resolve them and push a clean
    merge so the programmatic squash-merge can proceed.

    ### Steps
    1. Ensure working tree is clean (`git status`). Stash or commit if needed.
    2. `git config rerere.enabled true && git config rerere.autoupdate true`
    3. `git fetch origin`
    4. `git pull --ff-only origin $(git branch --show-current)` (sync remote branch changes)
    5. `git -c merge.conflictstyle=zdiff3 merge origin/main`
    6. If conflicts:
       - `git status` to list conflicted files.
       - Read both sides' intent before editing. Prefer minimal, intention-preserving edits.
       - For generated files: resolve source files first, then regenerate.
       - `git add <file>` after each resolution.
    7. `git merge --continue`
    8. `git diff --check` (verify no conflict markers remain)
    9. Run the project's validation suite (follow AGENTS.md).
    10. `git push origin $(git branch --show-current)`

    ### Safety
    - Do NOT force-push or rewrite history.
    - Do NOT create a new PR or modify the PR description.
    - Do NOT skip, disable, or delete tests.
    - Do NOT use `--ours`/`--theirs` unless one side clearly wins entirely.

    The orchestrator will re-verify and retry the programmatic merge after you push.
    """
  end

  # Warm-session review loop: reviewer (session B) wrote findings into the
  # workpad's latest `### Code Review` section. This dispatch resumes session
  # A (implement thread) — or, if resume failed, a fresh cold session — and
  # tells the agent to apply those findings. The two branches only differ in
  # what the agent can be assumed to remember.
  defp unit_instructions(%Unit{kind: :implement_subtask, subtask_id: "review-fix-" <> _ = id}, opts) do
    if Keyword.get(opts, :is_resumed_session, false) do
      """
      ## Implement review fix `#{id}`

      The reviewer (running in a SEPARATE persistent thread) just posted
      findings. They appear verbatim in the `<review_findings>` block above
      — the implement thread never sees review history on its own, so that
      block is the canonical source. Apply the MEDIUM+ fixes, keep tests
      green, and commit. Plan / prior continuation notes are in your own
      conversation history — no need to re-read those.

      **Done when**
      - every MEDIUM-or-higher finding from the latest Code Review round is fixed
      - `./scripts/verify-changed.sh` exits green
      - a commit references `#{id}` in its message

      Leave LOW findings if fixing them would balloon scope; note the choice in
      the commit message.

      NEVER force-push. NEVER commit while verification is red.
      """
    else
      """
      ## Implement review fix `#{id}` (cold session — no prior memory)

      Resume failed or the implement thread expired, so you are starting with
      no conversation history. The workpad above contains the full `### Plan`,
      `### Notes` continuations, and the latest `### Code Review` section with
      the findings to fix. Read all three before writing code.

      **Done when**
      - every MEDIUM-or-higher finding from the latest Code Review round is fixed
      - `./scripts/verify-changed.sh` exits green
      - a commit references `#{id}` in its message

      Leave LOW findings if fixing them would balloon scope; note the choice in
      the commit message.

      NEVER force-push. NEVER commit while verification is red.
      """
    end
  end

  defp unit_instructions(%Unit{kind: :implement_subtask, subtask_id: "rework-" <> _, subtask_text: _text}, _opts) do
    """
    ## Instructions — Rework Fix
    This ticket was sent back for rework. Linear comments on this ticket
    are in the `<ticket_comments>` block above, sorted chronologically with
    author and timestamp. They include supervisor review findings and any
    other context posted on the ticket.

    1. Identify the supervisor's review findings in `<ticket_comments>`. Use
       timestamps to focus on what's outstanding vs already-addressed in prior
       commits. Later comments generally supersede earlier ones.
    2. Implement **all** fixes for MEDIUM and above severity findings.
    3. Commit your changes with a descriptive message referencing the findings.

    Do NOT re-plan or restructure — only fix what was flagged.
    Do NOT do handoff, verify, or create a new PR — the orchestrator handles the rest.
    """
  end

  defp unit_instructions(%Unit{kind: :implement_subtask, subtask_id: id, subtask_text: text}, opts) do
    subtask_contract =
      case render_subtask_contract(Keyword.get(opts, :current_subtask)) do
        nil ->
          ""

        block ->
          """

          Structured contract for `[#{id}]`:
          #{block}
          """
      end

    """
    ## Instructions — Implement Subtask
    You are implementing **one subtask only**: `#{id}`#{if text, do: " — #{text}", else: ""}

    The current Codex Workpad (if any) is in the `<workpad>` block above. Before
    starting, read it:
    - Look at the `[#{id}]` entry under `### Plan` for context. If a
      `<subtask_contract>` block appears below, treat it as the orchestrator's
      authoritative parse of that entry. When `touch:` paths are listed,
      start with those files; expand to adjacent files only when necessary
      to satisfy the `accept:` criterion (treat `touch:` as a default
      starting surface, not a hard fence). If no contract block is present,
      read any `touch:` / `accept:` sub-lines directly from the workpad
      entry; otherwise follow the subtask title above.
    - Read any prior continuation notes under `### Notes` (entries named
      `#### [plan-N] continuation`) so you know what earlier subtasks changed
      and which gotchas they flagged. Do not re-do exploration that a prior
      continuation note already answered.
    #{subtask_contract}

    1. Implement this subtask only, starting with the `touch` paths when
       present and aimed at satisfying the `accept` criterion (or the
       subtask title when the plan entry is flat). Expand beyond the
       listed paths only when necessary to meet `accept`.
    2. Commit your changes with a descriptive message that references `#{id}`.
    3. **Append a continuation note** under `### Notes` in the workpad, as a
       new sub-block named `#### [#{id}] continuation`, keeping it under ~200
       tokens:
       - `files touched:` comma-separated paths actually edited this session
       - `key decision:` one sentence on what you chose and why
       - `watch out:` anything the next subtask needs to know, or `none`
       Do not rewrite or delete prior continuation notes — append only.
    4. **CRITICAL: Update the Linear workpad checklist** — change `- [ ] [#{id}]` to `- [x] [#{id}]` in the `## Codex Workpad` comment. If you do not mark it done, this subtask will be re-dispatched.

    Do NOT touch other subtasks. Do NOT run the terminal `handoff` unit's
    work (creating a PR, posting `## Results`, transitioning to Human Review)
    — the orchestrator dispatches one unit at a time to prevent drift.
    """
  end

  defp unit_instructions(%Unit{kind: :doc_fix}, _opts) do
    """
    ## Instructions — Doc Fix
    Recent code changes may have made documentation stale.
    1. Check AGENTS.md, docs/ARCHITECTURE.md, and relevant engineering docs.
    2. Update any docs that no longer match the current code.
    3. Commit doc changes only.

    Do NOT change functional code — this unit exists solely to keep docs as a reliable context anchor for future sessions.
    """
  end

  defp unit_instructions(%Unit{kind: :verify}, _opts) do
    """
    ## Instructions — Verify
    The orchestrator runs validation commands automatically after this session.
    Your job: review workspace readiness.
    1. Check that all planned changes are committed.
    2. Review git status for untracked or unstaged files that should be included.
    3. Report any concerns.

    Do NOT run validation scripts — the orchestrator owns verification to prevent bypass.
    Do NOT fix code or do handoff.
    """
  end

  # Two-branch routing (post-Iter-10 simplification):
  #
  #   retry_reason !is present → prepend as prefix, agent reads reason +
  #                              uses the base prompt to decide what to do.
  #
  #   base prompt is cold OR resumed based on whether we have a baseline:
  #     is_resumed AND last_reviewed_sha is a binary → resumed prompt
  #     else                                         → cold prompt
  #
  # The previous 5-branch cond table was the source of three HIGH regressions
  # across Iter 6/7/9 (findings→clean flip, cold-fallback reporting framing,
  # skill-not-invoked bypass). Trusting the agent to read the rejection
  # reason + base prompt and figure out the right action is fewer moving
  # parts and fewer edges. Closeout-level guards (reviewer_committed?,
  # findings→clean rejection, SHA match) are the hard stops regardless.
  defp unit_instructions(%Unit{kind: :code_review}, opts) do
    last_reviewed_sha = Keyword.get(opts, :last_reviewed_sha)
    is_resumed = Keyword.get(opts, :is_resumed_session, false)

    base =
      if is_resumed and is_binary(last_reviewed_sha) do
        code_review_resumed_prompt(last_reviewed_sha)
      else
        code_review_cold_prompt()
      end

    code_review_retry_prefix(Keyword.get(opts, :retry_reason)) <> base
  end

  # If the prior dispatch was rejected by closeout, prepend a short block
  # naming the exact rejection. The base prompt underneath (cold or resumed)
  # tells the agent WHAT to do; this prefix tells them WHY they're re-running.
  # Defined after the unit_instructions clause block below (Elixir warns on
  # interrupted same-name/arity defps).

  # Handoff: goal-oriented, low-effort unit
  defp unit_instructions(%Unit{kind: :handoff}, _opts) do
    """
    ## Instructions — Handoff
    Deliver the completed work for human review. Your goal:
    - Write `## Results` comment on the Linear issue with deliverables summary.
      Include a one-line pointer to the workpad's `### Code Review` section
      (the orchestrator dispatched a `code_review` unit before this one, so
      that section already exists — just reference it).
    - Push branch and create/update PR via `push` skill.
    - Attach PR URL to the issue.
    - Move issue to `Human Review`.

    Do NOT write new functional code — all implementation is complete at this point.
    Do NOT re-run `$code-review` — it already ran in the previous unit.
    """
  end

  # Merge is handled programmatically (no Codex session).
  # This clause exists only as a safety net if merge is somehow dispatched
  # through the old code path.
  defp unit_instructions(%Unit{kind: :merge}, _opts) do
    """
    ## Instructions — Merge
    Merge the PR with `gh pr merge --squash --delete-branch` and move issue to `Done`.
    Do NOT wait for CI — just merge and exit.
    """
  end

  defp unit_instructions(_unit, _opts) do
    "Follow the instructions for this unit."
  end

  # --- code_review prompts (moved here so the unit_instructions/2 clauses
  # above stay contiguous — Elixir warns on same-name/arity defps interrupted
  # by other definitions) ---

  # Retry prefix — prepended onto cold/resumed when prior dispatch was
  # rejected. Agent reads reason + base prompt and picks the right action.
  defp code_review_retry_prefix(reason) when is_binary(reason) and reason != "" do
    """
    ## Previous attempt rejected

    The orchestrator's closeout rejected the previous turn:

        #{reason}

    Use the instructions below to address the rejection. If the rejection
    says the skill was not invoked, run `$code-review` before writing the
    workpad section. If it says the Reviewed SHA was stale or the workpad
    was not updated since last accepted review, re-examine the current HEAD
    — do not just edit the SHA to match. If it says the Verdict line was
    malformed, fix the line (do NOT re-run the skill; your findings from
    the previous turn are in this session's history, assuming the session
    is warm; cold-fallback sessions should re-run the skill).

    """
  end

  defp code_review_retry_prefix(_), do: ""

  # First (cold) dispatch of the review session B. Carry full context — the
  # reviewer has no conversation history yet.
  defp code_review_cold_prompt do
    """
    ## Code Review

    Run the `$code-review` skill on this branch, then — when the diff touches
    web UI — also run `$visual-review` on fresh screenshots. Record the
    combined outcome in the workpad.

    **Step 1: Code review (review-only — do NOT commit fixes)**
    - `$code-review` executed per `.codex/skills/code-review/SKILL.md` (use the
      skill's protocol; do NOT substitute `codex exec review`).
    - Record EVERY MEDIUM-or-higher finding in the workpad section below.
      Do NOT commit fixes from this unit — the implement thread runs them as
      `review-fix-N` next dispatch, where `./scripts/verify-changed.sh` is a
      mandatory gate. A reviewer-committed fix would bypass that gate and
      ship unverified code behind a "clean" verdict.
    - LOW findings may be skipped — note the choice in the workpad section.

    **Step 2: Visual review (web UI only)**
    - Detect UI changes on the branch range. Resolve the branch base first
      and FAIL LOUDLY on missing ref — don't let `|| true` mask a missing
      `origin/main` / non-`main` default branch, otherwise an empty `ui`
      means "base lookup broke", not "no UI files", and visual review
      silently skips on a real UI diff:
      ```
      base=$(git merge-base HEAD @{upstream} 2>/dev/null || \
             git merge-base HEAD origin/HEAD 2>/dev/null || \
             git merge-base HEAD origin/main 2>/dev/null)
      if [ -z "$base" ]; then
        echo "[visual] SKIPPED: could not resolve branch base (try: git fetch origin)"
        # Write Verdict: findings — fail closed.
      else
        ui=$(git diff --name-only "$base"..HEAD | \
          grep -E '^apps/web/(app|components)/.*\\.(tsx|jsx|css|scss)$|^apps/web/app/.*layout\\.tsx$|^apps/web/(theme|tokens|styles|design-system)/' || true)
      fi
      ```
    - If `$ui` is empty AND base resolved → skip Step 2 (no UI files).
    - Else: start `pnpm --dir apps/web dev &`, record `DEV_PID=$!`, `trap 'kill $DEV_PID 2>/dev/null' EXIT`
      so cleanup can't be skipped. Poll `http://localhost:3100` up to 90s.
      Timeout → log `[visual] SKIPPED: dev server did not start` and write
      `Verdict: findings`. Otherwise capture routes inferred from
      `apps/web/app/**/page.tsx` into `/tmp/visual-review-<sha>/` (desktop
      1440x900 + mobile 390x844; reference patterns in
      `apps/web/scripts/capture-board-redesign.mjs`), run `$visual-review` on
      the PNGs. Do NOT use `lsof | kill -9 tcp:3100` — that kills whatever
      happens to hold the port, not just your own dev server.

    **Step 3: Write workpad**
    Append a `### Code Review` section to the `## Codex Workpad` comment with:
    - `Reviewed SHA:` the final HEAD you reviewed (after any fix commits)
    - `Findings:` counts by severity, or `none`
    - `Verdict:` `clean` when no MEDIUM+ remain; otherwise `findings`
    - Tagged findings list, one per line:
      - `[code] <severity> <file>:<line> <summary>`
      - `[visual] <severity> <route> <summary>`
    - If Step 2 was skipped because no UI files changed, note:
      `[visual] N/A — no UI files in diff`
    - If Step 2 was attempted but SKIPPED due to infra failure, the Verdict
      MUST be `findings` (fail closed; the orchestrator will re-dispatch).

    Do NOT do handoff. The orchestrator dispatches handoff only after the
    `Verdict: clean` line appears.

    NEVER force-push. NEVER silently skip the skill — missing workpad section
    causes the orchestrator to re-dispatch you.
    """
  end

  # Resumed dispatch of review session B. Neutral framing — works for
  # happy-path re-review (implement just pushed fixes), for retry-after-
  # stale-SHA (closeout flagged the prior section), and for retry-after-
  # malformed-Verdict (agent fixes the reporting without re-running the
  # skill — session history has the findings, assuming thread is warm).
  #
  # Caller guards ensure last_reviewed_sha is always a binary.
  defp code_review_resumed_prompt(last_reviewed_sha) when is_binary(last_reviewed_sha) do
    """
    ## Code Review (resumed turn)

    Examine the diff since the last accepted review:

        git diff #{last_reviewed_sha}..HEAD

    Your prior review context is in this thread's history. If the diff is
    empty and no rejection reason above tells you otherwise, flag no new
    findings and append a new round confirming the prior state. If the
    retry prefix above says the skill was not invoked, run `$code-review`
    on the full branch BEFORE writing findings.

    **Done when**
    - each prior MEDIUM+ finding is confirmed resolved or still flagged
    - any new issues introduced by commits in the diff are flagged
    - if the diff touches web UI surfaces (tsx/jsx/css/scss in
      `apps/web/app|components`, `apps/web/app/*/layout.tsx`, or
      `apps/web/{theme,tokens,styles,design-system}/**`), re-run the visual
      review flow from your first turn: start dev server, capture fresh
      screenshots, run `$visual-review`, merge findings
    - a new round is appended to `### Code Review` in the workpad with updated
      `Reviewed SHA:`, `Findings:`, and `Verdict:` lines (do not rewrite prior
      rounds — append only), using the same `[code]` / `[visual]` tagging

    Do NOT commit code fixes from this unit — fixes go through `review-fix-N`
    on the implement thread, which has the `./scripts/verify-changed.sh` gate.
    """
  end

  defp render_subtask_contract(%{touch: touch, accept: accept}) do
    lines =
      [
        render_touch_line(touch),
        render_accept_line(accept)
      ]
      |> Enum.reject(&is_nil/1)

    case lines do
      [] ->
        nil

      _ ->
        body =
          lines
          |> Enum.join("\n")
          |> sanitize_contract_body()

        """
        <subtask_contract>
        #{body}
        </subtask_contract>
        """
    end
  end

  defp render_subtask_contract(_), do: nil

  defp render_touch_line(touch) when is_list(touch) and touch != [] do
    "touch: " <> Enum.join(touch, ", ")
  end

  defp render_touch_line(_), do: nil

  defp render_accept_line(accept) when is_binary(accept) do
    case String.trim(accept) do
      "" -> nil
      trimmed -> "accept: " <> trimmed
    end
  end

  defp render_accept_line(_), do: nil

  # Defense-in-depth: plan authors can paste arbitrary text into continuation
  # lines, so neutralize literal wrapper tags before rendering the block.
  defp sanitize_contract_body(body) do
    neutralize_wrapper_tag(body, "subtask_contract")
  end

  # "Do NOT expand scope" was removed here: for plan-N subtasks it was
  # redundant with the Instructions ("Do NOT touch other subtasks"); for
  # rework subtasks it actively contradicted "implement all fixes for
  # MEDIUM and above severity findings", teaching agents to fix the
  # loudest blocker and leave the rest.
  defp unit_guardrails(%Unit{kind: :implement_subtask}) do
    """
    ## Guardrails
    - Work only inside the current workspace.
    - Never commit/push from main/master.
    - Close stdin on long commands: append `< /dev/null`.
    """
  end

  defp unit_guardrails(_unit) do
    """
    ## Guardrails
    - Work only inside the current workspace.
    - Never commit/push from main/master.
    - Unattended session — never ask human for input.
    """
  end
end
