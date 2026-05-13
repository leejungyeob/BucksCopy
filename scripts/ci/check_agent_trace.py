#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path


ALL_AGENTS = {
    "bucks-copy-l1-planner-orchestrator",
    "bucks-copy-l2-architect",
    "bucks-copy-l2-code-reviewer",
    "bucks-copy-l2-security",
    "bucks-copy-l2-tdd-guide",
    "bucks-copy-l3-build-fixer",
    "bucks-copy-l3-doc-writer",
    "bucks-copy-l3-migration",
}

ALL_SKILLS = ALL_AGENTS | {
    "bucks-copy-macos-structure",
    "bucks-copy-bitget-integration",
    "bucks-copy-trading-engine",
}

WRITE_CAPABLE_AGENTS = {
    "bucks-copy-l3-build-fixer",
    "bucks-copy-l3-doc-writer",
    "bucks-copy-l3-migration",
}

REQUIRED_FIELDS = {
    "version",
    "task_id",
    "request_summary",
    "direct_handle",
    "used_skills",
    "route",
    "spawned_agents",
    "fallback_reason",
    "write_owner",
    "checks",
    "max_threads",
}


@dataclass(frozen=True)
class Finding:
    path: Path
    message: str


def is_non_empty_string(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def is_string_list(value: object) -> bool:
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as file:
        return json.load(file)


def check_trace(path: Path) -> list[Finding]:
    try:
        payload = load_json(path)
    except json.JSONDecodeError as error:
        return [Finding(path, f"invalid JSON: {error}")]

    findings: list[Finding] = []
    missing = sorted(REQUIRED_FIELDS - set(payload))
    for field in missing:
        findings.append(Finding(path, f"missing required field: {field}"))
    if missing:
        return findings

    if payload["version"] != 1:
        findings.append(Finding(path, "version must be 1"))
    if not is_non_empty_string(payload["task_id"]):
        findings.append(Finding(path, "task_id must be a non-empty string"))
    if not is_non_empty_string(payload["request_summary"]):
        findings.append(Finding(path, "request_summary must be a non-empty string"))
    if not isinstance(payload["direct_handle"], bool):
        findings.append(Finding(path, "direct_handle must be boolean"))
    if payload["max_threads"] != 3:
        findings.append(Finding(path, "max_threads must be 3"))

    for field in ("used_skills", "route", "spawned_agents", "checks"):
        if not is_string_list(payload[field]):
            findings.append(Finding(path, f"{field} must be a list of strings"))

    if findings:
        return findings

    used_skills = payload["used_skills"]
    route = payload["route"]
    spawned_agents = payload["spawned_agents"]
    direct_handle = payload["direct_handle"]
    write_owner = payload["write_owner"]
    fallback_reason = payload["fallback_reason"]

    for skill in sorted(set(used_skills) - ALL_SKILLS):
        findings.append(Finding(path, f"unknown used skill: {skill}"))

    for agent in sorted(set(route) - ALL_AGENTS):
        findings.append(Finding(path, f"unknown route agent: {agent}"))

    for agent in sorted(set(spawned_agents) - ALL_AGENTS):
        findings.append(Finding(path, f"unknown spawned agent: {agent}"))

    for agent in spawned_agents:
        if agent not in route:
            findings.append(Finding(path, f"spawned agent must also be in route: {agent}"))

    if direct_handle:
        if route:
            findings.append(Finding(path, "direct_handle trace must not have route agents"))
        if spawned_agents:
            findings.append(Finding(path, "direct_handle trace must not have spawned agents"))
        if write_owner is not None:
            findings.append(Finding(path, "direct_handle trace must not have write_owner"))
    elif not route:
        findings.append(Finding(path, "orchestrated trace must include route"))

    if write_owner is not None:
        if write_owner not in WRITE_CAPABLE_AGENTS:
            findings.append(Finding(path, f"write_owner is not write-capable: {write_owner}"))
        if write_owner not in route:
            findings.append(Finding(path, f"write_owner must be included in route: {write_owner}"))

    write_agents = [agent for agent in route if agent in WRITE_CAPABLE_AGENTS]
    if write_agents and write_owner not in write_agents:
        findings.append(Finding(path, f"write-capable route agents require write_owner: {write_agents}"))

    if fallback_reason is not None and not is_non_empty_string(fallback_reason):
        findings.append(Finding(path, "fallback_reason must be null or a non-empty string"))
    if fallback_reason is not None and spawned_agents:
        findings.append(Finding(path, "fallback_reason should be null when spawned_agents is not empty"))
    if not direct_handle and not spawned_agents and fallback_reason is None:
        findings.append(Finding(path, "orchestrated trace without spawned agents must include fallback_reason"))
    if not direct_handle and not payload["checks"]:
        findings.append(Finding(path, "orchestrated trace should include at least one check or explicit skipped check"))

    return findings


def collect_paths(paths: list[Path]) -> list[Path]:
    result: list[Path] = []
    for path in paths:
        if path.is_dir():
            result.extend(sorted(path.glob("*.json")))
        else:
            result.append(path)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate BucksCopy agent run trace JSON files.")
    parser.add_argument("paths", nargs="*", type=Path, default=[Path(__file__).resolve().parent / "fixtures/agent-trace"])
    args = parser.parse_args()

    trace_paths = collect_paths([path.resolve() for path in args.paths])
    if not trace_paths:
        print("agent trace check failed:")
        print("- no trace JSON files found")
        return 1

    findings: list[Finding] = []
    for path in trace_paths:
        findings.extend(check_trace(path))

    if findings:
        print("agent trace check failed:")
        for finding in findings:
            print(f"- {finding.path}: {finding.message}")
        return 1

    print("agent trace check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
