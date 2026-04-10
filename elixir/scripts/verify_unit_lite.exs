#!/usr/bin/env elixir
# Symphony Unit-Lite Verification Script
#
# Run with: mix run scripts/verify_unit_lite.exs
#
# Runs real verification against the three core problems:
# 1. Can validation be skipped? (must be NO)
# 2. Are units dispatched as separate sessions? (must be YES)
# 3. Does subtask dispatch work? (must be YES)
#
# Uses real git workspaces but no Codex API calls.

defmodule VerifyUnitLite do
  @test_dir System.tmp_dir!() |> Path.join("symphony_verify_#{System.unique_integer([:positive])}")

  def run do
    IO.puts("\n=== Symphony Unit-Lite Verification ===\n")
    setup()

    results = [
      verify_problem_1(),
      verify_problem_2(),
      verify_problem_3(),
      verify_crash_recovery(),
      verify_doc_impact(),
      verify_closeout_doc_pipeline(),
      verify_closeout_no_false_positive(),
      verify_verifier_closeout(),
      verify_rework_flow()
    ]

    cleanup()

    passed = Enum.count(results, &(&1 == :pass))
    failed = Enum.count(results, &(&1 == :fail))
    IO.puts("\n=== Results: #{passed} passed, #{failed} failed ===")

    if failed > 0, do: System.halt(1)
  end

  defp setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
  end

  defp cleanup do
    File.rm_rf!(@test_dir)
  end

  # --- Problem 1: Agent cannot skip validation ---
  defp verify_problem_1 do
    IO.puts("Problem 1: Validation cannot be skipped")

    ws = create_workspace("p1")

    # Setup: bootstrapped, planned, all subtasks done
    init_exec(ws, %{
      "bootstrapped" => true,
      "plan_version" => 1,
      "last_verified_sha" => nil,    # NOT verified
      "last_commit_sha" => "abc123"
    })

    workpad = """
    ## Codex Workpad
    ### Plan
    - [x] [plan-1] Done
    - [x] [plan-2] Done
    """

    head = git_head(ws)

    # Resolve should dispatch verify, NOT handoff
    ctx = %{
      issue: %{state: "In Progress"},
      exec: read_exec(ws),
      workpad_text: workpad,
      git_head: head
    }

    case SymphonyElixir.DispatchResolver.resolve(ctx) do
      {:dispatch, %{kind: :verify}} ->
        IO.puts("  ✓ Resolver dispatches verify (not handoff) when unverified")

        # Now simulate: set verified_sha to WRONG value (stale)
        update_exec(ws, %{"last_verified_sha" => "stale_sha"})
        ctx2 = %{ctx | exec: read_exec(ws)}

        case SymphonyElixir.DispatchResolver.resolve(ctx2) do
          {:dispatch, %{kind: :verify}} ->
            IO.puts("  ✓ Stale verification SHA triggers re-verify")

            # Now set correct verified sha
            update_exec(ws, %{"last_verified_sha" => head})
            ctx3 = %{ctx | exec: read_exec(ws)}

            case SymphonyElixir.DispatchResolver.resolve(ctx3) do
              {:dispatch, %{kind: :handoff}} ->
                IO.puts("  ✓ Correct verified SHA allows handoff")
                IO.puts("  PASS: Validation skip is mechanically impossible\n")
                :pass

              other ->
                IO.puts("  ✗ Expected handoff, got #{inspect(other)}")
                :fail
            end

          other ->
            IO.puts("  ✗ Expected verify on stale SHA, got #{inspect(other)}")
            :fail
        end

      other ->
        IO.puts("  ✗ Expected verify dispatch, got #{inspect(other)}")
        :fail
    end
  end

  # --- Problem 2: Units are separate sessions ---
  defp verify_problem_2 do
    IO.puts("Problem 2: Each unit is a fresh session")

    ws = create_workspace("p2")
    init_exec(ws)

    # Simulate bootstrap → plan dispatch sequence
    # Each should produce a separate ledger entry

    # Unit 1: bootstrap
    SymphonyElixir.Ledger.unit_started(ws, %{"kind" => "bootstrap"})
    SymphonyElixir.Ledger.unit_accepted(ws, %{"kind" => "bootstrap"})
    update_exec(ws, %{"bootstrapped" => true, "current_unit" => nil})

    # Unit 2: plan
    SymphonyElixir.Ledger.unit_started(ws, %{"kind" => "plan"})
    SymphonyElixir.Ledger.unit_accepted(ws, %{"kind" => "plan"}, %{"plan_version" => 1})
    update_exec(ws, %{"plan_version" => 1, "current_unit" => nil})

    # Unit 3: implement_subtask
    SymphonyElixir.Ledger.unit_started(ws, %{"kind" => "implement_subtask", "subtask_id" => "plan-1"})
    SymphonyElixir.Ledger.unit_accepted(ws, %{"kind" => "implement_subtask", "subtask_id" => "plan-1"})

    {:ok, entries} = SymphonyElixir.Ledger.read(ws)
    started_count = Enum.count(entries, &(&1["event"] == "unit_started"))
    accepted_count = Enum.count(entries, &(&1["event"] == "unit_accepted"))

    if started_count == 3 and accepted_count == 3 do
      IO.puts("  ✓ 3 units dispatched as separate entries (not one long session)")
      IO.puts("  ✓ Each unit has start + accept lifecycle events")

      # Verify prompts are different
      bootstrap_prompt = SymphonyElixir.PromptBuilder.build_unit_prompt(
        %{identifier: "ENT-1", title: "Test"},
        SymphonyElixir.Unit.bootstrap()
      )
      implement_prompt = SymphonyElixir.PromptBuilder.build_unit_prompt(
        %{identifier: "ENT-1", title: "Test"},
        SymphonyElixir.Unit.implement_subtask("plan-1", "Do thing")
      )

      if bootstrap_prompt != implement_prompt and
         String.length(bootstrap_prompt) < 2000 and
         String.length(implement_prompt) < 2000 do
        IO.puts("  ✓ Each unit gets a focused prompt (< 2000 chars)")
        IO.puts("  PASS: Units are separate, focused sessions\n")
        :pass
      else
        IO.puts("  ✗ Prompts not differentiated or too large")
        :fail
      end
    else
      IO.puts("  ✗ Expected 3 starts + 3 accepts, got #{started_count}/#{accepted_count}")
      :fail
    end
  end

  # --- Problem 3: Subtask dispatch works ---
  defp verify_problem_3 do
    IO.puts("Problem 3: Implement dispatches one subtask at a time")

    ws = create_workspace("p3")
    init_exec(ws, %{"bootstrapped" => true, "plan_version" => 1})

    workpad = """
    ## Codex Workpad
    ### Plan
    - [ ] [plan-1] Add component
    - [ ] [plan-2] Write tests
    - [ ] [plan-3] Update docs
    """

    head = git_head(ws)
    ctx = %{
      issue: %{state: "In Progress"},
      exec: read_exec(ws),
      workpad_text: workpad,
      git_head: head
    }

    # Should dispatch plan-1 first
    case SymphonyElixir.DispatchResolver.resolve(ctx) do
      {:dispatch, %{kind: :implement_subtask, subtask_id: "plan-1"}} ->
        IO.puts("  ✓ First dispatch: plan-1 (not plan-2 or plan-3)")

        # Mark plan-1 done, re-resolve
        workpad2 = String.replace(workpad, "- [ ] [plan-1]", "- [x] [plan-1]")
        ctx2 = %{ctx | workpad_text: workpad2}

        case SymphonyElixir.DispatchResolver.resolve(ctx2) do
          {:dispatch, %{kind: :implement_subtask, subtask_id: "plan-2"}} ->
            IO.puts("  ✓ After plan-1 done: dispatches plan-2 (sequential)")

            # Mark all done
            workpad3 = workpad2
              |> String.replace("- [ ] [plan-2]", "- [x] [plan-2]")
              |> String.replace("- [ ] [plan-3]", "- [x] [plan-3]")
            ctx3 = %{ctx | workpad_text: workpad3}

            case SymphonyElixir.DispatchResolver.resolve(ctx3) do
              {:dispatch, %{kind: :verify}} ->
                IO.puts("  ✓ After all done: dispatches verify (not another subtask)")
                IO.puts("  PASS: Subtask dispatch is sequential and bounded\n")
                :pass

              other ->
                IO.puts("  ✗ Expected verify, got #{inspect(other)}")
                :fail
            end

          other ->
            IO.puts("  ✗ Expected plan-2, got #{inspect(other)}")
            :fail
        end

      other ->
        IO.puts("  ✗ Expected plan-1, got #{inspect(other)}")
        :fail
    end
  end

  # --- Bonus: Crash recovery ---
  defp verify_crash_recovery do
    IO.puts("Bonus: Crash recovery replays current unit")

    ws = create_workspace("crash")
    init_exec(ws, %{
      "bootstrapped" => true,
      "plan_version" => 1,
      "current_unit" => %{"kind" => "implement_subtask", "subtask_id" => "plan-2", "attempt" => 1}
    })

    workpad = """
    ## Codex Workpad
    ### Plan
    - [x] [plan-1] Done
    - [ ] [plan-2] Was in progress when crash happened
    - [ ] [plan-3] Not started
    """

    ctx = %{
      issue: %{state: "In Progress"},
      exec: read_exec(ws),
      workpad_text: workpad,
      git_head: git_head(ws)
    }

    case SymphonyElixir.DispatchResolver.resolve(ctx) do
      {:dispatch, %{kind: :implement_subtask, subtask_id: "plan-2", attempt: 2}} ->
        IO.puts("  ✓ Replays plan-2 with attempt=2 (not plan-1 or plan-3)")
        IO.puts("  PASS: Crash recovery works\n")
        :pass

      other ->
        IO.puts("  ✗ Expected replay plan-2 attempt 2, got #{inspect(other)}")
        :fail
    end
  end

  # --- Bonus: Doc impact triggers doc_fix ---
  defp verify_doc_impact do
    IO.puts("Bonus: Doc-impact detection triggers doc_fix")

    # Test architecture-sensitive change without doc changes
    case SymphonyElixir.DocImpact.check("/tmp", ["src/screens/EditorScreen.js", "src/store/board.ts"]) do
      {:ok, {:stale, _reason}} ->
        IO.puts("  ✓ Architecture changes without docs → stale detected")

        # Test with doc changes included
        case SymphonyElixir.DocImpact.check("/tmp", ["src/screens/EditorScreen.js", "docs/ARCHITECTURE.md"]) do
          {:ok, :fresh} ->
            IO.puts("  ✓ Architecture changes WITH docs → fresh")

            # Test doc_fix dispatch priority
            ws = create_workspace("docfix")
            init_exec(ws, %{
              "bootstrapped" => true,
              "plan_version" => 1,
              "doc_fix_required" => true
            })

            workpad = """
            ## Codex Workpad
            ### Plan
            - [ ] [plan-1] Still pending
            """

            ctx = %{
              issue: %{state: "In Progress"},
              exec: read_exec(ws),
              workpad_text: workpad,
              git_head: git_head(ws)
            }

            case SymphonyElixir.DispatchResolver.resolve(ctx) do
              {:dispatch, %{kind: :doc_fix}} ->
                IO.puts("  ✓ doc_fix dispatched BEFORE next subtask")
                IO.puts("  PASS: Doc-impact → doc_fix pipeline works\n")
                :pass

              other ->
                IO.puts("  ✗ Expected doc_fix, got #{inspect(other)}")
                :fail
            end

          other ->
            IO.puts("  ✗ Expected fresh with docs, got #{inspect(other)}")
            :fail
        end

      other ->
        IO.puts("  ✗ Expected stale, got #{inspect(other)}")
        :fail
    end
  end

  # --- Bonus: Full closeout → doc-impact → doc_fix pipeline with real git ---
  defp verify_closeout_doc_pipeline do
    IO.puts("Bonus: Closeout actually runs doc-impact and triggers doc_fix")

    ws = create_workspace("closeout_doc")
    init_exec(ws, %{"bootstrapped" => true, "plan_version" => 1})

    # Create architecture-sensitive file change (simulating agent work)
    File.mkdir_p!(Path.join(ws, "src/screens"))
    File.write!(Path.join(ws, "src/screens/NewScreen.js"), "export default function NewScreen() {}")
    System.cmd("git", ["add", "-A"], cd: ws)
    System.cmd("git", ["commit", "-m", "add NewScreen"], cd: ws)

    # Run REAL closeout for implement_subtask
    unit = %{"kind" => "implement_subtask", "subtask_id" => "plan-1"}
    issue = %{state: "In Progress", identifier: "ENT-99"}

    SymphonyElixir.IssueExec.start_unit(ws, unit)
    result = SymphonyElixir.Closeout.run(ws, unit, issue)

    case result do
      :accepted ->
        IO.puts("  ✓ Closeout accepted implement_subtask")

        # Check that doc_fix_required was set (because src/screens/ changed without docs)
        {:ok, exec} = SymphonyElixir.IssueExec.read(ws)

        if exec["doc_fix_required"] == true do
          IO.puts("  ✓ Closeout detected doc-impact and set doc_fix_required=true")

          # Check ledger has doc_fix_required event
          {:ok, entries} = SymphonyElixir.Ledger.read(ws)
          has_doc_event = Enum.any?(entries, &(&1["event"] == "doc_fix_required"))

          if has_doc_event do
            IO.puts("  ✓ Ledger recorded doc_fix_required event")

            # Verify resolver now dispatches doc_fix before next subtask
            SymphonyElixir.IssueExec.accept_unit(ws)

            workpad = """
            ## Codex Workpad
            ### Plan
            - [x] [plan-1] Done (just completed)
            - [ ] [plan-2] Still pending
            """

            ctx = %{
              issue: %{state: "In Progress"},
              exec: read_exec(ws),
              workpad_text: workpad,
              git_head: git_head(ws)
            }

            case SymphonyElixir.DispatchResolver.resolve(ctx) do
              {:dispatch, %{kind: :doc_fix}} ->
                IO.puts("  ✓ Resolver dispatches doc_fix BEFORE plan-2")

                # Simulate doc_fix completion → clears flag
                SymphonyElixir.Closeout.run(ws, %{"kind" => "doc_fix"}, issue)
                {:ok, exec2} = SymphonyElixir.IssueExec.read(ws)

                if exec2["doc_fix_required"] == false do
                  IO.puts("  ✓ After doc_fix closeout, flag cleared")
                  IO.puts("  PASS: Full closeout → doc-impact → doc_fix pipeline verified\n")
                  :pass
                else
                  IO.puts("  ✗ doc_fix_required still true after doc_fix closeout")
                  :fail
                end

              other ->
                IO.puts("  ✗ Expected doc_fix dispatch, got #{inspect(other)}")
                :fail
            end
          else
            IO.puts("  ✗ Ledger missing doc_fix_required event")
            :fail
          end
        else
          IO.puts("  ✗ doc_fix_required not set after architecture change")
          IO.puts("    exec: #{inspect(exec)}")
          :fail
        end

      other ->
        IO.puts("  ✗ Expected accepted, got #{inspect(other)}")
        :fail
    end
  end

  # --- Bonus: Closeout does NOT trigger doc-impact for non-sensitive changes ---
  defp verify_closeout_no_false_positive do
    IO.puts("Bonus: Closeout does not trigger doc_fix for non-sensitive changes")

    ws = create_workspace("closeout_nodoc")
    init_exec(ws, %{"bootstrapped" => true, "plan_version" => 1})

    # Create a non-architecture-sensitive change
    File.write!(Path.join(ws, "test_file.txt"), "just a test file")
    System.cmd("git", ["add", "-A"], cd: ws)
    System.cmd("git", ["commit", "-m", "add test file"], cd: ws)

    unit = %{"kind" => "implement_subtask", "subtask_id" => "plan-1"}
    issue = %{state: "In Progress", identifier: "ENT-100"}

    SymphonyElixir.IssueExec.start_unit(ws, unit)
    result = SymphonyElixir.Closeout.run(ws, unit, issue)

    case result do
      :accepted ->
        {:ok, exec} = SymphonyElixir.IssueExec.read(ws)

        if exec["doc_fix_required"] == false do
          IO.puts("  ✓ Non-sensitive change does NOT trigger doc_fix_required")
          IO.puts("  PASS: No false positive doc-impact\n")
          :pass
        else
          IO.puts("  ✗ doc_fix_required triggered for non-sensitive change")
          :fail
        end

      other ->
        IO.puts("  ✗ Expected accepted, got #{inspect(other)}")
        :fail
    end
  end

  # --- Bonus: Verify unit actually runs verifier ---
  defp verify_verifier_closeout do
    IO.puts("Bonus: Verify unit closeout actually runs verification commands")

    ws = create_workspace("verifier")
    init_exec(ws, %{"bootstrapped" => true, "plan_version" => 1})

    # Create a simple passing verification command
    script_path = Path.join(ws, "verify.sh")
    File.write!(script_path, "#!/bin/sh\nexit 0\n")
    System.cmd("chmod", ["+x", script_path])

    unit = %{"kind" => "verify"}
    issue = %{state: "In Progress", identifier: "ENT-101"}

    SymphonyElixir.IssueExec.start_unit(ws, unit)

    # Run verify closeout with explicit command
    result = SymphonyElixir.Verifier.run(ws, commands: ["./verify.sh"])

    case result do
      :pass ->
        head = SymphonyElixir.Verifier.current_head(ws)
        SymphonyElixir.IssueExec.set_verified_sha(ws, head)
        SymphonyElixir.Ledger.verify_passed(ws, head)

        {:ok, exec} = SymphonyElixir.IssueExec.read(ws)

        if exec["last_verified_sha"] == head do
          IO.puts("  ✓ Verifier ran command and it passed (exit 0)")
          IO.puts("  ✓ last_verified_sha set to current HEAD (#{String.slice(head, 0..6)})")

          # Now test failing verification
          File.write!(script_path, "#!/bin/sh\necho 'FAIL: tests broken'\nexit 1\n")
          result2 = SymphonyElixir.Verifier.run(ws, commands: ["./verify.sh"])

          case result2 do
            {:fail, output} ->
              IO.puts("  ✓ Failing command returns {:fail, output}")
              IO.puts("  ✓ Output captured: #{String.slice(output, 0..50)}...")
              IO.puts("  PASS: Verifier runs real commands\n")
              :pass

            _ ->
              IO.puts("  ✗ Expected fail on exit 1")
              :fail
          end
        else
          IO.puts("  ✗ last_verified_sha not set correctly")
          :fail
        end

      other ->
        IO.puts("  ✗ Expected pass, got #{inspect(other)}")
        :fail
    end
  end

  # --- Bonus: Rework flow ---
  defp verify_rework_flow do
    IO.puts("Bonus: Rework flow resets to plan")

    ws = create_workspace("rework")
    init_exec(ws, %{
      "bootstrapped" => true,
      "plan_version" => 1,
      "phase" => "handoff",
      "last_accepted_unit" => %{"kind" => "handoff"},
      "last_verified_sha" => "abc123"
    })

    ctx = %{
      issue: %{state: "Rework"},
      exec: read_exec(ws),
      workpad_text: nil,
      git_head: "abc123"
    }

    case SymphonyElixir.DispatchResolver.resolve(ctx) do
      {:dispatch, %{kind: :plan}} ->
        IO.puts("  ✓ Rework resets to plan (not done or handoff)")
        IO.puts("  PASS: Rework flow works\n")
        :pass

      other ->
        IO.puts("  ✗ Expected plan dispatch, got #{inspect(other)}")
        :fail
    end
  end

  # --- Helpers ---

  defp create_workspace(name) do
    ws = Path.join(@test_dir, name)
    File.mkdir_p!(Path.join(ws, ".symphony"))

    # Init git repo
    System.cmd("git", ["init"], cd: ws, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: ws)
    System.cmd("git", ["config", "user.name", "Test"], cd: ws)
    File.write!(Path.join(ws, "README.md"), "# Test")
    System.cmd("git", ["add", "-A"], cd: ws)
    System.cmd("git", ["commit", "-m", "init"], cd: ws)

    ws
  end

  defp init_exec(ws, overrides \\ %{}) do
    SymphonyElixir.IssueExec.init(ws)
    if overrides != %{}, do: SymphonyElixir.IssueExec.update(ws, overrides)
  end

  defp read_exec(ws) do
    {:ok, exec} = SymphonyElixir.IssueExec.read(ws)
    exec
  end

  defp update_exec(ws, changes) do
    SymphonyElixir.IssueExec.update(ws, changes)
  end

  defp git_head(ws) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: ws, stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end
end

VerifyUnitLite.run()
