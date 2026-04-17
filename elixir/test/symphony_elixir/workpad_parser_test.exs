defmodule SymphonyElixir.WorkpadParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkpadParser

  @workpad_with_explicit_ids """
  ## Codex Workpad
  `host:dir@abc123`

  ### Plan
  - [x] [plan-1] Add BorderDetector component
  - [ ] [plan-2] Integrate into EditorScreen
  - [ ] [plan-3] Add unit tests

  ### Notes
  - branch: feature/ENT-42
  """

  @workpad_without_ids """
  ## Codex Workpad

  ### Plan
  - [x] Add BorderDetector component
  - [ ] Integrate into EditorScreen
  - [ ] Add unit tests

  ### Notes
  - some note
  """

  @workpad_no_plan """
  ## Codex Workpad
  Just some text without a plan section.
  """

  @workpad_empty_plan """
  ## Codex Workpad

  ### Plan

  ### Notes
  - nothing here
  """

  describe "parse/1" do
    test "parses workpad with explicit IDs" do
      {:ok, subtasks} = WorkpadParser.parse(@workpad_with_explicit_ids)

      assert length(subtasks) == 3
      assert Enum.at(subtasks, 0) == %{id: "plan-1", text: "Add BorderDetector component", done: true, touch: [], accept: nil}
      assert Enum.at(subtasks, 1) == %{id: "plan-2", text: "Integrate into EditorScreen", done: false, touch: [], accept: nil}
      assert Enum.at(subtasks, 2) == %{id: "plan-3", text: "Add unit tests", done: false, touch: [], accept: nil}
    end

    test "parses workpad without explicit IDs, falls back to positional" do
      {:ok, subtasks} = WorkpadParser.parse(@workpad_without_ids)

      assert length(subtasks) == 3
      assert Enum.at(subtasks, 0) == %{id: "plan-1", text: "Add BorderDetector component", done: true, touch: [], accept: nil}
      assert Enum.at(subtasks, 1) == %{id: "plan-2", text: "Integrate into EditorScreen", done: false, touch: [], accept: nil}
      assert Enum.at(subtasks, 2) == %{id: "plan-3", text: "Add unit tests", done: false, touch: [], accept: nil}
    end

    test "parses both touch and accept continuation lines" do
      workpad = """
      ### Plan
      - [ ] [plan-1] Wire parser
        - touch: lib/a.ex, lib/b.ex
        - accept: mix test test/symphony_elixir/workpad_parser_test.exs
      """

      assert {:ok, [%{touch: ["lib/a.ex", "lib/b.ex"], accept: "mix test test/symphony_elixir/workpad_parser_test.exs"}]} =
               WorkpadParser.parse(workpad)
    end

    test "concatenates multiple touch lines and keeps the last non-empty accept line" do
      workpad = """
      ### Plan
      - [ ] [plan-1] Wire parser
        - touch: lib/a.ex, lib/b.ex
        - accept: first acceptance
        - touch: test/a_test.exs
        - accept: final acceptance
      """

      assert {:ok, [%{touch: ["lib/a.ex", "lib/b.ex", "test/a_test.exs"], accept: "final acceptance"}]} =
               WorkpadParser.parse(workpad)
    end

    test "parses only accept lines and preserves commas in accept text" do
      workpad = """
      ### Plan
      - [ ] [plan-1] Wire parser
        - accept: run focused tests, then do a quick smoke check
      """

      assert {:ok, [%{touch: [], accept: "run focused tests, then do a quick smoke check"}]} =
               WorkpadParser.parse(workpad)
    end

    test "defaults touch to [] and accept to nil when continuation lines are absent" do
      workpad = """
      ### Plan
      - [ ] [plan-1] Flat plan entry
      """

      assert {:ok, [%{touch: [], accept: nil}]} = WorkpadParser.parse(workpad)
    end

    test "trims extra whitespace around continuation keys and values" do
      workpad = """
      ### Plan
      - [ ] [plan-1] Wire parser
          -  touch:  lib/a.ex, test/a_test.exs
          -  accept:   mix test
      """

      assert {:ok, [%{touch: ["lib/a.ex", "test/a_test.exs"], accept: "mix test"}]} =
               WorkpadParser.parse(workpad)
    end

    test "matches continuation keys case-insensitively" do
      workpad = """
      ### Plan
      - [ ] [plan-1] Wire parser
        - Touch: lib/a.ex
        - ACCEPT: mix test
      """

      assert {:ok, [%{touch: ["lib/a.ex"], accept: "mix test"}]} = WorkpadParser.parse(workpad)
    end

    test "accepts * bullets for checklist and continuation lines" do
      workpad = """
      ### Plan
      * [ ] [plan-1] Wire parser
        * touch: lib/a.ex
        * accept: mix test
      """

      assert {:ok, [%{id: "plan-1", touch: ["lib/a.ex"], accept: "mix test"}]} =
               WorkpadParser.parse(workpad)
    end

    test "keeps parsing plan items across #### subheadings inside the plan section" do
      workpad = """
      ### Plan
      - [ ] [plan-1] foo
      #### Sub-note
        - touch: lib/foo.ex
        - accept: keep foo working
      - [ ] [plan-2] bar
      """

      assert {:ok,
              [
                %{id: "plan-1", touch: ["lib/foo.ex"], accept: "keep foo working"},
                %{id: "plan-2", text: "bar"}
              ]} = WorkpadParser.parse(workpad)
    end

    test "ignores unknown continuation keys without leaking them into the contract" do
      workpad = """
      ### Plan
      - [ ] [plan-1] Wire parser
        - Note: rebase after foo
      """

      assert {:ok, [%{id: "plan-1", text: "Wire parser", touch: [], accept: nil}]} =
               WorkpadParser.parse(workpad)
    end

    test "trims explicit checklist ids before returning them" do
      workpad = """
      ### Plan
      - [ ] [plan-1 ] Wire parser
      """

      assert {:ok, [%{id: "plan-1", text: "Wire parser"}]} = WorkpadParser.parse(workpad)
    end

    test "returns error when no plan section" do
      assert {:error, :no_plan_section} = WorkpadParser.parse(@workpad_no_plan)
    end

    test "returns error when plan section has no checklist items" do
      assert {:error, :no_checklist_items} = WorkpadParser.parse(@workpad_empty_plan)
    end

    test "returns error for non-string input" do
      assert {:error, :invalid_input} = WorkpadParser.parse(nil)
    end
  end

  describe "pending/1" do
    test "returns only unchecked items" do
      {:ok, pending} = WorkpadParser.pending(@workpad_with_explicit_ids)
      assert length(pending) == 2
      assert Enum.all?(pending, &(not &1.done))
    end
  end

  describe "next_pending/1" do
    test "returns first unchecked item" do
      next = WorkpadParser.next_pending(@workpad_with_explicit_ids)
      assert next.id == "plan-2"
    end

    test "returns nil when all done" do
      all_done = """
      ### Plan
      - [x] [plan-1] Done
      - [x] [plan-2] Also done
      """

      assert WorkpadParser.next_pending(all_done) == nil
    end
  end

  describe "all_done?/1" do
    test "returns false when items pending" do
      refute WorkpadParser.all_done?(@workpad_with_explicit_ids)
    end

    test "returns true when all checked" do
      all_done = """
      ### Plan
      - [x] [plan-1] Done
      - [x] [plan-2] Also done
      """

      assert WorkpadParser.all_done?(all_done)
    end
  end

  describe "truncate_preserving_sections/2 — anti-cut-off invariant" do
    # Prompt-integrity invariant (see docs/design/warm-session-review-loop.md):
    # when the workpad exceeds the byte budget for injection into a cold
    # dispatch prompt, truncation MUST preserve the sections that gate the
    # dispatch decision — namely the latest ### Code Review section and the
    # ### Plan — and drop old ### Notes / continuation entries first. A
    # blanket byte-cap that slices the latest review mid-line is the specific
    # silent failure mode the warm-session design must prevent.

    test "returns the workpad unchanged when under budget" do
      workpad = "## Workpad\n\n### Plan\n- [x] [plan-1] Done\n"
      assert ^workpad = WorkpadParser.truncate_preserving_sections(workpad, 10_000)
    end

    test "preserves `### Plan` section verbatim even when total is over budget" do
      plan = """
      ### Plan
      - [x] [plan-1] Core
      - [x] [plan-2] Tests
      """

      notes = "### Notes\n" <> String.duplicate("old continuation\n", 500)
      workpad = "## Codex Workpad\n\n" <> plan <> "\n" <> notes

      result = WorkpadParser.truncate_preserving_sections(workpad, 500)

      # All plan items survive
      assert result =~ "[plan-1] Core"
      assert result =~ "[plan-2] Tests"
      # Something got dropped — an elision marker signals the omission
      assert result =~ ~r/omitted|truncated/i
    end

    test "preserves the latest `### Code Review` section when over budget" do
      # This is the specific failure mode the user called out: the latest
      # review findings would be cut off, so the resumed implement session
      # would see an empty / mid-sentence review block.
      noise = "### Notes\n" <> String.duplicate("history line\n", 500)

      latest_review = """
      ### Code Review
      - Reviewed SHA: deadbeef
      - Findings: **HIGH** apps/web/stripe.ts:45 — wrong apiVersion
      - Verdict: findings
      """

      workpad = "## Codex Workpad\n\n### Plan\n- [x] [plan-1] Done\n\n" <> noise <> "\n" <> latest_review

      result = WorkpadParser.truncate_preserving_sections(workpad, 600)

      assert result =~ "### Code Review"
      assert result =~ "Verdict: findings"
      assert result =~ "apps/web/stripe.ts:45"
    end

    test "adversarial layout: old byte-cap cuts Code Review mid-line; new truncator does not" do
      # Construct a workpad where a naive HEAD-cut at max_bytes bytes WOULD
      # land inside the tail ### Code Review section (slicing the load-bearing
      # Verdict line), but the section-aware truncator drops Notes continuation
      # blocks and keeps the review intact. This demonstrates the specific
      # failure mode — without this test the prior "preserves" test could pass
      # by coincidence on a layout where old head-cut also happened to drop
      # the whole Notes + Code Review in one go.

      # Layout (byte positions chosen so cap falls mid-tail-review):
      # [preamble]      ~30 bytes  "## Codex Workpad\n\n"
      # [plan]          ~50 bytes  "### Plan\n- [x] [plan-1] Done\n"
      # [notes]        ~640 bytes  "### Notes\n" + 10 × 60-byte blocks
      # [code review]   ~180 bytes (load-bearing verdict inside)
      # total          ~900 bytes
      # cap =           750 bytes → old head-cut lands inside Code Review
      plan = "### Plan\n- [x] [plan-1] Core\n"

      notes_blocks =
        Enum.map_join(1..10, "", fn i ->
          "#### [plan-#{i}] continuation block " <> String.duplicate("x", 40) <> "\n"
        end)

      code_review = """
      ### Code Review
      - Reviewed SHA: deadbeef
      - [code] HIGH apps/web/stripe.ts:42 mismatched apiVersion — TAIL-FINDING
      - Verdict: findings
      """

      workpad = "## Codex Workpad\n\n" <> plan <> "\n### Notes\n" <> notes_blocks <> "\n" <> code_review

      cap = 750

      # Safety: verify the layout actually triggers the adversarial cut.
      assert byte_size(workpad) > cap
      head_cut = :binary.part(workpad, 0, cap)
      refute head_cut =~ "TAIL-FINDING",
             "test precondition: naive head-cut must NOT include the tail finding"
      refute head_cut =~ "Verdict: findings",
             "test precondition: naive head-cut must slice away the verdict line"

      # New truncator: drops notes blocks first, preserves Plan + latest Code Review.
      result = WorkpadParser.truncate_preserving_sections(workpad, cap)

      assert result =~ "TAIL-FINDING",
             "section-aware truncator must preserve tail finding where head-cut would slice it"
      assert result =~ "Verdict: findings"
      assert result =~ "[plan-1] Core"
    end

    test "result byte_size is ALWAYS <= max_bytes (hard cap invariant)" do
      # Iter6 Codex HIGH: elision markers and section wrappers previously
      # weren't counted in the budget, so `truncate_preserving_sections(text, N)`
      # could return > N bytes — defeating the whole point of a byte cap.
      # Property: for any input/cap combo, output byte_size MUST be <= cap.

      cases = [
        # No headings — preamble-only fallback. Cap smaller than marker.
        {String.duplicate("A", 500), 10},
        # No headings — preamble-only fallback. Marker fits.
        {String.duplicate("A", 500), 200},
        # Plan + Code Review combined exceed a tiny cap.
        {"### Plan\n- [x] [plan-1] a\n### Code Review\nVerdict: clean\n", 40},
        # Multiple sections with notes, tight cap.
        {"### Plan\n- [x] [plan-1] x\n### Notes\n#### [plan-1] old\n\n#### [plan-2] new\n### Code Review\nVerdict: findings\n",
         60}
      ]

      for {input, cap} <- cases do
        result = WorkpadParser.truncate_preserving_sections(input, cap)

        assert byte_size(result) <= cap,
               "input size=#{byte_size(input)}, cap=#{cap}, result size=#{byte_size(result)} exceeds cap"
      end
    end

    test "drops oldest continuation notes first, preserving the most recent" do
      continuation_block =
        Enum.map_join(1..10, "\n\n", fn i ->
          "#### [plan-#{i}] continuation\n- files touched: a/b/c.ex\n- key decision: decision #{i}\n- watch out: nothing"
        end)

      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done

      ### Notes
      #{continuation_block}
      """

      result = WorkpadParser.truncate_preserving_sections(workpad, 800)

      # Most recent continuation survives; oldest goes first
      assert result =~ "[plan-10] continuation"
      refute result =~ "decision 1\n"
    end

    test "never leaves a section heading without body content" do
      # Degenerate case: if truncation lands in the middle of a section,
      # either the whole section is kept or the whole section is dropped.
      workpad = """
      ## Codex Workpad

      ### Plan
      - [x] [plan-1] Done

      ### Notes
      - some note

      ### Code Review
      - Verdict: clean
      """

      # Force a tight budget
      result = WorkpadParser.truncate_preserving_sections(workpad, 120)

      # No orphan headings: every ### heading that survives must have
      # a non-empty body below it before the next heading or EOF.
      refute result =~ ~r/###[^\n]*\n\s*(?:###|\z)/
    end

    test "handles nil gracefully (upstream caller may pass nil when no workpad)" do
      assert nil == WorkpadParser.truncate_preserving_sections(nil, 100)
    end
  end

  describe "code_review_verdict/1 — warm-session loop gate" do
    # The warm-session review loop's closeout reads the Verdict: line from the
    # LATEST ### Code Review section to decide whether to loop back to implement
    # (findings) or advance to doc_fix/handoff (clean). Parsing must be
    # tolerant of whitespace/case, and honour the latest round when the agent
    # appended rather than rewrote.

    test "returns :missing when no ### Code Review section exists" do
      workpad = """
      ### Plan
      - [x] [plan-1] Done
      """

      assert :missing = WorkpadParser.code_review_verdict(workpad)
    end

    test "returns :invalid when section exists but has no Verdict: line" do
      workpad = """
      ### Code Review
      - Looked at the diff. Nothing to flag.
      """

      assert :invalid = WorkpadParser.code_review_verdict(workpad)
    end

    test "extracts Verdict: clean" do
      workpad = """
      ### Code Review
      - Reviewed SHA: abc123
      - Findings: none
      - Verdict: clean
      """

      assert "clean" = WorkpadParser.code_review_verdict(workpad)
    end

    test "extracts Verdict: findings" do
      workpad = """
      ### Code Review
      - Reviewed SHA: abc123
      - Findings: 2 HIGH
      - Verdict: findings
      """

      assert "findings" = WorkpadParser.code_review_verdict(workpad)
    end

    test "is case-insensitive on the verdict value" do
      workpad = """
      ### Code Review
      - Verdict: CLEAN
      """

      assert "clean" = WorkpadParser.code_review_verdict(workpad)
    end

    test "returns the LATEST verdict when multiple rounds accumulated in one section" do
      workpad = """
      ### Code Review
      - Reviewed SHA: old_sha
      - Verdict: findings

      - Reviewed SHA: new_sha
      - Verdict: clean
      """

      assert "clean" = WorkpadParser.code_review_verdict(workpad)
    end

    test "returns :invalid on unrecognized verdict strings (fail closed)" do
      workpad = """
      ### Code Review
      - Verdict: looks ok
      """

      assert :invalid = WorkpadParser.code_review_verdict(workpad)
    end

    test "returns :missing on nil / empty input" do
      assert :missing = WorkpadParser.code_review_verdict(nil)
      assert :missing = WorkpadParser.code_review_verdict("")
    end

    test "returns LATEST verdict when the workpad has two sibling ### Code Review sections" do
      # If the agent appends a whole new `### Code Review` section on each
      # round (rather than adding rounds inside one section — both are
      # plausible prompt interpretations), the parser MUST read the newest
      # sibling. Otherwise the orchestrator gates on a stale verdict from
      # the first round and either dispatches a fix the agent already made
      # or wedges the cycle.
      workpad = """
      ## Codex Workpad

      ### Code Review
      Reviewed SHA: aaaaaaa
      Verdict: findings
      Findings: 1 HIGH

      ### Code Review
      Reviewed SHA: bbbbbbb
      Verdict: clean
      Findings: none
      """

      assert "clean" = WorkpadParser.code_review_verdict(workpad)
    end

    test "trailing punctuation (`Verdict: findings.`) fails closed to :invalid" do
      # Strict schema: Verdict line must be exactly `clean` or `findings`.
      # A cosmetic period triggers retry, but that's cheap compared to the
      # alternative — lenient parsing that silently accepts malformed
      # verdicts and lets a handoff fire on stale review state.
      workpad = """
      ### Code Review
      Reviewed SHA: abc123
      Verdict: findings.
      """

      assert :invalid = WorkpadParser.code_review_verdict(workpad)
    end

    test "accepts mixed-case FINDINGS / CLEAN as case-insensitive match" do
      workpad_upper = """
      ### Code Review
      Reviewed SHA: abc
      Verdict: FINDINGS
      """

      workpad_mixed = """
      ### Code Review
      Reviewed SHA: abc
      Verdict: Clean
      """

      assert "findings" = WorkpadParser.code_review_verdict(workpad_upper)
      assert "clean" = WorkpadParser.code_review_verdict(workpad_mixed)
    end
  end

  describe "code_review_reviewed_sha/1" do
    test "extracts a plain sha on its own line" do
      workpad = """
      ### Code Review
      Reviewed SHA: abc1234def5678
      Verdict: clean
      """

      assert "abc1234def5678" = WorkpadParser.code_review_reviewed_sha(workpad)
    end

    test "strips surrounding backticks — common Markdown habit from LLM agents" do
      # Iter4 Codex finding: agents often wrap the SHA in code ticks. A naive
      # \\S+ capture would include backticks and break closeout's prefix
      # match against current HEAD, forcing a spurious retry.
      workpad = """
      ### Code Review
      Reviewed SHA: `abc1234def5678`
      Verdict: clean
      """

      assert "abc1234def5678" = WorkpadParser.code_review_reviewed_sha(workpad)
    end

    test "strips parens and brackets" do
      assert "abcdef1" = WorkpadParser.code_review_reviewed_sha("### Code Review\nReviewed SHA: (abcdef1)\nVerdict: clean\n")
      assert "abcdef1" = WorkpadParser.code_review_reviewed_sha("### Code Review\nReviewed SHA: [abcdef1]\nVerdict: clean\n")
    end

    test "is case-insensitive on the heading AND normalizes sha to lowercase" do
      workpad = """
      ### Code Review
      Reviewed SHA: ABCDEF1
      """

      assert "abcdef1" = WorkpadParser.code_review_reviewed_sha(workpad)
    end

    test "returns :invalid when section exists but no parseable Reviewed SHA" do
      workpad = """
      ### Code Review
      Verdict: clean
      """

      assert :invalid = WorkpadParser.code_review_reviewed_sha(workpad)
    end

    test "returns :missing when no ### Code Review section" do
      assert :missing = WorkpadParser.code_review_reviewed_sha("### Plan\n- [x] [plan-1] Done\n")
      assert :missing = WorkpadParser.code_review_reviewed_sha(nil)
      assert :missing = WorkpadParser.code_review_reviewed_sha("")
    end

    test "returns LATEST Reviewed SHA across multiple sibling sections" do
      workpad = """
      ### Code Review
      Reviewed SHA: aaaaaaa
      Verdict: findings

      ### Code Review
      Reviewed SHA: bbbbbbb
      Verdict: clean
      """

      assert "bbbbbbb" = WorkpadParser.code_review_reviewed_sha(workpad)
    end
  end

end
