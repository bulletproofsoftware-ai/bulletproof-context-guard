#!/usr/bin/env python3
"""Context Budget MCP Server — exposes context window usage with 5-compartment breakdown.

Compartments (estimated from available telemetry):
  1. system_prompt    — System instructions, CLAUDE.md, plugin injections
  2. conversation     — User messages + assistant responses (historical turns)
  3. tool_results     — Output from tool calls (Read, Bash, Grep, etc.)
  4. file_contents    — Files read into context (Read tool payloads)
  5. working_memory   — Current turn working set (recent tool calls + response in progress)

Since Claude Code only provides aggregate token counts, compartments are estimated
by parsing the session transcript JSONL and categorizing each message type.

Integrates with the existing 4-tier escalation thresholds and publishes telemetry
events consumable by the conductor plugin.
"""

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# MCP protocol over stdio
#
# MCP stdio transport is NEWLINE-DELIMITED JSON: one JSON-RPC message per line.
# This server previously wrote LSP-style "Content-Length:" framing, which no
# MCP client speaks, so the advertised context_budget tool never once
# responded to a real client — the handshake simply never completed.
#
# (The old framing also computed Content-Length with len() on a str, i.e.
# characters rather than UTF-8 bytes, which would have mis-framed any
# non-ASCII payload even for a client that did speak LSP framing.)
# ---------------------------------------------------------------------------
def _write_message(msg):
    """Write one JSON-RPC message as a single line, per MCP stdio transport."""
    # ensure_ascii keeps the payload on one line and byte-safe regardless of
    # the terminal encoding; separators drop insignificant whitespace.
    line = json.dumps(msg, ensure_ascii=True, separators=(",", ":"))
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def send_response(id_, result):
    _write_message({"jsonrpc": "2.0", "id": id_, "result": result})


def send_error(id_, code, message):
    _write_message(
        {"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": message}}
    )


# ---------------------------------------------------------------------------
# Untrusted identifiers
# ---------------------------------------------------------------------------
_SAFE_SEGMENT = re.compile(r"\A[A-Za-z0-9._-]{1,255}\Z")


def safe_child(base: Path, identifier, suffix: str = "") -> Path:
    """Resolve base/<identifier><suffix>, or raise ValueError.

    session_id reaches this server as a tool argument, so it is untrusted.
    Joining it directly let "../.." escape the sessions directory, and let an
    absolute path replace the base entirely (pathlib discards the left operand
    when the right is absolute) — allowing an arbitrary JSON file to be read
    back to the caller, and an arbitrary path to be written by the telemetry
    writer.
    """
    if not isinstance(identifier, str) or not _SAFE_SEGMENT.match(identifier):
        raise ValueError(f"unsafe identifier: {identifier!r}")
    if identifier in (".", "..") or identifier.startswith("."):
        raise ValueError(f"unsafe identifier: {identifier!r}")
    candidate = base / f"{identifier}{suffix}"
    resolved_base = base.resolve()
    resolved = candidate.resolve()
    if resolved != resolved_base and resolved_base not in resolved.parents:
        raise ValueError(f"identifier escapes {base}: {identifier!r}")
    return resolved

# Paths
PLUGIN_ROOT = Path(__file__).resolve().parent.parent
STATE_DIR = PLUGIN_ROOT / "state"
SESSIONS_DIR = STATE_DIR / "sessions"
CONFIG_PATH = PLUGIN_ROOT / "plugin.json"

# Load thresholds from plugin.json
def load_config():
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
        thresholds = cfg.get("configuration", {}).get("thresholds", {})
        return {
            "level_1_distance": thresholds.get("level_1_distance", 30),
            "level_2_distance": thresholds.get("level_2_distance", 15),
            "level_3_distance": thresholds.get("level_3_distance", 7),
            "level_4_distance": thresholds.get("level_4_distance", 3),
        }
    except Exception:
        return {"level_1_distance": 30, "level_2_distance": 15, "level_3_distance": 7, "level_4_distance": 3}


def get_latest_session():
    """Find the most recently updated session directory."""
    if not SESSIONS_DIR.exists():
        return None
    sessions = []
    for d in SESSIONS_DIR.iterdir():
        raw = d / "raw"
        if raw.exists():
            sessions.append((raw.stat().st_mtime, d))
    if not sessions:
        return None
    sessions.sort(key=lambda x: x[0], reverse=True)
    return sessions[0][1]


def read_session_data(session_dir):
    """Read raw statusline data for a session."""
    raw_path = session_dir / "raw"
    if not raw_path.exists():
        return None
    try:
        with open(raw_path) as f:
            return json.load(f)
    except Exception:
        return None


def estimate_compartments(session_data):
    """Estimate 5-compartment breakdown from session telemetry.

    Since Claude Code doesn't expose per-category breakdowns, we estimate:
    - system_prompt: ~15-25% of input tokens (system instructions, CLAUDE.md, plugin hooks)
    - conversation: ~20-30% of input tokens (user messages + cached assistant turns)
    - tool_results: ~25-35% of input tokens (tool output)
    - file_contents: ~15-20% of input tokens (Read tool results, included as tool_results subset)
    - working_memory: remaining input tokens (current turn context)

    These are heuristic estimates refined by reading the session transcript when available.
    """
    cw = session_data.get("context_window", {})
    total_input = cw.get("total_input_tokens", 0)
    total_output = cw.get("total_output_tokens", 0)
    window_size = cw.get("context_window_size", 200000)
    used_pct = cw.get("used_percentage", 0)
    remaining_pct = cw.get("remaining_percentage", 100)

    current_usage = cw.get("current_usage", {})
    cache_creation = current_usage.get("cache_creation_input_tokens", 0)
    cache_read = current_usage.get("cache_read_input_tokens", 0)
    current_input = current_usage.get("input_tokens", 0)
    current_output = current_usage.get("output_tokens", 0)

    # Total tokens in the current context window
    tokens_used = int(window_size * used_pct / 100) if used_pct > 0 else (total_input + total_output)

    # Try to read transcript for more accurate breakdown
    transcript_path = session_data.get("transcript_path", "")
    transcript_breakdown = _analyze_transcript(transcript_path) if transcript_path else None

    if transcript_breakdown:
        # Use transcript-derived estimates
        system_tokens = transcript_breakdown["system"]
        conversation_tokens = transcript_breakdown["conversation"]
        tool_result_tokens = transcript_breakdown["tool_results"]
        file_content_tokens = transcript_breakdown["file_contents"]
        working_tokens = max(0, tokens_used - system_tokens - conversation_tokens - tool_result_tokens - file_content_tokens)
    else:
        # Heuristic estimation based on typical Claude Code sessions
        system_tokens = int(tokens_used * 0.20)       # System prompt + CLAUDE.md + hooks
        conversation_tokens = int(tokens_used * 0.25)  # User + assistant history
        tool_result_tokens = int(tokens_used * 0.30)   # Tool outputs
        file_content_tokens = int(tokens_used * 0.15)  # File reads (subset of tool_results)
        working_tokens = max(0, tokens_used - system_tokens - conversation_tokens - tool_result_tokens - file_content_tokens)

    return {
        "system_prompt": {
            "tokens": system_tokens,
            "percentage": round(system_tokens / window_size * 100, 2) if window_size > 0 else 0,
            "description": "System instructions, CLAUDE.md, plugin hook injections",
        },
        "conversation_history": {
            "tokens": conversation_tokens,
            "percentage": round(conversation_tokens / window_size * 100, 2) if window_size > 0 else 0,
            "description": "User messages and assistant responses from previous turns",
        },
        "tool_results": {
            "tokens": tool_result_tokens,
            "percentage": round(tool_result_tokens / window_size * 100, 2) if window_size > 0 else 0,
            "description": "Output from Bash, Grep, Read, and other tool calls",
        },
        "file_contents": {
            "tokens": file_content_tokens,
            "percentage": round(file_content_tokens / window_size * 100, 2) if window_size > 0 else 0,
            "description": "File content loaded via Read tool (subset of tool_results)",
        },
        "working_memory": {
            "tokens": working_tokens,
            "percentage": round(working_tokens / window_size * 100, 2) if window_size > 0 else 0,
            "description": "Current turn working set and response generation",
        },
    }


def _analyze_transcript(transcript_path):
    """Parse session transcript JSONL to get message-type token estimates."""
    try:
        path = Path(transcript_path)
        if not path.exists():
            return None

        system_chars = 0
        conversation_chars = 0
        tool_result_chars = 0
        file_content_chars = 0

        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue

                msg_type = entry.get("type", "")
                content = str(entry.get("message", entry.get("content", "")))
                chars = len(content)

                if msg_type == "system":
                    system_chars += chars
                elif msg_type in ("human", "assistant"):
                    conversation_chars += chars
                elif msg_type == "tool_result":
                    tool_name = entry.get("tool_name", "")
                    if tool_name == "Read":
                        file_content_chars += chars
                    else:
                        tool_result_chars += chars
                elif msg_type == "tool_use":
                    tool_result_chars += chars

        # Convert chars to approximate tokens (1 token ~ 4 chars)
        CHARS_PER_TOKEN = 4
        return {
            "system": system_chars // CHARS_PER_TOKEN,
            "conversation": conversation_chars // CHARS_PER_TOKEN,
            "tool_results": tool_result_chars // CHARS_PER_TOKEN,
            "file_contents": file_content_chars // CHARS_PER_TOKEN,
        }
    except Exception:
        return None


def determine_escalation_tier(remaining_pct, config):
    """Map remaining percentage to escalation tier."""
    # Dynamic compaction threshold
    compact_threshold = 16  # default fallback
    compaction_log = STATE_DIR / "compaction.log"
    if compaction_log.exists():
        try:
            lines = compaction_log.read_text().strip().split("\n")[-10:]
            values = []
            for line in lines:
                if "remaining=" in line:
                    val = int(line.split("remaining=")[1].split()[0])
                    if 0 < val < 100:
                        values.append(val)
            if values:
                compact_threshold = sum(values) // len(values)
        except Exception:
            pass

    distance = max(0, remaining_pct - compact_threshold)

    if distance <= config["level_4_distance"]:
        return {"tier": 4, "label": "CRITICAL", "distance_to_compaction": distance, "action": "Save state immediately, complete only current operation"}
    elif distance <= config["level_3_distance"]:
        return {"tier": 3, "label": "HIGH", "distance_to_compaction": distance, "action": "Save state, finish current operation, suggest new session"}
    elif distance <= config["level_2_distance"]:
        return {"tier": 2, "label": "MEDIUM", "distance_to_compaction": distance, "action": "Save state, avoid chaining steps, summarize outputs"}
    elif distance <= config["level_1_distance"]:
        return {"tier": 1, "label": "LOW", "distance_to_compaction": distance, "action": "Optimize usage, delegate to subagents, use offset/limit"}
    else:
        return {"tier": 0, "label": "NORMAL", "distance_to_compaction": distance, "action": "Operating normally"}


def write_telemetry(session_id, budget_data):
    """Write telemetry event to shared file for conductor consumption."""
    telemetry_dir = STATE_DIR / "telemetry"
    telemetry_dir.mkdir(exist_ok=True)

    event = {
        "type": "context_budget",
        "session_id": session_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "data": {
            "used_percentage": budget_data["summary"]["used_percentage"],
            "remaining_percentage": budget_data["summary"]["remaining_percentage"],
            "escalation_tier": budget_data["escalation"]["tier"],
            "tokens_used": budget_data["summary"]["tokens_used"],
            "window_size": budget_data["summary"]["window_size"],
        },
    }

    # session_id originates from a tool argument or a session record, so it is
    # untrusted here: without this check a crafted id wrote JSON to an
    # arbitrary path.
    try:
        event_file = safe_child(telemetry_dir, session_id, ".json")
    except ValueError:
        return
    with open(event_file, "w") as f:
        json.dump(event, f, indent=2)


def handle_context_budget(params):
    """Main handler for the context_budget tool."""
    config = load_config()
    session_id = params.get("session_id")

    if session_id:
        # Untrusted tool argument: "../.." escaped SESSIONS_DIR and an
        # absolute path replaced it outright, so any readable JSON file could
        # be pulled back to the caller.
        try:
            session_dir = safe_child(SESSIONS_DIR, session_id)
        except ValueError:
            return {"error": "Invalid session_id"}
    else:
        session_dir = get_latest_session()

    if not session_dir:
        return {"error": "No active session found", "sessions_dir": str(SESSIONS_DIR)}

    session_data = read_session_data(session_dir)
    if not session_data:
        return {"error": f"Cannot read session data from {session_dir}"}

    cw = session_data.get("context_window", {})
    model = session_data.get("model", {})
    cost = session_data.get("cost", {})

    remaining_pct = cw.get("remaining_percentage", 100)
    used_pct = cw.get("used_percentage", 0)
    window_size = cw.get("context_window_size", 200000)
    tokens_used = int(window_size * used_pct / 100) if used_pct > 0 else 0

    compartments = estimate_compartments(session_data)
    escalation = determine_escalation_tier(remaining_pct, config)

    result = {
        "session_id": session_data.get("session_id", "unknown"),
        "model": {
            "id": model.get("id", "unknown"),
            "display_name": model.get("display_name", "unknown"),
        },
        "summary": {
            "window_size": window_size,
            "tokens_used": tokens_used,
            "tokens_remaining": window_size - tokens_used,
            "used_percentage": used_pct,
            "remaining_percentage": remaining_pct,
        },
        "compartments": compartments,
        "escalation": escalation,
        "cost": {
            "total_cost_usd": cost.get("total_cost_usd", 0),
            "session_duration_ms": cost.get("total_duration_ms", 0),
        },
        "thresholds": config,
        "estimation_method": "transcript_analysis" if session_data.get("transcript_path") and Path(session_data["transcript_path"]).exists() else "heuristic",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

    # Write telemetry for conductor
    write_telemetry(result["session_id"], result)

    return result


def main():
    """MCP stdio server main loop.

    Reads newline-delimited JSON-RPC, one message per line, which is what the
    MCP stdio transport specifies and what clients actually send.
    """
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue

        # Tolerate a client that still sends LSP-style framing: skip the
        # header and its blank line, then read the declared body.
        if line.startswith("Content-Length:"):
            try:
                content_length = int(line.split(":", 1)[1].strip())
            except (IndexError, ValueError):
                continue
            sys.stdin.readline()  # blank separator
            body = sys.stdin.read(content_length)
        else:
            body = line

        try:
            request = json.loads(body)
        except json.JSONDecodeError:
            continue
        if not isinstance(request, dict):
            continue

        method = request.get("method", "")
        id_ = request.get("id")

        if method == "initialize":
            send_response(id_, {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "context-guard-mcp", "version": "3.1.0"},
            })
        elif method == "notifications/initialized":
            pass  # No response needed
        elif method == "tools/list":
            send_response(id_, {
                "tools": [{
                    "name": "context_budget",
                    "description": "Returns context window usage with 5-compartment breakdown (system_prompt, conversation_history, tool_results, file_contents, working_memory), escalation tier, and telemetry. Use to monitor context consumption and plan session strategy.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "session_id": {
                                "type": "string",
                                "description": "Optional session ID. If omitted, uses the most recent active session.",
                            },
                        },
                    },
                }],
            })
        elif method == "tools/call":
            tool_name = request.get("params", {}).get("name", "")
            arguments = request.get("params", {}).get("arguments", {})
            if tool_name == "context_budget":
                try:
                    result = handle_context_budget(arguments)
                    send_response(id_, {
                        "content": [{
                            "type": "text",
                            "text": json.dumps(result, indent=2),
                        }],
                    })
                except Exception as e:
                    send_response(id_, {
                        "content": [{"type": "text", "text": json.dumps({"error": str(e)})}],
                        "isError": True,
                    })
            else:
                send_error(id_, -32601, f"Unknown tool: {tool_name}")
        elif method == "ping":
            send_response(id_, {})
        else:
            if id_ is not None:
                send_error(id_, -32601, f"Method not found: {method}")


if __name__ == "__main__":
    main()
