defmodule SymphonyElixir.PromptBuilderUnitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{PromptBuilder, Unit}

  @issue %{identifier: "ENT-42", title: "Add border detection", state: "In Progress"}

  describe "build_unit_prompt/3" do
    test "bootstrap prompt contains bootstrap instructions" do
      prompt = PromptBuilder.build_unit_prompt(@issue, Unit.bootstrap())
      assert prompt =~ "Bootstrap"
      assert prompt =~ "ENT-42"
      assert prompt =~ "Do NOT write a plan"
    end

    test "plan prompt contains plan instructions" do
      prompt = PromptBuilder.build_unit_prompt(@issue, Unit.plan())
      assert prompt =~ "Plan"
      assert prompt =~ "### Plan"
      assert prompt =~ "[plan-1]"
      assert prompt =~ "Do NOT implement"
    end

    test "implement_subtask prompt is focused on one subtask" do
      unit = Unit.implement_subtask("plan-2", "Integrate into EditorScreen")
      prompt = PromptBuilder.build_unit_prompt(@issue, unit)
      assert prompt =~ "plan-2"
      assert prompt =~ "Integrate into EditorScreen"
      assert prompt =~ "one subtask only"
      assert prompt =~ "Do NOT touch other subtasks"
      assert prompt =~ "orchestrator dispatches one subtask"
    end

    test "implement_subtask prompt includes stdin guardrail" do
      unit = Unit.implement_subtask("plan-1")
      prompt = PromptBuilder.build_unit_prompt(@issue, unit)
      assert prompt =~ "/dev/null"
    end

    test "doc_fix prompt is docs-only" do
      prompt = PromptBuilder.build_unit_prompt(@issue, Unit.doc_fix())
      assert prompt =~ "Doc Fix"
      assert prompt =~ "AGENTS.md"
      assert prompt =~ "Do NOT change functional code"
    end

    test "verify prompt delegates to orchestrator" do
      prompt = PromptBuilder.build_unit_prompt(@issue, Unit.verify())
      assert prompt =~ "Verify"
      assert prompt =~ "orchestrator"
      assert prompt =~ "Do NOT run validation"
    end

    test "handoff prompt requires results and PR" do
      prompt = PromptBuilder.build_unit_prompt(@issue, Unit.handoff())
      assert prompt =~ "Handoff"
      assert prompt =~ "Results"
      assert prompt =~ "Human Review"
      assert prompt =~ "Do NOT write new functional code"
    end

    test "merge prompt is a safety-net fallback (merge is programmatic)" do
      prompt = PromptBuilder.build_unit_prompt(@issue, Unit.merge())
      assert prompt =~ "Merge"
      assert prompt =~ "gh pr merge"
      assert prompt =~ "Done"
    end

    test "prompts are reasonably sized (not monolithic)" do
      for unit <- [Unit.bootstrap(), Unit.plan(), Unit.implement_subtask("plan-1"),
                   Unit.doc_fix(), Unit.verify(), Unit.handoff(), Unit.merge()] do
        prompt = PromptBuilder.build_unit_prompt(@issue, unit)
        # Each unit prompt should be under 2000 chars (focused, not monolithic)
        assert String.length(prompt) < 2000,
          "#{unit.display_name} prompt too long: #{String.length(prompt)} chars"
      end
    end
  end
end
