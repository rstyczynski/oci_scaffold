# ensure-compute.sh — Design

## Purpose

Idempotent OCI Compute instance creation for integration testing. Minimal by default — one instance, one subnet, no frills.

## Dependencies

Requires `ensure-subnet.sh` to have run first (`.subnet.ocid`).

## Inputs

| State key | Required | Default | Notes |
| --- | --- | --- |---|
| `.inputs.oci_compartment` | yes | — | |
| `.inputs.name_prefix` | yes | — | display name = `{prefix}-instance` |
| `.subnet.ocid` | yes | — | from `ensure-subnet.sh` |
| `.inputs.compute_uri` | no | *(none)* | adopt existing instance: `/instance_name` or `/compartment/path/instance_name`; skips creation, sets `.compute.created=false` |
| `.inputs.compute_shape` | no | `VM.Standard.E4.Flex` | `--shape` |
| `.inputs.compute_ocpus` | no | `1` | composed into `--shape-config`; flex shapes only |
| `.inputs.compute_memory_gb` | no | `4` | composed into `--shape-config`; flex shapes only |
| `.inputs.compute_image_id` | no | latest Oracle Linux 8 in region | `--image-id`; auto-discovered if not set |
| `.inputs.compute_ssh_authorized_keys_file` | no | *(none)* | `--ssh-authorized-keys-file`; no key = no SSH |
| `.inputs.compute_user_data_file` | no | *(none)* | `--user-data-file`; cloud-init script path |

`compute_ocpus` and `compute_memory_gb` are handled explicitly (composed into `--shape-config`). All other `.inputs.compute_*` keys are forwarded to `oci compute instance launch` via `_state_extra_args`.

## Image auto-discovery

When `.inputs.compute_image_id` is not set:

```bash
oci compute image list \
  --compartment-id "$COMPARTMENT_OCID" \
  --operating-system "Oracle Linux" \
  --operating-system-version "8" \
  --shape "$COMPUTE_SHAPE" \
  --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output
```

## Outputs

| State key | Value |
| --- | --- |
| `.compute.ocid` | instance OCID |
| `.compute.name` | display name |
| `.compute.public_ip` | public IP or empty |
| `.compute.private_ip` | private IP |
| `.compute.created` | `true` / `false` |

## Teardown

`teardown-compute.sh` — terminates instance if `.compute.created = true`, polls `--wait-for-state TERMINATED`.

## Cycle

`cycle-compute.sh` — compartment → VCN → SL → SGW → RT → subnet → compute → teardown.
