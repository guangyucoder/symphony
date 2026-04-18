defmodule SymphonyElixir.StageCloseoutTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.StageCloseout

  @moduletag :tmp_dir

  @issue "ENT-187"
  @other_issue "ENT-999"

  setup context do
    if context[:tmp_dir] do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "symphony-stage-closeout-test-#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    else
      :ok
    end
  end

  test "check_review passes when dispatch head, code-review marker, and tree are clean", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    head = head!(repo)

    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: head),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: head,
          verdict: "clean"
        )
      ])

    assert StageCloseout.check_review(repo, workpad, head, @issue) == :ok
  end

  test "check_doc_fix passes for no-updates when docs-checked matches clean review head", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    head = head!(repo)

    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: head),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: head,
          verdict: "clean"
        ),
        marker(
          kind: "docs-checked",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: head,
          docfix_outcome: "no-updates"
        )
      ])

    assert StageCloseout.check_doc_fix(repo, workpad, @issue) == :ok
  end

  test "check_doc_fix passes when only docs paths changed", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    review_sha = head!(repo)

    File.mkdir_p!(Path.join(repo, "docs"))
    File.write!(Path.join(repo, "docs/guide.txt"), "updated docs\n")
    commit_all!(repo, "docs update")
    head = head!(repo)

    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: review_sha),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: review_sha,
          verdict: "clean"
        ),
        marker(
          kind: "docs-checked",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: head,
          docfix_outcome: "updated"
        )
      ])

    assert StageCloseout.check_doc_fix(repo, workpad, @issue) == :ok
  end

  test "check_review fails when reviewer moved HEAD after dispatch", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    dispatch_head = head!(repo)

    File.write!(Path.join(repo, "review.txt"), "reviewer committed\n")
    commit_all!(repo, "reviewer commit")
    head = head!(repo)

    workpad =
      workpad([
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: head,
          verdict: "clean"
        )
      ])

    assert StageCloseout.check_review(repo, workpad, dispatch_head, @issue) ==
             {:error, {:reviewer_committed, old: dispatch_head, new: head}}
  end

  test "check_review fails when the current round has no code-review marker", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    head = head!(repo)

    workpad = workpad([marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: head)])

    assert StageCloseout.check_review(repo, workpad, head, @issue) ==
             {:error, {:missing_marker, :code_review}}
  end

  test "check_doc_fix fails when the current round has no docs-checked marker", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    head = head!(repo)

    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: head),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: head,
          verdict: "clean"
        )
      ])

    assert StageCloseout.check_doc_fix(repo, workpad, @issue) ==
             {:error, {:missing_marker, :docs_checked}}
  end

  test "check_review fails when latest code-review reviewed_sha differs from HEAD", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    reviewed_sha = head!(repo)

    File.write!(Path.join(repo, "lib.txt"), "new head\n")
    commit_all!(repo, "advance head")
    head = head!(repo)

    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: reviewed_sha),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: reviewed_sha,
          verdict: "clean"
        )
      ])

    assert StageCloseout.check_review(repo, workpad, head, @issue) ==
             {:error, {:reviewed_sha_mismatch, marker: :code_review, reviewed_sha: reviewed_sha, head: head}}
  end

  test "check_review fails when the working tree is dirty", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    head = head!(repo)
    File.write!(Path.join(repo, "scratch.txt"), "dirty\n")

    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: head),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: head,
          verdict: "clean"
        )
      ])

    assert StageCloseout.check_review(repo, workpad, head, @issue) ==
             {:error, {:working_tree_dirty, ["?? scratch.txt"]}}
  end

  test "check_review rejects a findings-to-clean flip at the same HEAD", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    head = head!(repo)

    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: head),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: head,
          verdict: "findings"
        ),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 2,
          reviewed_sha: head,
          verdict: "clean"
        )
      ])

    assert StageCloseout.check_review(repo, workpad, head, @issue) ==
             {:error, {:findings_to_clean_flip_same_head, head}}
  end

  test "check_doc_fix rejects non-doc paths in the diff since latest clean review", %{tmp_dir: tmp_dir} do
    repo = init_repo!(tmp_dir)
    review_sha = head!(repo)

    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "lib/code.ex"), "defmodule Code do\nend\n")
    File.write!(Path.join(repo, "README.md"), "# updated\n")
    commit_all!(repo, "mixed docfix commit")
    head = head!(repo)

    workpad =
      workpad([
        marker(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: review_sha),
        marker(
          kind: "code-review",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: review_sha,
          verdict: "clean"
        ),
        marker(
          kind: "docs-checked",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: head,
          docfix_outcome: "updated"
        )
      ])

    assert StageCloseout.check_doc_fix(repo, workpad, @issue) ==
             {:error, {:non_docs_paths, ["lib/code.ex"]}}
  end

  test "check_implement always returns :ok" do
    assert StageCloseout.check_implement(:anything, @other_issue, nil) == :ok
  end

  defp init_repo!(tmp_dir) do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "README.md"), "# test\n")
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    repo
  end

  defp commit_all!(repo, message) do
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-m", message])
  end

  defp head!(repo) do
    git!(repo, ["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp workpad(markers) do
    """
    Notes outside marker region.

    <!-- SYMPHONY-MARKERS-BEGIN -->
    #{Enum.map_join(markers, "\n", &marker_block/1)}
    <!-- SYMPHONY-MARKERS-END -->
    """
  end

  defp marker(fields) do
    Keyword.put_new(fields, :issue_identifier, @issue)
  end

  defp marker_block(fields) do
    body =
      Enum.map_join(fields, "\n", fn {key, value} ->
        "#{key}: #{yaml_value(value)}"
      end)

    """
    ```symphony-marker
    #{body}
    ```
    """
  end

  defp yaml_value(value) when is_binary(value), do: value
  defp yaml_value(value) when is_integer(value), do: Integer.to_string(value)
end
