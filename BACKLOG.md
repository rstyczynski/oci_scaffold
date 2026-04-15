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
