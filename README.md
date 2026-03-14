# OCI Scaffold

Modular, idempotent framework for provisioning and tearing down Oracle Cloud Infrastructure (OCI) resources — primarily for integration testing of OCI Functions and related services.

> **Scope:** Each `ensure-*.sh` script manages exactly **one** resource of its type per state file. This is by design — the scaffold is a thin, readable CLI wrapper for quickly assembling resource sets needed by integration tests, not a general-purpose infrastructure manager.

## What it does

Creates a complete OCI resource stack (network, vault, logging, functions app), runs connectivity checks, then tears it all down. Resources are tracked in a JSON state file so scripts are safe to re-run. All async OCI operations poll work requests for all terminal states (SUCCEEDED / FAILED / CANCELED) — failures surface immediately with a diagnostic message and are recorded in the state file for post-mortem inspection.

## Project structure

```text
do/
  oci_scaffold.sh      # Shared utilities, JSON state management, OCI discovery helpers
  teardown.sh          # Orchestrated teardown in reverse creation order
resource/
  ensure-*.sh          # Idempotent resource creation (network, vault, key, secret, logs, fn app, bucket, compartment, path analyzer)
  teardown-*.sh        # Resource deletion scripts
cycle-subnet.sh         # Full cycle: VCN + SGW (no internet)
cycle-subnet-nat.sh     # Full cycle: VCN + SGW + NAT (with internet)
cycle-vault.sh          # Full cycle: Vault + Key + Secret
cycle-log.sh            # Full cycle: Bucket + Log Group + Log
cycle-compartment.sh    # Full cycle: IAM compartment path creation
```

## Quick start

```bash
# OCI_REGION is optional — defaults to home region

# OCI_COMPARTMENT is optional — defaults to tenancy OCID
# here we will set active compartment to /oci_scaffold/test
source do/oci_scaffold.sh
_state_set '.inputs.compartment_path' /oci_scaffold/test
resource/ensure-compartment.sh
export OCI_COMPARTMENT=$(_state_get '.compartment.ocid')
unset STATE_FILE


# Network cycle (Service Gateway / OSN only)
NAME_PREFIX=subnet ./cycle-subnet.sh

# Network + NAT Gateway (internet access) cycle
NAME_PREFIX=subnet_nat ./cycle-subnet-nat.sh

# Bucket + Log Group + Log (objectstorage/write) cycle
NAME_PREFIX=logs ./cycle-log.sh

# IAM compartment path cycle (creates all segments, tears them down)
NAME_PREFIX=cmp COMPARTMENT_PATH=/landing-zone/workloads/myapp ./cycle-compartment.sh
```

## Resource / cycle coverage

| Resource | ensure/teardown | Cycle script |
| --- | --- | --- |
| VCN, Security List, SGW, Route Table, Subnet | yes | `cycle-subnet.sh` |
| NAT Gateway | yes | `cycle-subnet-nat.sh` |
| Path Analyzer | yes | `cycle-subnet.sh`, `cycle-subnet-nat.sh` |
| Vault, KMS Key, Secret | yes | `cycle-vault.sh` |
| Object Storage Bucket | yes | `cycle-log.sh` |
| Log Group, Log | yes | `cycle-log.sh` |
| IAM Compartment path | yes | `cycle-compartment.sh` |
| Functions Application | yes | *(no dedicated cycle — combine with subnet test)* |

## Failure handling

All async resource operations poll OCI work requests until a terminal state is reached:

```bash
--wait-for-state SUCCEEDED \
--wait-for-state FAILED \
--wait-for-state CANCELED \
--max-wait-seconds 300
```

When a work request ends in a non-SUCCEEDED state the script:

1. **Records the failure in the state file** — partial entries are written so you can inspect exactly what was attempted:

   ```json
   "log": {
     "created": false,
     "status": "FAILED",
     "name": "logs-invoke",
     "error_config": {
       "service": "objectstorage",
       "resource": "my-bucket",
       "category": "write"
     }
   }
   ```

2. **Prints a `[FAIL]` message** with the work-request status and the OCI error text captured from stderr.

3. **Exits non-zero** — the calling test script stops immediately (no teardown, leaving resources for manual inspection).

The state file always reflects the last known state, including failed attempts. Inspect it after a failure:

```bash
jq . state-logs.json
```

Then clean up manually using the individual teardown scripts or re-run the test (idempotent — existing resources are detected and reused).

### Cleaning up after a failed run

When a cycle fails mid-way, teardown is skipped and the state file is left in place. Resources that were detected as pre-existing have `created: false` and are normally skipped by teardown. Use `FORCE_DELETE=true` to delete everything in state regardless of the `created` flag:

```bash
# State file still present
FORCE_DELETE=true NAME_PREFIX=subnet_nat do/teardown.sh

# State file already archived (teardown ran but resources remain)
STATE_FILE=state-subnet_nat.deleted-20260313T220309.json \
  FORCE_DELETE=true do/teardown.sh
```

## Compartment teardown

IAM compartment deletion is async and uses OCI work requests. `teardown-compartment.sh`:

- Deletes in deepest-path-first order so children are removed before parents.
- Polls the work request directly and prints live progress:

  ```text
  [WAIT] Deleting '/landing-zone/workloads/myapp' … 30s (status: IN_PROGRESS)
  ```

- If a compartment is already mid-deletion from a prior interrupted run (DELETING state), waits for it to settle instead of re-triggering.
- If a compartment ended in FAILED state (e.g. was non-empty), recovers it to ACTIVE then retries.
- Compartments already deleted in prior runs are reported at the start of each teardown run for full path visibility.

## Vault cycle and deferred deletion

### Why vault teardown is different

OCI KMS Vaults, Master Encryption Keys (MEKs), and Secrets **cannot be deleted immediately**. When you run `cycle-vault.sh` and teardown executes, OCI does *not* remove the resources — it schedules them for deletion after a mandatory retention window (7–30 days for Vault/Key, minimum 1 day for Secret). The resources enter `PENDING_DELETION` state and remain billable and visible in the console until the retention period expires.

This means re-running `cycle-vault.sh` with the same `NAME_PREFIX` within that window will not create fresh resources — it will see the `PENDING_DELETION` state, cancel the scheduled deletion, and resume using the existing resources.

### Running the vault cycle

```bash
# Shortest retention (7 days) — recommended for integration tests
NAME_PREFIX=secret SECRET_VALUE=myvalue ./cycle-vault.sh

# Override retention period (days must be in [7, 30])
NAME_PREFIX=secret SECRET_VALUE=myvalue \
  VAULT_DELETION_DAYS=14 KEY_DELETION_DAYS=14 ./cycle-vault.sh
```

`OCI_COMPARTMENT` is optional; omit it to use the tenancy OCID.

After the script completes the vault and key are in `PENDING_DELETION`. They will be permanently removed by OCI after the configured number of days — no further action is required.

### Deferred deletion state tracking

The scaffold tracks this two-phase lifecycle with state flags per resource:

| Flag | Meaning |
| --- | --- |
| `.deletion_scheduled` | Teardown has requested deletion; OCI resource is in `PENDING_DELETION` |
| `.deleted` | OCI has actually removed the resource (confirmed by API or 404) |

### Lifecycle transitions

```text
ensure  ──→  .created: true
                 │
teardown ──→  .deletion_scheduled: true   (OCI: PENDING_DELETION)
                 │
                 ├── re-run teardown (within retention)
                 │     → queries OCI, sees PENDING_DELETION
                 │     → "deletion already scheduled (PENDING_DELETION)"
                 │
                 ├── re-run teardown (after retention)
                 │     → queries OCI, gets DELETED / 404
                 │     → sets .deleted: true, clears .deletion_scheduled
                 │
                 ├── re-run ensure (within retention)
                 │     → cancels deletion via OCI API
                 │     → clears .deletion_scheduled, proceeds normally
                 │
                 └── re-run ensure (after retention, resource gone)
                       → cancel fails (404)
                       → sets .deleted: true, clears OCID
                       → creates a fresh resource
```

### Configuration

Retention period is controlled via state (set by `cycle-vault.sh` from environment):

| Key | Default | Range | Description |
| --- | --- | --- | --- |
| `.inputs.vault_deletion_days` | `7` | 7–30 | Days until vault is permanently deleted |
| `.inputs.key_deletion_days` | `7` | 7–30 | Days until key is permanently deleted |

```bash
# Schedule deletion with shortest retention (7 days)
NAME_PREFIX=secret SECRET_VALUE=myvalue ./cycle-vault.sh

# Override retention period
NAME_PREFIX=secret SECRET_VALUE=myvalue VAULT_DELETION_DAYS=14 KEY_DELETION_DAYS=14 ./cycle-vault.sh
```

## State file

All resource OCIDs and flags are stored in `STATE_FILE` (default: `./state-{NAME_PREFIX}.json` in the current directory). The `meta.creation_order` array drives teardown sequencing. Only resources with `created: true` are deleted on teardown.

```bash
# Override location
STATE_FILE=/tmp/state-run1.json NAME_PREFIX=run1 ./cycle-subnet.sh
```

Summary counters (`created`, `existing`, `tested`, `failed`) are reset at the start of each test run and updated in real-time as each resource operation completes.

## Key configuration

### Generic environment (non-`.inputs`)

| Variable | Default | Description |
| --- | --- | --- |
| `NAME_PREFIX` | **required** | Prefix for all created resource names (also used in default state file name) |
| `OCI_COMPARTMENT` | tenancy OCID | Target compartment; auto-discovered from tenancy when omitted |
| `OCI_REGION` | home region | Region identifier (e.g. `eu-zurich-1`); auto-discovered from home region when omitted |
| `STATE_FILE` | `./state-{NAME_PREFIX}.json` | JSON state file path; set before sourcing `do/oci_scaffold.sh` |

### Generic `.inputs.*` keys

These are set by the cycle scripts and shared by many ensure scripts:

| Key | Description |
| --- | --- |
| `.inputs.oci_compartment` | Compartment OCID all resources are created in |
| `.inputs.oci_region` | Region identifier propagated into state |
| `.inputs.name_prefix` | Name prefix used by all resources in this cycle |

### Network-related `.inputs.*` keys

| Key | Default | Description |
| --- | --- | --- |
| `.inputs.vcn_cidr` | `10.0.0.0/16` | VCN CIDR block (`ensure-vcn.sh`) |
| `.inputs.subnet_cidr` | `10.0.0.0/24` | Subnet CIDR block (`ensure-subnet.sh`) |
| `.inputs.subnet_prohibit_public_ip` | `true` | Prohibit public IPs on VNICs (`ensure-subnet.sh`) |
| `.inputs.sl_egress_cidr` | `0.0.0.0/0` | Security list egress CIDR (`ensure-sl.sh`) |
| `.inputs.sl_egress_protocol` | `all` | Security list egress protocol (`ensure-sl.sh`) |
| `.inputs.natgw_block_traffic` | `false` | Whether NATGW should block all traffic (`ensure-natgw.sh`) |

### Vault / key / secret `.inputs.*` keys

| Key | Default | Description |
| --- | --- | --- |
| `.inputs.vault_type` | `DEFAULT` | Vault type (`ensure-vault.sh`) |
| `.inputs.key_algorithm` | `AES` | KMS key algorithm (`ensure-key.sh`) |
| `.inputs.key_length` | `32` | KMS key length in bytes (`ensure-key.sh`) |
| `.inputs.key_protection_mode` | `SOFTWARE` | Key protection: `SOFTWARE` \| `HSM` \| `EXTERNAL` (`ensure-key.sh`) |
| `.inputs.secret_name` | `{NAME_PREFIX}-secret` | Secret display name (`ensure-secret.sh`) |
| `.inputs.secret_value` | **required** | Plaintext secret value (`ensure-secret.sh`, set by `cycle-vault.sh`) |
| `.inputs.vault_deletion_days` | `7` | Days until vault deletion (clamped to [7,30]) (`teardown-vault.sh`) |
| `.inputs.key_deletion_days` | `7` | Days until key deletion (clamped to [7,30]) (`teardown-key.sh`) |

### Logging / bucket `.inputs.*` keys

| Key | Default | Description |
| --- | --- | --- |
| `.inputs.bucket_name` | `{NAME_PREFIX}-bucket` | Object Storage bucket name (`ensure-bucket.sh`) |
| `.inputs.oci_namespace` | discovered | Object Storage namespace (`ensure-bucket.sh`) |
| `.inputs.bucket_<flag>` | *(none)* | **Pass-through** (`ensure-bucket.sh` only) — any `bucket_`-prefixed key is forwarded to `oci os bucket create` as `--<flag>` (underscores → hyphens). E.g. `.inputs.bucket_kms_key_id` → `--kms-key-id`, `.inputs.bucket_storage_tier` → `--storage-tier`. |
| `.inputs.log_group_name` | `{NAME_PREFIX}-logs` | Log Group name (`ensure-log_group.sh`) |
| `.inputs.log_source_service` | `functions` or `objectstorage` | Service name for log source (`ensure-log.sh`, `cycle-log.sh`) |
| `.inputs.log_source_resource` | — | Resource identifier to scope logs (e.g. bucket or Fn app) (`ensure-log.sh`, `cycle-log.sh`) |
| `.inputs.log_source_category` | `invoke` or `write` | Log source category (`ensure-log.sh`, `cycle-log.sh`) |
| `.inputs.log_name` | `{NAME_PREFIX}-invoke` | Log display name (`ensure-log.sh`) |

### Fn Application `.inputs.*` keys

| Key | Default | Description |
| --- | --- | --- |
| `.inputs.fn_app_name` | `{NAME_PREFIX}-fn-app` | Fn Application name (`ensure-fn_app.sh`) |
| `.inputs.fn_shape` | `GENERIC_X86` / `GENERIC_ARM` | Fn Application shape (`ensure-fn_app.sh`) |

### Compartment path `.inputs.*` keys

| Key | Description |
| --- | --- |
| `.inputs.compartment_path` | Full IAM compartment path (e.g. `/landing-zone/workloads/myapp`) (`ensure-compartment.sh`, set by `cycle-compartment.sh`) |

## Compartment path resolution

Use `_oci_compartment_ocid_by_path` to resolve a compartment OCID by its full path from the tenancy root. Any depth is supported — each segment is resolved against the direct children of the previous one:

```bash
source do/oci_scaffold.sh

# arbitrary depth — walk each segment step by step
OCI_COMPARTMENT=$(_oci_compartment_ocid_by_path "/landing-zone/workloads/teams/myapp")

# single level
OCI_COMPARTMENT=$(_oci_compartment_ocid_by_path "/myapp")
```

If any segment is not found the function prints `[ERROR] Compartment not found at path segment: <name>` and returns 1. Only `ACTIVE` compartments are matched at each level.

## Step-by-step usage

```bash
export NAME_PREFIX=mytest
# export OCI_COMPARTMENT="ocid1.compartment..."  # optional

source do/oci_scaffold.sh
_state_set '.inputs.oci_compartment' "$OCI_COMPARTMENT"
_state_set '.inputs.name_prefix'     "$NAME_PREFIX"

resource/ensure-vcn.sh
resource/ensure-sl.sh
resource/ensure-sgw.sh
resource/ensure-natgw.sh   # optional: internet access
resource/ensure-rt.sh
resource/ensure-subnet.sh

# use the subnet OCID from the state file
jq -r '.subnet.ocid' "$STATE_FILE"

do/teardown.sh "$NAME_PREFIX"
```

## Parallel runs

```bash
NAME_PREFIX=run1 ./test-subnet.sh &
NAME_PREFIX=run2 ./test-subnet.sh &
wait
```

Each run gets its own `state-{NAME_PREFIX}.json` file automatically.

## Internal techniques

### Async operation handling

Most OCI resources use the standard OCI CLI `--wait-for-state` pattern, which blocks until the work request reaches a terminal state:

```bash
--wait-for-state SUCCEEDED \
--wait-for-state FAILED \
--wait-for-state CANCELED \
--max-wait-seconds 300
```

### Self-polling with live progress (compartment teardown)

IAM compartment deletion returns a work request ID (`opc-work-request-id`) rather than a synchronous result. `teardown-compartment.sh` implements its own polling loop instead of using `--wait-for-state`, so it can print a live progress line:

```bash
_wr_ocid=$(oci iam compartment delete --force \
  --query '"opc-work-request-id"' --raw-output)

while true; do
  WR_STATUS=$(oci iam work-request get --work-request-id "$_wr_ocid" \
    --query 'data.status' --raw-output)
  printf "\033[2K\r  [WAIT] Deleting '%s' … %ds (status: %s)" "$_path" "$_elapsed" "$WR_STATUS"
  [ "$WR_STATUS" = "SUCCEEDED" ] && { echo; break; }
  sleep 5; _elapsed=$((_elapsed + 5))
done
```

`\033[2K\r` clears the current terminal line before rewriting it, producing a clean in-place update instead of stacking lines.

The same loop handles edge cases from prior interrupted runs: if the compartment is already in DELETING state, the loop waits for it to settle; if it ended in FAILED state, it recovers it with `oci iam compartment recover` before retrying.

### Dynamic CLI argument pass-through (`_state_extra_args`)

`do/oci_scaffold.sh` provides `_state_extra_args` — a shared helper that builds optional OCI CLI flags from state inputs at runtime, without hardcoding a flag per field in each script.

**Convention:** `.inputs.<prefix>_<suffix>` → `--<suffix>` (underscores replaced with hyphens). Required keys that must not be forwarded are listed as skip arguments.

```bash
# Signature
_state_extra_args <prefix> <array_var> [skip_key ...]

# Example — bucket with optional KMS key and storage tier
_extra_args=()
_state_extra_args bucket _extra_args name   # skips .inputs.bucket_name
oci os bucket create \
  --namespace-name "$NAMESPACE" \
  --compartment-id "$OCI_COMPARTMENT" \
  --name "$BUCKET_NAME" \
  "${_extra_args[@]}"
```

State key → CLI flag examples:

| State key | CLI flag |
| --- | --- |
| `.inputs.bucket_kms_key_id` | `--kms-key-id` |
| `.inputs.bucket_storage_tier` | `--storage-tier` |
| `.inputs.bucket_public_access_type` | `--public-access-type` |

Adding support for a new optional OCI parameter requires no script changes — set the key in state before calling the ensure script.

Currently used by `ensure-bucket.sh`. Extend to other ensure scripts by following the same pattern.

## Backlog

- **Apply self-polling to other resources** — currently only `teardown-compartment.sh` uses explicit work-request polling with live progress. Evaluate whether other long-running teardown operations (e.g. vault, log) benefit from the same treatment, or whether the silent `--wait-for-state` is sufficient for those resources.
- **Apply `_state_extra_args` to all ensure scripts** — currently only `ensure-bucket.sh` uses dynamic CLI argument pass-through. Apply the same pattern to the remaining ensure scripts (`ensure-vcn.sh`, `ensure-subnet.sh`, `ensure-vault.sh`, `ensure-key.sh`, `ensure-secret.sh`, `ensure-fn_app.sh`, `ensure-log.sh`, etc.) so optional OCI CLI flags can be passed to any resource without script changes.

## Dependencies

- `oci` CLI (configured and authenticated)
- `jq`
- `dig`
