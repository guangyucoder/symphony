defmodule SymphonyElixir.WorkpadParser do
  @moduledoc """
  Parses the `### Plan` section from a Codex Workpad comment to extract
  a structured checklist of subtasks for unit-lite dispatch.

  Expected format (from WORKFLOW-production.md):

      ### Plan
      - [x] [plan-1] Completed item
      - [ ] [plan-2] Current item ← HERE
      - [ ] [plan-3] Remaining item

  Falls back to positional IDs (plan-1, plan-2, ...) when explicit IDs
  are missing.

  Continuation-line semantics are intentionally asymmetric:
  - Multiple `touch:` lines concatenate their comma-split paths.
  - Multiple `accept:` lines keep the last non-empty value.

  Plan authors: merge acceptance criteria onto one `accept:` line when the
  intent is a single criterion.
  """

  @type subtask :: %{
          id: String.t(),
          text: String.t(),
          done: boolean(),
          touch: [String.t()],
          accept: String.t() | nil
        }

  # Matches: - [x] [plan-1] text  OR  * [ ] [plan-1] text
  @explicit_id_pattern ~r/^\s*[-*]\s+\[([ xX])\]\s+\[([^\]]+)\]\s+(.+)$/
  # Matches: - [x] text  OR  * [ ] text (no explicit ID)
  @implicit_id_pattern ~r/^\s*[-*]\s+\[([ xX])\]\s+(.+)$/
  @continuation_pattern ~r/^\s+[-*]\s+(touch|accept)\s*:\s*(.*?)\s*$/i

  @doc """
  Parse workpad text and extract subtask checklist from the `### Plan` section.
  Returns {:ok, subtasks} or {:error, reason}.
  """
  @spec parse(String.t()) :: {:ok, [subtask()]} | {:error, atom()}
  def parse(workpad_text) when is_binary(workpad_text) do
    case extract_plan_section(workpad_text) do
      nil ->
        {:error, :no_plan_section}

      plan_text ->
        subtasks = parse_checklist(plan_text)

        if subtasks == [] do
          {:error, :no_checklist_items}
        else
          {:ok, subtasks}
        end
    end
  end

  def parse(_), do: {:error, :invalid_input}

  @doc "Return only pending (unchecked) subtasks."
  @spec pending(String.t()) :: {:ok, [subtask()]} | {:error, atom()}
  def pending(workpad_text) do
    case parse(workpad_text) do
      {:ok, subtasks} -> {:ok, Enum.filter(subtasks, &(not &1.done))}
      error -> error
    end
  end

  @doc "Return the next unchecked subtask, or nil."
  @spec next_pending(String.t()) :: subtask() | nil
  def next_pending(workpad_text) do
    case pending(workpad_text) do
      {:ok, [next | _]} -> next
      _ -> nil
    end
  end

  @doc "Check if all subtasks are done."
  @spec all_done?(String.t()) :: boolean()
  def all_done?(workpad_text) do
    case parse(workpad_text) do
      {:ok, subtasks} -> Enum.all?(subtasks, & &1.done)
      _ -> false
    end
  end

  @doc """
  Extract the verdict in the latest `### Code Review` section.

  Returns `"clean"` | `"findings"` when a parseable `Verdict:` line is present;
  `:invalid` when the section exists but has no parseable verdict (closeout
  retries rather than advancing); `:missing` when no section exists.

  Case-insensitive on both heading and verdict value. When agents append new
  rounds inside the same section, the **last** `Verdict:` line wins so
  historical rounds do not overshadow current state.
  """
  @spec code_review_verdict(String.t() | nil) :: String.t() | :invalid | :missing
  def code_review_verdict(workpad_text) when is_binary(workpad_text) do
    case extract_code_review_section(workpad_text) do
      nil -> :missing
      section -> parse_verdict_line(section)
    end
  end

  def code_review_verdict(_), do: :missing

  @doc """
  Extract the latest `Reviewed SHA:` value from the latest `### Code Review`
  section. Closeout uses this to verify the review was actually written for
  the current HEAD — without this check, a stale section left over from a
  prior round can bless a new HEAD as "reviewed" when the review session
  never wrote anything new.

  Returns the sha string on a match; `:invalid` if a section exists with
  no parseable Reviewed SHA line; `:missing` when no section exists.
  """
  @spec code_review_reviewed_sha(String.t() | nil) :: String.t() | :invalid | :missing
  def code_review_reviewed_sha(workpad_text) when is_binary(workpad_text) do
    case extract_code_review_section(workpad_text) do
      nil -> :missing
      section -> parse_reviewed_sha_line(section)
    end
  end

  def code_review_reviewed_sha(_), do: :missing

  @doc """
  Return the body of the LATEST `### Code Review` section, trimmed. Used by
  PromptBuilder to inject findings into the `review-fix-N` implement dispatch
  — the review thread and the implement thread are SEPARATE Codex threads,
  so the implement side cannot see findings via conversation history alone.
  Returns `nil` when no section exists.
  """
  @spec latest_code_review_section(String.t() | nil) :: String.t() | nil
  def latest_code_review_section(workpad_text) when is_binary(workpad_text) do
    case extract_code_review_section(workpad_text) do
      nil -> nil
      section -> String.trim(section)
    end
  end

  def latest_code_review_section(_), do: nil

  defp parse_reviewed_sha_line(section) do
    # Match a hex prefix (≥7 chars) on the Reviewed SHA line, not a bare
    # \S+ token. Agents commonly wrap the SHA in backticks / brackets /
    # parens (Markdown formatting habits); \S+ would capture the wrappers,
    # breaking closeout's prefix-match against current HEAD. The [0-9a-f]
    # class excludes punctuation implicitly.
    matches =
      Regex.scan(
        ~r/^\s*[-*]?\s*reviewed\s+sha\s*:[^\n]*?([0-9a-f]{7,40})/im,
        section,
        capture: :all_but_first
      )

    case List.last(matches) do
      [raw] -> String.downcase(String.trim(raw))
      nil -> :invalid
    end
  end

  defp parse_verdict_line(section) do
    # Require the Verdict: line to END with exactly `clean` or `findings`
    # (modulo trailing whitespace). Anchoring to end-of-line rejects prose
    # like "Verdict: clean because visual review skipped" — otherwise the
    # agent can unlock the clean path by qualifying the verdict with excuses.
    # Leading `- ` / `* ` list markers still tolerated.
    matches =
      Regex.scan(
        ~r/^\s*[-*]?\s*verdict\s*:\s*(clean|findings)\s*$/im,
        section,
        capture: :all_but_first
      )

    case List.last(matches) do
      [raw_verdict] -> String.downcase(raw_verdict)
      nil -> :invalid
    end
  end

  @doc """
  Truncate the workpad so the rendered form stays under `max_bytes`, while
  preserving the sections that gate dispatch decisions (`### Plan` and the
  latest `### Code Review`). Oldest `### Notes` continuation entries are
  dropped first; if more space is needed after that, whole `### Notes` is
  dropped; the Plan / latest Code Review are never cut mid-line.

  Returns the original text when it already fits, a reduced-but-coherent
  string when trimming happens (with an explicit elision marker inserted),
  or `nil` when input is nil.

  See docs/design/warm-session-review-loop.md — this is the core guard
  against the "workpad cut-off silently loses the latest findings" failure
  mode that breaks resumed implement sessions.
  """
  @spec truncate_preserving_sections(String.t() | nil, pos_integer()) :: String.t() | nil
  def truncate_preserving_sections(nil, _), do: nil

  def truncate_preserving_sections(text, max_bytes) when is_binary(text) and is_integer(max_bytes) and max_bytes > 0 do
    if byte_size(text) <= max_bytes do
      text
    else
      result =
        case split_sections(text) do
          {preamble, []} ->
            # No level-3 headings at all (agent used ## or non-standard depth).
            # Section-aware trimming has nothing to work with; fall back to a
            # head-byte cap. The elision marker takes space, so reserve for it
            # by cutting preamble to max_bytes - marker_size first.
            marker = "\n<!-- workpad truncated to fit prompt budget -->\n"
            marker_size = byte_size(marker)

            if max_bytes > marker_size do
              take_head_bytes(preamble, max_bytes - marker_size) <> marker
            else
              # Cap is smaller than the marker itself — just byte-cap the text.
              take_head_bytes(preamble, max_bytes)
            end

          sections ->
            reduce_sections(sections, max_bytes)
        end

      # Final hard cap. Take-head-bytes-as-last-resort was the Iter 6 hotfix
      # for marker-inflation, but at tiny caps (< Plan + Code Review sizes)
      # it reintroduces the exact head-cut bug this function exists to
      # prevent — slicing `### Code Review` mid-heading and dropping the
      # `Verdict:` line. Instead: if still over budget, drop Plan entirely
      # and emit `preamble + latest Code Review` only; if even that doesn't
      # fit, emit a minimal `### Code Review\n<Verdict line>` skeleton so the
      # load-bearing lines (heading + Verdict, used by closeout) survive.
      if byte_size(result) <= max_bytes do
        result
      else
        preserve_code_review_at_all_costs(text, max_bytes)
      end
    end
  end

  # Last-ditch: extract the latest `### Code Review` block, render it alone
  # (no preamble, no Plan, no Notes). If it STILL exceeds max_bytes, reduce
  # to the minimum viable shape — `### Code Review\n<Verdict line>\n`.
  # Guarantees closeout can still parse Verdict + Reviewed SHA.
  defp preserve_code_review_at_all_costs(text, max_bytes) do
    {_preamble, sections} = split_sections(text)
    last_review_idx = last_index_of(sections, :code_review)

    case last_review_idx do
      nil ->
        # No Code Review to preserve — fall back to hard head-cut with
        # marker. When cap is smaller than the marker itself, skip the
        # marker entirely (Iter 10 Codex MEDIUM: otherwise the marker
        # inflates result past the cap we promised to enforce).
        marker = "\n<!-- workpad truncated to fit prompt budget -->\n"

        if max_bytes > byte_size(marker) do
          take_head_bytes(text, max_bytes - byte_size(marker)) <> marker
        else
          take_head_bytes(text, max_bytes)
        end

      idx ->
        review = Enum.at(sections, idx)
        rendered = (review.heading || "### Code Review") <> "\n" <> review.body

        if byte_size(rendered) <= max_bytes do
          rendered
        else
          minimal_code_review_skeleton(review, max_bytes)
        end
    end
  end

  defp minimal_code_review_skeleton(%{body: body, heading: heading}, max_bytes) do
    verdict_line =
      Regex.run(~r/^\s*[-*]?\s*verdict\s*:[^\n]*/im, body)
      |> case do
        [line] -> line
        _ -> "Verdict: findings"
      end

    skeleton = (heading || "### Code Review") <> "\n" <> verdict_line <> "\n"

    if byte_size(skeleton) <= max_bytes do
      skeleton
    else
      # Cap is absurdly small; keep the Verdict line and drop the heading.
      take_head_bytes(verdict_line, max_bytes)
    end
  end

  defp take_head_bytes(text, byte_cap) when byte_size(text) <= byte_cap, do: text

  defp take_head_bytes(text, byte_cap) do
    text |> binary_part(0, byte_cap) |> trim_invalid_utf8_tail()
  end

  defp trim_invalid_utf8_tail(<<>>), do: <<>>

  defp trim_invalid_utf8_tail(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_invalid_utf8_tail(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  # Split the workpad into {preamble, [section_block]} where each section_block
  # keeps its heading + body together. Preamble is anything before the first
  # level-3 heading (usually `## Codex Workpad\n` plus any stamp line).
  defp split_sections(text) do
    # Split on level-3 headings at the start of a line. Regex captures the
    # heading so we can re-prepend it to each section.
    parts = Regex.split(~r/(?=^###(?!#))/m, text, trim: false)

    case parts do
      [only] ->
        {only, []}

      [preamble | rest] ->
        sections =
          Enum.map(rest, fn chunk ->
            {heading, body} = split_heading(chunk)
            classify_section(heading, body)
          end)

        {preamble, sections}
    end
  end

  defp split_heading(chunk) do
    case String.split(chunk, "\n", parts: 2) do
      [heading, body] -> {heading, body}
      [heading] -> {heading, ""}
    end
  end

  defp classify_section(heading, body) do
    cond do
      Regex.match?(~r/^###\s*Plan\b/i, heading) ->
        %{kind: :plan, heading: heading, body: body}

      Regex.match?(~r/^###\s*Code[\s_-]*Review\b/i, heading) ->
        %{kind: :code_review, heading: heading, body: body}

      Regex.match?(~r/^###\s*Notes\b/i, heading) ->
        %{kind: :notes, heading: heading, body: body}

      true ->
        %{kind: :other, heading: heading, body: body}
    end
  end

  # Budget-aware reducer. Keep Plan and the LAST Code Review intact; trim
  # Notes content (oldest `#### continuation` blocks first) or drop entire
  # non-essential sections to fit. On drop, leave an explicit elision marker
  # so readers (human or agent) see something was omitted.
  defp reduce_sections({preamble, sections}, max_bytes) do
    # Sections in render order. Find the index of the LAST Code Review.
    last_review_idx = last_index_of(sections, :code_review)

    # Step 1: drop all non-Plan / non-last-Code-Review / non-Notes sections first
    trimmed =
      sections
      |> Enum.with_index()
      |> Enum.map(fn {section, idx} ->
        cond do
          section.kind == :plan -> section
          section.kind == :code_review and idx == last_review_idx -> section
          section.kind == :notes -> section
          true -> drop_section(section)
        end
      end)

    rendered = render_preamble_and_sections(preamble, trimmed)

    if byte_size(rendered) <= max_bytes do
      rendered
    else
      # Step 2: trim Notes by dropping oldest continuations
      step2 = trim_notes_oldest_first(preamble, trimmed, max_bytes)
      rendered2 = render_preamble_and_sections(preamble, step2)

      if byte_size(rendered2) <= max_bytes do
        rendered2
      else
        # Step 3: Notes content had to go entirely. If still over budget,
        # drop the Notes section heading itself too (Plan + latest Code Review
        # remain — they are load-bearing for dispatch decisions).
        step3 =
          Enum.map(step2, fn section ->
            if section.kind == :notes, do: drop_section(section), else: section
          end)

        rendered3 = render_preamble_and_sections(preamble, step3)

        if byte_size(rendered3) <= max_bytes do
          rendered3
        else
          # Step 4 (final hard cap): Plan + latest Code Review together exceed
          # the budget. Trim the Plan body at a line boundary first (cheaper
          # to lose plan detail than review findings). If still over, trim the
          # Code Review body at a line boundary. Never leaves a heading with
          # only a partial line after it — cut points are between lines.
          hard_cap_sections(preamble, step3, max_bytes)
        end
      end
    end
  end

  # Final budget enforcement when Plan + latest Code Review genuinely don't
  # fit. Priority: Code Review survives → trim Plan body, then Code Review body.
  # Cuts happen at newline boundaries with an explicit "(trimmed …)" marker so
  # the agent sees what was dropped. Total still may slightly exceed max_bytes
  # if the two essential headings alone exceed it — in that case we return the
  # minimal shape (empty bodies + markers) rather than truncating a heading.
  defp hard_cap_sections(preamble, sections, max_bytes) do
    last_review_idx = last_index_of(sections, :code_review)

    # First pass: trim Plan body.
    sections =
      Enum.map(sections, fn s ->
        if s.kind == :plan, do: trim_body_to_fit(s, :plan), else: s
      end)

    rendered = render_preamble_and_sections(preamble, sections)

    if byte_size(rendered) <= max_bytes do
      rendered
    else
      # Second pass: trim the latest Code Review body. We keep the Verdict
      # line at the tail since closeout parses it — trim from the TOP.
      sections =
        sections
        |> Enum.with_index()
        |> Enum.map(fn {s, idx} ->
          if s.kind == :code_review and idx == last_review_idx do
            overflow = byte_size(render_preamble_and_sections(preamble, sections)) - max_bytes
            trim_code_review_body(s, max(overflow, 0))
          else
            s
          end
        end)

      render_preamble_and_sections(preamble, sections)
    end
  end

  defp trim_body_to_fit(section, :plan) do
    lines = String.split(section.body, "\n")
    # Keep only the first 8 lines of the Plan — plenty to signal structure.
    kept = Enum.take(lines, 8)

    trimmed_body =
      Enum.join(kept, "\n") <>
        if length(lines) > 8, do: "\n<!-- remaining plan lines omitted to fit prompt budget -->\n", else: "\n"

    %{section | body: trimmed_body}
  end

  defp trim_code_review_body(section, overflow_bytes) when overflow_bytes > 0 do
    lines = String.split(section.body, "\n")

    # Find the `Reviewed SHA:` line — it's load-bearing (closeout parses it
    # to verify the review covered current HEAD; cold review-fix uses it to
    # git diff against). If we blindly top-drop and slice it off, the cold
    # agent sees "Verdict: findings" but can't find WHICH HEAD was reviewed.
    {sha_line_idx, _} =
      Enum.with_index(lines)
      |> Enum.find({nil, nil}, fn {line, _} ->
        Regex.match?(~r/^\s*[-*]?\s*reviewed\s+sha\s*:/i, line)
      end)

    body_candidate_drop = min(length(lines) - 3, estimate_lines_to_drop(lines, overflow_bytes))

    # Never drop past (or over) the Reviewed SHA line.
    drop_count =
      if is_integer(sha_line_idx) do
        min(body_candidate_drop, sha_line_idx)
      else
        body_candidate_drop
      end

    kept = Enum.drop(lines, drop_count)

    body =
      if drop_count > 0 do
        "<!-- oldest #{drop_count} Code Review line(s) omitted to fit prompt budget -->\n" <>
          Enum.join(kept, "\n")
      else
        Enum.join(kept, "\n")
      end

    %{section | body: body}
  end

  defp trim_code_review_body(section, _), do: section

  defp estimate_lines_to_drop(lines, overflow_bytes) do
    # Prefix-sum over line byte sizes; drop until the cumulative drop meets overflow.
    Enum.reduce_while(Enum.with_index(lines), {0, 0}, fn {line, idx}, {total, _} ->
      new_total = total + byte_size(line) + 1
      if new_total >= overflow_bytes, do: {:halt, {new_total, idx + 1}}, else: {:cont, {new_total, idx + 1}}
    end)
    |> elem(1)
  end

  defp last_index_of(sections, kind) do
    sections
    |> Enum.with_index()
    |> Enum.filter(fn {s, _} -> s.kind == kind end)
    |> List.last()
    |> case do
      {_, idx} -> idx
      nil -> nil
    end
  end

  defp drop_section(section) do
    %{section | heading: nil, body: "<!-- section omitted to fit prompt budget: #{section.kind} -->\n"}
  end

  # Split Notes body at `#### ` subheadings (which is how continuation notes
  # are scaffolded) and drop the earliest ones until the whole workpad fits.
  defp trim_notes_oldest_first(preamble, sections, max_bytes) do
    case Enum.find_index(sections, &(&1.kind == :notes)) do
      nil ->
        sections

      idx ->
        notes = Enum.at(sections, idx)
        # split_notes_blocks returns {preamble, [continuation_blocks]} so the
        # Notes preamble can be preserved while old continuations are dropped.
        {notes_preamble, continuations} = split_notes_blocks(notes.body)

        trimmed_notes =
          shrink_until_fit(preamble, sections, idx, {notes_preamble, continuations}, max_bytes)

        List.replace_at(sections, idx, trimmed_notes)
    end
  end

  defp shrink_until_fit(preamble, sections, notes_idx, {notes_preamble, continuations}, max_bytes) do
    notes = Enum.at(sections, notes_idx)

    # Try dropping oldest CONTINUATION blocks one at a time — the Notes
    # preamble (`- branch:` / `- key decision:` global context set by plan)
    # is load-bearing for later rounds and must survive.
    Enum.reduce_while(0..length(continuations), continuations, fn drop_count, current ->
      reduced_notes = %{notes | body: render_notes_body(notes_preamble, current, drop_count)}
      candidate_sections = List.replace_at(sections, notes_idx, reduced_notes)
      rendered = render_preamble_and_sections(preamble, candidate_sections)

      if byte_size(rendered) <= max_bytes do
        {:halt, reduced_notes}
      else
        if drop_count >= length(current) do
          # Can't drop more continuations; keep Notes preamble only with an
          # elision note. Preamble stays even here — it's small and load-bearing.
          {:halt,
           %{notes | body: notes_preamble <> "<!-- all continuation notes omitted to fit prompt budget -->\n"}}
        else
          {:cont, current}
        end
      end
    end)
  end

  # Split the Notes body into `{preamble, [continuation_block, ...]}`.
  # Preamble is everything before the first `#### ` heading (the plan-set
  # global context like branch name and key decisions).
  defp split_notes_blocks(body) do
    case Regex.split(~r/(?=^####\s)/m, body, trim: false) do
      [only] ->
        {only, []}

      [preamble | rest] ->
        {preamble, rest}
    end
  end

  defp render_notes_body(preamble, continuations, 0) do
    preamble <> Enum.join(continuations, "")
  end

  defp render_notes_body(preamble, continuations, drop_count) when drop_count > 0 do
    kept = Enum.drop(continuations, drop_count)
    marker = "<!-- #{drop_count} older continuation note(s) omitted to fit prompt budget -->\n"
    preamble <> marker <> Enum.join(kept, "")
  end

  defp render_preamble_and_sections(preamble, sections) do
    body =
      sections
      |> Enum.map(fn
        %{heading: nil, body: body} -> body
        %{heading: heading, body: body} -> heading <> "\n" <> body
      end)
      |> Enum.join("")

    preamble <> body
  end

  defp extract_code_review_section(text) do
    # Capture from the Code Review heading to the next level-3 heading or EOF.
    # Returns the LAST matching section — an agent that appends a fresh
    # `### Code Review` sibling per round (rather than round-within-section)
    # must have its newest verdict read, not the stale first occurrence.
    case Regex.scan(~r/###\s*Code[\s_-]*Review\b[^\n]*\n(.*?)(?=\n###(?!#)|\z)/is, text) do
      [] -> nil
      matches -> matches |> List.last() |> Enum.at(1)
    end
  end

  # --- Private ---

  defp extract_plan_section(text) do
    # Find ### Plan header, capture until the next level-3 heading or end.
    case Regex.run(~r/###\s*Plan\s*\n(.*?)(?=\n###(?!#)|\z)/s, text) do
      [_, section] -> String.trim(section)
      _ -> nil
    end
  end

  defp parse_checklist(plan_text) do
    plan_text
    |> String.split("\n")
    |> Enum.reduce({[], nil, 1}, &collect_checklist_line/2)
    |> finalize_checklist_groups()
    |> Enum.map(&parse_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp collect_checklist_line(line, {items, current_item, index}) do
    cond do
      checklist_item_line?(line) ->
        {
          maybe_push_item(items, current_item),
          %{line: line, index: index, continuation_lines: []},
          index + 1
        }

      heading_line?(line) ->
        {maybe_push_item(items, current_item), nil, index}

      current_item && continuation_line?(line) ->
        continuation_lines = current_item.continuation_lines ++ [line]
        {items, %{current_item | continuation_lines: continuation_lines}, index}

      true ->
        {items, current_item, index}
    end
  end

  defp finalize_checklist_groups({items, current_item, _index}) do
    items
    |> maybe_push_item(current_item)
    |> Enum.reverse()
  end

  defp maybe_push_item(items, nil), do: items
  defp maybe_push_item(items, item), do: [item | items]

  defp parse_item(%{line: line, index: index, continuation_lines: continuation_lines}) do
    contract = parse_contract(continuation_lines)

    cond do
      # Try explicit ID first: - [x] [plan-1] text
      match = Regex.run(@explicit_id_pattern, line) ->
        [_, check, id, text] = match

        %{id: String.trim(id), text: String.trim(text), done: checked?(check)}
        |> Map.merge(contract)

      # Fall back to implicit ID: - [x] text
      match = Regex.run(@implicit_id_pattern, line) ->
        [_, check, text] = match

        %{id: "plan-#{index}", text: String.trim(text), done: checked?(check)}
        |> Map.merge(contract)

      true ->
        nil
    end
  end

  defp parse_contract(lines) do
    Enum.reduce(lines, %{touch: [], accept: nil}, fn line, acc ->
      case parse_continuation_line(line) do
        {:touch, paths} ->
          %{acc | touch: acc.touch ++ paths}

        {:accept, nil} ->
          acc

        {:accept, accept} ->
          %{acc | accept: accept}

        nil ->
          acc
      end
    end)
  end

  defp parse_continuation_line(line) do
    case Regex.run(@continuation_pattern, line) do
      [_, key, value] ->
        case String.downcase(key) do
          "touch" ->
            {:touch, split_touch_paths(value)}

          "accept" ->
            {:accept, normalized_value(value)}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp split_touch_paths(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalized_value(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp checklist_item_line?(line) do
    Regex.match?(@explicit_id_pattern, line) or Regex.match?(@implicit_id_pattern, line)
  end

  defp continuation_line?(line), do: Regex.match?(@continuation_pattern, line)
  defp heading_line?(line), do: Regex.match?(~r/^\s*###(?!#)/, line)

  defp checked?(check), do: check in ["x", "X"]
end
