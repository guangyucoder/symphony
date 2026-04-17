You are working on Linear ticket `{{ issue.identifier }}`: `{{ issue.title }}`.
Current status: `{{ issue.state }}`. Labels: {{ issue.labels }}. URL: {{ issue.url }}

{% if issue.description %}
Description:
{{ issue.description }}
{% endif %}

## Marker Contract (STRICT)
- First, find the existing Linear issue comment whose header is `## Codex Workpad`.
- In that comment, locate the bounded marker section delimited by `<!-- SYMPHONY-MARKERS-BEGIN -->` and `<!-- SYMPHONY-MARKERS-END -->`.
- Markers live only inside that bounded section of the existing Linear `## Codex Workpad` comment:

````markdown
<!-- SYMPHONY-MARKERS-BEGIN -->
```symphony-marker
kind: review-request | code-review | docs-checked
round_id: <integer >= 1>
stage_round: <integer >= 1>
reviewed_sha: <40-char hex SHA>
issue_identifier: {{ issue.identifier }}
```
<!-- SYMPHONY-MARKERS-END -->
````

- Append new markers only between `<!-- SYMPHONY-MARKERS-BEGIN -->` and `<!-- SYMPHONY-MARKERS-END -->` in that Linear comment, after the last existing ` ```symphony-marker ` block and before the END marker.
- Only bounded ` ```symphony-marker ` blocks are parsed. Do not write markers outside that section.
- Required fields for every marker: `kind`, `round_id`, `stage_round`, `reviewed_sha`, `issue_identifier`.
- `issue_identifier` must exactly equal `{{ issue.identifier }}`.
- `reviewed_sha` must be `git rev-parse HEAD` at the moment you write the marker.
- `stage_round` increments independently per `kind` within the same `round_id`.
- Per-kind rules:
  - `review-request`: no extra fields.
  - `code-review`: must include `verdict: clean | findings`; when `verdict: findings`, you may also include optional `findings:` entries with `severity: high | medium | low` and `summary`.
  - `docs-checked`: must include `docfix_outcome: no-updates | updated`.

## Doc-Fix Stage

You are the docs sweeper for this ticket.
Only change `*.md` files and files under `docs/**`. Do not change any non-doc file. Keep docs aligned with the current `HEAD`.

Check whether documentation that should reflect the current code is still accurate, including places such as `AGENTS.md`, `README.md`, and `docs/`.

Follow this order exactly:

1. If no documentation updates are needed, do not make repo changes.
2. If documentation updates are needed, make only doc-path edits, commit them with a message that starts with `docs:`, then push the commit.

Before writing the `docs-checked` marker in either path, ensure all intended doc edits are committed, verify `git status --porcelain` is empty, and take `reviewed_sha` from that clean `git rev-parse HEAD`.

When writing the marker:
- `round_id`: the same `round_id` as the clean review you are responding to.
- `stage_round`: `max(existing docs-checked.stage_round in that round_id) + 1`; first doc-fix in the round is `1`.
- `issue_identifier`: `{{ issue.identifier }}`.

Example:

```symphony-marker
kind: docs-checked
round_id: <current round_id>
stage_round: <next docs-checked stage_round in this round>
reviewed_sha: <git rev-parse HEAD after all doc commits>
issue_identifier: {{ issue.identifier }}
docfix_outcome: no-updates | updated
```

Stop the turn immediately after writing the marker.
