# Sprint 2 - Design

## OCI-3. Block Volume resource — review, integrate, document

Status: Approved

### Requirement Summary

Review the existing block volume resource scripts, align them with scaffold conventions, provide a repeatable cycle that provisions and tears down the resource end-to-end, and document the workflow. Because Sprint 2 requires `Regression: unit`, add the smallest reusable test harness needed to execute both new-code and regression gates.

### Feasibility Analysis

**API Availability**

Required OCI CLI commands are available in the current approach:
- `oci bv volume list|get|create|delete`
- `oci compute volume-attachment list|get|attach|attach-iscsi-volume|detach`
- `oci compute instance get`

These APIs cover creation, adoption lookup, attachment, detach, and deletion.

**Codebase Availability**

The scaffold already provides:
- shared state helpers via `do/oci_scaffold.sh`
- compute/network composition via existing ensure scripts
- teardown orchestration based on `.meta.creation_order`
- existing integration-test style in `tests/integration/test_dashboard.sh`

**Conclusion**

The sprint is fully feasible without architecture changes. The only new shared infrastructure is a minimal `tests/run.sh`, added because the sprint definition already requires it.

### Design Overview

The sprint will deliver two tightly scoped outcomes:

1. **Block volume resource alignment**
   - make `ensure-blockvolume.sh` follow the explicit adoption/create pattern used elsewhere
   - make `teardown-blockvolume.sh` robust against stale state and already-removed attachments
   - keep state fields predictable and readable

2. **Minimal test infrastructure**
   - add `tests/run.sh` to execute unit or integration scripts by manifest
   - add a block-volume component manifest
   - add one fast unit script and one integration script

### Resource Script Design

#### `resource/ensure-blockvolume.sh`

Discovery order:
- A. `.inputs.blockvolume_ocid` — adopt by explicit volume OCID; verify existence; no creation
- B. `.inputs.blockvolume_name` — lookup by explicit display name; create if not found
- C. `.inputs.name_prefix` fallback — derive `{name_prefix}-bv`; create if not found

Attachment behavior:
- if `.blockvolume.attachment_ocid` already resolves to an active attachment, reuse it
- otherwise look up an attachment for `(.compute.ocid, .blockvolume.ocid)`
- if not found, create the attachment using the configured attach type

State outputs:
- `.blockvolume.name`
- `.blockvolume.ocid`
- `.blockvolume.created`
- `.blockvolume.deleted`
- `.blockvolume.attachment_ocid`
- `.blockvolume.attachment_created`
- `.blockvolume.device_path`
- `.blockvolume.attach_type`
- `.blockvolume.vpus_per_gb`
- for iSCSI: `.blockvolume.iqn`, `.blockvolume.ipv4`, `.blockvolume.port`, `.blockvolume.is_multipath`

Conventions to match:
- explicit adopt paths set `.created=false`
- name-lookup path uses `_state_set_if_unowned` to preserve ownership on retry
- ensure resets `.deleted=false`
- append only one creation marker: `.meta.creation_order += "blockvolume"`

#### `resource/teardown-blockvolume.sh`

Teardown order:
1. detach the attachment if owned or forced
2. delete the volume if owned or forced

Robustness rules:
- tolerate already-missing attachment/volume
- clear attachment state after successful detach
- set `.blockvolume.deleted=true` after confirmed delete
- do not fail on empty state; behave like other teardown scripts

### Cycle Design

#### `cycle-blockvolume.sh`

Composition:
- ensure `/oci_scaffold` compartment
- create public network stack and compute instance
- create and attach a block volume
- verify state and OCI-visible attachment
- demonstrate one adopt path in a fresh state file
- teardown through `do/teardown.sh`

Why a dedicated cycle:
- the backlog item explicitly asks for end-to-end exercise
- attachment semantics require a real compose scenario, not a standalone volume-only script

Verification inside cycle:
- volume OCID recorded
- attachment OCID recorded
- if iSCSI, connection data recorded
- adopt-by-OCID path sets `.blockvolume.created=false`

### Testing Strategy

#### Recommended Sprint Parameters

- **Test:** integration — new functionality is exercised through OCI create/attach/detach lifecycle
- **Regression:** unit — fast regression enabled by the minimal runner bootstrap approved by the user
- **Regression scope:** blockvolume

#### Unit Test Targets

| Component | Functions / behavior to test | Key inputs & edge cases | Isolation |
|-----------|------------------------------|-------------------------|-----------|
| `tests/run.sh` | manifest filtering and function dispatch | `--new-only`, `--component`, missing manifest | local shell only |
| `resource/teardown-blockvolume.sh` | no-op behavior on empty/non-owned state | `created=false`, missing OCIDs, `deleted=true` | mocked `oci` shim in shell |

#### Integration Test Scenarios

| Scenario | Infrastructure Dependencies | Expected Outcome | Est. Runtime |
|----------|-----------------------------|------------------|--------------|
| Full cycle | OCI CLI, compartment, compute/network permissions | create, attach, verify, teardown succeed | 5-10 min |
| Adopt existing volume by OCID | volume and attachment created by prior step | `.blockvolume.created=false`, attachment reused or discovered | < 2 min |
| Teardown ordering | state with compute + blockvolume creation order | block volume detaches/deletes before compute termination | included in full cycle |

#### Smoke Test Candidates

None for this sprint. The smallest meaningful verification is integration-level because the feature is OCI-backed.

## Test Specification

Sprint Test Configuration:
- Test: integration
- Regression: unit
- Mode: managed

### Unit Tests

#### UT-1: `tests/run.sh` component manifest selection
- **Input:** `--unit --component blockvolume`
- **Expected Output:** only scripts from `tests/manifests/component_blockvolume.manifest` are selected
- **Edge Cases:** missing manifest returns non-zero with a clear error
- **Isolation:** local shell fixtures only
- **Target file:** `tests/unit/test_runner.sh`

#### UT-2: `teardown-blockvolume.sh` no-op on unowned state
- **Input:** state file with `.blockvolume.created=false`, attachment/volume OCIDs present
- **Expected Output:** script reports nothing to delete and exits 0
- **Edge Cases:** `.blockvolume.deleted=true`
- **Isolation:** shim `oci` command to prove no delete/detach is attempted
- **Target file:** `tests/unit/test_blockvolume.sh`

### Integration Tests

#### IT-1: Full lifecycle via `cycle-blockvolume.sh`
- **Preconditions:** OCI CLI configured; target compartment creatable/usable; compute and block-volume permissions granted
- **Steps:** run `NAME_PREFIX=<prefix> ./cycle-blockvolume.sh`
- **Expected Outcome:** create, attach, verify, and teardown complete with exit 0
- **Verification:** state records volume and attachment before teardown; archived state records `.blockvolume.deleted=true`
- **Target file:** `tests/integration/test_blockvolume.sh`

#### IT-2: Adopt existing block volume by OCID
- **Preconditions:** block volume exists from setup portion of the cycle
- **Steps:** run `ensure-blockvolume.sh` in a fresh state with `.inputs.blockvolume_ocid`
- **Expected Outcome:** `.blockvolume.created=false`; volume state is populated without duplicate creation
- **Target file:** `tests/integration/test_blockvolume.sh`

### Traceability

| Backlog Item | Unit Tests | Integration Tests |
|--------------|------------|-------------------|
| OCI-3 | UT-1, UT-2 | IT-1, IT-2 |

### Implementation Approach

Construction phase will make these changes after design approval:
1. align `ensure-blockvolume.sh`
2. align `teardown-blockvolume.sh`
3. add `cycle-blockvolume.sh`
4. add `tests/run.sh`
5. add `tests/unit/test_runner.sh`
6. add `tests/unit/test_blockvolume.sh`
7. add `tests/integration/test_blockvolume.sh`
8. add `tests/manifests/component_blockvolume.manifest`
9. add `progress/sprint_2/new_tests.manifest`
10. update `README.md` and `PROGRESS_BOARD.md`
