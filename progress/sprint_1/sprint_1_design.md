# Sprint 1 - Design

## OCI-1. Add ensure/teardown scripts and cycle example for OCI Dashboard service

Status: Accepted

### Requirement Summary

Add idempotent ensure/teardown scripts for OCI Management Dashboards with URI-based resource discovery, and a cycle script demonstrating end-to-end lifecycle.

### Feasibility Analysis

**API Availability:**
- `oci management-dashboard dashboard list-dashboards --compartment-id <ocid> --display-name <name>` — existence check
- `oci management-dashboard dashboard import-dashboard --from-json <file>` — create (JSON payload)
- `oci management-dashboard dashboard delete-management-dashboard --management-dashboard-id <ocid>` — delete
- `oci management-dashboard dashboard export-dashboard --export-dashboard-details <json>` — read OCID by dashboard IDs

All commands available in standard OCI CLI ≥ 3.x.

**Technical Constraints:**
- Dashboard creation uses `import-dashboard` (bulk JSON); no single-resource `create` command exists
- Dashboard Group has no OCI API resource — implemented as namespace metadata in state only
- Dashboard display-name must be unique within a compartment for reliable lookup

**Risk Assessment:**
- Low: `list-dashboards --display-name` filter works as exact match for lookup
- Low: `import-dashboard` is idempotent when `dashboardId` is a stable UUID derived from name

### Design Overview

**URI Parsing (consistent with ensure-bucket.sh):**
```
/oci_scaffold/test/my-group/my-dashboard
└─────────────────────┘  └──────┘  └────────────┘
   compartment path      group     dashboard name
```

`DASHBOARD_GROUP_URI` last segment = group name; everything before = compartment path.
`DASHBOARD_URI` last two segments = group + dashboard; everything before = compartment path.

**ensure-dashboard_group.sh:** Resolves compartment OCID from URI prefix, records group name and compartment in state. No OCI resource is created — the group is a logical namespace.

**ensure-dashboard.sh:** Discovery order:
- A. `.inputs.dashboard_ocid` — adopt by OCID
- B. `.inputs.dashboard_uri` — URI `/comp/path/group/name`; resolves compartment and name; falls through to creation
- C. `.inputs.dashboard_name` + `.inputs.oci_compartment` — lookup by name; falls through to creation
- D. Creation via `import-dashboard` with stable UUID dashboardId

**teardown-dashboard.sh:** Deletes dashboard if `.dashboard.created=true`.
**teardown-dashboard_group.sh:** Clears group state entry; no OCI API call.

**Key Components:**
1. `resource/ensure-dashboard_group.sh` — URI → compartment + group metadata in state
2. `resource/ensure-dashboard.sh` — URI → adopt or create OCI Management Dashboard
3. `resource/teardown-dashboard.sh` — delete if created
4. `resource/teardown-dashboard_group.sh` — state cleanup only
5. `cycle-dashboard.sh` — full lifecycle demo with exemplary dashboard

**Dashboard ID strategy (YOLO decision):** Generate a stable UUID from `NAME_PREFIX + dashboard_name` using `uuidgen -n @url -N "oci-scaffold:${NAME_PREFIX}:${DASHBOARD_NAME}" --sha1` (RFC-4122 v5). Falls back to random UUID when uuidgen v5 unavailable.

### Technical Specification

**State outputs — ensure-dashboard_group.sh:**
```
.dashboard_group.name          display name
.dashboard_group.compartment   compartment OCID
.dashboard_group.created       always false (no OCI resource)
```

**State outputs — ensure-dashboard.sh:**
```
.dashboard.name      display name
.dashboard.ocid      OCI Management Dashboard OCID
.dashboard.created   true | false
```

**Import JSON envelope:**
```json
{
  "dashboards": [{
    "dashboardId":    "<uuid>",
    "displayName":    "<name>",
    "description":    "<desc>",
    "compartmentId":  "<ocid>",
    "isOobDashboard": false,
    "tiles":          [ ... ]
  }]
}
```

### Implementation Approach

1. Write `ensure-dashboard_group.sh` — parse URI, resolve compartment, record state
2. Write `ensure-dashboard.sh` — paths A/B/C/D, import-dashboard for creation
3. Write `teardown-dashboard.sh` — delete if created
4. Write `teardown-dashboard_group.sh` — state cleanup
5. Write `cycle-dashboard.sh` — demo lifecycle (group → dashboard → verify → teardown)
6. Write `resource/dashboard-widgets-example.json` — widget definitions for OCI-2

### Testing Strategy

#### Recommended Sprint Parameters
- **Test:** integration — no pure unit functions; full OCI API interaction
- **Regression:** none — first sprint, no prior tests
- **Regression scope:** n/a

#### Integration Test Scenarios

| Scenario | Infrastructure Dependencies | Expected Outcome | Est. Runtime |
|----------|----------------------------|------------------|--------------|
| IT-1: cycle-dashboard.sh full lifecycle | OCI CLI, compartment, management-dashboard access | Creates and deletes dashboard; state has correct fields | 2-3 min |
| IT-2: URI adopt existing dashboard | Dashboard from IT-1 still present (run before teardown) | `.dashboard.created=false`, OCID recorded | < 30 sec |
| IT-3: Teardown deletes only created resources | created=true | Dashboard absent after teardown | < 30 sec |

**Success Criteria:** `cycle-dashboard.sh` exits 0; state file has `.dashboard.ocid`; OCI Console shows dashboard in correct compartment; dashboard removed after teardown.

## OCI-2. Exemplary dashboard with logging, audit, and metrics widgets

Status: Accepted

### Requirement Summary

Provide a ready-to-use dashboard JSON definition with three widget tiles: Log Explorer (OCI Logging), Audit Events, and Metrics (oci_objectstorage namespace). Parameterised by compartment OCID.

### Feasibility Analysis

**API Availability:** OCI Management Dashboard `import-dashboard` accepts full tile definitions. All three widget types (`LOG_EXPLORER`, `AUDIT_EVENTS`, `METRIC_EXPLORER`) are supported.

**Technical Constraints:**
- Widget JSON must match the `import-dashboard` schema exactly
- Compartment OCID must be injected at runtime (not hard-coded)
- `savedSearchId` inside each tile must be a stable UUID

### Design Overview

File: `resource/dashboard-widgets-example.json`

Placeholder `__COMPARTMENT_OCID__` is substituted by `cycle-dashboard.sh` using `jq` before import.

**Tile 1 — Log Explorer:**
- `savedSearchType`: `"SEARCH_SHOW_IN_DASHBOARD"`
- `dataConfigDetails.searchFilters`: Logging service query for OCI Logging logs in compartment

**Tile 2 — Audit Events:**
- `savedSearchType`: `"AUDIT_EVENT_CUSTOM_SHOW_IN_DASHBOARD"`
- Time range: last 24 hours

**Tile 3 — Metrics Explorer:**
- `savedSearchType`: `"METRIC_EXPLORATION_SHOW_IN_DASHBOARD"`
- Namespace: `oci_objectstorage`, metric: `ObjectCount`
- Interval: `1h`, statistic: `sum`

### Implementation Approach

1. Create `resource/dashboard-widgets-example.json` with three tile definitions and `__COMPARTMENT_OCID__` placeholder
2. In `cycle-dashboard.sh`: use `jq` to substitute compartment and feed to `ensure-dashboard.sh` via state

---

# Design Summary

## Overall Architecture

Both OCI-1 and OCI-2 are implemented as a single cohesive feature set: the ensure/teardown scripts plus the cycle script which consumes the exemplary widget JSON.

## Shared Components

- `_oci_compartment_ocid_by_path` from `do/oci_scaffold.sh` used by both ensure scripts
- `_state_get` / `_state_set` / `_state_append_once` pattern identical to existing scripts

## YOLO Mode Decisions

### Decision 1: Dashboard Group Implementation
**Context:** OCI has no native dashboard group API resource.
**Decision Made:** Group = state-only metadata namespace; no OCI resource created.
**Rationale:** Matches how OCI Console groups dashboards by compartment + naming convention.
**Alternatives Considered:** Using OCI Tags as group discriminator.
**Risk:** Low — teardown-dashboard_group.sh is a no-op on OCI, only clears state.

### Decision 2: Dashboard ID Generation
**Context:** `import-dashboard` requires a `dashboardId` UUID.
**Decision Made:** Derive v5 UUID from `NAME_PREFIX + dashboard_name`; fall back to `uuidgen` random.
**Rationale:** Stable UUID enables idempotent re-runs (same ID = update, not duplicate).
**Alternatives Considered:** Always use random UUID (causes duplicates on retry).
**Risk:** Low — uuidgen -v5 available on macOS and most Linux; fallback handles older versions.

## Design Risks

- OCI Management Dashboard API requires `management-dashboard` IAM policy. Caller must have it.

## Resource Requirements

- OCI CLI ≥ 3.x with `management-dashboard` plugin
- `jq` ≥ 1.6
- `uuidgen` (macOS built-in; coreutils on Linux)

## Design Approval Status

Accepted (YOLO auto-approve)

---

## Test Specification

Sprint Test Configuration:
- Test: integration
- Mode: YOLO

### Integration Tests

#### IT-1: Full lifecycle via cycle-dashboard.sh
- **Preconditions:** OCI CLI configured; compartment `/oci_scaffold/test` accessible; management-dashboard IAM policy granted
- **Steps:** Run `NAME_PREFIX=test1 ./cycle-dashboard.sh`
- **Expected Outcome:** Exit 0; state records `.dashboard.ocid`; dashboard visible in console; deleted during teardown
- **Verification:** `jq '.dashboard.ocid' state-test1.json` is non-empty; dashboard absent after teardown
- **Target file:** tests/integration/test_dashboard.sh

#### IT-2: URI adopt — existing dashboard
- **Preconditions:** Dashboard created in IT-1 still present
- **Steps:** Run ensure-dashboard.sh with `.inputs.dashboard_uri` pointing to existing resource
- **Expected Outcome:** `.dashboard.created=false`; OCID recorded correctly
- **Target file:** tests/integration/test_dashboard.sh

#### IT-3: Teardown respects created flag
- **Preconditions:** Dashboard with `.dashboard.created=true`
- **Steps:** Run teardown-dashboard.sh
- **Expected Outcome:** Dashboard deleted from OCI; `.dashboard.deleted=true` in state
- **Target file:** tests/integration/test_dashboard.sh

### Traceability

| Backlog Item | Integration Tests          |
|--------------|----------------------------|
| OCI-1        | IT-1, IT-2, IT-3           |
| OCI-2        | IT-1 (widgets deployed)    |
