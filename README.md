# OCI Scaffold

<p align="center">
  <img src="doc/images/logo.png" alt="OCI Scaffold Logo" width="300">
</p>

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
  ensure-*.sh          # Idempotent resource creation (network, compute, vault, key, secret, logs, fn app, fn function, API GW, bucket, compartment, path analyzer)
  teardown-*.sh        # Resource deletion scripts
etc/cloudinit/
  mitmproxy.yaml       # cloud-init: installs mitmproxy and starts it as a systemd service
src/fn/echo/            # Example Node.js Fn Project function (echo)
cycle-subnet.sh         # Full cycle: VCN + SGW (no internet)
cycle-subnet-nat.sh     # Full cycle: VCN + SGW + NAT (with internet)
cycle-compute.sh        # Full cycle: VCN + SGW + subnet + Compute instance
cycle-proxy.sh          # Full cycle: mitmproxy HTTPS inspection proxy (port 443)
cycle-vault.sh          # Full cycle: Vault + Key + Secret
cycle-log.sh            # Full cycle: Bucket + Log Group + Log
cycle-compartment.sh    # Full cycle: IAM compartment path creation
cycle-bucket.sh         # Full cycle: all bucket modes (OCID, name, URI, extra args)
cycle-iam_access.sh     # Full cycle: IAM user + group + policy + API-key bucket test
cycle-function.sh       # Full cycle: Fn app + deploy echo function + direct invoke test
cycle-apigw.sh          # Full cycle: Fn app + function + API GW + Internet test
```

## Quick start

```bash
# OCI_REGION is optional — defaults to home region

# COMPARTMENT_OCID is optional — defaults to tenancy OCID
# here we will set active compartment to /oci_scaffold/test
source do/oci_scaffold.sh
_state_set '.inputs.compartment_path' /oci_scaffold/test
resource/ensure-compartment.sh
export COMPARTMENT_OCID=$(_state_get '.compartment.ocid')
unset STATE_FILE


# Network cycle (Service Gateway / OSN only)
NAME_PREFIX=subnet ./cycle-subnet.sh

# Network + NAT Gateway (internet access) cycle
NAME_PREFIX=subnet_nat ./cycle-subnet-nat.sh

# Bucket + Log Group + Log (objectstorage/write) cycle
NAME_PREFIX=logs ./cycle-log.sh

# Bucket adoption cycle (create, adopt by OCID / name / URI, extra args)
NAME_PREFIX=bkt ./cycle-bucket.sh

# IAM compartment path cycle (creates all segments, tears them down)
NAME_PREFIX=cmp COMPARTMENT_PATH=/oci_scaffold/home ./cycle-compartment.sh

# IAM user access cycle (user + group + tenancy policy + temporary API key; create/delete bucket)
NAME_PREFIX=iam ./cycle-iam_access.sh

# Compute instance cycle (VCN + subnet + instance, SSH-ready via CloudShell)
NAME_PREFIX=compute ./cycle-compute.sh

# Compute instance cycle — all resources in /oci_scaffold (create compartment if missing)
COMPARTMENT_PATH=/oci_scaffold NAME_PREFIX=compute ./cycle-compute.sh

# mitmproxy HTTPS inspection proxy cycle
NAME_PREFIX=proxy ./cycle-proxy.sh

# mitmproxy proxy cycle — all resources in /oci_scaffold (create compartment if missing)
COMPARTMENT_PATH=/oci_scaffold NAME_PREFIX=proxy ./cycle-proxy.sh

# Fn function cycle (deploy src/fn/echo and test via direct invoke)
NAME_PREFIX=fn ./cycle-function.sh

# API GW cycle (deploy src/fn/echo and test via public API GW endpoint)
NAME_PREFIX=apigw ./cycle-apigw.sh

# Customize API GW function/paths/methods (example)
NAME_PREFIX=apigw \
FN_FUNCTION_SRC_DIR=src/fn/echo \
APIGW_PATH_PREFIX=/oci_scaffold \
APIGW_ROUTE_PATH=/echo \
APIGW_METHODS=POST \
./cycle-apigw.sh
```

## Resource / cycle coverage

| Resource | ensure/teardown | Cycle script |
| --- | --- | --- |
| VCN, Security List, SGW, Route Table, Subnet | yes | `cycle-subnet.sh` |
| NAT Gateway | yes | `cycle-subnet-nat.sh` |
| Path Analyzer | yes | `cycle-subnet.sh`, `cycle-subnet-nat.sh` |
| Compute Instance | yes | `cycle-compute.sh`, `cycle-proxy.sh` |
| mitmproxy HTTPS proxy | — | `cycle-proxy.sh` |
| Vault, KMS Key, Secret | yes | `cycle-vault.sh` |
| Object Storage Bucket | yes | `cycle-log.sh`, `cycle-bucket.sh` |
| Log Group, Log | yes | `cycle-log.sh` |
| IAM Compartment path | yes | `cycle-compartment.sh` |
| IAM User, Group, user-in-group, Policy | yes | `cycle-iam_access.sh` |
| Functions Application | yes | `cycle-function.sh`, `cycle-apigw.sh` |
| Functions Function (`fnfunc`) | yes | `cycle-function.sh`, `cycle-apigw.sh` |
| API Gateway (ApiGw + Deployment) | yes | `cycle-apigw.sh` |

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

`COMPARTMENT_OCID` is optional; omit it to use the tenancy OCID.

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
| `COMPARTMENT_OCID` | tenancy OCID | Target compartment; auto-discovered from tenancy when omitted |
| `COMPARTMENT_PATH` | *(none)* | IAM compartment path (e.g. `/oci_scaffold`); when set, `cycle-compute.sh` and `cycle-proxy.sh` resolve or create the compartment via `ensure-compartment.sh` and override `COMPARTMENT_OCID` |
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
| `.inputs.sl_ingress_cidr` | `.vcn.cidr` | Security list ingress CIDR (`ensure-sl.sh`) |
| `.inputs.sl_ingress_protocol` | `6` (TCP) | Security list ingress protocol (`ensure-sl.sh`) |
| `.inputs.natgw_block_traffic` | `false` | Whether NATGW should block all traffic (`ensure-natgw.sh`) |

### Compute `.inputs.*` keys

| Key | Default | Description |
| --- | --- | --- |
| `.inputs.compute_ocid` | *(none)* | **Adopt existing instance by OCID** — skips creation, sets `.compute.created = false` |
| `.inputs.compute_uri` | *(none)* | **Adopt existing instance by URI** — `/instance_name` or `/compartment/path/instance_name`; falls through to creation if not found |
| `.inputs.compute_name` | `{NAME_PREFIX}-instance` | Instance display name (`ensure-compute.sh`) |
| `.inputs.compute_shape` | `VM.Standard.E4.Flex` | Instance shape (`ensure-compute.sh`) |
| `.inputs.compute_ocpus` | `1` | OCPUs for flex shapes, composed into `--shape-config` (`ensure-compute.sh`) |
| `.inputs.compute_memory_gb` | `4` | Memory in GB for flex shapes, composed into `--shape-config` (`ensure-compute.sh`) |
| `.inputs.compute_image_id` | latest Oracle Linux 8 in region | Image OCID; auto-discovered when not set (`ensure-compute.sh`) |
| `.inputs.compute_availability_domain` | first AD in region | Availability domain; auto-discovered when not set (`ensure-compute.sh`) |
| `.inputs.compute_ssh_authorized_keys_file` | *(none)* | Path to SSH public key file forwarded as `--ssh-authorized-keys-file` |
| `.inputs.compute_user_data_file` | *(none)* | Path to cloud-init script forwarded as `--user-data-file` (e.g. `etc/cloudinit/mitmproxy.yaml`) |
| `.inputs.compute_user_data_b64` | *(none)* | Base64-encoded cloud-init content; decoded to a temp file and forwarded as `--user-data-file`; takes precedence over `compute_user_data_file` |
| `.inputs.compute_<flag>` | *(none)* | **Pass-through** — any `compute_`-prefixed key is forwarded to `oci compute instance launch` as `--<flag>`. Keys `shape`, `ocpus`, `memory_gb`, `image_id`, `availability_domain`, `uri`, `name` are always skipped. |

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
| `.inputs.bucket_ocid` | *(none)* | **Adopt existing bucket by OCID** — when set, `ensure-bucket.sh` skips name-based discovery and creation, resolves the bucket name from OCI, and sets `.bucket.created = false` so teardown does not delete it. Takes precedence over `.inputs.bucket_name`. |
| `.inputs.oci_namespace` | discovered | Object Storage namespace (`ensure-bucket.sh`) |
| `.inputs.bucket_<flag>` | *(none)* | **Pass-through** (`ensure-bucket.sh` only) — any `bucket_`-prefixed key is forwarded to `oci os bucket create` as `--<flag>` (underscores → hyphens). Keys `name` and `ocid` are always skipped. E.g. `.inputs.bucket_kms_key_id` → `--kms-key-id`, `.inputs.bucket_storage_tier` → `--storage-tier`. |
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
COMPARTMENT_OCID=$(_oci_compartment_ocid_by_path "/landing-zone/workloads/teams/myapp")

# single level
COMPARTMENT_OCID=$(_oci_compartment_ocid_by_path "/myapp")
```

If any segment is not found the function prints `[ERROR] Compartment not found at path segment: <name>` and returns 1. Only `ACTIVE` compartments are matched at each level.

## Step-by-step usage

```bash
export NAME_PREFIX=mytest
# export COMPARTMENT_OCID="ocid1.compartment..."  # optional

source do/oci_scaffold.sh
_state_set '.inputs.oci_compartment' "$COMPARTMENT_OCID"
_state_set '.inputs.name_prefix'     "$NAME_PREFIX"

resource/ensure-vcn.sh
resource/ensure-sl.sh
resource/ensure-sgw.sh
resource/ensure-natgw.sh   # optional: internet access
resource/ensure-rt.sh
resource/ensure-subnet.sh

# use the subnet OCI ID from the state file
jq -r '.subnet.ocid' "$STATE_FILE"

NAME_PREFIX=$NAME_PREFIX do/teardown.sh
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
  --compartment-id "$COMPARTMENT_OCID" \
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

### Adopting an existing bucket by OCID

A bucket created by one cycle can be adopted by another using its OCID. The adopting cycle records the bucket as not created (`.bucket.created = false`) so teardown does not delete it.

**Step 1 — create the bucket in cycle A:**

```bash
export NAME_PREFIX=storage
source do/oci_scaffold.sh

_state_set '.inputs.oci_compartment' "$COMPARTMENT_OCID"
_state_set '.inputs.name_prefix'     "$NAME_PREFIX"

resource/ensure-bucket.sh

# capture the OCID for use in cycle B
BUCKET_OCID=$(_state_get '.bucket.ocid')
```

Output:

```text
  [INFO] STATE_FILE: /Users/rstyczynski/projects/oci_scaffold/state-storage.json
  [DONE] Bucket created: storage-bucket
```

**Step 2 — adopt the bucket in cycle B:**

```bash
export NAME_PREFIX=myapp
source do/oci_scaffold.sh

# pass the OCID from cycle A — no compartment or name_prefix needed for this
_state_set '.inputs.bucket_ocid' "$BUCKET_OCID"

# resolves name from OCI, skips creation, sets .bucket.created = false
resource/ensure-bucket.sh

# bucket name and namespace are now available in cycle B's state
BUCKET_NAME=$(_state_get '.bucket.name')
NAMESPACE=$(_state_get '.bucket.namespace')
```

Output:

```text
  [INFO] STATE_FILE: /Users/rstyczynski/projects/oci_scaffold/state-myapp.json
  [OK]   Using existing bucket 'storage-bucket'
```

When `do/teardown.sh` is called for cycle B, the bucket is left untouched. It is only deleted if cycle A's teardown runs.

```bash
do/teardown.sh
```

```text
  [OK]   Bucket: nothing to delete
  [INFO] State archived: /Users/rstyczynski/projects/oci_scaffold/state-myapp.deleted-20260318T091140.json
```

```bash
export NAME_PREFIX=storage
do/teardown.sh
```

```text
  [INFO] STATE_FILE: /Users/rstyczynski/projects/oci_scaffold/state-storage.json
  [DONE] Bucket deleted: storage-bucket
  [INFO] State archived: /Users/rstyczynski/projects/oci_scaffold/state-storage.deleted-20260318T091151.json
```

### Creating and adopting an existing bucket by URI

A bucket can be adopted using a URI of the form `/bucket_name` (tenancy root) or `/compartment/path/bucket_name`. The adopting cycle resolves the compartment OCID from the path (empty path = tenancy root), looks up the bucket by name, and records it as not created (`.bucket.created = false`) so teardown does not delete it.

**Step 1 — create the bucket in cycle A:**

```bash
export NAME_PREFIX=storage
source do/oci_scaffold.sh

_state_set '.inputs.name_prefix'     "$NAME_PREFIX"

resource/ensure-bucket.sh

# capture the bucket name for reference
BUCKET_NAME=$(_state_get '.bucket.name')
```

Output:

```text
  [INFO] STATE_FILE: /Users/rstyczynski/projects/oci_scaffold/state-storage.json
  [DONE] Bucket created: storage-bucket
```

**Step 2 — adopt the bucket in cycle B by URI:**

```bash
export NAME_PREFIX=myapp
source do/oci_scaffold.sh

# URI encodes the full compartment path and bucket name — no OCID lookup needed
_state_set '.inputs.bucket_uri' "/storage-bucket"

# resolves compartment from path, looks up bucket by name, sets .bucket.created = false
resource/ensure-bucket.sh

# bucket name and namespace are now available in cycle B's state
BUCKET_NAME=$(_state_get '.bucket.name')
NAMESPACE=$(_state_get '.bucket.namespace')
```

Output:

```text
  [INFO] STATE_FILE: /Users/rstyczynski/projects/oci_scaffold/state-myapp.json
  [OK]   Using existing bucket 'storage-bucket'
```

When `do/teardown.sh` is called for cycle B, the bucket is left untouched. It is only deleted if cycle A's teardown runs.

```bash
do/teardown.sh
```

```text
  [OK]   Bucket: nothing to delete
  [INFO] State archived: /Users/rstyczynski/projects/oci_scaffold/state-myapp.deleted-20260318T091140.json
```

```bash
export NAME_PREFIX=storage
do/teardown.sh
```

```text
  [INFO] STATE_FILE: /Users/rstyczynski/projects/oci_scaffold/state-storage.json
  [DONE] Bucket deleted: storage-bucket
  [INFO] State archived: /Users/rstyczynski/projects/oci_scaffold/state-storage.deleted-20260318T091151.json
```

### Base64 file content in state (`_state_get_file`)

Some OCI CLI commands accept file arguments (e.g. `--user-data-file` for compute). Rather than requiring a file on the caller's filesystem, the scaffold provides a generic helper `_state_get_file` that resolves a file path from state — decoding base64 content to a temp file when available, or returning a plain file path as a fallback.

**Function signature:**

```bash
_state_get_file <key_prefix>
```

Looks up `.inputs.<key_prefix>_b64` first. If set, base64-decodes it to a temp file and prints the path. Falls back to `.inputs.<key_prefix>_file` when b64 is absent. Prints nothing when neither is set. Always returns 0 — safe under `set -euo pipefail`.

**Usage in ensure scripts:**

```bash
_ud_file=$(_state_get_file 'compute_user_data')
[ -n "$_ud_file" ] && _extra_args+=(--user-data-file "$_ud_file")
```

**Example — cloud-init with port substitution in `cycle-proxy.sh`:**

```bash
# render template, substitute placeholders, encode to b64
_user_data_b64=$(sed \
  -e "s/@@PROXY_PORT@@/${PROXY_PORT}/g" \
  -e "s/@@CA_PORT@@/${CA_PORT}/g" \
  "$DIR/etc/cloudinit/mitmproxy.yaml" | base64 | tr -d '\n')

_state_set '.inputs.compute_user_data_b64' "$_user_data_b64"
```

`ensure-compute.sh` calls `_state_get_file 'compute_user_data'` — the b64 key is found, decoded to a temp file, and its path forwarded to `oci compute instance launch --user-data-file`.

This keeps the state file self-contained — no dependency on the caller's filesystem layout — and allows in-memory content transforms (port substitution, templating) before the file is passed to OCI.

Currently applied in `ensure-compute.sh` (`.inputs.compute_user_data_b64` / `.inputs.compute_user_data_file`).

## mitmproxy HTTPS inspection proxy

`cycle-proxy.sh` provisions a compute instance running [mitmproxy](https://mitmproxy.org/) as an HTTPS inspection proxy, verifies it works, and optionally tears it down.

### How it works

- Cloud-init (`etc/cloudinit/mitmproxy.yaml`) installs mitmproxy in a Python 3.8 venv and starts it as a systemd service on **port 443**.
- A lightweight HTTP server (port 80) serves the mitmproxy CA certificate for client distribution.
- **Port 80** serves the CA certificate over plain HTTP. DPI firewalls allow standard HTTP GET on port 80.
- **Port 443** runs the proxy. DPI firewalls treat port 443 as opaque HTTPS and pass it through without inspection. Non-standard ports (8080, 3128, etc.) are blocked: the TCP handshake completes but the DPI silently drops the `HTTP CONNECT` payload after it, causing the client to time out. Port 443 bypasses this entirely.
- `block_global: false` is written to `/var/lib/mitmproxy/config.yaml` so the proxy accepts connections from all IPs, not just loopback.

### Usage

```bash
NAME_PREFIX=proxy ./cycle-proxy.sh
```

The script:

1. Provisions the instance and waits for cloud-init to complete
2. Downloads the CA cert to `/tmp/mitmproxy-ca-${NAME_PREFIX}.pem`
3. Fetches a joke via the proxy as a live end-to-end test
4. Prints proxy configuration instructions
5. Asks whether to teardown (auto-yes after 15 seconds)

### Using the proxy

```bash
# download CA cert
curl http://<public-ip>:80/mitmproxy-ca-cert.pem -o /tmp/mitmproxy-ca.pem

# use as HTTPS proxy
export HTTPS_PROXY=http://<public-ip>:443
export https_proxy=http://<public-ip>:443
curl --cacert /tmp/mitmproxy-ca.pem https://cloud.oracle.com

# remove proxy from CLI
unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy
```

### Notes

- mitmproxy 8.x requires Python 3.8+ — the cloud-init installs `python38` from OL8 AppStream.
- `werkzeug<2.3` is pinned alongside mitmproxy because mitmproxy 8.x's onboarding app uses a Flask API removed in werkzeug 2.3.
- The `ssl_insecure` option is intentionally omitted — with `ca-certificates` installed, Python's ssl module uses the OS trust store and verifies upstream certificates correctly.

## Backlog

- **Retry-safe `created` flag (`_state_set_if_unowned`)** — when an ensure script finds a resource by name on retry (because a prior run created it and then failed), it must not overwrite `created=true` with `false`. Without this, teardown treats the resource as externally owned and skips deletion, leaving it orphaned. Fix: use `_state_set_if_unowned` in the name-based lookup path — it sets `created=false` only when the flag was never `true`. Explicit adoption paths (OCID / URI inputs) always set `false` directly. ✅ Implemented for `ensure-vcn.sh`, `ensure-sl.sh`, `ensure-igw.sh`, `ensure-rt.sh`, `ensure-subnet.sh`, `ensure-compute.sh`. ⬜ Remaining: `ensure-natgw.sh`, `ensure-sgw.sh`, `ensure-vault.sh`, `ensure-key.sh`, `ensure-secret.sh`, `ensure-bucket.sh`, `ensure-fn_app.sh`, `ensure-log.sh`, `ensure-log_group.sh`, `ensure-compartment.sh`.

- **Apply self-polling to other resources** — currently only `teardown-compartment.sh` uses explicit work-request polling with live progress. Evaluate whether other long-running teardown operations (e.g. vault, log) benefit from the same treatment, or whether the silent `--wait-for-state` is sufficient for those resources. ✅ Implemented for `teardown-compartment.sh`.
- **Apply `_state_extra_args` to all ensure scripts** — currently only `ensure-bucket.sh` uses dynamic CLI argument pass-through. Apply the same pattern to the remaining ensure scripts (`ensure-vcn.sh`, `ensure-subnet.sh`, `ensure-vault.sh`, `ensure-key.sh`, `ensure-secret.sh`, `ensure-fn_app.sh`, `ensure-log.sh`, etc.) so optional OCI CLI flags can be passed to any resource without script changes. ✅ Implemented for `ensure-bucket.sh`.
- **Adopt existing resource by OCID** — allow setting `.inputs.{resource}_ocid` in state before running `ensure-*.sh`. When an OCID is present, skip the name-based discovery query and use the provided OCID directly. Set `.created = false` so teardown does not delete the adopted resource. ✅ Implemented for `ensure-bucket.sh` (`.inputs.bucket_ocid`).
- **Adopt existing resource by URI path** — allow setting `.inputs.{resource}_uri` in state as a compartment-path + resource name, e.g. `/comp1/comp2/resource_name`. The ensure script would resolve the compartment path to an OCID, query the resource by name within that compartment, and adopt it with `.created = false`. This decouples resource adoption from the `NAME_PREFIX` naming convention entirely. ✅ Implemented for `ensure-bucket.sh` (`.inputs.bucket_uri`).
- **Base64 file content in state (`.inputs.{resource}_file_b64`)** — instead of passing a local file path (`.inputs.{resource}_file`), allow supplying the file content as a base64-encoded string stored directly in the state. The ensure script checks for the `_b64` key first, decodes to a temp file, and falls back to the `_file` path when absent. This makes state files self-contained and removes the dependency on the caller's filesystem. ✅ Implemented for `ensure-compute.sh` (`.inputs.compute_user_data_b64` / `.inputs.compute_user_data_file`). ⬜ Remaining: other ensure scripts that accept file inputs.

## Dependencies

- `oci` CLI (configured and authenticated)
- `jq`
- `dig`
