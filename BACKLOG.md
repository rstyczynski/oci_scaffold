# OCI Scaffold - Backlog

version: 1

OCI Scaffold is a modular, idempotent framework for provisioning and tearing down Oracle Cloud Infrastructure (OCI) resources — primarily for integration testing of OCI Functions and related services.

## Backlog

Project aim is to deliver all the features listed in a below Backlog. Backlog Items selected for implementation are added to iterations detailed in `PLAN.md`. Full list of Backlog Items presents general direction and aim for this project.

### OCI-1. Add ensure/teardown scripts and cycle example for OCI Dashboard service

OCI Monitoring Dashboards lack scaffold coverage, making it impossible to provision and clean up dashboards as part of automated integration test cycles. Add `ensure-dashboard_group.sh` and `ensure-dashboard.sh` scripts that adopt or create resources identified by a URI of the form `/compartment/path/dashboard-group/dashboard`, consistent with the URI approach already used by `ensure-bucket.sh`. A matching `teardown-dashboard.sh` and `teardown-dashboard_group.sh` handle deletion only when the scaffold created the resource. The `cycle-dashboard.sh` script demonstrates the full lifecycle end-to-end.

Test: `cycle-dashboard.sh` completes without error, creating and tearing down a dashboard group and dashboard identified by URI, with state recorded correctly in the state file.

### OCI-2. Exemplary dashboard with logging, audit, and metrics widgets

A bare dashboard is not useful as a reference for users building real observability setups. Provide a ready-to-use dashboard definition included by `cycle-dashboard.sh` that contains at least one Log Explorer widget sourced from the OCI Logging service, one Audit Events widget, and one Metrics widget bound to a platform-available metric namespace such as `oci_computeagent` or `oci_objectstorage`. The widget definitions follow the OCI Monitoring Dashboard JSON schema and are parameterised by compartment OCID so the cycle script can inject them without hard-coding.

Test: the deployed dashboard is visible in the OCI Console under the correct compartment and displays all three widget types populated with data from the target compartment.

### OCI-3. Block Volume resource — review, integrate, document

Block volume provisioning (`ensure-blockvolume.sh`, `teardown-blockvolume.sh`) was introduced from an external project and is not yet fully aligned with oci_scaffold conventions. Review both scripts against patterns used elsewhere (state layout, `creation_order`, idempotency, adoption of existing resources, error messages, and any async OCI behaviour). Add a dedicated cycle script (for example `cycle-blockvolume.sh` or a small compose cycle with compute plus volume) so the resource can be exercised end-to-end like other modules. Extend `README.md` with prerequisites, state inputs, run/teardown instructions, and how the cycle fits the rest of the scaffold.

Test: the new or updated cycle completes create and teardown without manual fixes, state reflects the volume and attachment correctly, and README documents the workflow clearly enough for a new operator to run it.

### OCI-4. Simple fio proof run for block volume cycle

The block volume cycle currently proves attach and teardown, but it does not yet demonstrate that the attached volume can sustain a basic application-style I/O workload. Add a short fio run inside the cycle using a regular mixed load and a fixed 60-second window, then save the raw fio JSON output together with an `iostat` report so operators can inspect both the benchmark result and the observed device activity. Keep it simple and demonstrative rather than turning the cycle into a long benchmark suite.

Test: the block volume cycle completes the 60-second fio run without manual fixes and leaves both a fio JSON artifact and an `iostat` report that show activity on the tested volume.

### OCI-5. URI-style adoption for block volume cycle

The block volume cycle should support the same user-facing URI adoption style already used by other scaffolded resources such as buckets and dashboards. Allow a second cycle to reference an existing block volume by a regular URI of the form `/compartment/path/volume-name`, adopt it without creating a second volume, and keep teardown ownership with the original creating cycle.

Test: a cycle started with a block volume URI adopts the existing volume with `.blockvolume.created=false`, does not create a second volume, and can be torn down before the original creating cycle.

### OCI-6. Add ensure/teardown scripts and cycle example for OCI File Storage Service (FSS)

OCI File Storage Service (FSS) is not yet supported by the scaffold, preventing automated integration test cycles from provisioning and cleaning up shared NFS storage. Add support for the core FSS resources: file system, mount target, and export. Provide `ensure-fss_filesystem.sh`, `ensure-fss_mount_target.sh`, and `ensure-fss_export.sh` scripts that are idempotent and follow the existing scaffold conventions (URI-style identification/adoption, state ownership tracking, and predictable output). Add matching teardown scripts (`teardown-fss_filesystem.sh`, `teardown-fss_mount_target.sh`, `teardown-fss_export.sh`) that only delete resources created by the scaffold. Include an exemplary `cycle-fss.sh` showing an end-to-end lifecycle: create/adopt mount target, create file system, create export, then tear down in reverse order.

Test: `cycle-fss.sh` completes without error, creates or adopts an FSS mount target, provisions a file system and export, records state correctly (including `.created` ownership flags), and tears down only scaffold-owned resources.
