#!/usr/bin/env python3
"""velocity.py — context-guard velocity detector (REQ-CTX-003).

Reads the rolling consumption log, computes tokens/operation over the last 3 samples,
and emits an early-escalation flag when sustained velocity exceeds the threshold.

Default threshold: >5 tokens/op triggers an early jump to the next warning tier.
Override with CONTEXT_VELOCITY_THRESHOLD env var.

Output: writes `state/telemetry/velocity.json` with:
  {window_size, samples_used, avg_tokens_per_op, threshold, early_escalate, computed_at}
Returns exit 0 always — never blocks the calling hook.
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PLUGIN_ROOT = SCRIPT_DIR.parent
STATE_DIR = PLUGIN_ROOT / "state"
TELEMETRY_DIR = STATE_DIR / "telemetry"

CONSUMPTION_LOG = STATE_DIR / "consumption.log"
OUT_PATH = TELEMETRY_DIR / "velocity.json"

WINDOW_SIZE = int(os.environ.get("CONTEXT_VELOCITY_WINDOW", "3"))
DEFAULT_THRESHOLD = float(os.environ.get("CONTEXT_VELOCITY_THRESHOLD", "5.0"))


def _read_recent_samples(n: int) -> list[float]:
    """Read up to n most recent tokens-per-op samples from consumption.log.

    Log format (one entry per line, oldest first):
        <ISO timestamp>\t<tokens_consumed>\t<tool_name>
    """
    if not CONSUMPTION_LOG.exists():
        return []
    try:
        lines = CONSUMPTION_LOG.read_text().splitlines()
    except OSError:
        return []
    samples: list[float] = []
    for line in reversed(lines):
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        try:
            samples.append(float(parts[1]))
        except ValueError:
            continue
        if len(samples) >= n:
            break
    samples.reverse()
    return samples


def compute_velocity(samples: list[float]) -> tuple[float, bool]:
    """Return (avg_tokens_per_op, early_escalate_flag)."""
    if not samples:
        return 0.0, False
    avg = sum(samples) / len(samples)
    return avg, avg > DEFAULT_THRESHOLD


def main() -> int:
    TELEMETRY_DIR.mkdir(parents=True, exist_ok=True)
    samples = _read_recent_samples(WINDOW_SIZE)
    avg, early = compute_velocity(samples)
    payload = {
        "window_size": WINDOW_SIZE,
        "samples_used": len(samples),
        "samples": samples,
        "avg_tokens_per_op": round(avg, 2),
        "threshold": DEFAULT_THRESHOLD,
        "early_escalate": early,
        "computed_at": datetime.now(timezone.utc).isoformat(),
    }
    try:
        OUT_PATH.write_text(json.dumps(payload, indent=2))
    except OSError as exc:
        sys.stderr.write(f"velocity.py: write failed: {exc}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
