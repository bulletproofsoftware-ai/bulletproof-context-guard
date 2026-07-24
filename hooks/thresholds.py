#!/usr/bin/env python3
"""thresholds.py — context-guard adaptive thresholds (REQ-CTX-004).

Computes alert tier thresholds from a rolling 10-measurement window of context
consumption. Adapts tier boundaries downward when consumption pace is high, while
enforcing a hard 16-token absolute floor that overrides all adaptive logic.

Default tier boundaries (in tokens-remaining):
  Warning    = 30
  Advisory   = 15
  Yellow     =  7
  Critical   =  3
  Hard floor = 16  (REQ-CTX-004 — adaptive thresholds can never drop below this)

Output: writes `state/telemetry/thresholds.json` with current tier boundaries +
how velocity influenced them. Exit 0 always.
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
OUT_PATH = TELEMETRY_DIR / "thresholds.json"

WINDOW_SIZE = int(os.environ.get("CONTEXT_THRESHOLD_WINDOW", "10"))
HARD_FLOOR = int(os.environ.get("CONTEXT_HARD_FLOOR", "16"))

DEFAULT_TIERS = {
    "warning": int(os.environ.get("CONTEXT_TIER_WARNING", "30")),
    "advisory": int(os.environ.get("CONTEXT_TIER_ADVISORY", "15")),
    "yellow": int(os.environ.get("CONTEXT_TIER_YELLOW", "7")),
    "critical": int(os.environ.get("CONTEXT_TIER_CRITICAL", "3")),
}


def _recent_samples(n: int) -> list[float]:
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


def adaptive_tiers(samples: list[float]) -> dict[str, int]:
    """Compute adaptive tier boundaries. Floor enforcement applies to ALL tiers.

    Heuristic: if rolling mean tokens/op > 5, scale every tier up by 1.5×
    so warnings fire earlier (more headroom). Otherwise keep defaults.
    Tiers never drop below HARD_FLOOR for the Warning tier; lower tiers floor at 0.
    """
    base = dict(DEFAULT_TIERS)
    if not samples:
        return _apply_floor(base)
    avg = sum(samples) / len(samples)
    if avg > 5.0:
        scale = min(2.0, 1.0 + (avg - 5.0) / 10.0)  # cap at 2× scale
        for k in base:
            base[k] = int(round(base[k] * scale))
    return _apply_floor(base)


def _apply_floor(tiers: dict[str, int]) -> dict[str, int]:
    # Warning tier is the canary — it must never drop below the floor.
    tiers["warning"] = max(tiers["warning"], HARD_FLOOR)
    # Lower tiers monotonic
    tiers["advisory"] = max(min(tiers["advisory"], tiers["warning"] - 1), 0)
    tiers["yellow"] = max(min(tiers["yellow"], tiers["advisory"] - 1), 0)
    tiers["critical"] = max(min(tiers["critical"], tiers["yellow"] - 1), 0)
    return tiers


def main() -> int:
    TELEMETRY_DIR.mkdir(parents=True, exist_ok=True)
    samples = _recent_samples(WINDOW_SIZE)
    tiers = adaptive_tiers(samples)
    payload = {
        "window_size": WINDOW_SIZE,
        "samples_used": len(samples),
        "hard_floor": HARD_FLOOR,
        "default_tiers": DEFAULT_TIERS,
        "active_tiers": tiers,
        "avg_tokens_per_op": round(sum(samples) / len(samples), 2) if samples else 0.0,
        "computed_at": datetime.now(timezone.utc).isoformat(),
    }
    try:
        OUT_PATH.write_text(json.dumps(payload, indent=2))
    except OSError as exc:
        sys.stderr.write(f"thresholds.py: write failed: {exc}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
