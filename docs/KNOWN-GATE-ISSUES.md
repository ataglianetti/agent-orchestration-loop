# Known gate issues

Open defects in the loop's human gate (the ship guard, the soft and hard run markers, and the review contract). Each was found by independent review of the scripts as they ship in this repo.

**Status:** open. Each row names a recommended fix; none has been decided yet.

## Review contract

| ID  | Severity | Where                                                   | Problem | Recommended fix |
| --- | -------- | ------------------------------------------------------- | ------- | --------------- |
| G11 | WARNING  | `execution/REVIEW_CONTRACT.md` — §5 claim-only rule     | Reusing an existing `F#` on a claim-only match conflicts with the rule that each `F#` appears in exactly one settled list. | Issue a new `F#` with a `related: F#` note instead of reusing the ID. |
