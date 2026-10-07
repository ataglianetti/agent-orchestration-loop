# APPROVAL CARD

<!-- Written by /orchestrate at a clean exit, a FLAG-HUMAN pause, or non-convergence. -->
<!-- the PM approves TWO things only: intent/scope and reversibility. Correctness was delegated to -->
<!-- the verification stack (reviewers + coverage + live-check), not to the PM. Keep depth one step away. -->

## Status

<!-- The loop sets ONE of these and stops. It must NEVER write "APPROVED" — that is a human-only state (see the Approval section). -->
<!-- CLEAN — AWAITING PM APPROVAL = verification satisfied; ready for the PM to judge -->
<!-- FLAG-HUMAN — AWAITING PM RULING = a human call in §4 blocks -->
<!-- NON-CONVERGENT — STOPPED = hit the round cap unresolved -->

CLEAN — AWAITING PM APPROVAL

## 1. What you asked for → what it built

- **Asked:** <the goal in one line>
- **Built:** <what shipped in one line>
- **Scope:** <on-scope · or: drifted — how>

## 2. How reversible

- <behind flag `X` / dark-launched / additive-only / one-commit revert> → wrong is cheap
- <or: touches money / a contract / a data migration / anonymous-access scope> → engage here
- **Revert path:** <one line — how to undo>

## 3. How confident

- **Reviewers:** <N independent passes; agreement — e.g. "3/3 agree, no open findings">
- **Coverage:** <a test exercises this change and passes? · or the gap>
- **Live-check:** <ran against the real endpoint? result>
- **Read:** <"verified three ways, all agree" · or "thin — one reviewer, no live test">

## 4. Decisions needed

<!-- FLAG-HUMAN findings, or the unresolved findings of a NON-CONVERGENT run. These are the ONLY things blocking you. "None." otherwise. -->
<!-- Every finding uses the PM block below (orchestrate.md → "Writing a finding for the PM"). No SEVERITY/reachability tokens here. -->

**[F#] <plain-language name — what goes wrong, not where in the code>**
- **Example:** <one concrete user, one concrete action, what they see — or "no realistic user path found; the reviewer's scenario needs <condition>">
- **Who and how often:** <which users · everyday / uncommon / needs an unusual setup>
- **If we ship as is:** <consequence> · <reversible how · or not reversible, because …>
- **Fixing it here costs:** <one small task · a round of rework · a new workstream> · touches <what>
- **Recommendation:** <fix here · ship and ticket · your call> — <one-line reason>
- **Your ruling:** ____

## 5. Found outside this change

<!-- Live CRITICAL findings that are pre-existing or hardening (origin gate, orchestrate.md 2d). NOT blocking — the loop parked them. -->
<!-- They are here because fixing one widens the scope, which is your call. Same PM block as §4. "None." otherwise. -->

**[F#] <plain-language name>**
- **Example:** <…>
- **Who and how often:** <…>
- **If we ship as is:** <… — note that this is already true in production today>
- **Fixing it here costs:** <…>
- **Recommendation:** <fix here · ticket it> — <one-line reason>

- **Other follow-ups parked:** <count> → `RISKS_AND_BLOCKERS.md` (tagged `follow-up`)

## 6. Findings digest

- **Auto-fixed criticals** (one plain-language line each — never hidden):
  - **[F#]** <what a user would have seen → fixed and re-reviewed>
- **Parked in-scope warnings/notes:** <count> → `RISKS_AND_BLOCKERS.md`
- **Depth:** full review `REVIEW.md` · evidence `TEST_RESULTS.md` · decisions `DECISIONS.md`

## Approval (human-only)

<!-- The loop leaves this blank and stops. ONLY the PM fills it in — the loop never writes here. -->

- **Decision:** — _(awaiting PM)_
- **Date:** —
- **Notes:** —

## Next — the PM's actions (the loop performs none of these)

- **Approve** → fill the Approval block above, then open the PR / merge / relocate the workstream to `done/`
- **Rule on §4** → record the ruling in `DECISIONS.md`, then re-invoke `/orchestrate <id>`
- **Show the review** → `REVIEW.md` (latest round) · `RUN_LOG.md`
