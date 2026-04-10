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
      assert Enum.at(subtasks, 0) == %{id: "plan-1", text: "Add BorderDetector component", done: true}
      assert Enum.at(subtasks, 1) == %{id: "plan-2", text: "Integrate into EditorScreen", done: false}
      assert Enum.at(subtasks, 2) == %{id: "plan-3", text: "Add unit tests", done: false}
    end

    test "parses workpad without explicit IDs, falls back to positional" do
      {:ok, subtasks} = WorkpadParser.parse(@workpad_without_ids)

      assert length(subtasks) == 3
      assert Enum.at(subtasks, 0).id == "plan-1"
      assert Enum.at(subtasks, 1).id == "plan-2"
      assert Enum.at(subtasks, 2).id == "plan-3"
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
end
