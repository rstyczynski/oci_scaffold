# Sprint 1 - Implementation Notes

## Implementation Overview

**Sprint Status:** under_construction

**Backlog Items:**
- OCI-1: under_construction
- OCI-2: under_construction

## OCI-1. Add ensure/teardown scripts and cycle example for OCI Dashboard service

Status: under_construction

### Implementation Summary

Four resource scripts and one cycle script implement idempotent lifecycle management for OCI Management Dashboards. URI parsing follows the pattern established by `ensure-bucket.sh`.

### Main Features

- URI `/comp/path/group/dashboard` parsed identically to bucket URI — last segment = name, rest = compartment path
- Dashboard group is state-only metadata (no OCI resource); `ensure-dashboard_group.sh` resolves compartment and records group name
- `ensure-dashboard.sh` paths A/B/C/D: OCID adopt → URI adopt/create → name adopt/create → import-dashboard
- Stable UUID v5 derived from `NAME_PREFIX:dashboard_name` ensures idempotent re-runs; falls back to random UUID on older `uuidgen`
- `teardown-dashboard.sh` deletes only when `.dashboard.created=true` or `FORCE_DELETE=true`
- `teardown-dashboard_group.sh` clears state entry only (no OCI API call)

### Code Artifacts

| Artifact                               | Purpose                                    | Status   |
|----------------------------------------|--------------------------------------------|----------|
| resource/ensure-dashboard_group.sh     | Resolve compartment + record group in state | Complete |
| resource/ensure-dashboard.sh           | Adopt or create OCI Management Dashboard   | Complete |
| resource/teardown-dashboard.sh         | Delete dashboard if created by scaffold    | Complete |
| resource/teardown-dashboard_group.sh   | Clear group state entry                    | Complete |
| cycle-dashboard.sh                     | Full lifecycle demonstration               | Complete |

### Design Compliance

Implementation follows approved design. URI parsing is line-for-line consistent with ensure-bucket.sh Path B.

### YOLO Mode Decisions

**Decision: `_state_set_if_unowned` usage in adopt paths**
Adopted the same guard as ensure-bucket.sh: when a resource is found by name (path C), `_state_set_if_unowned` preserves `created=true` across retries. Explicit adopt paths (OCID / URI) always set `false`.

### User Documentation

#### Overview

Provision and tear down OCI Management Dashboards idempotently using the same URI approach as other scaffold resources.

#### Prerequisites

- OCI CLI ≥ 3.x configured (`~/.oci/config`)
- IAM policy granting `manage management-dashboards` in the target compartment
- `jq` ≥ 1.6
- `uuidgen` (built-in on macOS; `uuid-runtime` package on Linux)

#### Usage

**Basic — create dashboard via URI:**
```bash
NAME_PREFIX=test1 ./cycle-dashboard.sh
```

**Override compartment and names:**
```bash
NAME_PREFIX=myapp \
COMPARTMENT_PATH=/mytenancy/prod \
DASHBOARD_GROUP_NAME=myapp-dashboards \
DASHBOARD_NAME=myapp-overview \
./cycle-dashboard.sh
```

**Skip teardown (inspect resources after cycle):**
```bash
NAME_PREFIX=test1 SKIP_TEARDOWN=true ./cycle-dashboard.sh
```

**Adopt existing dashboard by OCID:**
```bash
source do/oci_scaffold.sh
_state_set '.inputs.dashboard_ocid' 'ocid1.managementdashboard.oc1...'
NAME_PREFIX=test1 resource/ensure-dashboard.sh
```

**Use custom tile definitions:**
```bash
NAME_PREFIX=test1 TILES_FILE=my-tiles.json ./cycle-dashboard.sh
```

---

## OCI-2. Exemplary dashboard with logging, audit, and metrics widgets

Status: under_construction

### Implementation Summary

`resource/dashboard-widgets-example.json` contains three tile definitions. `cycle-dashboard.sh` injects the compartment OCID using `jq` before passing the tiles to `ensure-dashboard.sh`.

### Main Features

- **Log Explorer tile** — queries OCI Logging for logs in the target compartment (last 1 hour)
- **Audit Events tile** — shows audit events for the compartment (last 24 hours)
- **Metrics tile** — Object Storage `ObjectCount` metric, hourly sum aggregation
- `__COMPARTMENT_OCID__` placeholder replaced at runtime by `cycle-dashboard.sh` via `jq`

### Code Artifacts

| Artifact                               | Purpose                              | Status   |
|----------------------------------------|--------------------------------------|----------|
| resource/dashboard-widgets-example.json | Three-widget tile definitions        | Complete |

### User Documentation

#### Customising Tile Definitions

The file `resource/dashboard-widgets-example.json` is a JSON array of tile objects following the OCI Management Dashboard import schema. To use your own tiles:

```bash
NAME_PREFIX=test1 TILES_FILE=path/to/my-tiles.json ./cycle-dashboard.sh
```

Each tile must have: `savedSearchId` (unique string), `displayName`, `savedSearchType`, `rowSpan`, `columnSpan`, `dataConfig`.

---

## Sprint Implementation Summary

### Overall Status

under_construction (pending quality gate execution)

### Achievements

- Full URI-based discovery for dashboards consistent with existing scaffold patterns
- Dashboard group abstraction cleanly separates OCI constraint (no group resource) from user-facing URI concept
- Exemplary three-widget dashboard ready for import

### Challenges Encountered

- OCI has no `create` command for Management Dashboards — `import-dashboard` used instead. This requires a full JSON payload including `dashboardId`. Resolved by stable UUID derivation.
- `uuidgen -v5` not universally available — added fallback to random UUID.

### Integration Verification

Follows exact same patterns as ensure-bucket.sh:
- `_oci_compartment_ocid_by_path` for URI compartment resolution
- `_state_set_if_unowned` for adopt paths
- `_state_append_once '.meta.creation_order'` for teardown ordering
- `_done` / `_ok` / `_fail` / `_existing` output helpers

### Ready for Production

After quality gate passes — Yes.
