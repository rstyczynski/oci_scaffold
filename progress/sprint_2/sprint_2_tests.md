# Sprint 2 — Test Execution Results

## Summary

| Gate | Result | Retries | Notes |
|------|--------|---------|-------|
| A1 Smoke | skip | — | `Test:` does not include smoke |
| A2 Unit | skip | — | `Test:` does not include unit |
| A3 Integration | PASS | 2 | first run failed on script permissions; rerun passed |
| B1 Smoke | skip | — | `Regression:` does not include smoke |
| B2 Unit | PASS | 1 | block volume component regression |
| B3 Integration | skip | — | `Regression:` does not include integration |

## Artifacts

| Gate | Log File |
|------|----------|
| A3 Integration attempt 1 | `progress/sprint_2/test_run_A3_integration_20260417_221331.log` |
| A3 Integration attempt 2 | `progress/sprint_2/test_run_A3_integration_20260417_221809.log` |
| B2 Unit | `progress/sprint_2/test_run_B2_unit_20260417_222521.log` |

## A3 Integration

### Attempt 1 — FAIL

- **Failure type:** broken
- **Symptom:** `cycle-blockvolume.sh` failed at line 64 with `Permission denied`
- **Root cause:** `resource/ensure-blockvolume.sh` was added without executable permissions
- **Fix:** set execute bits on new scripts and reran the gate

### Attempt 2 — PASS

Verified:
- full block volume create + attach lifecycle
- archived state shows `.blockvolume.deleted=true`
- adopt-by-OCID in a fresh state file records `.blockvolume.created=false`
- teardown ordering works: block volume detach/delete completes before compute/network teardown

## B2 Unit Regression

Validated:
- `tests/run.sh` component-manifest selection
- clear failure mode for missing component manifests
- `teardown-blockvolume.sh` exits cleanly on unowned state without issuing OCI mutations

## Final Gate Status

All required Sprint 2 gates passed:
- A3 Integration: PASS
- B2 Unit: PASS
