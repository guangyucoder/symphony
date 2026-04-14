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

  test "unit_lite merge dispatch still runs before_run after after_create" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-unit-lite-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      before_run_counter = Path.join(test_root, "before_run.count")

      init_git_repo!(template_repo, %{"tracked.txt" => "tracked\n"})

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        execution_mode: "unit_lite",
        hook_after_create: "git clone #{template_repo} .",
        hook_before_run: "test -f tracked.txt\necho call >> \"#{before_run_counter}\""
      )

      issue = %Issue{
        id: "issue-unit-lite-hooks",
        identifier: "MT-unit-lite-hooks",
        title: "Verify unit-lite hook order",
        description: "Ensure before_run still fires for merge dispatches.",
        state: "Merging",
        url: "https://example.org/issues/MT-unit-lite-hooks",
        labels: []
      }

      assert :ok =
               AgentRunner.run_unit_lite(issue, nil,
                 pr_checker: fn _workspace -> :open end,
                 ci_checker: fn _workspace -> :pending end,
                 workpad_text: "merge fast path"
               )

      assert count_lines(before_run_counter) == 1
    after
      File.rm_rf(test_root)
    end
  end

  test "unit_lite: before_run failure short-circuits dispatch and does NOT fire after_run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-before-run-fail-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      after_run_counter = Path.join(test_root, "after_run.count")

      init_git_repo!(template_repo, %{"tracked.txt" => "tracked\n"})

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        execution_mode: "unit_lite",
        hook_after_create: "git clone #{template_repo} .",
        hook_before_run: "exit 1",
        hook_after_run: "echo call >> \"#{after_run_counter}\""
      )

      issue = %Issue{
        id: "issue-before-run-fail",
        identifier: "MT-before-run-fail",
        title: "Hook failure short-circuit",
        description: "before_run exits non-zero; after_run must NOT fire.",
        state: "Merging",
        url: "https://example.org/issues/MT-before-run-fail",
        labels: []
      }

      assert_raise RuntimeError, ~r/unit_lite run failed/, fn ->
        AgentRunner.run_unit_lite(issue, nil,
          pr_checker: fn _workspace -> :open end,
          ci_checker: fn _workspace -> :pending end,
          workpad_text: "merge fast path"
        )
      end

      # The dispatch never actually started, so cleanup hooks must not have fired.
      refute File.exists?(after_run_counter),
             "after_run hook fired despite before_run failure — a cleanup hook would be lying about the dispatch state"
    after
      File.rm_rf(test_root)
    end
  end

  test "legacy run does not prepare an existing workspace before before_run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-legacy-prepare-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      before_run_counter = Path.join(test_root, "before_run.count")

      init_git_repo!(template_repo, %{"tracked.txt" => "tracked\n"})

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-legacy"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-legacy"}}}'
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
        execution_mode: "legacy",
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never",
        codex_thread_sandbox: "danger-full-access",
        codex_turn_sandbox_policy: %{type: "dangerFullAccess", networkAccess: true},
        hook_after_create: "git clone #{template_repo} .",
        hook_before_run:
          "grep -q 'dirty tracked change' tracked.txt\n" <>
            "test -f local-progress.txt\n" <>
            "test -f .symphony_session.json\n" <>
            "echo call >> \"#{before_run_counter}\"",
        max_turns: 1,
        prompt: "You are a test agent."
      )

      issue = %Issue{
        id: "issue-legacy-prepare",
        identifier: "MT-legacy-prepare",
        title: "Verify legacy run preserves workspace state",
        description: "Legacy run should not call prepare_for_dispatch.",
        state: "In Progress",
        url: "https://example.org/issues/MT-legacy-prepare",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      tracked_file = Path.join(workspace, "tracked.txt")
      local_progress = Path.join(workspace, "local-progress.txt")
      session_meta = Path.join(workspace, ".symphony_session.json")

      File.write!(tracked_file, "dirty tracked change\n")
      File.write!(local_progress, "keep me\n")
      File.write!(session_meta, ~s({"thread_id":"legacy-thread"}) <> "\n")

      assert :ok =
               AgentRunner.run(issue, nil,
                 max_turns: 1,
                 issue_state_fetcher: fn [_issue_id] ->
                   {:ok, [%Issue{issue | state: "Done"}]}
                 end
               )

      assert count_lines(before_run_counter) == 1
      assert File.read!(tracked_file) == "dirty tracked change\n"
      assert File.read!(local_progress) == "keep me\n"
      assert File.exists?(session_meta)
      assert %{"thread_id" => "thread-legacy"} = Jason.decode!(File.read!(session_meta))
    after
      File.rm_rf(test_root)
    end
  end

  defp init_git_repo!(repo, files) do
    File.mkdir_p!(repo)

    Enum.each(files, fn {path, contents} ->
      full_path = Path.join(repo, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, contents)
    end)

    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "initial"])
    repo
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, status} ->
        flunk("git #{Enum.join(args, " ")} failed with status #{status}: #{output}")
    end
  end

  defp count_lines(path) do
    case File.read(path) do
      {:ok, contents} -> contents |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  # ---------- subtask contract wiring (regression for silent --ours drop) ----------

  describe "maybe_attach_current_subtask_contract/2" do
    @workpad_with_contract """
    ## Codex Workpad

    ### Plan
    - [ ] [plan-1] Wire the border detector
      - touch: apps/web/lib/border.ts, apps/web/lib/foo.ts
      - accept: pnpm --dir apps/web test:unit -- border
    - [ ] [plan-2] Integrate into Editor
      - touch: apps/web/components/Editor.tsx
      - accept: manual smoke on /scan
    """

    test "attaches :current_subtask for a regular implement_subtask and PromptBuilder renders the contract block" do
      unit = %SymphonyElixir.Unit{
        kind: :implement_subtask,
        subtask_id: "plan-1",
        subtask_text: "Wire the border detector",
        display_name: "implement plan-1"
      }

      opts =
        SymphonyElixir.AgentRunner.maybe_attach_current_subtask_contract(unit,
          workpad_text: @workpad_with_contract
        )

      current = Keyword.get(opts, :current_subtask)
      assert is_map(current)
      assert current.id == "plan-1"
      assert current.touch == ["apps/web/lib/border.ts", "apps/web/lib/foo.ts"]
      assert current.accept == "pnpm --dir apps/web test:unit -- border"

      issue = %SymphonyElixir.Linear.Issue{identifier: "ENT-1", title: "wire border"}
      prompt = SymphonyElixir.PromptBuilder.build_unit_prompt(issue, unit, opts)

      assert prompt =~ "<subtask_contract>"
      assert prompt =~ "touch: apps/web/lib/border.ts, apps/web/lib/foo.ts"
      assert prompt =~ "accept: pnpm --dir apps/web test:unit -- border"
    end

    test "does not attach contract for rework-* / verify-fix-* / merge-sync-* subtasks" do
      for prefix <- ["rework-", "verify-fix-", "merge-sync-"] do
        unit = %SymphonyElixir.Unit{
          kind: :implement_subtask,
          subtask_id: prefix <> "1",
          subtask_text: "",
          display_name: prefix <> "1"
        }

        opts =
          SymphonyElixir.AgentRunner.maybe_attach_current_subtask_contract(
            unit,
            workpad_text: @workpad_with_contract
          )

        refute Keyword.has_key?(opts, :current_subtask),
               "expected no :current_subtask for #{prefix} unit, got #{inspect(opts)}"
      end
    end

    test "returns opts unchanged when workpad is absent, malformed, or subtask id not in plan" do
      plan_unit = %SymphonyElixir.Unit{
        kind: :implement_subtask,
        subtask_id: "plan-99",
        subtask_text: "missing from plan",
        display_name: "implement plan-99"
      }

      assert SymphonyElixir.AgentRunner.maybe_attach_current_subtask_contract(plan_unit, []) == []

      opts =
        SymphonyElixir.AgentRunner.maybe_attach_current_subtask_contract(plan_unit,
          workpad_text: @workpad_with_contract
        )

      refute Keyword.has_key?(opts, :current_subtask)

      opts =
        SymphonyElixir.AgentRunner.maybe_attach_current_subtask_contract(plan_unit,
          workpad_text: "no plan section here"
        )

      refute Keyword.has_key?(opts, :current_subtask)
    end
  end
end
