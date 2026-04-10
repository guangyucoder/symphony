defmodule SymphonyElixir.DocImpactTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DocImpact

  @workspace "/tmp/dummy"

  describe "check/2" do
    test "returns fresh when no files changed" do
      assert {:ok, :fresh} = DocImpact.check(@workspace, [])
    end

    test "returns fresh when only docs changed" do
      assert {:ok, :fresh} = DocImpact.check(@workspace, ["docs/ARCHITECTURE.md", "AGENTS.md"])
    end

    test "returns fresh when only test files changed" do
      assert {:ok, :fresh} = DocImpact.check(@workspace, ["test/some_test.exs", "spec/helper.rb"])
    end

    test "returns stale when architecture files changed without doc changes" do
      assert {:ok, {:stale, reason}} = DocImpact.check(@workspace, [
        "src/screens/EditorScreen.js",
        "src/store/board.ts"
      ])
      assert reason =~ "Architecture-sensitive"
    end

    test "returns fresh when both architecture and docs changed" do
      assert {:ok, :fresh} = DocImpact.check(@workspace, [
        "src/screens/EditorScreen.js",
        "docs/ARCHITECTURE.md"
      ])
    end

    test "returns stale for apps/ changes without docs" do
      assert {:ok, {:stale, _}} = DocImpact.check(@workspace, ["apps/web/src/index.tsx"])
    end

    test "returns stale for scripts/ changes without docs" do
      assert {:ok, {:stale, _}} = DocImpact.check(@workspace, ["scripts/validate-app.sh"])
    end

    test "returns fresh for non-architecture files" do
      assert {:ok, :fresh} = DocImpact.check(@workspace, [
        "package.json",
        "pnpm-lock.yaml",
        ".gitignore"
      ])
    end
  end
end
