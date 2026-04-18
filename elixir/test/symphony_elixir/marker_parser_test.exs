defmodule SymphonyElixir.MarkerParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.MarkerParser
  alias SymphonyElixir.MarkerParser.Marker

  @issue "ENT-187"
  @other_issue "ENT-999"
  @sha1 String.duplicate("a", 40)
  @sha2 String.duplicate("b", 40)
  @sha3 String.duplicate("c", 40)

  test "no BEGIN/END region returns empty list" do
    assert MarkerParser.parse(marker_block(kind: "review-request"), @issue) == []
  end

  test "empty BEGIN/END region returns empty list" do
    assert MarkerParser.parse(wrap_region(""), @issue) == []
  end

  test "single valid review-request is parsed" do
    markers =
      wrap_region(
        marker_block(
          kind: "review-request",
          round_id: 1,
          stage_round: 1,
          reviewed_sha: @sha1,
          issue_identifier: @issue
        )
      )
      |> MarkerParser.parse(@issue)

    assert markers == [
             %Marker{
               kind: :review_request,
               round_id: 1,
               stage_round: 1,
               reviewed_sha: @sha1,
               issue_identifier: @issue,
               verdict: nil,
               findings: nil,
               docfix_outcome: nil
             }
           ]
  end

  test "code-review missing verdict is dropped" do
    assert parse_single("""
           kind: code-review
           round_id: 1
           stage_round: 1
           reviewed_sha: #{@sha1}
           issue_identifier: #{@issue}
           """) == []
  end

  test "docs-checked missing docfix_outcome is dropped" do
    assert parse_single("""
           kind: docs-checked
           round_id: 1
           stage_round: 1
           reviewed_sha: #{@sha1}
           issue_identifier: #{@issue}
           """) == []
  end

  test "invalid YAML is dropped" do
    assert parse_single("""
           kind: [oops
           round_id: 1
           """) == []
  end

  test "issue_identifier mismatch is dropped" do
    assert parse_single("""
           kind: review-request
           round_id: 1
           stage_round: 1
           reviewed_sha: #{@sha1}
           issue_identifier: #{@other_issue}
           """) == []
  end

  test "archived fenced block is ignored" do
    workpad =
      wrap_region("""
      ```symphony-marker-archived
      kind: review-request
      round_id: 1
      stage_round: 1
      reviewed_sha: #{@sha1}
      issue_identifier: #{@issue}
      ```
      """)

    assert MarkerParser.parse(workpad, @issue) == []
  end

  test "fenced block outside BEGIN/END is ignored" do
    workpad = """
    #{marker_block(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue)}

    #{wrap_region("")}
    """

    assert MarkerParser.parse(workpad, @issue) == []
  end

  test "multiple markers are returned in text order" do
    workpad =
      wrap_region("""
      #{marker_block(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue)}
      #{marker_block(kind: "code-review", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue, verdict: "findings")}
      #{marker_block(kind: "docs-checked", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue, docfix_outcome: "updated")}
      """)

    markers = MarkerParser.parse(workpad, @issue)

    assert Enum.map(markers, & &1.kind) == [:review_request, :code_review, :docs_checked]
    assert Enum.map(markers, & &1.stage_round) == [1, 1, 1]
  end

  test "review_pending? is true when the last review marker is a review-request" do
    markers =
      parse_markers("""
      #{marker_block(kind: "code-review", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue, verdict: "clean")}
      #{marker_block(kind: "review-request", round_id: 2, stage_round: 1, reviewed_sha: @sha2, issue_identifier: @issue)}
      """)

    assert MarkerParser.review_pending?(markers)
  end

  test "review_pending? is false when the last review marker is a code-review" do
    markers =
      parse_markers("""
      #{marker_block(kind: "review-request", round_id: 2, stage_round: 1, reviewed_sha: @sha2, issue_identifier: @issue)}
      #{marker_block(kind: "code-review", round_id: 2, stage_round: 1, reviewed_sha: @sha2, issue_identifier: @issue, verdict: "findings")}
      """)

    refute MarkerParser.review_pending?(markers)
  end

  test "latest_code_review returns the current round findings verdict" do
    markers =
      parse_markers("""
      #{marker_block(kind: "code-review", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue, verdict: "clean")}
      #{marker_block(kind: "review-request", round_id: 2, stage_round: 1, reviewed_sha: @sha2, issue_identifier: @issue)}
      #{marker_block(kind: "code-review", round_id: 2, stage_round: 1, reviewed_sha: @sha2, issue_identifier: @issue, verdict: "findings")}
      """)

    assert %Marker{verdict: :findings, reviewed_sha: @sha2} = MarkerParser.latest_code_review(markers)
  end

  test "latest_review_sha returns only for a clean code-review in the current round" do
    clean_markers =
      parse_markers("""
      #{marker_block(kind: "review-request", round_id: 2, stage_round: 1, reviewed_sha: @sha2, issue_identifier: @issue)}
      #{marker_block(kind: "code-review", round_id: 2, stage_round: 1, reviewed_sha: @sha2, issue_identifier: @issue, verdict: "clean")}
      """)

    findings_markers =
      parse_markers("""
      #{marker_block(kind: "review-request", round_id: 2, stage_round: 1, reviewed_sha: @sha2, issue_identifier: @issue)}
      #{marker_block(kind: "code-review", round_id: 2, stage_round: 1, reviewed_sha: @sha2, issue_identifier: @issue, verdict: "findings")}
      """)

    assert MarkerParser.latest_review_sha(clean_markers) == @sha2
    assert MarkerParser.latest_review_sha(findings_markers) == nil
  end

  test "docs_checked_matches_review? is true when docs-checked sha matches latest clean review sha" do
    markers =
      parse_markers("""
      #{marker_block(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue)}
      #{marker_block(kind: "code-review", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue, verdict: "clean")}
      #{marker_block(kind: "docs-checked", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue, docfix_outcome: "no-updates")}
      """)

    assert MarkerParser.docs_checked_matches_review?(markers)
  end

  test "docs_checked_matches_review? is false when docs-checked sha differs from latest clean review sha" do
    markers =
      parse_markers("""
      #{marker_block(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue)}
      #{marker_block(kind: "code-review", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue, verdict: "clean")}
      #{marker_block(kind: "docs-checked", round_id: 1, stage_round: 1, reviewed_sha: @sha3, issue_identifier: @issue, docfix_outcome: "updated")}
      """)

    refute MarkerParser.docs_checked_matches_review?(markers)
  end

  test "docs_checked_matches_review? looks at last docs-checked, not any matching older one" do
    # older docs-checked matches clean review sha, newer one does not (stale after extra commit)
    markers =
      parse_markers("""
      #{marker_block(kind: "review-request", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue)}
      #{marker_block(kind: "code-review", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue, verdict: "clean")}
      #{marker_block(kind: "docs-checked", round_id: 1, stage_round: 1, reviewed_sha: @sha1, issue_identifier: @issue, docfix_outcome: "no-updates")}
      #{marker_block(kind: "docs-checked", round_id: 1, stage_round: 2, reviewed_sha: @sha3, issue_identifier: @issue, docfix_outcome: "updated")}
      """)

    refute MarkerParser.docs_checked_matches_review?(markers)
  end

  test "code-review with valid verdict but malformed findings still parses with findings: nil" do
    workpad =
      wrap_region("""
      ```symphony-marker
      kind: code-review
      round_id: 1
      stage_round: 1
      reviewed_sha: #{@sha1}
      issue_identifier: #{@issue}
      verdict: findings
      findings: "this should be a list"
      ```
      """)

    assert [%Marker{kind: :code_review, verdict: :findings, findings: nil}] =
             MarkerParser.parse(workpad, @issue)
  end

  defp parse_single(yaml_body) do
    yaml_body
    |> marker_block()
    |> wrap_region()
    |> MarkerParser.parse(@issue)
  end

  defp parse_markers(blocks) do
    blocks
    |> wrap_region()
    |> MarkerParser.parse(@issue)
  end

  defp wrap_region(inner) do
    """
    intro text

    <!-- SYMPHONY-MARKERS-BEGIN -->
    #{String.trim(inner)}
    <!-- SYMPHONY-MARKERS-END -->

    footer text
    """
  end

  defp marker_block(fields) when is_binary(fields) do
    """
    ```symphony-marker
    #{String.trim(fields)}
    ```
    """
  end

  defp marker_block(fields) when is_list(fields) do
    fields
    |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{yaml_value(value)}" end)
    |> marker_block()
  end

  defp yaml_value(value) when is_binary(value), do: value
  defp yaml_value(value) when is_integer(value), do: Integer.to_string(value)
end
