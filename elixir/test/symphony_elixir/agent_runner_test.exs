defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

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

  # ---------- build_unit_prompt_for_dispatch — end-to-end seam ----------
  #
  # The helper-only tests above would pass even if the CALL to
  # `maybe_attach_current_subtask_contract` were deleted from
  # `execute_unit`. These seam tests pin the whole enrichment→render
  # chain so a future merge conflict that drops an enrichment step
  # breaks the test.

  describe "build_unit_prompt_for_dispatch/4 (full pipeline seam)" do
    @seam_workpad """
    ## Codex Workpad

    ### Plan
    - [ ] [plan-1] Wire the border detector
      - touch: apps/web/lib/border.ts
      - accept: pnpm --dir apps/web test:unit -- border
    """

    test "plan-N unit produces prompt with contract block (regression guard for --ours wiring loss)" do
      workspace = seam_workspace!()
      on_exit(fn -> File.rm_rf(Path.dirname(workspace)) end)

      unit = %SymphonyElixir.Unit{
        kind: :implement_subtask,
        subtask_id: "plan-1",
        subtask_text: "Wire the border detector",
        display_name: "implement plan-1"
      }

      issue = %SymphonyElixir.Linear.Issue{identifier: "ENT-1", title: "wire border"}

      {prompt, enriched_opts} =
        SymphonyElixir.AgentRunner.build_unit_prompt_for_dispatch(
          workspace,
          issue,
          unit,
          workpad_text: @seam_workpad
        )

      # The whole point: prompt must carry the contract. If someone deletes
      # the maybe_attach_current_subtask_contract step from the seam, this
      # fails.
      assert prompt =~ "<subtask_contract>"
      assert prompt =~ "touch: apps/web/lib/border.ts"
      assert prompt =~ "accept: pnpm --dir apps/web test:unit -- border"

      # Seam must return enriched opts so downstream Closeout sees
      # :current_subtask (and :dispatch_head when applicable).
      assert Keyword.has_key?(enriched_opts, :current_subtask)
    end

    test "rework-* unit does NOT get contract block, even with a matching workpad" do
      workspace = seam_workspace!()
      on_exit(fn -> File.rm_rf(Path.dirname(workspace)) end)

      # Workpad includes an entry that would match "rework-1" if the skip
      # were bypassed. If regular_implement_subtask_id? ever inverts, this
      # test fails.
      workpad = """
      ## Codex Workpad

      ### Plan
      - [ ] [rework-1] Bogus rework plan entry
        - touch: should/not/leak.ts
        - accept: should not appear in prompt
      """

      unit = %SymphonyElixir.Unit{
        kind: :implement_subtask,
        subtask_id: "rework-1",
        subtask_text: "rework sample",
        display_name: "rework-1"
      }

      issue = %SymphonyElixir.Linear.Issue{identifier: "ENT-2", title: "rework"}

      {prompt, _opts} =
        SymphonyElixir.AgentRunner.build_unit_prompt_for_dispatch(
          workspace,
          issue,
          unit,
          workpad_text: workpad
        )

      refute prompt =~ "<subtask_contract>"
      refute prompt =~ "should/not/leak.ts"
    end
  end

  defp seam_workspace! do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-seam-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "workspace"))
    Path.join(root, "workspace")
  end
end
