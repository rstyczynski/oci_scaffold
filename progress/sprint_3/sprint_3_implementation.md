# Sprint 3 — Implementation

Backlog: `OCI-6` (OCI File Storage Service / FSS scaffold)

## What was implemented

### New scripts

- `resource/ensure-fss_mount_target.sh`
  - Adopt by OCID or ensure-by-name (create if missing)
  - Records: `.fss_mount_target.{ocid,name,private_ip,export_set_ocid,created}`
- `resource/ensure-fss_filesystem.sh`
  - Adopt by OCID or ensure-by-name (create if missing)
  - Records: `.fss_filesystem.{ocid,name,created}`
- `resource/ensure-fss_export.sh`
  - Adopt by OCID or ensure-by-(export_set, filesystem, path)
  - Records: `.fss_export.{ocid,path,created}`
- `resource/teardown-fss_export.sh`
- `resource/teardown-fss_filesystem.sh`
- `resource/teardown-fss_mount_target.sh`

### New cycle

- `cycle-fss.sh`
  - Inputs:
    - `NAME_PREFIX` (required)
    - `COMPARTMENT_PATH` (recommended; resolves compartment via `ensure-compartment.sh`)
    - `FSS_COMPARTMENT_OCID` (alternative to `COMPARTMENT_PATH`)
    - `FSS_SUBNET_OCID` (optional; when set, skips network creation and reuses the subnet)
    - `COMPARTMENT_PATH` (optional; resolves compartment via `ensure-compartment.sh`)
    - `SKIP_TEARDOWN` (optional; defaults to `false`)
  - Ensures network stack (when `FSS_SUBNET_OCID` is not provided): VCN + SGW + RT + SL + subnet
  - Ensures mount target, file system, export
  - Runs Network Path Analyzer validation via existing `resource/ensure-path_analyzer.sh`:
    - subnet → mount target IP
    - TCP/2049 (NFS)
    - result appended to `.path_analyzer[]`
  - Teardown order: export → file system → mount target
  - Marks `.fss.deleted=true` and archives `state-<prefix>.deleted-<ts>.json`

## Tests added/updated

- `tests/integration/test_fss.sh:test_IT1_full_lifecycle`
  - Executes `cycle-fss.sh`
  - Asserts:
    - archived state contains `.fss.deleted == true`
    - archived state contains at least one `.path_analyzer[]` entry with `result == "SUCCEEDED"`

## Notes / constraints

- Per `RUP_patch.md`, no gate execution is claimed here unless backed by committed `progress/sprint_3/test_run_*.log` artifacts.
