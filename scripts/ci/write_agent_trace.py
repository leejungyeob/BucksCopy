#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

from check_agent_trace import check_trace


def parse_optional_string(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = value.strip()
    if not stripped or stripped.lower() == "null":
        return None
    return stripped


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Write a BucksCopy agent run trace JSON file.")
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--request-summary", required=True)
    parser.add_argument("--direct-handle", action="store_true")
    parser.add_argument("--used-skill", action="append", default=[])
    parser.add_argument("--route-agent", action="append", default=[])
    parser.add_argument("--spawned-agent", action="append", default=[])
    parser.add_argument("--fallback-reason", default=None)
    parser.add_argument("--write-owner", default=None)
    parser.add_argument("--check", action="append", default=[])
    parser.add_argument("--max-threads", type=int, default=3)
    parser.add_argument("--output-dir", type=Path, default=Path(".codex/runs"))
    parser.add_argument("--date", default=datetime.now().strftime("%Y-%m-%d"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    trace_root = args.output_dir / args.date
    trace_root.mkdir(parents=True, exist_ok=True)
    trace_path = trace_root / f"{args.task_id}.json"

    payload = {
        "version": 1,
        "task_id": args.task_id,
        "request_summary": args.request_summary,
        "direct_handle": args.direct_handle,
        "used_skills": args.used_skill,
        "route": [] if args.direct_handle else args.route_agent,
        "spawned_agents": [] if args.direct_handle else args.spawned_agent,
        "fallback_reason": None if args.direct_handle else parse_optional_string(args.fallback_reason),
        "write_owner": None if args.direct_handle else parse_optional_string(args.write_owner),
        "checks": args.check,
        "max_threads": args.max_threads,
    }

    trace_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    findings = check_trace(trace_path)
    if findings:
        trace_path.unlink(missing_ok=True)
        print("agent trace write failed:")
        for finding in findings:
            print(f"- {finding.path}: {finding.message}")
        return 1

    print(trace_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
