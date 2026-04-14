defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

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
      unit_context(unit, opts),
      unit_instructions(unit, opts),
      unit_guardrails(unit)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
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

  # Regular implement_subtask: inject the current Codex Workpad comment so the
  # agent sees sibling subtasks' status, prior continuation notes, and the
  # overall plan shape without having to make a Linear API call at turn start.
  # This is the structured-note-taking pattern: one agent writes a continuation
  # note under `### Notes`, the next reads it from the prompt.
  defp unit_context(%Unit{kind: :implement_subtask}, opts) do
    render_workpad_context(Keyword.get(opts, :workpad_text))
  end

  defp unit_context(_unit, _opts), do: nil

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
      rendered =
        if byte_size(trimmed) > @max_workpad_bytes do
          head = take_head_bytes(trimmed, @max_workpad_bytes)
          "#{head}\n…(workpad truncated to fit prompt budget — fetch the full `## Codex Workpad` comment from Linear if you need content past this point)"
        else
          trimmed
        end

      """
      <workpad>
      #{sanitize_workpad_body(rendered)}
      </workpad>
      """
    end
  end

  defp render_workpad_context(_), do: nil

  # Cut a binary prefix at byte_cap and strip any trailing partial UTF-8
  # code point so the result is always a valid string. O(byte_cap) upper
  # bound on the trim walk; in practice at most a 3-byte continuation run.
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
  # neutralize any literal `</workpad>` so the block can't be closed early.
  defp sanitize_workpad_body(body) do
    body
    |> String.replace("</workpad>", "</workpad_filtered>")
    |> String.replace("<workpad>", "<workpad_filtered>")
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
  @max_comment_body_chars 9_216
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
    # Use String.length / String.slice (grapheme-based) consistently to avoid
    # the byte_size vs grapheme mismatch — truncating by byte count while
    # checking by graphemes (or vice versa) lets UTF-8 multi-byte bodies drift
    # past their nominal cap. The total-size cap upstream is still in bytes,
    # which bounds overall prompt size regardless of individual-body drift.
    truncated =
      if String.length(body) > @max_comment_body_chars do
        String.slice(body, 0, @max_comment_body_chars) <> "\n…(comment body truncated)"
      else
        body
      end

    truncated
    |> String.replace("</ticket_comments>", "</ticket_comments_filtered>")
    |> String.replace("<ticket_comments>", "<ticket_comments_filtered>")
    |> String.replace("</comment>", "</comment_filtered>")
    |> String.replace("<comment ", "<comment_filtered ")
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
      authoritative parse of that entry and prefer it over manually re-reading
      `touch:` / `accept:` sub-lines. If no contract block is present, read any
      `touch:` / `accept:` sub-lines directly from the workpad entry; otherwise
      follow the subtask title above.
    - Read any prior continuation notes under `### Notes` (entries named
      `#### [plan-N] continuation`) so you know what earlier subtasks changed
      and which gotchas they flagged. Do not re-do exploration that a prior
      continuation note already answered.
    #{subtask_contract}

    1. Implement this subtask only, scoped to the `touch` paths when present
       and aimed at satisfying the `accept` criterion (or the subtask title
       when the plan entry is flat).
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

  # Handoff: goal-oriented, low-effort unit
  defp unit_instructions(%Unit{kind: :handoff}, _opts) do
    """
    ## Instructions — Handoff
    Deliver the completed work for human review. Your goal:
    - Write `## Results` comment on the Linear issue with deliverables summary.
    - Push branch and create/update PR via `push` skill.
    - Attach PR URL to the issue.
    - Move issue to `Human Review`.

    Do NOT write new functional code — all implementation is complete at this point.
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
    body
    |> String.replace("</subtask_contract>", "</subtask_contract_filtered>")
    |> String.replace("<subtask_contract>", "<subtask_contract_filtered>")
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

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
