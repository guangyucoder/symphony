defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  test "continuation prompt contains yield and phase-aware language" do
    # build_turn_prompt is private, so test via the public interface behavior.
    # We verify the prompt content by checking what the fake codex receives.

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-yield-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-yield")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-yield.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      # Fake codex that handles 2 turns:
      # Turn 1: initialize, thread/start, turn/start, turn/completed
      # Between turns: compact (id=5)
      # Turn 2: turn/start, turn/completed
      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-yield.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-yield-1"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          4)
            printf '%s\\n' '{"id":5,"result":{"status":"completed"}}'
            printf '%s\\n' '{"method":"thread/compacted","params":{}}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never",
        codex_thread_sandbox: "danger-full-access",
        codex_turn_sandbox_policy: %{type: "dangerFullAccess", networkAccess: true},
        codex_compact_between_turns: true,
        max_turns: 5,
        prompt: "You are a test agent."
      )

      issue = %Issue{
        id: "issue-yield",
        identifier: "MT-yield",
        title: "Test yield behavior",
        description: "Verify multi-turn with compact",
        state: "In Progress",
        url: "https://example.org/issues/MT-yield",
        labels: []
      }

      # Use a custom issue_state_fetcher that returns "In Progress" for turn 1,
      # then "Done" for turn 2 (simulates agent completing work in turn 2)
      call_count = :counters.new(1, [:atomics])

      issue_state_fetcher = fn [_issue_id] ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count <= 1 do
          # After turn 1: still active → triggers continuation
          {:ok, [%Issue{issue | state: "In Progress"}]}
        else
          # After turn 2: done
          {:ok, [%Issue{issue | state: "Done"}]}
        end
      end

      assert :ok =
               AgentRunner.run(issue, nil,
                 max_turns: 5,
                 issue_state_fetcher: issue_state_fetcher
               )

      # Verify the trace shows 2 turns + 1 compact
      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      json_payloads =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(fn line ->
          line |> String.trim_leading("JSON:") |> Jason.decode!()
        end)

      # Turn 1 prompt (turn/start with the full prompt)
      turn_starts =
        Enum.filter(json_payloads, fn p -> p["method"] == "turn/start" end)

      assert length(turn_starts) == 2, "Expected 2 turn/start messages, got #{length(turn_starts)}"

      # Turn 2 prompt should contain continuation guidance with yield language
      turn_2_prompt =
        turn_starts
        |> List.last()
        |> get_in(["params", "input"])
        |> List.first()
        |> Map.get("text")

      assert turn_2_prompt =~ "Continuation guidance"
      assert turn_2_prompt =~ "Yield Policy"
      assert turn_2_prompt =~ "workpad"

      # Compact was called between turns
      compacts =
        Enum.filter(json_payloads, fn p -> p["method"] == "thread/compact/start" end)

      assert length(compacts) == 1, "Expected 1 compact call, got #{length(compacts)}"

      assert get_in(List.first(compacts), ["params", "threadId"]) == "thread-yield-1"
    after
      File.rm_rf(test_root)
    end
  end

  test "compact is skipped when compact_between_turns is false" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-no-compact-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-nocompact")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-nocompact.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      # Fake codex: 2 turns, NO compact expected
      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-nocompact.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-nocompact"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never",
        codex_thread_sandbox: "danger-full-access",
        codex_turn_sandbox_policy: %{type: "dangerFullAccess", networkAccess: true},
        codex_compact_between_turns: false,
        max_turns: 5,
        prompt: "You are a test agent."
      )

      issue = %Issue{
        id: "issue-nocompact",
        identifier: "MT-nocompact",
        title: "Test no compact",
        description: "Verify compact is skipped when disabled",
        state: "In Progress",
        url: "https://example.org/issues/MT-nocompact",
        labels: []
      }

      call_count = :counters.new(1, [:atomics])

      issue_state_fetcher = fn [_issue_id] ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count <= 1 do
          {:ok, [%Issue{issue | state: "In Progress"}]}
        else
          {:ok, [%Issue{issue | state: "Done"}]}
        end
      end

      assert :ok =
               AgentRunner.run(issue, nil,
                 max_turns: 5,
                 issue_state_fetcher: issue_state_fetcher
               )

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      json_payloads =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(fn line ->
          line |> String.trim_leading("JSON:") |> Jason.decode!()
        end)

      # 2 turns ran
      turn_starts =
        Enum.filter(json_payloads, fn p -> p["method"] == "turn/start" end)

      assert length(turn_starts) == 2

      # No compact calls
      compacts =
        Enum.filter(json_payloads, fn p -> p["method"] == "thread/compact/start" end)

      assert compacts == [], "Expected no compact calls when disabled, got #{length(compacts)}"
    after
      File.rm_rf(test_root)
    end
  end
end
