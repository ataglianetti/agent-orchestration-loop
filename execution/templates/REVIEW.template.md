# REVIEW

<!-- Append one block per loop round, written once at the close of the round. -->
<!-- Orchestrate routes off the LAST block and reads EVERY block to rebuild the seen-set. -->
<!-- Vocab + matching rules: docs/execution/REVIEW_CONTRACT.md. Prose detail also goes to RUN_LOG.md. -->

## Round 1 — YYYY-MM-DD

VERDICT: CONCERNS
Personas: adversarial-reviewer, run, code-review (3 independent passes)
Carried: settled — none
Carried: open — none
Seen-set: F1–F1 · 1 finding · 0 terminal, 1 open
Progress: 0 settled, 1 new, 0 suppressed re-raises

| ID  | SEVERITY         | reachability       | origin     | consensus | FLAG-HUMAN | disposition | summary         |
| --- | ---------------- | ------------------ | ---------- | --------- | ---------- | ----------- | --------------- |
| F1  | CRITICAL-ON-FLIP | dormant-at-default | introduced | 2/3       | no         | open        | example finding |

### Detail

**F1 — example finding** (`path/to/file.ts` · `symbolName()` · L42-58)
What's wrong, why it matters, and the condition under which it fires.
The symbol in the anchor is the cross-round identity; the line range is a hint only.
Origin: introduced (anchor absent at <base-sha>).
Raised by: adversarial-reviewer, run.

<!-- Round 2+ example of the two disposition cell forms, plus a non-blocking origin parked at normalization:
| F2 | WARNING | live      | introduced   | 1/3 | no | re-raised → open   | escape hatch: reachability dormant→live            |
| F3 | NOTE    | test-only | hardening    | 1/3 | no | re-raised → parked | settled round 1 (R-002); suppressed, not re-routed |
| F4 | WARNING | live      | pre-existing | 2/3 | no | parked             | present at <base-sha>; follow-up R-003             |
-->
