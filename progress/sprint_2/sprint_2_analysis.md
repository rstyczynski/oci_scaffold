# Sprint 2 - Analysis

Status: Complete

## Sprint Overview

Sprint 2 implements `OCI-3. Block Volume resource — review, integrate, document`.

The backlog item is not a net-new feature. It is a review-and-alignment sprint for an already present pair of scripts, with three concrete deliverables:
- align the block volume resource scripts with existing scaffold conventions
- add a repeatable end-to-end cycle
- document the workflow for a new operator

The sprint also needs a minimal test harness bootstrap because `PLAN.md` explicitly requires:
- `Test: integration`
- `Regression: unit`

## Current Codebase Findings

### Existing block volume scripts

`resource/ensure-blockvolume.sh` and `resource/teardown-blockvolume.sh` already exist, but they are materially less consistent than the rest of the scaffold.

Observed gaps:
- no adopt/create discovery contract comment block like the other mature `ensure-*` scripts
- no URI- or explicit-name-based adoption path; lookup is only by prior state or derived display name
- no `.deleted=false` reset during ensure paths, which can leave stale deletion state across retries
- no `.name` field recorded in state, unlike other resources
- attachment ownership is not tracked separately from volume ownership, making adopt/create semantics less clear
- teardown does not verify whether attachment/volume are already absent before acting
- iSCSI attachment detail retrieval makes three separate OCI calls instead of a single queried get
- error messages and lifecycle reporting are less explicit than the newer scripts

### Cycle coverage

There is no `cycle-blockvolume.sh`. Existing cycle patterns show two common styles:
- simple create/test/teardown (`cycle-log.sh`)
- review-oriented create/adopt/teardown demonstration (`cycle-bucket.sh`)

For OCI-3, the block volume cycle should be closer to the second style because the backlog item explicitly calls out review of idempotency and adoption behavior.

### Test harness state

The repo currently has:
- `tests/integration/test_dashboard.sh`
- `tests/manifests/component_dashboard.manifest`

The repo currently does not have:
- `tests/run.sh`
- `tests/unit/`
- any unit manifests beyond dashboard integration coverage

That means the Sprint-defined regression gate is not executable without adding minimal shared test infrastructure.

## Compatibility and Feasibility

### Feasibility

High.

The codebase already contains working building blocks for an end-to-end block volume cycle:
- network provisioning
- compute provisioning
- teardown orchestration via `.meta.creation_order`
- shared state helpers in `do/oci_scaffold.sh`

OCI block volume attach/detach flows are already partially implemented and only need alignment, not invention.

### Compatibility

High, with one design choice required:
- the cycle must create a compute instance because attachment requires an instance target

This is consistent with existing scaffold composition patterns. A dedicated cycle that provisions VCN + subnet + compute + block volume is aligned with the project’s current operating model.

## Proposed Minimal Scope

### OCI-3 core scope

1. Align `ensure-blockvolume.sh`
2. Align `teardown-blockvolume.sh`
3. Add `cycle-blockvolume.sh`
4. Add integration coverage for the new cycle
5. Update README

### Test-harness bootstrap scope

Only what Sprint 2 needs:
- `tests/run.sh` with support for `--unit`, `--integration`, `--new-only`, and `--component`
- `tests/unit/` with at least one fast shell-level unit test for block volume state helpers/teardown preconditions
- `tests/manifests/component_blockvolume.manifest`

No broader test-framework expansion is needed for this sprint.

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| OCI attach/detach operations can be slow or eventually consistent | Medium | wait on terminal states and use explicit post-action lookups |
| Existing scripts may leave stale state flags across retries | Medium | normalize `.created` and `.deleted` handling to match other resources |
| Block volume teardown could fail if compute teardown runs first | High | ensure `creation_order` and cycle order preserve reverse detach/delete sequencing |
| Unit regression scope is underspecified because there is no existing unit suite | Medium | create minimal component-scoped unit harness for this sprint |

## Readiness

Analysis complete. The sprint is feasible and the missing test harness issue is resolved by the user’s explicit approval to include the minimal bootstrap in scope.
