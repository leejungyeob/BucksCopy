#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path


L1 = "bucks-copy-l1-planner-orchestrator"
ARCHITECT = "bucks-copy-l2-architect"
CODE_REVIEWER = "bucks-copy-l2-code-reviewer"
SECURITY = "bucks-copy-l2-security"
TDD_GUIDE = "bucks-copy-l2-tdd-guide"
BUILD_FIXER = "bucks-copy-l3-build-fixer"
DOC_WRITER = "bucks-copy-l3-doc-writer"
MIGRATION = "bucks-copy-l3-migration"

WRITE_CAPABLE_AGENTS = {BUILD_FIXER, DOC_WRITER, MIGRATION}


@dataclass(frozen=True)
class Route:
    direct_handle: bool
    agents: list[str]
    write_owner: str | None
    agent_creation: str


@dataclass(frozen=True)
class Finding:
    fixture: Path
    message: str


def contains_any(text: str, terms: list[str]) -> bool:
    normalized = text.casefold()
    return any(term.casefold() in normalized for term in terms)


def unique(items: list[str]) -> list[str]:
    result: list[str] = []
    for item in items:
        if item not in result:
            result.append(item)
    return result


def classify(prompt: str) -> Route:
    simple_direct = contains_any(prompt, ["오타", "typo", "짧은 문서", "단순 질의", "설명만"])
    build = contains_any(prompt, ["빌드", "build", "generate", "tuist", "xcode", "import error", "컴파일", "compile"])
    migration = contains_any(prompt, ["migration", "마이그레이션", "레이어", "layer", "옮겨", "이동", "module boundary"])
    docs = contains_any(prompt, ["문서", "docs", "AGENTS.md", "README", "skill", "스킬", "harness", "fixture", "canonical"]) and not simple_direct
    bitget = contains_any(prompt, ["bitget", "websocket", "rest", "socket", "api", "dto", "rate-limit", "reconnect", "usdt-m", "usdt-futures"])
    credential = contains_any(prompt, ["api key", "secret", "passphrase", "credential", "keychain", "토큰", "인증", "시크릿"])
    storage = contains_any(prompt, ["local db", "sqlite", "market history", "gap fill", "히스토리", "로컬 db", "로컬 데이터", "저장소"])
    trading = contains_any(prompt, ["candle", "봉", "strategy", "전략", "자동매매", "paper", "live", "order", "주문", "trading engine", "watchlist"])
    test = contains_any(prompt, ["test", "테스트", "acceptance", "edge case", "검증", "tdd"])
    review = contains_any(prompt, ["review", "리뷰", "회귀", "regression", "버그", "bug"])

    if simple_direct and not any([build, migration, docs, bitget, credential, trading, test, review]):
        return Route(True, [], None, "none")

    agents: list[str] = []
    write_owner: str | None = None

    if build:
        agents.extend([L1, BUILD_FIXER, CODE_REVIEWER])
        write_owner = BUILD_FIXER

    if migration:
        agents.extend([L1, ARCHITECT, MIGRATION, BUILD_FIXER, CODE_REVIEWER])
        write_owner = write_owner or MIGRATION

    if docs:
        agents.extend([L1, DOC_WRITER, CODE_REVIEWER])
        write_owner = write_owner or DOC_WRITER

    if bitget:
        agents.extend([L1, ARCHITECT, SECURITY, TDD_GUIDE, CODE_REVIEWER])

    if credential:
        agents.extend([L1, ARCHITECT, SECURITY, TDD_GUIDE, CODE_REVIEWER])

    if storage:
        agents.extend([L1, ARCHITECT, SECURITY, TDD_GUIDE, CODE_REVIEWER])

    if trading:
        agents.extend([L1, ARCHITECT, TDD_GUIDE, CODE_REVIEWER])
        if contains_any(prompt, ["live", "실거래"]):
            agents.insert(agents.index(TDD_GUIDE), SECURITY) if SECURITY not in agents else None
            agents.append(DOC_WRITER)

    if test:
        agents.extend([L1, TDD_GUIDE])

    if review:
        agents.extend([L1, CODE_REVIEWER])

    agents = unique(agents)
    if not agents:
        return Route(True, [], None, "none")

    if write_owner is None:
        write_agents = [agent for agent in agents if agent in WRITE_CAPABLE_AGENTS]
        write_owner = write_agents[0] if len(write_agents) == 1 else None

    return Route(False, agents, write_owner, "runtime-permitting")


def load_fixture(path: Path) -> dict:
    with path.open(encoding="utf-8") as file:
        return json.load(file)


def check_fixture(path: Path) -> list[Finding]:
    fixture = load_fixture(path)
    route = classify(fixture["prompt"])
    findings: list[Finding] = []

    expected_direct_handle = fixture.get("expected_direct_handle")
    if expected_direct_handle is not None and route.direct_handle != expected_direct_handle:
        findings.append(Finding(path, f"expected direct_handle={expected_direct_handle}, got {route.direct_handle}"))

    expected_agents = fixture.get("expected_agents")
    if expected_agents is not None and route.agents != expected_agents:
        findings.append(Finding(path, f"expected agents={expected_agents}, got {route.agents}"))

    expected_write_owner = fixture.get("expected_write_owner")
    if expected_write_owner is not None and route.write_owner != expected_write_owner:
        findings.append(Finding(path, f"expected write_owner={expected_write_owner}, got {route.write_owner}"))

    expected_agent_creation = fixture.get("expected_agent_creation")
    if expected_agent_creation is not None and route.agent_creation != expected_agent_creation:
        findings.append(Finding(path, f"expected agent_creation={expected_agent_creation}, got {route.agent_creation}"))

    for forbidden_agent in fixture.get("forbidden_agents", []):
        if forbidden_agent in route.agents:
            findings.append(Finding(path, f"forbidden agent was routed: {forbidden_agent}"))

    write_agents = [agent for agent in route.agents if agent in WRITE_CAPABLE_AGENTS]
    if write_agents and route.write_owner not in write_agents:
        findings.append(Finding(path, f"route has write-capable agents but no valid write owner: {write_agents}"))

    return findings


def run(fixtures_dir: Path) -> list[Finding]:
    fixture_paths = sorted(fixtures_dir.glob("*.json"))
    if not fixture_paths:
        return [Finding(fixtures_dir, "no routing fixtures found")]

    findings: list[Finding] = []
    for fixture_path in fixture_paths:
        findings.extend(check_fixture(fixture_path))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description="Check BucksCopy deterministic agent routing fixtures.")
    parser.add_argument("--fixtures", type=Path, default=Path(__file__).resolve().parent / "fixtures/agent-routing")
    args = parser.parse_args()

    findings = run(args.fixtures.resolve())
    if findings:
        print("agent routing check failed:")
        for finding in findings:
            print(f"- {finding.fixture}: {finding.message}")
        return 1

    print("agent routing check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
