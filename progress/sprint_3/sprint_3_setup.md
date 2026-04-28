# Sprint 3 - Setup

Mode: managed | Sprint: 3 | Date: 2026-04-27

## Contract

Scope for Sprint 3 is limited to backlog item `OCI-6` (OCI File Storage Service / FSS scaffold: file system, mount target, export + ensure/teardown scripts + `cycle-fss.sh`).

Rules reviewed and understood (available in this repo):
- `AGENTS.md`: follow RUP process and use rule paths under `RUPStrikesBack/` when present
- `RUP_patch.md`: any test/gate execution claims must be backed by committed log artifacts under `progress/sprint_3/`

Prior contracting reference:
- Sprint 2 contract exists in `progress/sprint_2/sprint_2_setup.md` and is treated as the baseline cooperation contract for this repository.

Responsibilities (Sprint 3):
- Add new FSS module scripts (`ensure-*`, `teardown-*`) matching existing scaffold conventions (idempotency, adoption, state ownership flags)
- Provide an exemplary end-to-end `cycle-fss.sh` for integration testing
- Ensure integration tests exist and are runnable per `PLAN.md` `Test: integration`

Constraints / compliance:
- Managed mode: produce setup + design; wait for explicit approval before construction (per RUP process)
- Evidence-backed testing: any gate/test result must have a corresponding committed log under `progress/sprint_3/` and referenced from sprint test docs
- Do not broaden scope beyond `OCI-6` without promoting a new backlog item

Open Questions / blockers:
- RUP rule files referenced by `AGENTS.md` and previous sprint docs (for example `RUPStrikesBack/rules/generic/*`) are not currently present in this working tree (directory appears empty). Sprint 3 will proceed using the local clarifications in `RUP_patch.md` plus established repo conventions unless the rules directory is restored.

Status:
- Contracting complete - ready for analysis

## Analysis

### Sprint Overview

Add OCI FSS coverage to oci_scaffold to enable provisioning and teardown of:
- **File system**
- **Mount target**
- **Export**

Deliverables explicitly required by `OCI-6`:
- `ensure-fss_filesystem.sh`
- `ensure-fss_mount_target.sh`
- `ensure-fss_export.sh`
- `teardown-fss_filesystem.sh`
- `teardown-fss_mount_target.sh`
- `teardown-fss_export.sh`
- `cycle-fss.sh`

### Backlog Items Analysis

#### OCI-6. Add ensure/teardown scripts and cycle example for OCI File Storage Service (FSS)

**Requirement Summary:**
- Support create/adopt/delete flows for the three FSS resources
- Match scaffold conventions (URI-style identification/adoption, state ownership tracking, predictable output)
- Provide an end-to-end cycle script

**Technical Approach (high-level):**
- Mirror existing resource patterns already present for bucket/dashboard/block volume:
  - resolve compartment from URI-style path
  - “ensure” does: lookup/adopt or create, then write to state with `.created` ownership flag
  - “teardown” does: delete only when `.created=true`, otherwise no-op with clear messaging
  - “cycle” demonstrates create/adopt + teardown ordering and persists logs/artifacts

**Dependencies:**
- OCI CLI availability and credentials for integration runs
- Existing scaffold primitives for state read/write and URI parsing (reuse, do not reinvent)

**Testing Strategy (managed + integration):**
- Add/extend integration tests covering:
  - ensure idempotency (run twice; second run is no-op/adopt)
  - teardown ownership (created vs adopted resources)
  - teardown order (export → filesystem/mount target as appropriate)
- Ensure new tests are registered in manifests and executed via the integration gate flow.

**Risks/Concerns:**
- OCI FSS operations can be asynchronous; may require polling/waits in scripts
- Network prerequisites for mount targets (subnet/security) may differ across environments; cycle should keep assumptions minimal and document required state inputs

**Compatibility Notes:**
- Scripts must follow repository naming and state conventions used by existing modules to remain consistent with `tests/run.sh` and current progress artifacts.

### Overall Sprint Assessment

**Feasibility:** Medium (depends on OCI CLI access and correct network inputs for mount targets)

**Estimated Complexity:** Moderate (three linked resources + ownership/teardown rules)

**Prerequisites Met:** Partially
- Repo conventions exist and prior integration gates have run for Sprint 2
- RUP generic rule files appear missing locally; rely on `RUP_patch.md` + repo conventions unless restored

**Open Questions:**
- None required to proceed with design, assuming the existing conventions (state + URI parsing) are reused for FSS.

**Readiness for Design Phase:** Confirmed Ready

