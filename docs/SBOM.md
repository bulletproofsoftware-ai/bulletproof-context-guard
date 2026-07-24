# Software Bill of Materials — bulletproof-context-guard

This project has **no third-party library dependencies**. It is plain Bash + Python 3
(standard library only), with no package manifests (`package.json` / `requirements.txt` /
`pyproject.toml`), no build step, and no Docker image. The "dependencies" are therefore
**runtime prerequisites** — interpreters and standard system utilities — not vendored
libraries.

A machine-readable CycloneDX 1.5 SBOM is committed alongside this file:
[`context-guard.cyclonedx.json`](context-guard.cyclonedx.json).

## Component summary

| Component | Version | Scope | Role |
|-----------|---------|-------|------|
| CPython (`python3`) | ≥ 3.10 | required | Runs `mcp/server.py`, `hooks/thresholds.py`, `hooks/velocity.py`. **Standard library only.** |
| `bash` | any modern | required | Runs the three lifecycle hooks + `scripts/statusline.sh`. |
| `jq` | any modern | required | Parses Claude Code hook JSON in the Bash scripts. Degrades gracefully if missing. |
| coreutils (`date`, `tr`, `find`, `awk`) | any modern | required | Shell utilities invoked by the scripts. |

**Component count: 4** — all runtime prerequisites, all under permissive/OS-standard
licensing. **Zero** vendored third-party libraries.

## Python standard-library modules used

No installable packages — only the following stdlib modules are imported across
`mcp/server.py`, `hooks/thresholds.py`, and `hooks/velocity.py`:

`json`, `os`, `sys`, `time`, `datetime`, `pathlib`, `__future__`.

## Base images

**None.** This repository ships no `Dockerfile` and produces no container image. It runs
in place inside the host Claude Code + shell environment.

## License distribution

| License | Components |
|---------|-----------|
| Apache-2.0 | This project (`bulletproof-context-guard`). |
| PSF / permissive | CPython (upstream). |
| Permissive / OS-standard | `bash`, `jq`, coreutils (governed by the host OS distribution). |

There are no bundled or vendored dependencies whose licenses this project redistributes.

## Supply-chain notes

- No lockfile exists because there is nothing to lock — the attack surface is limited to
  the host-provided interpreters and utilities.
- The one CI-side action dependency is `actions/checkout@v4` in
  `.github/workflows/ci.yml`; ShellCheck is installed transiently via `apt-get` at CI
  time and is not part of the shipped artifact.

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
