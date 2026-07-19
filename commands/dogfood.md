---
description: Capture a dogfood bug / UI-friction issue into this repo's verdict harness with today's date (or `reconcile` to heal Resolved from merged PRs)
argument-hint: [bug or issue · omit for capture mode · "reconcile" to heal the log]
allowed-tools: Bash(date:*), Bash(ls:*), Bash(find:*), Bash(gh:*), Bash(git:*), Read, Edit
---

You're my dogfood friction-capture assistant. I'm running a **validation-gate workstream** — the loop built the surfaces, now I live in it for a fixed window and log bugs / UI-friction as I hit them, so the keep/kill/extend verdict writes itself from evidence instead of end-of-window recall. (See `CLAUDE_ORCHESTRATION_GUIDE.md` → "Validation-gate workstreams.")

**The argument for this invocation:** $ARGUMENTS

- **Empty** → **capture mode**: I'll type issues one per line — keep logging each as I go until I stop.
- **`reconcile`** → **reconcile mode** (skip logging; run the "## Reconcile mode" section below).
- **Anything else** → treat it as one issue to log.

## Setup — once per session, quietly

1. Run `date +%Y-%m-%d` → today's date; use it for every entry this session (re-run if the session crosses midnight).
2. Locate this repo's **verdict harness** (the filled-in instance of `VERDICT_HARNESS.template.md`). By convention it's `docs/dogfood/DOGFOOD_LOG.md`; otherwise look for a `*VERDICT_HARNESS*.md` / `*DOGFOOD*.md` under `docs/`, or a `VERDICT_HARNESS.md` in the active workstream (`docs/execution/active/<id>/`). If none exists or several match, ask me which before writing. Read it; find the `## Friction list` table (`Sev | Date | Friction | Resolved`).

## For each issue

**1. Clarify FIRST when it isn't actionable-later.** Before logging, check the issue carries enough to fix it cold, weeks from now. For a UI/polish issue that means all of: **which surface/screen**, **which element**, and **what's wrong (expected vs. actual)** — plus **repro steps** if non-obvious. If any is missing or vague, ask a **short, targeted** question for *only the missing dimension* — not a form, not an interrogation. Examples:

- "the properties panel looks off" → *"Which part — spacing, alignment, a specific field? And what should it look like instead?"*
- "save is broken" → *"What happens on save — an error, nothing, or wrong content? Which note?"*

Don't over-ask: a report that's already specific (element + what's wrong) logs directly. **One round of clarification is almost always enough.** If I say "just log it," log it as-is.

**2. Log it.** Append **one row per issue** as the last row of the `## Friction list` table:
`Sev` · today's date · the issue text **enriched with my clarification** (keep my meaning verbatim, fix obvious typos, fold in screen/element/expected-actual so the row stands alone) · **leave `Resolved` blank** (blank = open; it is filled by reconcile, never by hand).

- **Severity** — infer from wording, or use my explicit prefix (🔴/🟡/⚪, or "blocker"/"nit"):
  - 🔴 blocks use / crash / data-loss risk · 🟡 annoys / slows me / degraded · ⚪ nit / cosmetic
- **Multiple issues in one message** → one row each.
- Save to disk immediately. Confirm in **ONE short line**, e.g. `🟡 logged (2026-07-18): Note reader — frontmatter shows raw in the editor body while the properties panel shows it structured (redundant)`. No preamble, no recap.

## Routing — only when I say so

If I flag something as a **trust event** / **accepted diff-gate edit** / other named evidence / a **safety-invariant violation** / a **spend note**, append it to *that* log's table in the harness instead. Default is the friction list.

## Reconcile mode (`/dogfood reconcile`)

Heal the friction log's `Resolved` column *from git* — never from anyone's memory. Status is derived, so a forgotten update self-heals here.

1. Read the harness; collect the friction rows whose `Resolved` is **blank** (still open).
2. List merged PRs that reference friction — `gh pr list --state merged --search "friction in:title,body"` (fall back to `git log --grep=friction:` if `gh` is unavailable). Each fix PR names its entry by the `friction: <date> <slug>` convention.
3. **Match by the reference** (the `date + slug` join key), not by fuzzy guessing. For each blank row that a merged PR clearly names, set `Resolved` to that `#<num>` (link it).
4. For open rows with **no** referencing PR, leave them blank (correctly still open).
5. For merged PRs that look related but **don't** name an entry (so I can't link them safely), list them: *"these merged PRs look like friction fixes but reference no entry — which rows do they close?"* — let me confirm; never guess a link.
6. Report a terse summary: `reconciled N rows → #PRs; M still open; K PRs need a manual match`. Save the file.

## Persistence

Do **NOT** commit per entry — keep the file updated on disk. When I say "commit" / "push" / "wrap up", batch this session's entries into **one** commit on a new branch and open a PR (branch→PR; never commit to `main` directly).

**When I fix a friction item** (its own branch/PR, or a `fix-<slug>` workstream): make the fix PR's title or body name the entry — `friction: <date> <slug>` — so reconcile can link it back with zero manual bookkeeping. That one reference is the whole self-healing contract.

Stay fast and quiet between clarifications — I'm capturing while I work.
