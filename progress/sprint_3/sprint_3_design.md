# Sprint 3 - Design

## OCI-6. Add ensure/teardown scripts and cycle example for OCI File Storage Service (FSS)

Status: Approved

### Requirement Summary

Add scaffold support for OCI File Storage Service (FSS) resources:

- file system
- mount target
- export

Deliver:

- `ensure-fss_filesystem.sh`, `ensure-fss_mount_target.sh`, `ensure-fss_export.sh`
- `teardown-fss_filesystem.sh`, `teardown-fss_mount_target.sh`, `teardown-fss_export.sh`
- `cycle-fss.sh` demonstrating the end-to-end lifecycle

All scripts must be idempotent, support URI-style identification/adoption, and record ownership (`.created`) in state so teardown only deletes scaffold-owned resources.

### Feasibility Analysis

**API Availability:**

- OCI supports FSS concepts and operations for file systems, mount targets, and exports via OCI CLI / API, per OCI docs (Overview of File Storage) and existing OCI CLI patterns in this repository.
- Reference: [OCI File Storage overview](https://docs.oracle.com/en-us/iaas/Content/File/Concepts/filestorageoverview.htm)

**Technical Constraints:**

- Mount targets are created in a subnet and require network access rules (security lists/NSGs) for NFS traffic; the cycle must rely on pre-existing networking primitives or documented inputs.
- Deletion/creation can be asynchronous; scripts must poll for lifecycle state transitions where needed.
- Export is tied to (file system + mount target export set); creation requires both IDs.

**Risk Assessment:**

- **Network pre-req mismatch**: wrong subnet/NSG/security list can break mounting/visibility. Mitigation: keep cycle focused on resource lifecycle only; document required state inputs; do not attempt to mount NFS as part of the first iteration.
- **Async operations/flakes**: eventual consistency can cause transient list/get failures. Mitigation: add bounded retries with clear logging; prefer `get` by OCID where possible.
- **Ownership mistakes**: teardown deleting unowned resources is unacceptable. Mitigation: strict `.created` checks and no-op default for unowned states.

### Design Overview

**Architecture:**

- Add a new “FSS component” implemented as resource scripts in `resource/` (consistent with existing components).
- Use existing OCI Network Path Analyzer integration (`resource/ensure-path_analyzer.sh`) to validate **subnet → mount target** reachability on **TCP/2049 (NFS)** during the cycle.
- Ensure scripts follow the existing scaffold style:
  - Inputs from environment/state
  - “adopt or create” behavior
  - state writes including `.created` boolean and OCIDs
  - predictable output and exit behavior

**Key Components:**

1. **Ensure scripts**:
   - `resource/ensure-fss_mount_target.sh`
   - `resource/ensure-fss_filesystem.sh`
   - `resource/ensure-fss_export.sh`
2. **Teardown scripts**:
   - `resource/teardown-fss_export.sh`
   - `resource/teardown-fss_filesystem.sh`
   - `resource/teardown-fss_mount_target.sh`
3. **Cycle script**:
   - `cycle-fss.sh` orchestrating ensure + teardown in the correct order
4. **Integration tests**:
   - `tests/integration/test_fss.sh` and `tests/manifests/component_fss.manifest`

**Data Flow:**

- `cycle-fss.sh` loads or generates a local state file, then:
  1. ensure mount target (create/adopt)
  2. ensure file system (create/adopt)
  3. ensure export (create/adopt)
  3a. run Network Path Analyzer check: subnet → mount target IP (TCP/2049) and record result in `.path_analyzer[]`
  4. teardown export (owned-only)
  5. teardown file system (owned-only)
  6. teardown mount target (owned-only)
  7. archive final state as `.deleted-*` like other cycles

### Technical Specification

**APIs Used (OCI CLI):**
- **Mount target**
  - `oci fs mount-target list|get|create|delete` (and waiting via `--wait-for-state` or polling)
- **File system**
  - `oci fs file-system list|get|create|delete`
- **Export**
  - `oci fs export list|get|create|delete`
  - `oci fs export-set get` (export set is required to create export; it’s associated with the mount target)

**State shape (proposed):**

```json
{
  "fss": {
    "mount_target_ocid": "ocid1.mounttarget....",
    "mount_target_created": true,
    "filesystem_ocid": "ocid1.filesystem....",
    "filesystem_created": true,
    "export_ocid": "ocid1.export....",
    "export_created": true,
    "export_set_ocid": "ocid1.exportset....",
    "subnet_ocid": "ocid1.subnet....",
    "compartment_ocid": "ocid1.compartment....",
    "display_name_prefix": "fss-xxxx"
  }
}
```

Notes:
- Keys may be flattened to match current repo conventions (e.g., `.blockvolume.*`). Exact key naming will follow the existing state conventions once implementation begins.
- `*_created` (or `.created`) must be persisted per resource.

**Scripts/Tools:**
- File: `resource/ensure-fss_mount_target.sh`
  - Purpose: ensure mount target exists in a subnet; adopt by explicit OCID or by name+compartment; write state with ownership.
  - Interface: invoked by `cycle-fss.sh` with environment variables/state file path.
  - Dependencies: `oci`, `jq`, existing state helper(s) used by other components.
- File: `resource/ensure-fss_filesystem.sh`
  - Purpose: ensure file system exists; adopt or create; write state.
- File: `resource/ensure-fss_export.sh`
  - Purpose: ensure export exists for (export set + file system) with specified export path; write state.
- Matching teardown scripts: delete only when owned, otherwise no-op.
- File: `cycle-fss.sh`
  - Purpose: orchestrate full lifecycle for integration tests and as a reference for users.

**Error Handling:**
- Missing required inputs (compartment/subnet/name) → fail fast with clear message.
- OCI “not found” on get/list for adopted resources → treat as broken state and fail (do not silently create).
- Delete failures due to dependencies (e.g. mount target in use) → ensure cycle deletes in reverse order and retries with bounded backoff.

### Implementation Approach

**Step 1:** Define minimal required inputs for `cycle-fss.sh` (compartment/subnet/name prefix; optional existing OCIDs for adoption).
**Step 2:** Implement `ensure-fss_mount_target.sh` first (required for export set).
**Step 3:** Implement `ensure-fss_filesystem.sh`.
**Step 4:** Implement `ensure-fss_export.sh` (lookup export set from mount target; create export).
**Step 5:** Implement teardown scripts in strict reverse order and ownership guarded.
**Step 6:** Add `tests/integration/test_fss.sh` to run `cycle-fss.sh` and validate archived state has delete markers.

### Testing Strategy

#### Recommended Sprint Parameters

- **Test:** integration (required by `PLAN.md`)
- **Regression:** unit (required by `PLAN.md`)
- **Regression scope:** `fss` (new component) once added; otherwise full unit suite

#### Unit Test Targets

| Component | Functions to Test | Key Inputs & Edge Cases | Isolation (Mocks) |
|-----------|-------------------|-------------------------|-------------------|
| `resource/ensure-fss_*.sh` | argument parsing + state ownership logic | missing inputs; adopt vs create; already-existing state | mock `oci` via PATH shadowing (if needed) |

#### Integration Test Scenarios

| Scenario | Infrastructure Dependencies | Expected Outcome | Est. Runtime |
|----------|----------------------------|------------------|--------------|
| IT-1: full lifecycle via `cycle-fss.sh` | OCI credentials; target compartment OCID; subnet OCID for mount target; NPA service availability in region | export + file system + mount target created/adopted; NPA reports SUCCEEDED for TCP/2049 to mount target IP; teardown deletes only owned resources and archives state | 5–15 min |

#### Smoke Test Candidates

None for this sprint (Sprint `Test:` excludes smoke).

**Success Criteria:**

- `cycle-fss.sh` can be executed end-to-end and produces an archived `.deleted-*` state that records ownership and deleted resources.
- `cycle-fss.sh` records a Network Path Analyzer result for mount target reachability on TCP/2049, and the integration test asserts it is `SUCCEEDED`.
- Integration test `IT-1` passes when run via `tests/run.sh --integration --new-only progress/sprint_3/new_tests.manifest`.

## Test Specification

### New Tests (Sprint 3)

| ID | Suite | Script | Function | Purpose | Backlog Trace |
|----|-------|--------|----------|---------|--------------|
| IT-1 | integration | `test_fss.sh` | `test_IT1_full_lifecycle` | Proves end-to-end create/adopt + teardown ordering via `cycle-fss.sh`, including NPA validation for TCP/2049 to mount target | OCI-6 |

### Manifest Registration

- `progress/sprint_3/new_tests.manifest`
  - `integration:test_fss.sh:test_IT1_full_lifecycle`
- `tests/manifests/component_fss.manifest`
  - `integration:test_fss.sh`

### Integration Notes

**Dependencies:**
- Existing state and helper patterns used by other resource scripts in this repository.

**Compatibility:**
- Naming follows existing patterns: `ensure-*.sh`, `teardown-*.sh`, `cycle-*.sh`, component manifests.

**Reusability:**
- Reuse the same “cycle script” patterns for archiving deleted state and PATH setup used by existing `cycle-*` scripts.

### Documentation Requirements

**User Documentation:**
- How to provide required inputs for FSS cycle (compartment, subnet, name/URI)
- How ownership flags affect teardown

**Technical Documentation:**
- State keys used for FSS resources
- Deletion ordering and any wait/poll behavior

### Design Decisions

**Decision 1:** Keep Sprint 3 integration test focused on resource lifecycle, not NFS mounting.
**Rationale:** Mounting requires additional OS packages, NFS client config, and network rules; lifecycle coverage is the minimal stable proof for scaffold correctness.
**Alternatives Considered:** Add a compute instance and mount NFS as part of the cycle.

### Open Design Questions

None.

---

## Design Summary

## Overall Architecture

Introduce a new FSS component implemented as resource scripts and an end-to-end cycle, covered by a single integration test validating lifecycle + state ownership invariants.

## Design Risks

- Environment network variability (subnet/NSG/security list) may cause integration runs to fail without correct prerequisites.
- Async OCI lifecycle operations may require careful waiting/retry logic in scripts.

## Resource Requirements

- `oci` CLI, `jq`
- OCI permissions for FSS create/delete in the target compartment and subnet

## Design Approval Status

Awaiting Review
