# Sprint 2 - Bugs

## BUG-1: `ensure-blockvolume.sh` cannot create an unattached block volume

**Item:** OCI-5
**Severity:** medium
**Status:** fixed

- **Symptom**: The intended two-step flow could not be executed: `NAME_PREFIX=bv-second resource/ensure-blockvolume.sh` failed because `ensure-blockvolume.sh` required `.compute.ocid` and always ensured an attachment. Observed while correcting the Sprint 2 README block-volume adoption examples.
- **Root cause**: `ensure-blockvolume.sh` combined two responsibilities in one path: ensure volume existence and ensure attachment existence. There was no unattached-volume path.
- **Fix**: Added unattached mode to `resource/ensure-blockvolume.sh`. The script now creates or adopts the volume without requiring `.compute.ocid`, skips attachment when no compute is provided or `.inputs.bv_skip_attach=true`, and derives the availability domain from `.inputs.bv_availability_domain`, the adopted compute, or the first tenancy AD.
- **Verification**: `bash tests/run.sh --unit --component blockvolume` passes, including `test_blockvolume.sh:test_UT1_ensure_can_create_unattached_volume`.
