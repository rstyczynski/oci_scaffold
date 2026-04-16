# Sprint 1 - Setup

Mode: YOLO | Sprint: 1 | Date: 2026-04-15

## Contract

Rules reviewed and understood:
- AGENTS.md: Submodule path prefixes confirmed; YOLO mode behavior understood
- GENERAL_RULES.md: Implementor role, progress files in progress/sprint_N/, no over-engineering
- GIT_RULES.md: Semantic commits, push after every commit, no scope prefix before colon
- PRODUCT_OWNER_GUIDE.md: Backlog Items drive scope; proposed changes go to proposedchanges.md
- GIT_RULES.md note: commit format is `type: (sprint-N) description` not `type(sprint-N):`

Responsibilities:
- Implement only what is in OCI-1 and OCI-2
- Follow URI pattern from ensure-bucket.sh
- Record all YOLO decisions
- No exit in copy-paste examples
- Push after every commit

Constraints:
- No design decisions in backlog items (already respected)
- No over-engineering beyond the two backlog items
- state .created flag controls teardown behavior

Open Questions: None — YOLO mode, proceeding with assumptions.

## Analysis

### OCI-1: ensure/teardown/cycle for OCI Dashboard service

**Requirement:** `ensure-dashboard_group.sh`, `ensure-dashboard.sh`, matching teardowns, `cycle-dashboard.sh`. URI `/compartment/path/dashboard-group/dashboard`.

**Technical Approach:**
- OCI CLI: `oci management-dashboard dashboard` (list-dashboards, import-dashboard, delete-management-dashboard, export-dashboard)
- Dashboard Group: OCI Management Dashboard has no separate group resource. YOLO decision: implement group as a compartment-scoped namespace recorded in state only; `ensure-dashboard_group.sh` resolves the compartment and records group metadata. A dashboard belongs to a group by name prefix convention `<group>/<dashboard>` stored as display-name.
- URI parsing: last two segments = group + dashboard name; everything before = compartment path; consistent with ensure-bucket.sh pattern

**OCI CLI create format:** `oci management-dashboard dashboard import-dashboard --from-json` with JSON payload matching the Management Dashboard schema.

**Dependencies:** Compartment must exist (resolved via `_oci_compartment_ocid_by_path`).

**Feasibility:** High — OCI CLI management-dashboard commands available in standard OCI CLI distribution.

**YOLO Assumption 1 — Dashboard Group:**
- Issue: No native OCI group container for dashboards
- Assumption: Group = compartment + name prefix stored in state; teardown-dashboard_group.sh is a metadata-only cleanup
- Risk: Low — matches how OCI console organises dashboards visually

### OCI-2: Exemplary dashboard with widgets

**Requirement:** Log Explorer, Audit Events, Metrics widgets; parameterised by compartment OCID; JSON definition included by cycle-dashboard.sh.

**Technical Approach:**
- `resource/dashboard-widgets-example.json` contains the tile definitions
- cycle-dashboard.sh injects COMPARTMENT_OCID via sed/jq substitution before import
- Widget types: `LOG_EXPLORER` (Logging), `AUDIT_EVENTS`, `METRIC_EXPLORER` (oci_objectstorage namespace)

**YOLO Assumption 2 — Widget JSON Schema:**
- Issue: OCI Management Dashboard JSON schema varies by OCI CLI version
- Assumption: Use `import-dashboard` format which is self-contained; JSON validated against a known-working export
- Risk: Low — import-dashboard accepts its own export format

**Feasibility:** High — all widget types are standard OCI Management Dashboard features.

## Overall Readiness

Feasibility: High
Complexity: Moderate (URI parsing, JSON generation for dashboard)
Prerequisites: OCI CLI configured with management-dashboard access
Open Questions: None

Analysis complete — ready for Design.
