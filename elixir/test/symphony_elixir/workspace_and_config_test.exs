defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  import ExUnit.CaptureLog
  alias SymphonyElixir.Linear.Client

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace reuses existing issue directory while clearing local transient dirs and caches" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.mkdir_p!(Path.join(first_workspace, ".elixir_ls"))
      File.mkdir_p!(Path.join([first_workspace, "apps", "web", ".next"]))
      File.mkdir_p!(Path.join([first_workspace, "node_modules", ".cache"]))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")
      File.write!(Path.join([first_workspace, ".elixir_ls", "project.plt"]), "remove me too\n")
      File.write!(Path.join([first_workspace, "apps", "web", ".next", "build.txt"]), "remove me too\n")
      File.write!(Path.join([first_workspace, "node_modules", ".cache", "bundler.txt"]), "remove cache\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"

      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) ==
               "compiled artifact\n"

      refute File.exists?(Path.join([second_workspace, "tmp", "scratch.txt"]))
      refute File.exists?(Path.join([second_workspace, ".elixir_ls", "project.plt"]))
      refute File.exists?(Path.join([second_workspace, "apps", "web", ".next", "build.txt"]))
      refute File.exists?(Path.join([second_workspace, "node_modules", ".cache", "bundler.txt"]))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == stale_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_symlink_escape, ^symlink_path, ^workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_equals_root, ^workspace_root, ^workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")

      assert {:ok, ^workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")

      untouched_workspace =
        Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"

    assert skipped_issue.blocked_by == [
             %{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}
           ]
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      assert Config.workspace_hooks().after_create =~ "echo after_create > after_create.log"
      assert Config.workspace_hooks().before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare_for_dispatch preserves .symphony state, .env.sh, and session metadata across repeated dispatches" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-prepare-preserve-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace: workspace} = create_cloned_git_workspace!(test_root, "MT-PREP-PRESERVE")
      symphony_state = Path.join([workspace, ".symphony", "state.json"])
      env_snapshot = Path.join(workspace, ".env.sh")

      File.mkdir_p!(Path.dirname(symphony_state))
      File.write!(symphony_state, ~s({"status":"keep"}) <> "\n")
      File.write!(env_snapshot, "export KEEP=1\n")

      log =
        capture_log(fn ->
          assert :ok = Workspace.prepare_for_dispatch(workspace, "MT-PREP-PRESERVE")
          assert :ok = Workspace.prepare_for_dispatch(workspace, "MT-PREP-PRESERVE")
        end)

      assert File.read!(symphony_state) == ~s({"status":"keep"}) <> "\n"
      assert File.read!(env_snapshot) == "export KEEP=1\n"
      assert log =~ ".env.sh is preserved and may be stale"

      assert length(Regex.scan(~r/\.env\.sh is preserved and may be stale/, log)) == 1
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare_for_dispatch removes untracked files at the repo root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-prepare-untracked-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace: workspace} = create_cloned_git_workspace!(test_root, "MT-PREP-UNTRACKED")
      scratch_file = Path.join(workspace, "scratch.txt")

      File.write!(scratch_file, "remove me\n")
      assert File.exists?(scratch_file)

      assert :ok = Workspace.prepare_for_dispatch(workspace, "MT-PREP-UNTRACKED")
      refute File.exists?(scratch_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare_for_dispatch resets tracked file edits back to HEAD" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-prepare-tracked-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace: workspace} = create_cloned_git_workspace!(test_root, "MT-PREP-TRACKED")
      tracked_file = Path.join(workspace, "tracked.txt")

      File.write!(tracked_file, "dirty change\n")
      assert File.read!(tracked_file) == "dirty change\n"

      assert :ok = Workspace.prepare_for_dispatch(workspace, "MT-PREP-TRACKED")
      assert File.read!(tracked_file) == "tracked\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare_for_dispatch wipes transient caches but preserves bootstrap-installed dirs" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-prepare-ignored-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue("MT-PREP-IGNORED")

      init_git_repo!(workspace, %{
        ".gitignore" => "node_modules/\ndeps/\n_build/\napps/web/.next/\n",
        "tracked.txt" => "tracked\n"
      })

      # Transient caches that @excluded_entries targets — must be wiped.
      transient_cache = Path.join([workspace, "node_modules", ".cache", "junk"])
      File.mkdir_p!(Path.dirname(transient_cache))
      File.write!(transient_cache, "remove me\n")

      next_build = Path.join([workspace, "apps", "web", ".next", "stale-chunk.js"])
      File.mkdir_p!(Path.dirname(next_build))
      File.write!(next_build, "stale\n")

      # Bootstrap-installed outputs — must survive. after_create is one-shot;
      # wiping these on redispatch would destroy dependencies installed by
      # `pnpm install` / `mix deps.get`.
      bootstrap_dep = Path.join([workspace, "node_modules", "react", "package.json"])
      File.mkdir_p!(Path.dirname(bootstrap_dep))
      File.write!(bootstrap_dep, "{}\n")

      elixir_dep = Path.join([workspace, "deps", "jason", "mix.exs"])
      File.mkdir_p!(Path.dirname(elixir_dep))
      File.write!(elixir_dep, "defmodule Jason.MixProject do end\n")

      log =
        capture_log(fn ->
          assert :ok = Workspace.prepare_for_dispatch(workspace, "MT-PREP-IGNORED")
        end)

      assert log =~ "git fetch failed; continuing with reset to local HEAD"

      # Transient caches wiped via @excluded_entries.
      refute File.exists?(transient_cache)
      refute File.exists?(next_build)

      # Bootstrap outputs preserved — regression guard for the -fdx trap.
      assert File.exists?(bootstrap_dep)
      assert File.exists?(elixir_dep)
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare_for_dispatch does not rerun after_create" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-prepare-after-create-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace: workspace, after_create_counter: after_create_counter} =
        create_cloned_git_workspace!(test_root, "MT-PREP-HOOK")

      assert count_lines(after_create_counter) == 1

      assert :ok = Workspace.prepare_for_dispatch(workspace, "MT-PREP-HOOK")
      assert count_lines(after_create_counter) == 1

      assert :ok = Workspace.prepare_for_dispatch(workspace, "MT-PREP-HOOK")
      assert count_lines(after_create_counter) == 1
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare_for_dispatch continues when git fetch fails without origin" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-prepare-no-origin-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue("MT-PREP-NO-ORIGIN")
      init_git_repo!(workspace, %{"tracked.txt" => "tracked\n"})

      tracked_file = Path.join(workspace, "tracked.txt")
      scratch_file = Path.join(workspace, "scratch.txt")

      File.write!(tracked_file, "dirty\n")
      File.write!(scratch_file, "remove me\n")

      log =
        capture_log(fn ->
          assert :ok = Workspace.prepare_for_dispatch(workspace, "MT-PREP-NO-ORIGIN")
        end)

      assert log =~ "git fetch failed; continuing with reset to local HEAD"
      assert File.read!(tracked_file) == "tracked\n"
      refute File.exists?(scratch_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare_for_dispatch continues when origin is configured but unreachable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-prepare-bad-origin-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue("MT-PREP-BAD-ORIGIN")
      init_git_repo!(workspace, %{"tracked.txt" => "tracked\n"})
      git!(workspace, ["remote", "add", "origin", "/nonexistent"])

      tracked_file = Path.join(workspace, "tracked.txt")
      scratch_file = Path.join(workspace, "scratch.txt")
      File.write!(tracked_file, "dirty\n")
      File.write!(scratch_file, "remove me\n")

      log =
        capture_log(fn ->
          assert :ok = Workspace.prepare_for_dispatch(workspace, "MT-PREP-BAD-ORIGIN")
        end)

      assert log =~ "git fetch failed; continuing with reset to local HEAD"
      assert File.read!(tracked_file) == "tracked\n"
      refute File.exists?(scratch_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare_for_dispatch skips reset and still cleans when HEAD is unset" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-prepare-empty-head-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue("MT-PREP-EMPTY")

      git!(workspace, ["init", "-b", "main"])
      git!(workspace, ["config", "user.email", "t@t.com"])
      git!(workspace, ["config", "user.name", "t"])

      scratch_file = Path.join(workspace, "scratch.txt")
      File.write!(scratch_file, "remove me\n")

      log =
        capture_log(fn ->
          assert :ok = Workspace.prepare_for_dispatch(workspace, "MT-PREP-EMPTY")
        end)

      assert log =~ "HEAD is unset (empty repo)"
      refute File.exists?(scratch_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare_for_dispatch records discarded WIP in the ledger" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-prepare-wip-ledger-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace: workspace} = create_cloned_git_workspace!(test_root, "MT-PREP-WIP")
      tracked_file = Path.join(workspace, "tracked.txt")
      scratch_file = Path.join(workspace, "scratch.txt")

      File.write!(tracked_file, "dirty tracked change\n")
      File.write!(scratch_file, "dirty scratch\n")

      log =
        capture_log(fn ->
          assert :ok = Workspace.prepare_for_dispatch(workspace, "MT-PREP-WIP")
        end)

      assert log =~ "will discard uncommitted changes"

      assert {:ok, ledger_entries} = SymphonyElixir.Ledger.read(workspace)

      discarded_event =
        Enum.find(ledger_entries, fn entry ->
          entry["event"] == "workspace_wip_discarded"
        end)

      assert discarded_event
      assert discarded_event["payload"]["issue_identifier"] == "MT-PREP-WIP"
      assert discarded_event["payload"]["file_count"] >= 2
      assert discarded_event["payload"]["summary"] =~ "tracked.txt"

      # Ledger payload points to a recoverable patch + untracked list.
      patch_rel = discarded_event["payload"]["patch_path"]
      untracked_rel = discarded_event["payload"]["untracked_list_path"]
      assert is_binary(patch_rel)
      assert is_binary(untracked_rel)

      patch_abs = Path.join(workspace, patch_rel)
      untracked_abs = Path.join(workspace, untracked_rel)
      assert File.exists?(patch_abs), "discarded WIP patch not written at #{patch_abs}"
      assert File.exists?(untracked_abs), "untracked-file list not written at #{untracked_abs}"

      # Patch captures the dirty tracked-file change.
      patch_contents = File.read!(patch_abs)
      assert patch_contents =~ "tracked.txt"
      assert patch_contents =~ "dirty tracked change"

      # Untracked list mentions the scratch file.
      untracked_contents = File.read!(untracked_abs)
      assert untracked_contents =~ "scratch.txt"

      # Regression guard for Codex P2: untracked file CONTENT (not just path)
      # must survive the reset. `git diff --binary HEAD` does not capture
      # brand-new files that were never `git add`'d — only path lists do.
      # The stash must mirror file contents under <ts>.untracked/ so
      # `cp -r` recovery works.
      untracked_content_rel = discarded_event["payload"]["untracked_content_path"]

      assert is_binary(untracked_content_rel),
             "discarded WIP ledger must carry untracked_content_path for new-file recovery"

      untracked_content_abs = Path.join(workspace, untracked_content_rel)
      scratch_stashed = Path.join(untracked_content_abs, "scratch.txt")

      assert File.exists?(scratch_stashed),
             "untracked file content not mirrored at #{scratch_stashed}"

      assert File.read!(scratch_stashed) == "dirty scratch\n",
             "untracked file content mismatch — brand-new file would be lost on next `git clean -fd`"
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare_for_dispatch skips non-git workspaces without crashing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-prepare-nongit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue("MT-PREP-NONGIT")
      File.mkdir_p!(Path.join(workspace, "tmp"))
      File.write!(Path.join([workspace, "tmp", "scratch.txt"]), "remove me\n")

      log =
        capture_log(fn ->
          assert :ok = Workspace.prepare_for_dispatch(workspace, "MT-PREP-NONGIT")
        end)

      assert log =~ "not a git repo"
      refute File.exists?(Path.join([workspace, "tmp", "scratch.txt"]))
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert Config.linear_endpoint() == "https://api.linear.app/graphql"
    assert Config.linear_api_token() == nil
    assert Config.linear_project_slug() == nil
    assert Config.workspace_root() == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert Config.max_concurrent_agents() == 10
    assert Config.codex_command() == "codex app-server"

    assert Config.codex_approval_policy() == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert Config.codex_thread_sandbox() == "workspace-write"

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Config.codex_turn_timeout_ms() == 3_600_000
    assert Config.codex_read_timeout_ms() == 5_000
    assert Config.codex_stall_timeout_ms() == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex app-server --model gpt-5.3-codex"
    )

    assert Config.codex_command() == "codex app-server --model gpt-5.3-codex"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: ["/tmp/workspace", "/tmp/cache"]
      }
    )

    assert Config.codex_approval_policy() == "on-request"
    assert Config.codex_thread_sandbox() == "workspace-write"

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["/tmp/workspace", "/tmp/cache"]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert Config.linear_active_states() == ["Todo", "In Progress"]

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert Config.max_concurrent_agents() == 10

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert Config.codex_turn_timeout_ms() == 3_600_000

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert Config.codex_read_timeout_ms() == 5_000

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert Config.codex_stall_timeout_ms() == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert Config.linear_active_states() == ["Todo", "In Progress"]

    assert Config.linear_terminal_states() == [
             "Closed",
             "Cancelled",
             "Canceled",
             "Duplicate",
             "Done"
           ]

    assert Config.poll_interval_ms() == 30_000
    assert Config.workspace_root() == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert Config.max_retry_backoff_ms() == 300_000
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("Review") == 10
    assert Config.hook_timeout_ms() == 60_000
    assert Config.observability_enabled?()
    assert Config.observability_refresh_ms() == 1_000
    assert Config.observability_render_interval_ms() == 16
    assert Config.server_port() == nil
    assert Config.server_host() == "123"

    # Tunable retry defaults fall through when unset.
    assert Config.max_unit_attempts() == 3
    assert Config.max_verify_attempts() == 3
    assert Config.max_verify_fix_cycles() == 2

    # Overrides round-trip through WORKFLOW.md.
    write_workflow_file!(Workflow.workflow_file_path(),
      max_unit_attempts: 5,
      verification_max_verify_attempts: 1,
      verification_max_verify_fix_cycles: 1
    )

    assert Config.max_unit_attempts() == 5
    assert Config.max_verify_attempts() == 1
    assert Config.max_verify_fix_cycles() == 1

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")

    assert Config.codex_approval_policy() == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert {:error, {:invalid_codex_approval_policy, ""}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert Config.codex_thread_sandbox() == "workspace-write"
    assert {:error, {:invalid_codex_thread_sandbox, ""}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:error, {:invalid_codex_turn_sandbox_policy, {:unsupported_value, "bad"}}} =
             Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    assert Config.codex_approval_policy() == "future-policy"
    assert Config.codex_thread_sandbox() == "future-sandbox"

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.codex_command() == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    assert Config.linear_api_token() == api_key
    assert Config.workspace_root() == Path.expand(workspace_root)
    assert Config.codex_command() == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    assert Config.linear_api_token() == "env:#{api_key_env_var}"
    assert Config.workspace_root() == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.max_concurrent_agents() == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10
  end

  defp create_cloned_git_workspace!(test_root, issue_identifier) do
    template_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")
    after_create_counter = Path.join(test_root, "after_create.count")

    init_git_repo!(template_repo, %{
      "README.md" => "hook clone\n",
      "tracked.txt" => "tracked\n"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "git clone #{template_repo} .\necho call >> \"#{after_create_counter}\""
    )

    assert {:ok, workspace} = Workspace.create_for_issue(issue_identifier)

    %{
      workspace: workspace,
      template_repo: template_repo,
      workspace_root: workspace_root,
      after_create_counter: after_create_counter
    }
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
end
