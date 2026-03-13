# OCI Scaffold

Modular, idempotent framework for provisioning and tearing down Oracle Cloud Infrastructure (OCI) resources — primarily for integration testing of OCI Functions and related services.

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
# OCI_COMPARTMENT is optional — defaults to tenancy OCID
# OCI_REGION is optional — defaults to home region

# Network cycle (Service Gateway / OSN only)
NAME_PREFIX=subnet ./cycle-subnet.sh

# Network + NAT Gateway (internet access) cycle
NAME_PREFIX=subnet_nat ./cycle-subnet-nat.sh

# Vault + Key + Secret cycle
NAME_PREFIX=secret SECRET_VALUE=myvalue ./cycle-vault.sh

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

## State file

All resource OCIDs and flags are stored in `STATE_FILE` (default: `./state-{NAME_PREFIX}.json` in the current directory). The `meta.creation_order` array drives teardown sequencing. Only resources with `created: true` are deleted on teardown.

```bash
# Override location
STATE_FILE=/tmp/state-run1.json NAME_PREFIX=run1 ./cycle-subnet.sh
```

Summary counters (`created`, `existing`, `tested`, `failed`) are reset at the start of each test run and updated in real-time as each resource operation completes.

## Key configuration

| Variable | Default | Description |
| --- | --- | --- |
| `NAME_PREFIX` | **required** | Prefix for all created resource names |
| `OCI_COMPARTMENT` | tenancy OCID | Target compartment; auto-discovered when omitted |
| `OCI_REGION` | home region | Region identifier (e.g. `eu-zurich-1`); auto-discovered when omitted |
| `STATE_FILE` | `./state-{NAME_PREFIX}.json` | JSON state file path; set before sourcing `do/oci_scaffold.sh` |
| `COMPARTMENT_PATH` | — | Full path for `cycle-compartment.sh` (e.g. `/landing-zone/workloads/myapp`) |
| `.inputs.vcn_cidr` | `10.0.0.0/16` | VCN CIDR block |
| `.inputs.subnet_cidr` | `10.0.0.0/24` | Subnet CIDR block |
| `.inputs.subnet_prohibit_public_ip` | `true` | Prohibit public IPs on VNICs |
| `SECRET_VALUE` | — | Secret value for `cycle-vault.sh` |

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

## Backlog

- **Apply self-polling to other resources** — currently only `teardown-compartment.sh` uses explicit work-request polling with live progress. Evaluate whether other long-running teardown operations (e.g. vault, log) benefit from the same treatment, or whether the silent `--wait-for-state` is sufficient for those resources.

## Dependencies

- `oci` CLI (configured and authenticated)
- `jq`
- `dig`
