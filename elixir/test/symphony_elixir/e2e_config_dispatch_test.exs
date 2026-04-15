defmodule SymphonyElixir.E2eConfigDispatchTest do
  @moduledoc """
  End-to-end tests: WORKFLOW.md → Config parsing → dispatch branching.
  These tests go through the real Config/Workflow pipeline, not mocked inputs.
  """
  use SymphonyElixir.TestSupport

  describe "verification config wiring" do
    test "default → empty verification commands" do
      assert Config.verification_baseline_commands() == []
      assert Config.verification_full_commands() == []
      assert Config.verification_timeout_ms() == 300_000
    end

    test "verification commands in WORKFLOW.md → Config reads them" do
      write_workflow_file!(Workflow.workflow_file_path(),
        verification_baseline_commands: ["./scripts/quick-check.sh"],
        verification_full_commands: ["./scripts/validate-app.sh"],
        verification_timeout_ms: 120_000
      )

      WorkflowStore.force_reload()

      assert Config.verification_baseline_commands() == ["./scripts/quick-check.sh"]
      assert Config.verification_full_commands() == ["./scripts/validate-app.sh"]
      assert Config.verification_timeout_ms() == 120_000
    end
  end

  describe "backward compatibility" do
    test "WORKFLOW.md without new fields parses and validates" do
      assert Config.verification_baseline_commands() == []
      assert Config.verification_full_commands() == []
      assert is_integer(Config.poll_interval_ms())
      assert is_integer(Config.max_concurrent_agents())
      assert is_binary(Config.codex_command())
      assert :ok == Config.validate!()
    end

    test "WORKFLOW.md with all new fields parses and validates" do
      write_workflow_file!(Workflow.workflow_file_path(),
        verification_baseline_commands: ["echo baseline"],
        verification_full_commands: ["echo full"],
        verification_timeout_ms: 60_000
      )

      WorkflowStore.force_reload()

      assert Config.verification_full_commands() == ["echo full"]
      assert :ok == Config.validate!()
    end
  end

  describe "Verifier reads real Config" do
    test "passes with configured passing command" do
      write_workflow_file!(Workflow.workflow_file_path(),
        verification_full_commands: ["echo 'test passed'"]
      )

      WorkflowStore.force_reload()

      ws = Path.join(System.tmp_dir!(), "verify_e2e_#{System.unique_integer([:positive])}")
      File.mkdir_p!(ws)

      assert :pass = SymphonyElixir.Verifier.run(ws)

      File.rm_rf!(ws)
    end

    test "fails with configured failing command" do
      write_workflow_file!(Workflow.workflow_file_path(),
        verification_full_commands: ["exit 1"]
      )

      WorkflowStore.force_reload()

      ws = Path.join(System.tmp_dir!(), "verify_e2e_fail_#{System.unique_integer([:positive])}")
      File.mkdir_p!(ws)

      assert {:fail, _output} = SymphonyElixir.Verifier.run(ws)

      File.rm_rf!(ws)
    end
  end
end
