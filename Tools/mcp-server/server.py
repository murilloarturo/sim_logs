#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp[cli]>=1.0"]
# ///
"""
sim_logs MCP server.

Reads the NDJSON export file written by `sim-console --export-to <path>` and
exposes query tools so an LLM agent (Claude, etc.) can inspect what's happening
inside an iOS app running on a simulator — network requests, analytics events,
log entries — without owning the rendering layer.

The shebang uses `uv` to resolve `mcp[cli]` on demand into an isolated venv, so
no user-side `pip install` is required. Run it directly:

    ./server.py        # via stdio (the MCP transport Claude Code uses)

Or wire into Claude Code's MCP config (see Tools/install-mcp.sh).

The export file path comes from $SIM_CONSOLE_EXPORT, defaulting to
~/.sim-console/events.jsonl.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP


DEFAULT_EXPORT_PATH = Path.home() / ".sim-console" / "events.jsonl"

mcp = FastMCP("sim_logs")


def _export_path() -> Path:
    p = os.environ.get("SIM_CONSOLE_EXPORT")
    return Path(p) if p else DEFAULT_EXPORT_PATH


def _load_events() -> list[dict[str, Any]]:
    """Read every NDJSON line from the export file. Robust to in-flight writes."""
    path = _export_path()
    if not path.exists():
        return []
    events: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                # In-flight writes may produce a partial last line; ignore.
                continue
    return events


def _latest_network_rows(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Network rows are re-emitted on every state change. Dedup by id; keep
    the last (most complete) version."""
    by_id: dict[str, dict[str, Any]] = {}
    for e in events:
        if e.get("kind") == "network" and "id" in e:
            by_id[e["id"]] = e
    return list(by_id.values())


def _matches(event: dict[str, Any], needle: str, *fields: str) -> bool:
    if not needle:
        return True
    n = needle.lower()
    for f in fields:
        v = event.get(f)
        if isinstance(v, str) and n in v.lower():
            return True
    return False


# ----------------------------------------------------------------------------
# Tools
# ----------------------------------------------------------------------------


@mcp.tool()
def list_recent_requests(
    filter: str = "",
    status_min: int | None = None,
    status_max: int | None = None,
    method: str = "",
    limit: int = 20,
) -> list[dict[str, Any]]:
    """List recent network requests captured by sim-console, newest first.

    Args:
        filter: case-insensitive substring matched against URL.
        status_min: only include responses with status >= this (e.g. 400 for errors).
        status_max: only include responses with status <= this.
        method: filter by HTTP method (case-insensitive exact match).
        limit: max rows to return.
    """
    rows = _latest_network_rows(_load_events())

    if filter:
        rows = [r for r in rows if _matches(r, filter, "url", "method")]
    if method:
        m = method.upper()
        rows = [r for r in rows if r.get("method", "").upper() == m]
    if status_min is not None:
        rows = [r for r in rows if isinstance(r.get("status"), int) and r["status"] >= status_min]
    if status_max is not None:
        rows = [r for r in rows if isinstance(r.get("status"), int) and r["status"] <= status_max]

    rows.sort(key=lambda r: r.get("ts", 0), reverse=True)
    # Trim oversized body fields for the list view — return summary only.
    trimmed = []
    for r in rows[:limit]:
        copy = dict(r)
        for k in ("request_body", "response_body"):
            v = copy.get(k)
            if isinstance(v, str) and len(v) > 200:
                copy[k] = v[:200] + f"…[+{len(v) - 200} chars — use get_request(id) for full]"
        trimmed.append(copy)
    return trimmed


@mcp.tool()
def get_request(id: str) -> dict[str, Any] | None:
    """Return the full record for one network request, including request and
    response headers and full bodies. Use the `id` returned by `list_recent_requests`."""
    for row in _latest_network_rows(_load_events()):
        if row.get("id") == id:
            return row
    return None


@mcp.tool()
def list_recent_analytics(
    filter: str = "",
    kinds: list[str] | None = None,
    since_seconds: int = 600,
    limit: int = 50,
) -> list[dict[str, Any]]:
    """List recent analytics + screen events from the SimConsole SDK.

    Args:
        filter: case-insensitive substring matched against event name + screen name.
        kinds: which kinds to include; pass e.g. ["analytics"] for only event() calls
               or ["screen"] for only screen views. Defaults to both.
        since_seconds: how far back in time to scan.
        limit: max rows to return, newest first.
    """
    want = set(kinds) if kinds else {"analytics", "screen"}
    cutoff = time.time() - since_seconds
    rows = [
        e for e in _load_events()
        if e.get("kind") in want and e.get("ts", 0) >= cutoff
        and _matches(e, filter, "event", "screen")
    ]
    rows.sort(key=lambda e: e.get("ts", 0), reverse=True)
    return rows[:limit]


@mcp.tool()
def list_recent_logs(
    filter: str = "",
    levels: list[str] | None = None,
    since_seconds: int = 600,
    limit: int = 50,
) -> list[dict[str, Any]]:
    """List recent structured log events emitted via SimConsole.log(...).

    These travel as `text` events from the Logs tab; the parsed JSON payload
    lives under `.payload`. This tool returns the structured payload form for
    convenience.

    Args:
        filter: case-insensitive substring matched against message + raw line.
        levels: filter to a subset of {"debug", "info", "warn", "error"}.
        since_seconds: how far back in time to scan.
        limit: max rows to return, newest first.
    """
    cutoff = time.time() - since_seconds
    out: list[dict[str, Any]] = []
    for e in _load_events():
        if e.get("kind") != "text":
            continue
        if e.get("tab") not in {"Logs", "Errors"}:
            continue
        if e.get("ts", 0) < cutoff:
            continue
        payload = e.get("payload") or {}
        if levels and payload.get("level") not in levels:
            continue
        haystack_line = e.get("line", "")
        haystack_msg = payload.get("msg", "")
        if filter and not (
            filter.lower() in haystack_line.lower() or filter.lower() in haystack_msg.lower()
        ):
            continue
        out.append({
            "ts": e.get("ts"),
            "tab": e.get("tab"),
            "level": payload.get("level"),
            "msg": payload.get("msg"),
            "fields": payload.get("fields") or {},
            "raw": e.get("line"),
        })
    out.sort(key=lambda r: r.get("ts", 0), reverse=True)
    return out[:limit]


@mcp.tool()
def stats() -> dict[str, Any]:
    """Counts and timing summary for everything currently in the export file."""
    events = _load_events()
    counts: dict[str, int] = {}
    for e in events:
        kind = e.get("kind", "unknown")
        counts[kind] = counts.get(kind, 0) + 1

    ts_values = [e["ts"] for e in events if isinstance(e.get("ts"), (int, float))]
    earliest = min(ts_values) if ts_values else None
    latest = max(ts_values) if ts_values else None

    network_rows = _latest_network_rows(events)
    network_by_status: dict[str, int] = {}
    for r in network_rows:
        s = r.get("status")
        bucket = (
            "no_response" if s is None
            else f"{s // 100}xx"
        )
        network_by_status[bucket] = network_by_status.get(bucket, 0) + 1

    return {
        "export_file": str(_export_path()),
        "total_events": len(events),
        "by_kind": counts,
        "unique_network_requests": len(network_rows),
        "network_by_status_bucket": network_by_status,
        "earliest_ts": earliest,
        "latest_ts": latest,
        "span_seconds": (latest - earliest) if (earliest and latest) else None,
    }


@mcp.tool()
def clear() -> dict[str, Any]:
    """Truncate the export file. Useful between test scenarios so subsequent
    queries only see fresh activity. The console keeps running; the file just
    starts over."""
    path = _export_path()
    if path.exists():
        path.write_text("")
        return {"ok": True, "cleared": str(path)}
    return {"ok": False, "reason": f"export file not found at {path}"}


if __name__ == "__main__":
    mcp.run()
