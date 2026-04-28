# Sprint 3 — Test Execution Results

## Summary

| Gate           | Result | Retries | Notes |
|----------------|--------|---------|-------|
| A1 Smoke       | skip   | —       | `Test:` does not include smoke |
| A2 Unit        | skip   | —       | `Test:` does not include unit |
| A3 Integration | PASS   | 6       | initial failures fixed (inputs, exec bits, FSS AD, export wait-state, mount target IP resolution, NPA destination endpoint type, test robustness) |
| B1 Smoke       | skip   | —       | `Regression:` does not include smoke |
| B2 Unit        | PASS   | 1       | unit regression suite (`component_unit.manifest`) |
| B3 Integration | skip   | —       | `Regression:` does not include integration |

## Artifacts

| Gate           | Log File |
|----------------|----------|
| A3 Integration | `progress/sprint_3/test_run_A3_integration_20260427_143729.log` |
| B2 Unit        | `progress/sprint_3/test_run_B2_unit_20260427_144029.log` |
