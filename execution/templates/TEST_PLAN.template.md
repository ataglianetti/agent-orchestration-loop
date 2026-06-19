# TEST PLAN

## Unit

| Area   | Command               | Expected |
| ------ | --------------------- | -------- |
| server | `npm run test:server` | pass     |
| client | `npm run test:client` | pass     |

## Integration

| Flow           | Steps                | Expected                 |
| -------------- | -------------------- | ------------------------ |
| Route behavior | execute request path | correct route + metadata |

## Manual Smoke

| Scenario | Steps                 | Expected       |
| -------- | --------------------- | -------------- |
| UI flow  | end-to-end in browser | no regressions |
