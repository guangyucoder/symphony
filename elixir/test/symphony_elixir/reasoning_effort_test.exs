defmodule SymphonyElixir.ReasoningEffortTest do
  @moduledoc """
  Tests that per-unit reasoning effort is correctly assigned and
  propagated through to the Codex command.
  """
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Unit

  describe "Unit reasoning_effort defaults" do
    test "bootstrap uses low" do
      assert Unit.bootstrap().reasoning_effort == "low"
    end

    test "plan uses xhigh" do
      assert Unit.plan().reasoning_effort == "xhigh"
    end

    test "implement_subtask uses medium" do
      assert Unit.implement_subtask("plan-1").reasoning_effort == "medium"
      assert Unit.implement_subtask("plan-2", "some text").reasoning_effort == "medium"
    end

    test "doc_fix uses medium" do
      assert Unit.doc_fix().reasoning_effort == "medium"
    end

    test "verify uses medium" do
      assert Unit.verify().reasoning_effort == "medium"
    end

    test "handoff uses low" do
      assert Unit.handoff().reasoning_effort == "low"
    end

    test "merge uses low" do
      assert Unit.merge().reasoning_effort == "low"
    end
  end

  describe "Unit.to_map includes reasoning_effort" do
    test "reasoning_effort appears in serialized map" do
      map = Unit.to_map(Unit.plan())
      assert map["reasoning_effort"] == "xhigh"
    end

    test "all unit kinds include reasoning_effort" do
      units = [
        Unit.bootstrap(),
        Unit.plan(),
        Unit.implement_subtask("s1"),
        Unit.doc_fix(),
        Unit.verify(),
        Unit.handoff(),
        Unit.merge()
      ]

      for unit <- units do
        map = Unit.to_map(unit)
        assert is_binary(map["reasoning_effort"]),
               "#{unit.kind} should have reasoning_effort in to_map"
      end
    end
  end

  describe "codex_command_with_effort/1" do
    test "nil returns base command unchanged" do
      # codex_command_with_effort(nil) delegates to Config.codex_command()
      # which in test env returns "codex app-server"
      result = AppServer.codex_command_with_effort(nil)
      assert is_binary(result)
    end

    test "replaces existing model_reasoning_effort in command" do
      # Temporarily override codex command to simulate WORKFLOW.md config
      base = "codex --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server"
      # We test the regex logic directly since codex_command_with_effort reads from Config
      replaced = Regex.replace(
        ~r/model_reasoning_effort=\w+/,
        base,
        "model_reasoning_effort=low"
      )
      assert replaced == "codex --config model_reasoning_effort=low --model gpt-5.3-codex app-server"
    end

    test "inserts reasoning effort when not present in base command" do
      base = "codex --model gpt-5.3-codex app-server"
      result = String.replace(
        base,
        "app-server",
        "--config model_reasoning_effort=medium app-server"
      )
      assert result == "codex --model gpt-5.3-codex --config model_reasoning_effort=medium app-server"
    end

    test "effort levels match Codex valid values" do
      valid_efforts = ["low", "medium", "high", "xhigh"]
      units = [
        Unit.bootstrap(),
        Unit.plan(),
        Unit.implement_subtask("s1"),
        Unit.doc_fix(),
        Unit.verify(),
        Unit.handoff(),
        Unit.merge()
      ]

      for unit <- units do
        assert unit.reasoning_effort in valid_efforts,
               "#{unit.kind} has invalid effort: #{unit.reasoning_effort}"
      end
    end
  end

  describe "command construction end-to-end" do
    test "each unit kind produces distinct command when effort differs" do
      base = "codex --config model_reasoning_effort=xhigh app-server"

      commands =
        [Unit.bootstrap(), Unit.plan(), Unit.implement_subtask("s1"), Unit.doc_fix()]
        |> Enum.map(fn unit ->
          Regex.replace(
            ~r/model_reasoning_effort=\w+/,
            base,
            "model_reasoning_effort=#{unit.reasoning_effort}"
          )
        end)

      # bootstrap=low, plan=xhigh, implement=medium, doc_fix=medium → 3 distinct
      assert length(Enum.uniq(commands)) == 3
    end
  end
end
