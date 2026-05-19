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


# ----------------------------------------------------------------------------
# Mock management — writes/reads the same file as the macOS UI + iOS reader
# ----------------------------------------------------------------------------

import uuid
from datetime import datetime, timezone


def _bundle_id() -> str | None:
    """Resolve the target app's bundle id. Env var wins; otherwise, infer from
    the most recent network entry's tab metadata; otherwise nil."""
    env = os.environ.get("SIM_CONSOLE_BUNDLE_ID")
    if env:
        return env
    events = _load_events()
    for e in reversed(events):
        if e.get("kind") == "network" and e.get("tab"):
            # We don't have bundle id in the event; the caller must set the env var.
            break
    return None


def _mocks_path(bundle_id: str | None = None) -> Path:
    """Path to mocks-<bundle-id>.json. Falls back to scanning for the most
    recently modified mocks-*.json in ~/.sim-console/."""
    override = os.environ.get("MOCKS_PATH")
    if override:
        return Path(override)
    bid = bundle_id or _bundle_id()
    base = Path.home() / ".sim-console"
    if bid:
        return base / f"mocks-{bid}.json"
    # Best-effort discovery for tooling without env var: pick most-recent mocks file.
    if base.exists():
        candidates = sorted(base.glob("mocks-*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
        if candidates:
            return candidates[0]
    return base / "mocks-unknown.json"


def _load_mocks(path: Path | None = None) -> dict[str, Any]:
    p = path or _mocks_path()
    if not p.exists():
        return {"version": 1, "mocks": []}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"version": 1, "mocks": []}


def _save_mocks(file: dict[str, Any], path: Path | None = None) -> Path:
    """Atomic write: temp file + os.replace, so the iOS reader never sees half a file."""
    p = path or _mocks_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(file, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(tmp, p)
    return p


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@mcp.tool()
def list_mocks() -> list[dict[str, Any]]:
    """List all mocks currently configured for the active bundle id."""
    return _load_mocks().get("mocks", [])


def _normalize_body(body: Any) -> str | None:
    """Accept body as either a plain string, a dict, or a list. Always store
    as a string. FastMCP / Pydantic auto-parse JSON-looking strings into
    structured types during validation, so accepting both shapes here lets
    agents pass either form without surprise."""
    if body is None: return None
    if isinstance(body, str): return body
    return json.dumps(body, separators=(",", ":"))


@mcp.tool()
def add_mock(
    method: str,
    url: str,
    status: int,
    headers: dict[str, str] | None = None,
    body: str | dict[str, Any] | list[Any] | None = None,
    delay_ms: int = 0,
    enabled: bool = True,
    body_contains: str | None = None,
) -> dict[str, Any]:
    """Add a new mock rule. Subsequent requests matching method + URL get the
    synthesized response instead of hitting the network.

    Args:
        method: HTTP method (GET, POST, etc.). Case-insensitive at match time.
        url: Full URL string. Exact match.
        status: HTTP status code (100-599).
        headers: Response headers. Defaults to {"Content-Type": "application/json"}.
        body: Response body. Accepts a raw string OR a JSON-serializable
              dict/list (auto-converted to a JSON string). None means no body.
        delay_ms: Artificial delay before delivering the response (useful for testing loading states).
        enabled: When false, the mock is persisted but not applied.
        body_contains: Optional substring the request body must contain for the mock to apply.
    """
    file = _load_mocks()
    mock = {
        "id": str(uuid.uuid4()),
        "match": {
            "method": method.upper(),
            "url": url,
            "body_contains": body_contains,
        },
        "response": {
            "status": status,
            "headers": headers or {"Content-Type": "application/json"},
            "body": _normalize_body(body),
        },
        "delay_ms": delay_ms,
        "enabled": enabled,
        "created_at": _now_iso(),
    }
    file["mocks"].append(mock)
    p = _save_mocks(file)
    return {"ok": True, "mock": mock, "file": str(p)}


@mcp.tool()
def update_mock(
    id: str,
    status: int | None = None,
    headers: dict[str, str] | None = None,
    body: str | dict[str, Any] | list[Any] | None = None,
    delay_ms: int | None = None,
    enabled: bool | None = None,
) -> dict[str, Any]:
    """Partial-update an existing mock by id. Only non-None args overwrite."""
    file = _load_mocks()
    for mock in file["mocks"]:
        if mock.get("id") == id:
            if status is not None: mock["response"]["status"] = status
            if headers is not None: mock["response"]["headers"] = headers
            if body is not None: mock["response"]["body"] = _normalize_body(body)
            if delay_ms is not None: mock["delay_ms"] = delay_ms
            if enabled is not None: mock["enabled"] = enabled
            _save_mocks(file)
            return {"ok": True, "mock": mock}
    return {"ok": False, "reason": f"no mock with id {id}"}


@mcp.tool()
def remove_mock(id: str) -> dict[str, Any]:
    """Delete a mock by id."""
    file = _load_mocks()
    before = len(file["mocks"])
    file["mocks"] = [m for m in file["mocks"] if m.get("id") != id]
    if len(file["mocks"]) == before:
        return {"ok": False, "reason": f"no mock with id {id}"}
    _save_mocks(file)
    return {"ok": True, "removed": id}


@mcp.tool()
def clear_mocks() -> dict[str, Any]:
    """Remove all mocks for the active bundle id."""
    file = _load_mocks()
    n = len(file["mocks"])
    file["mocks"] = []
    p = _save_mocks(file)
    return {"ok": True, "cleared": n, "file": str(p)}


@mcp.tool()
def mock_last_request(
    status: int,
    body: str | dict[str, Any] | list[Any] | None = None,
    headers: dict[str, str] | None = None,
    delay_ms: int = 0,
) -> dict[str, Any]:
    """Convenience: mock the most recent network request observed in the
    export file. Saves you from having to look up the URL by hand —
    "mock the last login call as a 401" is one MCP call.
    """
    rows = _latest_network_rows(_load_events())
    if not rows:
        return {"ok": False, "reason": "no network requests captured yet"}
    rows.sort(key=lambda r: r.get("ts", 0), reverse=True)
    last = rows[0]
    method = last.get("method", "GET")
    url = last.get("url", "")
    if not url:
        return {"ok": False, "reason": "most recent request has no URL"}
    return add_mock(
        method=method,
        url=url,
        status=status,
        headers=headers,
        body=body,
        delay_ms=delay_ms,
    )


# ----------------------------------------------------------------------------
# Performance metrics — reads metric.* events from the export file
# ----------------------------------------------------------------------------


def _metric_events(kinds: set[str]) -> list[dict[str, Any]]:
    return [e for e in _load_events() if e.get("kind") in kinds]


@mcp.tool()
def current_metrics() -> dict[str, Any]:
    """Snapshot: latest value of each system sample, latest gauges, current
    counter totals, and latest hang count. The fastest "is the app healthy"
    check — use this first when triaging perf issues."""
    samples = _metric_events({"metric.sample"})
    latest_samples: dict[str, dict[str, Any]] = {}
    for s in samples:
        name = s.get("name")
        if not name: continue
        prev = latest_samples.get(name)
        if not prev or s.get("ts", 0) > prev.get("ts", 0):
            latest_samples[name] = s

    gauges = _metric_events({"metric.gauge"})
    latest_gauges: dict[str, dict[str, Any]] = {}
    for g in gauges:
        n = g.get("name")
        if not n: continue
        prev = latest_gauges.get(n)
        if not prev or g.get("ts", 0) > prev.get("ts", 0):
            latest_gauges[n] = g

    counters = _metric_events({"metric.counter"})
    latest_counters: dict[str, dict[str, Any]] = {}
    for c in counters:
        n = c.get("name")
        if not n: continue
        prev = latest_counters.get(n)
        if not prev or c.get("ts", 0) > prev.get("ts", 0):
            latest_counters[n] = c

    hangs = _metric_events({"metric.hang"})
    longest = max((h.get("duration_ms", 0) for h in hangs), default=0)

    return {
        "samples": {n: {"value": s.get("value"),
                        "ts": s.get("ts"),
                        "fields": s.get("fields", {})}
                    for n, s in latest_samples.items()},
        "gauges": {n: g.get("value") for n, g in latest_gauges.items()},
        "counters": {n: c.get("total") for n, c in latest_counters.items()},
        "hangs": {"count": len(hangs), "longest_ms": longest},
    }


@mcp.tool()
def launch_timeline() -> list[dict[str, Any]]:
    """Ordered list of launch milestones (e.g. scene_active, first_screen_visible)
    with `ms_since_launch` deltas. Use to diagnose slow cold starts — where's
    the gap between two milestones?"""
    milestones = _metric_events({"metric.milestone"})
    milestones.sort(key=lambda m: m.get("ms_since_launch", 0))
    return [{"name": m.get("name"),
             "ms_since_launch": m.get("ms_since_launch"),
             "ts": m.get("ts"),
             "fields": m.get("fields", {})}
            for m in milestones]


@mcp.tool()
def recent_signposts(
    name: str = "",
    since_seconds: int = 60,
    limit: int = 50,
) -> list[dict[str, Any]]:
    """Custom timed regions emitted via SimConsole.metric.signpost(...) or
    .measure(_:body:). Filter by exact name (empty = all)."""
    cutoff = time.time() - since_seconds
    sps = [e for e in _metric_events({"metric.signpost"})
           if e.get("ts", 0) >= cutoff
           and (not name or e.get("name") == name)]
    sps.sort(key=lambda s: s.get("ts", 0), reverse=True)
    return sps[:limit]


@mcp.tool()
def recent_hangs(since_seconds: int = 300, limit: int = 20) -> list[dict[str, Any]]:
    """Main-thread hangs (>250ms blocks) in the last N seconds, newest first."""
    cutoff = time.time() - since_seconds
    hs = [e for e in _metric_events({"metric.hang"}) if e.get("ts", 0) >= cutoff]
    hs.sort(key=lambda h: h.get("ts", 0), reverse=True)
    return hs[:limit]


@mcp.tool()
def metric_history(name: str, seconds: int = 60) -> list[dict[str, Any]]:
    """Time series for one sample/gauge by name (e.g. 'memory.resident_mb',
    'fps.avg_1s'). Returns [(ts, value)] sorted oldest-first — good for
    plotting or spotting trends like steady memory growth."""
    cutoff = time.time() - seconds
    events = [e for e in _metric_events({"metric.sample", "metric.gauge"})
              if e.get("name") == name and e.get("ts", 0) >= cutoff]
    events.sort(key=lambda e: e.get("ts", 0))
    return [{"ts": e.get("ts"), "value": e.get("value")} for e in events]


if __name__ == "__main__":
    mcp.run()
