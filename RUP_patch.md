# RUP Patch — Local Repository Policy

This repository adopts RUP rules from `RUPStrikesBack/rules/`. The sections below are **local clarifications** to prevent ambiguity and ensure test/quality gate reporting is verifiable.

## P1. Test execution claims must be evidence-backed

Any statement that a test or quality gate was run (or passed/failed) **must be backed by an artifact** in the repository.

- A gate is only considered **executed** if there is a corresponding timestamped log file committed under `progress/sprint_N/` (see RUP `test_procedures.md`).
- When writing `progress/sprint_N/sprint_N_tests.md`, every gate row (PASS/FAIL/PARTIAL) must reference the **exact log file path** produced by that run.
- Never infer or assume a gate outcome. If you did not run it and cannot produce the log, the status must be recorded as **NOT RUN** (with reason).

## P2. When tests cannot be executed, record it explicitly

If tests/quality gates cannot be executed due to missing credentials, unavailable OCI capacity, environment constraints, or runtime limitations:

- Record the situation in `progress/sprint_N/sprint_N_tests.md` as **NOT RUN** with a short reason.
- Create/append an entry in `progress/sprint_N/sprint_N_openquestions.md` or `progress/sprint_N/sprint_N_proposedchanges.md` (whichever fits) describing what is required to enable execution.
- Do not “paper over” missing execution with narrative summaries.

## P3. No “synthetic passing” without an explicit policy decision

If a sprint requires gates that are expensive or long-running (for example OCI integration runs) and a reduced gate is desired (smoke-only, shortened runtime, or partial coverage), this must be treated as a **plan change**:

- Propose it in `progress/sprint_N/sprint_N_proposedchanges.md` and wait for Product Owner acceptance.
- Until accepted, execute the gates as specified by `PLAN.md` and RUP procedures, or mark them **NOT RUN**.

## P4. Documentation snippets must be executed and validated

Any command sequence published in sprint documentation (especially sprint manuals and user-facing runbooks) **must be executed by the agent** before the documentation is considered release-ready.

- Each documented snippet must have a corresponding execution artifact (for example a captured stdout/stderr log) stored under `progress/sprint_N/` and referenced from `progress/sprint_N/sprint_N_tests.md`.
- If a snippet cannot be executed (missing credentials, no OCI access, destructive side effects, or cost/capacity constraints), it must be explicitly marked **NOT RUN** with a short reason and an alternative verification plan, and treated as an open issue until resolved or accepted as a plan change.

