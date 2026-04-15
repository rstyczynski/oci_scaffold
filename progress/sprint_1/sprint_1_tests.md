# Sprint 1 — Test Execution Results

## Summary

| Gate            | Result | Retries | Pass Rate |
|-----------------|--------|---------|-----------|
| A1 Smoke        | skip   | —       | —         |
| A2 Unit         | skip   | —       | —         |
| A3 Integration  | PASS   | 2       | 100%      |
| B1–B3 Regression| skip   | —       | — (Regression: none) |

## Artifacts

| Gate           | Log File                                          |
|----------------|---------------------------------------------------|
| A3 Integration | `progress/sprint_1/test_run_A3_integration_*.log` |

Three log files produced across two fix iterations (retry 1: `created=false` logic; retry 2: `deleted` flag persistence).

## Failures and Fixes

### Retry 1 — A3 Integration (run 1)
- **Root cause:** Scripts used `oci management-dashboard` — wrong service; correct is `oci dashboard-service`
- **Fix:** Rewrote all four scripts with correct CLI commands

### Retry 2 — A3 Integration (run 2)
- **Issue:** Step 4 OCID adopt reported `created=true` instead of `false`
- **Root cause:** `_state_set_if_unowned` preserved `created=true` from Step 3; correct pattern (matching `ensure-bucket.sh`) is unconditional `false` on adoption
- **Fix:** Changed adoption path to `_state_set '.dashboard.created' false`

### Retry 3 — A3 Integration (run 3)
- **Issue:** Step 7 teardown skipped (`deleted=true` stale from run 1's state file)
- **Root cause:** Adoption path did not reset the `deleted` flag; stale `deleted=true` blocked teardown of new resource
- **Fix:** Added `_state_set '.dashboard.deleted' false` in both creation and adoption paths of both ensure scripts

### Final run — PASS
```
Summary: 4 CREATED, 4 EXISTING, 3 TESTED, 0 FAILED
```

- Step 1: Compartment `/oci_scaffold/test` — EXISTING ✓
- Step 2: Dashboard group created via URI — DONE ✓
- Step 3: Dashboard created with 3 widgets (logging, audit, metrics) — DONE ✓
- Step 4: Adopt by OCID → created=false — OK ✓
- Step 5: Adopt by URI → created=false — OK ✓
- Step 6: Verify via CLI — OK ✓
- Step 7: Dashboard deleted, group deleted — DONE ✓
