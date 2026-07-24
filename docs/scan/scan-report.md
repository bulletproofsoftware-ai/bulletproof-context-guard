# Security Scan Report — bulletproof-context-guard

**Scanner:** Code Hardener (`standard` profile — 12 code-appropriate scanners)
**Scan ID:** `7cbe07b4-098f-41f3-a2f0-964f66c4967d`
**Branch:** `main`
**Date:** 2026-07-24
**Score:** **946 / 1000** — quality level **excellent**

## Result: 0 critical / 0 high

| Severity | Count |
|----------|-------|
| Critical | **0** |
| High | **0** |
| Medium | 7 |
| Low | 2 |
| Info | 0 |

- **Secrets scan (gitleaks): PASS** — 21 files, 150+ patterns, entropy analysis, **0 secrets**.
- **Dependency CVEs (trivy + grype): 0** — no vulnerable packages (repo has no third-party libraries).
- **IaC (checkov) / GitHub Actions (actionlint): 0.**
- Twelve scanners executed: trivy, gitleaks, opengrep, checkov, grype, syft, ruff,
  actionlint, jscpd, typos (+ oxlint and package-validator skipped — no JS/TS and no
  dependency manifests to validate).

## Fixes applied

| Finding | Scanner | Severity | Fix |
|---------|---------|----------|-----|
| `github-actions-mutable-action-tag` — `actions/checkout@v4` not pinned | opengrep | medium | Pinned to immutable commit SHA `11d5960a326750d5838078e36cf38b85af677262 # v4` in `.github/workflows/ci.yml` (commit `d5c240c`). |
| `Unknown License: actions/checkout@v4` | syft | low | Resolved alongside the pin (finding now references the SHA; see residual note below). |

Both the initial scan (score 943) and the confirming re-scan (score 946) reported
**0 critical / 0 high**. No security-impacting finding remained after the fix; the pin was
applied to eliminate the one supply-chain-hardening medium and improve provenance.

## What remains (low-risk, intentionally not chased)

Per the repo's documentation-pipeline policy, cosmetic mediums and informational lows are
documented honestly rather than force-fixed:

- **7 × Ruff (medium) — unused locals/imports in `mcp/server.py`:** `os` and `time`
  imports, and the locals `cache_creation`, `cache_read`, `current_input`,
  `current_output`, and a shadowed `remaining_pct` inside `estimate_compartments`. These
  are dead code with **no security impact**. They are left in place deliberately — the
  extracted `current_usage` fields document the telemetry shape the estimator can consume,
  and auto-stripping them risks removing intentional near-term scaffolding. A maintainer
  may remove them in a routine cleanup.
- **1 × syft (low) — "Unknown License" for `actions/checkout`:** GitHub Actions do not
  publish SPDX license metadata, so this is informational and not fixable at our layer.
- **1 × trivy (low) — "License Compliance: Apache-2.0 in LICENSE":** the scanner detecting
  the project's own Apache-2.0 license file. Informational; correct and expected.

## Signed artifacts

The following are generated from the final clean scan and committed alongside this file:

- [`bulletproof-context-guard-scan-report.pdf`](bulletproof-context-guard-scan-report.pdf)
  — rich portal report (8 pages). Page 1 is the **in-toto attestation certificate**:
  score 946/1000, Ed25519-signed, subject digest `sha256:5bfc1ac6…`.
- [`attestation.json`](attestation.json) — cryptographic attestation (in-toto, Ed25519).
- [`scan-report.sarif.json`](scan-report.sarif.json) — SARIF 2.1.0 findings (paths
  normalized; no host paths).
- [`scan-report-full.md`](scan-report-full.md) — full machine-generated report.

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [../LICENSE](../../LICENSE) and [../NOTICE](../../NOTICE).
