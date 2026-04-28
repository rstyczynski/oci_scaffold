# Sprint 2 - Setup

Mode: managed | Sprint: 2 | Date: 2026-04-17

## Contract

Rules reviewed and understood:
- `AGENTS.md`: use `RUPStrikesBack/` rule paths; Sprint 2 is managed mode
- `RUPStrikesBack/rules/generic/GENERAL_RULES.md`: only implement assigned backlog item, keep changes minimal, design approval required before construction
- `RUPStrikesBack/rules/generic/GIT_RULES.md`: semantic commit message format if a commit is created later
- `RUPStrikesBack/rules/generic/sprint_definition.md`: Sprint 2 requires `Test: integration` and `Regression: unit`
- `RUPStrikesBack/rules/generic/test_procedures.md`: design must define test specification and quality-gate flow
- `RUPStrikesBack/rules/generic/bug_policy.md`: failures during gates are fold-in unless scope expands

User decisions captured:
- Approved expanding Sprint 2 scope to include a minimal test harness so `Regression: unit` is executable
- Requested that any actual script/test execution happens only after `2026-04-18 00:08 CEST`

Responsibilities:
- Review and align `ensure-blockvolume.sh` and `teardown-blockvolume.sh` with scaffold conventions
- Add a dedicated cycle script for end-to-end block volume exercise
- Extend README with prerequisites, inputs, usage, and teardown workflow
- Bootstrap the smallest viable `tests/run.sh` and unit/integration layout needed to satisfy Sprint 2 test gates

Constraints:
- Managed mode: stop after design for approval before construction
- Do not revert user changes already present in `PLAN.md` and `BACKLOG.md`
- Do not execute OCI-affecting commands before `2026-04-18 00:08 CEST`

Open Questions:
- None at setup time after the user selected option 2 for the missing test harness.
