# Sprint 1 — Test Execution Results

## Summary

| Gate            | Result | Retries | Pass Rate |
|-----------------|--------|---------|-----------|
| A1 Smoke        | skip   | —       | —         |
| A2 Unit         | skip   | —       | —         |
| A3 Integration  | PASS   | 2       | 100%      |
| A3 Post-sprint  | PASS   | 5       | 100%      |
| B1–B3 Regression| skip   | —       | — (Regression: none) |

## Artifacts

| Gate              | Log File                                          |
|-------------------|---------------------------------------------------|
| A3 Integration    | `progress/sprint_1/test_run_A3_integration_*.log` |
| A3 Post-sprint    | manual runs documented below                      |

## A3 Integration — Sprint-time Failures and Fixes

### Retry 1
- **Root cause:** Scripts used `oci management-dashboard` — wrong service; correct is `oci dashboard-service`
- **Fix:** Rewrote all four scripts with correct CLI commands

### Retry 2
- **Issue:** Step 4 OCID adopt reported `created=true` instead of `false`
- **Root cause:** `_state_set_if_unowned` preserved `created=true` from Step 3
- **Fix:** Unconditional `_state_set '.dashboard.created' false` on adoption

### Retry 3
- **Issue:** Teardown skipped (`deleted=true` stale from previous state file)
- **Root cause:** Adoption path did not reset the `deleted` flag
- **Fix:** Added `_state_set '.dashboard.deleted' false` in both ensure scripts

### Sprint-time Final run — PASS
```
Summary: 4 CREATED, 4 EXISTING, 3 TESTED, 0 FAILED
```

---

## A3 Post-sprint — Issues Found in Real Usage

### Post-sprint Fix 1 — URI not self-resolved in ensure-dashboard.sh (2026-04-16)
- **Issue:** `ensure-dashboard.sh` Path B only extracted dashboard name from URI; group was still taken from state, not URI
- **Root cause:** URI parsing in Path B incomplete — compartment and group not resolved
- **Fix:** Path B now parses full URI: compartment path → OCID, group name → OCID, then dashboard lookup
- **Test:** `ensure-dashboard.sh` called with `dashboard_uri` only (no group in state) → adopted correctly

### Post-sprint Fix 2 — Widgets empty and not editable (2026-04-16)
- **Issue:** All three LoggingChart widgets empty; LoggingChart `mode:advanced` crashes the console Edit dialog
- **Root cause:** `LoggingChart mode:advanced` is incompatible with the console edit panel; general log search query returns no data in test compartment
- **Fix:** Removed LoggingChart; replaced with LoggingTable `mode:basic` (schema derived from console-created widget); replaced ObjectStorage metric with VCN `VnicFromNetworkBytes` (tenancy scope, always has data); added Markdown widget
- **Test:** validate-dash created and inspected in OCI Console — Markdown renders, LoggingTable shows audit events, VCN metric shows data

### Post-sprint Fix 3 — cycle-dashboard.sh used NAME_PREFIX derived from group, ignoring caller (2026-04-16)
- **Issue:** `NAME_PREFIX=test2 ... cycle-dashboard.sh` ignored `test2`; derived NAME_PREFIX from group name instead
- **Root cause:** `NAME_PREFIX="${DASHBOARD_GROUP_NAME%-group}"` always overwrote caller-supplied value
- **Fix:** `NAME_PREFIX="${NAME_PREFIX:-${DASHBOARD_GROUP_NAME%-group}}"` — caller wins
- **Test:** `NAME_PREFIX=qg1 DASHBOARD_URI=.../qg1-group/qg1-dashboard` → STATE_FILE=state-qg1.json ✓

### Post-sprint Fix 4 — deploy-on-adopt not implemented (2026-04-16)
- **Issue:** `ensure-dashboard.sh` only applied widgets during creation; adopting an existing dashboard left widgets untouched
- **Fix:** If tiles file is set and exists: run `update-dashboard-v1 --widgets` on adopt; track `.dashboard.deployed`
- **Test:** ensure-dashboard.sh called against existing validate-dash with tiles file → `[DONE] Dashboard widgets deployed` ✓

### Post-sprint Fix 5 — teardown fails after SKIP_TEARDOWN=true cycle (2026-04-16)
- **Issue:** `NAME_PREFIX=qg1 ./do/teardown.sh` after cycle with `SKIP_TEARDOWN=true` → "created=false or OCID missing"
- **Root cause:** Steps 4 and 5 (adopt tests) reset `created=false`, overwriting `true` set at creation. Teardown.sh then saw `created=false` and skipped deletion.
- **Fix:** Capture `_DASHBOARD_CREATED` and `_GROUP_CREATED` after step 3; restore before step 6/7. Removed forced `_state_set .dashboard.created true` from inline teardown.
- **Test:**
  ```
  NAME_PREFIX=qg1 DASHBOARD_URI=/oci_scaffold/test/qg1-group/qg1-dashboard SKIP_TEARDOWN=true cycle-dashboard.sh
  → state-qg1.json: dashboard.created=true, dashboard_group.created=true ✓
  NAME_PREFIX=qg1 ./do/teardown.sh
  → [DONE] Dashboard deleted: qg1-dashboard ✓
  → [DONE] Dashboard group deleted: qg1-group ✓
  ```

## Post-sprint Final State

All 5 post-sprint issues resolved. Full cycle with teardown passes:
```
NAME_PREFIX=qg1 DASHBOARD_URI=/oci_scaffold/test/qg1-group/qg1-dashboard SKIP_TEARDOWN=true cycle-dashboard.sh
Summary: 2 CREATED, 4 EXISTING, 3 TESTED, 0 FAILED

NAME_PREFIX=qg1 ./do/teardown.sh
[DONE] Dashboard deleted: qg1-dashboard
[DONE] Dashboard group deleted: qg1-group
```
