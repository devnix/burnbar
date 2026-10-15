# ADR-0001: Optional `[[ ]]` groups in the format string

## Status

Accepted — 2026-06-25.

## Context

Some `{tag}`s render empty depending on runtime state. The clearest case is the
`{5h}`/`{1w}` plan-usage meters, which come from the JSON `rate_limits` fields and
are present **only for Pro/Max subscribers, after the first API response**. For a
non-subscriber (or before that first response) they expand to an empty string.

Other tags can also be empty: `{monthly}`/`{daily}` (no ccusage data yet),
`{delta}`/`{spark}` (no completed turn), `{cache}` (placeholder only).

The format string lets users keep static labels *outside* the tag, e.g.
`5h: {5h}` or `cache: {cache}`. When such a tag is empty, the label is left
orphaned (`5h: ` with nothing after it) and the surrounding `{sep}` separators
collapse into doubled `│ │` or a trailing `│`.

Two rejected alternatives:

- **Label-in-value** (move `5h:` into the rendered `_5h`): hides the label from the
  user — it is no longer customizable via `BURNBAR_FORMAT`.
- **Affix-on-tag** (a per-tag prefix/suffix syntax): needs regex parsing in the
  per-second hot path, and only solves the single-tag case.

## Decision

Introduce an **optional group** construct in the format string:

> `[[ ... ]]` survives **iff at least one `{tag}` inside it expands to non-empty.**
> Zero tags inside, or all empty → the whole group (literal text included) disappears.

Rules (kept deliberately small):

- Flat — no nested groups.
- No `{sep}`/`{wrap}` inside a group.
- `[[` / `]]` are reserved, no escape mechanism (YAGNI).

The default format wraps the three labels that sit outside an empty-capable tag —
`[[cache: {cache}]]`, `[[5h: {5h}]]`, `[[1w: {1w}]]`. The remaining tags carry an
internal label (`mo:`, `day:`, `next:`) or are fully empty, so they need no group;
the separator-collapse pass handles their dangling `{sep}`.

A companion **`{sep}` collapse pass** runs before the wrap/sep loop: it splits on
the still-literal `{sep}`, drops blank segments, and rejoins — removing the doubled
or trailing separators a vanished group (or a fully empty bare tag) would leave.

## Consequences

- The format mini-language gains one construct; the renderer gains two pure-bash
  passes (group resolution before substitution, separator collapse after).
- Implemented bash-3.2-safe: the group pass scans the literal `{xxx}` tokens and
  checks each tag's `_xxx` bash variable via **indirect expansion** (`${!var}`) —
  no associative array. The `{xxx}`→`_xxx` mapping is uniform across all tag
  substitutions, and `{sep}`/`{wrap}` have no `_sep`/`_wrap` var (so they can never
  keep a group — which is why they are banned inside groups).
- **Glob caution:** `[` is a character-class metacharacter. Every match must quote
  the brackets (`*'[['*`, `\[\[`, `\]\]`); a bare `[` makes a malformed class that
  silently never matches yet still passes `bash -n`.
- Hot-path cost is negligible: pure parameter expansion, zero forks, a handful of
  iterations per tick.
