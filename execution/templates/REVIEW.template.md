# REVIEW

<!-- Append one block per loop round. Orchestrate reads the LAST block. -->
<!-- Vocab + rules: docs/execution/REVIEW_CONTRACT.md. Prose detail also goes to RUN_LOG.md. -->

## Round 1 — YYYY-MM-DD

VERDICT: CONCERNS
Personas: adversarial-reviewer, run, code-review (3 independent passes)

| ID  | SEVERITY         | reachability       | consensus | FLAG-HUMAN | summary               |
| --- | ---------------- | ------------------ | --------- | ---------- | --------------------- |
| F1  | CRITICAL-ON-FLIP | dormant-at-default | 2/3       | no         | example finding       |

### Detail

**F1 — example finding** (`path/to/file.ts:line`)
What's wrong, why it matters, and the condition under which it fires.
Raised by: adversarial-reviewer, run.
