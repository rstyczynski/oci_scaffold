# Development plan

OCI Scaffold is a modular, idempotent framework for provisioning and tearing down Oracle Cloud Infrastructure (OCI) resources — primarily for integration testing of OCI Functions and related services.

Instruction for the operator: keep the development sprint by sprint by changing `Status` label from Planned via Progress to Done. To achieve simplicity each iteration contains exactly one feature. You may add more backlog Items in `BACKLOG.md` file, referring them in this plan.

Instruction for the implementor: keep analysis, design and implementation as simple as possible to achieve goals presented as Backlog Items. Remove each not required feature sticking to the Backlog Items definitions.

## Sprint 1 - OCI Dashboard scaffold

Status: Done
Mode: YOLO
Test: integration
Regression: none

Backlog Items:

* OCI-1. Add ensure/teardown scripts and cycle example for OCI Dashboard service
* OCI-2. Exemplary dashboard with logging, audit, and metrics widgets

## Sprint 2 - Block Volume integration (OCI-3, OCI-4, OCI-5)

Status: Done
Mode: managed
Test: integration
Regression: unit

Backlog Items:

* OCI-3. Block Volume resource — review, integrate, document
* OCI-4. Simple fio proof run for block volume cycle
* OCI-5. URI-style adoption for block volume cycle

## Sprint 3 - OCI File Storage Service (FSS) scaffold (OCI-6)

Status: Progress
Mode: managed
Test: integration
Regression: unit

Backlog Items:

* OCI-6. Add ensure/teardown scripts and cycle example for OCI File Storage Service (FSS)
