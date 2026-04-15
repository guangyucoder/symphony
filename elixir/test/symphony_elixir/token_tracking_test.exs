defmodule SymphonyElixir.TokenTrackingTest do
  @moduledoc """
  Tests that token tracking correctly extracts usage from Codex on_message events.
  The message format is set by AppServer.emit_message/4 → maybe_set_usage/2.
  """
  use ExUnit.Case, async: true

  # Simulate what AppServer.emit_message produces
  defp make_codex_message(usage) do
    base = %{
      event: :turn_completed,
      timestamp: DateTime.utc_now(),
      payload: %{"method" => "turn/completed"},
      raw: "{}",
      details: %{}
    }

    if usage, do: Map.put(base, :usage, usage), else: base
  end

  # We can't call track_unit_tokens directly (it's private), but we can test
  # the full token_tracking_handler closure pattern from execute_unit
  # Replicate the full extraction logic from agent_runner.ex
  defp track_and_read(messages) do
    counter = :counters.new(3, [:atomics])

    for msg <- messages do
      usage = extract_usage_from_message(msg)

      if is_map(usage) do
        input = first_integer(usage, ["inputTokens", "input_tokens", "prompt_tokens", :inputTokens, :input_tokens])
        output = first_integer(usage, ["outputTokens", "output_tokens", "completion_tokens", :outputTokens, :output_tokens])
        total = first_integer(usage, ["totalTokens", "total_tokens", "total", :totalTokens, :total_tokens, :total])

        if is_integer(input) and input > 0, do: :counters.put(counter, 1, input)
        if is_integer(output) and output > 0, do: :counters.put(counter, 2, output)
        if is_integer(total) and total > 0, do: :counters.put(counter, 3, total)
      end
    end

    %{
      input_tokens: :counters.get(counter, 1),
      output_tokens: :counters.get(counter, 2),
      total_tokens: :counters.get(counter, 3)
    }
  end

  defp extract_usage_from_message(msg) do
    dig(msg, [:payload, "params", "tokenUsage", "total"]) ||
      dig(msg, [:payload, "tokenUsage", "total"]) ||
      dig(msg, ["params", "tokenUsage", "total"]) ||
      Map.get(msg, :usage) ||
      Map.get(msg, "usage") ||
      dig(msg, [:payload, "usage"])
  end

  defp dig(map, []) when is_map(map), do: map

  defp dig(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nil -> nil
      val -> dig(val, rest)
    end
  end

  defp dig(_, _), do: nil

  defp first_integer(map, keys) when is_map(map) do
    Enum.find_value(keys, fn k ->
      case Map.get(map, k) do
        v when is_integer(v) -> v
        _ -> nil
      end
    end)
  end

  describe "token tracking from Codex events" do
    test "extracts usage with string keys (inputTokens/outputTokens/totalTokens)" do
      msg = make_codex_message(%{"inputTokens" => 1500, "outputTokens" => 300, "totalTokens" => 1800})
      result = track_and_read([msg])

      assert result.input_tokens == 1500
      assert result.output_tokens == 300
      assert result.total_tokens == 1800
    end

    test "extracts usage with snake_case string keys" do
      msg = make_codex_message(%{"input_tokens" => 2000, "output_tokens" => 500, "total_tokens" => 2500})
      result = track_and_read([msg])

      assert result.input_tokens == 2000
      assert result.output_tokens == 500
      assert result.total_tokens == 2500
    end

    test "extracts usage with atom keys" do
      msg = make_codex_message(%{inputTokens: 100, outputTokens: 50, totalTokens: 150})
      result = track_and_read([msg])

      assert result.input_tokens == 100
      assert result.output_tokens == 50
      assert result.total_tokens == 150
    end

    test "cumulative values: last message wins (put, not add)" do
      msg1 = make_codex_message(%{"inputTokens" => 500, "outputTokens" => 100, "totalTokens" => 600})
      msg2 = make_codex_message(%{"inputTokens" => 1500, "outputTokens" => 300, "totalTokens" => 1800})
      result = track_and_read([msg1, msg2])

      # Should reflect the LAST (cumulative) value, not sum
      assert result.input_tokens == 1500
      assert result.output_tokens == 300
      assert result.total_tokens == 1800
    end

    test "no usage in message → zeros" do
      msg = make_codex_message(nil)
      result = track_and_read([msg])

      assert result.input_tokens == 0
      assert result.output_tokens == 0
      assert result.total_tokens == 0
    end

    test "empty usage map → zeros" do
      msg = make_codex_message(%{})
      result = track_and_read([msg])

      assert result.input_tokens == 0
      assert result.output_tokens == 0
      assert result.total_tokens == 0
    end

    test "extracts from Codex thread/tokenUsage/updated event (real format)" do
      # This is the actual structure from Codex app-server protocol v2
      msg = %{
        event: :notification,
        timestamp: DateTime.utc_now(),
        payload: %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{
            "threadId" => "t-123",
            "turnId" => "turn-1",
            "tokenUsage" => %{
              "total" => %{
                "inputTokens" => 5000,
                "outputTokens" => 1200,
                "totalTokens" => 6200,
                "cachedInputTokens" => 800,
                "reasoningOutputTokens" => 300
              },
              "last" => %{
                "inputTokens" => 2000,
                "outputTokens" => 500,
                "totalTokens" => 2500,
                "cachedInputTokens" => 100,
                "reasoningOutputTokens" => 100
              }
            }
          }
        },
        raw: "{}",
        details: %{}
      }

      result = track_and_read([msg])

      # Should pick up the "total" breakdown
      assert result.input_tokens == 5000
      assert result.output_tokens == 1200
      assert result.total_tokens == 6200
    end

    test "mixed events: only usage-bearing messages update counters" do
      msg_no_usage = make_codex_message(nil)
      msg_with_usage = make_codex_message(%{"inputTokens" => 800, "outputTokens" => 200, "totalTokens" => 1000})
      msg_no_usage_2 = make_codex_message(nil)
      result = track_and_read([msg_no_usage, msg_with_usage, msg_no_usage_2])

      assert result.input_tokens == 800
      assert result.total_tokens == 1000
    end
  end
end
