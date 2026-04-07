#!/usr/bin/env bash
# teardown-gateway.sh — DEPRECATED (use teardown-apigw.sh)
#
# Reads from state.json:
#   .gateway.gateway_ocid
#   .gateway.gateway_created
#   .gateway.deployment_ocid
#   .gateway.deployment_created
#
# Optional:
#   FORCE_DELETE=true  # deletes even if not created by this run
set -euo pipefail
# shellcheck source=do/oci_scaffold.sh
source "$(dirname "$0")/../do/oci_scaffold.sh"

_info "teardown-gateway.sh is deprecated; use teardown-apigw.sh"
teardown-apigw.sh

exit 0

