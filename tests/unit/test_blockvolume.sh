#!/usr/bin/env bash
# tests/unit/test_blockvolume.sh — local teardown behavior tests
set -euo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0
FAIL=0

_pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
_section() { echo ""; echo "=== $* ==="; }

make_mock_oci_teardown() {
  local bin_dir="$1"
  cat > "$bin_dir/oci" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_OCI_LOG:?}"

case "$*" in
  "compute volume-attachment get --volume-attachment-id attach-123 --query data.\"lifecycle-state\" --raw-output")
    echo "ATTACHED"
    ;;
  "bv volume get --volume-id vol-123 --query data.\"lifecycle-state\" --raw-output")
    echo "AVAILABLE"
    ;;
  "compute volume-attachment detach --volume-attachment-id attach-123 --wait-for-state DETACHED --force")
    ;;
  "bv volume delete --volume-id vol-123 --wait-for-state TERMINATED --force")
    ;;
  *)
    ;;
esac
EOF
  chmod +x "$bin_dir/oci"
}

make_mock_oci_ensure_unattached() {
  local bin_dir="$1"
  cat > "$bin_dir/oci" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_OCI_LOG:?}"

case "$*" in
  "bv volume list --compartment-id ocid1.compartment.oc1..test --query data[?\"display-name\"==\`unitbv-bv\` && \"lifecycle-state\"!=\`TERMINATED\`].id | [0] --raw-output")
    echo ""
    ;;
  "iam availability-domain list --compartment-id ocid1.tenancy.oc1..test --query data[0].name --raw-output")
    echo "kIdk:EU-FRANKFURT-1-AD-1"
    ;;
  "os ns get-metadata --query data.\"default-s3-compartment-id\" --raw-output")
    echo "ocid1.tenancy.oc1..test"
    ;;
  "bv volume create --compartment-id ocid1.compartment.oc1..test --availability-domain kIdk:EU-FRANKFURT-1-AD-1 --display-name unitbv-bv --size-in-gbs 50 --wait-for-state AVAILABLE --query data.id --raw-output")
    echo "vol-new"
    ;;
  "bv volume get --volume-id vol-new --query data.\"vpus-per-gb\" --raw-output")
    echo "10"
    ;;
  *)
    ;;
esac
EOF
  chmod +x "$bin_dir/oci"
}

test_UT1_ensure_can_create_unattached_volume() {
  _section "UT-1: ensure creates unattached volume without compute"

  local tmpdir state_file out status=0
  tmpdir=$(mktemp -d)
  state_file="$tmpdir/state-unitbv.json"
  jq -n '{}' > "$state_file"

  make_mock_oci_ensure_unattached "$tmpdir"
  : > "$tmpdir/oci.log"

  out=$(cd "$tmpdir" && \
    PATH="$tmpdir:$PATH" \
    MOCK_OCI_LOG="$tmpdir/oci.log" \
    NAME_PREFIX="unitbv" \
    COMPARTMENT_OCID="ocid1.compartment.oc1..test" \
    OCI_REGION="eu-test-1" \
    bash "$DIR/resource/ensure-blockvolume.sh" 2>&1) || status=$?

  if [ "$status" -eq 0 ] &&
     [[ "$out" == *"Block volume created (50 GB): vol-new"* ]] &&
     [[ "$out" == *"Block volume attachment skipped"* ]] &&
     jq -e '
       .blockvolume.ocid == "vol-new" and
       .blockvolume.name == "unitbv-bv" and
       .blockvolume.created == true and
       .blockvolume.attachment_ocid == "" and
       .blockvolume.attachment_created == false and
       .blockvolume.attach_type == "" and
       .blockvolume.deleted == false
     ' "$state_file" >/dev/null 2>&1 &&
     ! grep -q 'compute volume-attachment' "$tmpdir/oci.log"; then
    _pass "UT-1: unattached ensure creates volume and skips attachment calls"
  else
    _fail "UT-1: expected unattached volume create path"
    echo "$out"
    cat "$state_file"
    [ -f "$tmpdir/oci.log" ] && cat "$tmpdir/oci.log"
  fi

  rm -rf "$tmpdir"
}

test_UT2_unowned_state_is_noop() {
  _section "UT-2: teardown no-op on unowned state"

  local tmpdir state_file out status=0
  tmpdir=$(mktemp -d)
  state_file="$tmpdir/state-unitbv.json"
  jq -n '{
    blockvolume: {
      ocid: "vol-123",
      attachment_ocid: "attach-123",
      created: false,
      attachment_created: false,
      deleted: false
    }
  }' > "$state_file"

  make_mock_oci_teardown "$tmpdir"
  : > "$tmpdir/oci.log"

  out=$(cd "$tmpdir" && \
    PATH="$tmpdir:$PATH" \
    MOCK_OCI_LOG="$tmpdir/oci.log" \
    NAME_PREFIX="unitbv" \
    COMPARTMENT_OCID="ocid1.compartment.oc1..test" \
    OCI_REGION="eu-test-1" \
    bash "$DIR/resource/teardown-blockvolume.sh" 2>&1) || status=$?

  if [ "$status" -eq 0 ] &&
     [[ "$out" == *"Block volume attachment: nothing to detach"* ]] &&
     [[ "$out" == *"Block volume: nothing to delete"* ]] &&
     [ ! -s "$tmpdir/oci.log" ]; then
    _pass "UT-2: unowned teardown exited cleanly without OCI mutations"
  else
    _fail "UT-2: expected no-op teardown for unowned state"
    echo "$out"
    [ -f "$tmpdir/oci.log" ] && cat "$tmpdir/oci.log"
  fi

  rm -rf "$tmpdir"
}

_run_tests() {
  local target="${1:-all}"
  if [ "$target" = "all" ]; then
    test_UT1_ensure_can_create_unattached_volume
    test_UT2_unowned_state_is_noop
  else
    "$target"
  fi

  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [ "$FAIL" -eq 0 ]
}

_run_tests "${1:-all}"
