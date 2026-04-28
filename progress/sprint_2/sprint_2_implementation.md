# Sprint 2 - Implementation Notes

## Implementation Overview

**Sprint Status:** implemented

**Backlog Items:**
- OCI-3: implemented

## OCI-3. Block Volume resource — review, integrate, document

Status: implemented

### Implementation Summary

Sprint 2 aligned the OCI Block Volume resource scripts with the scaffold’s current conventions, added a dedicated `cycle-blockvolume.sh`, and bootstrapped the minimal shared test runner required by the sprint’s `Regression: unit` setting.

See [sprint_2_bugs.md](./sprint_2_bugs.md) for the no-attach block-volume bug discovered and fixed while refining the URI-adoption operator flow.

### Main Features

- `resource/ensure-blockvolume.sh`
  - explicit discovery contract and state outputs
  - adoption by `.inputs.blockvolume_ocid`
  - lookup/create by `.inputs.blockvolume_name` or `{name_prefix}-bv`
  - normalized ownership handling for `.blockvolume.created`
  - normalized `.blockvolume.deleted=false` on ensure
  - attachment reuse/discovery before creating a new attachment
  - single attachment metadata fetch for iSCSI details

- `resource/teardown-blockvolume.sh`
  - no-op behavior on unowned state
  - detach-before-delete sequencing
  - tolerant handling of missing attachment or missing volume
  - `.blockvolume.deleted=true` on successful delete

- `cycle-blockvolume.sh`
  - creates compute prerequisites and block volume
  - verifies attach state and iSCSI metadata
  - exercises adopt-by-OCID in a fresh state file
  - supports `SKIP_TEARDOWN=true`

- `tests/run.sh`
  - minimal manifest-driven runner for `--unit`, `--integration`, `--component`, `--new-only`
  - sufficient for Sprint 2 gates without broader framework work

### Code Artifacts

| Artifact | Purpose | Status |
|----------|---------|--------|
| `resource/ensure-blockvolume.sh` | aligned volume ensure/adopt/attach behavior | Complete |
| `resource/teardown-blockvolume.sh` | aligned detach/delete teardown behavior | Complete |
| `cycle-blockvolume.sh` | end-to-end block volume compose cycle | Complete |
| `tests/run.sh` | minimal shared test runner | Complete |
| `tests/unit/test_runner.sh` | test runner fixture and manifest checks | Complete |
| `tests/unit/test_blockvolume.sh` | block volume teardown unit coverage | Complete |
| `tests/integration/test_blockvolume.sh` | OCI block volume integration coverage | Complete |
| `tests/manifests/component_blockvolume.manifest` | block volume component manifest | Complete |

### Implementation Notes

#### Block volume ownership model

The implementation separates:
- volume ownership: `.blockvolume.created`
- attachment ownership/reuse: `.blockvolume.attachment_created`

This keeps teardown predictable and makes adopt-by-OCID explicit.

#### Cycle behavior

The cycle uses a compute-backed compose scenario because block volume attach semantics are not meaningful without an instance target. This stayed within the existing scaffold composition patterns instead of introducing a special-purpose test harness outside the project model.

#### Test harness scope

The new `tests/run.sh` is intentionally minimal. It only solves the sprint’s immediate gap:
- run integration tests from `new_tests.manifest`
- run unit regression from a component manifest

It does not try to become a generic framework.

### Construction Bug Fixed During Gate Execution

#### Bug 1 — new resource scripts missing execute bit

- **Symptom:** first `A3` run failed with `Permission denied` when `cycle-blockvolume.sh` invoked `ensure-blockvolume.sh`
- **Root cause:** newly added scripts had no executable bit
- **Fix:** applied executable permissions and reran the gate
- **Impact:** no code logic change required; classified as broken construction setup
