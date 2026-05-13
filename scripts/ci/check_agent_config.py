#!/usr/bin/env python3

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path


REQUIRED_AGENTS = {
    "bucks-copy-l1-planner-orchestrator": "read-only",
    "bucks-copy-l2-architect": "read-only",
    "bucks-copy-l2-code-reviewer": "read-only",
    "bucks-copy-l2-security": "read-only",
    "bucks-copy-l2-tdd-guide": "read-only",
    "bucks-copy-l3-build-fixer": "workspace-write",
    "bucks-copy-l3-doc-writer": "workspace-write",
    "bucks-copy-l3-migration": "workspace-write",
}

DOMAIN_SKILLS = {
    "bucks-copy-macos-structure",
    "bucks-copy-bitget-integration",
    "bucks-copy-trading-engine",
}

IMPLICIT_SKILLS = {
    "bucks-copy-l2-architect",
    "bucks-copy-l2-code-reviewer",
    "bucks-copy-l2-security",
    "bucks-copy-l2-tdd-guide",
    "bucks-copy-l3-build-fixer",
    "bucks-copy-l3-doc-writer",
    "bucks-copy-l3-migration",
}

ACTIVE_TEXT_FILES = [
    "README.md",
    "AGENTS.md",
    "docs/00-governance/doc-map.md",
    "docs/20-architecture/system-overview.md",
    "docs/20-architecture/decision-log.md",
    "docs/30-quality/security-checklist.md",
    "docs/30-quality/test-strategy.md",
    "docs/40-agents/orchestration-model.md",
    "docs/40-agents/routing-matrix.md",
    "docs/40-agents/skill-catalog.md",
    "docs/40-agents/token-optimization-playbook.md",
    "docs/50-migration/migration-playbook.md",
    "docs/CODE_CONVENTION.md",
]

REQUIRED_ACTIVE_PATTERNS = [
    "Paper trading",
    "Bitget",
    "Presentation",
    "local market history",
    "bucks-copy-l1-planner-orchestrator",
    "bucks-copy-l2-security",
    "bucks-copy-trading-engine",
]

FORBIDDEN_ACTIVE_PATTERNS = [
    "future-bank",
    "AttendanceFeature",
    "UIKit + Rx",
    "live order execution is enabled by default",
]


@dataclass(frozen=True)
class Finding:
    path: Path
    message: str


def parse_toml_value(value: str) -> object:
    stripped = value.strip()
    if stripped.startswith('"""') and stripped.endswith('"""'):
        return stripped[3:-3]
    if stripped.startswith('"') and stripped.endswith('"'):
        return stripped[1:-1]
    if stripped.lower() == "true":
        return True
    if stripped.lower() == "false":
        return False
    try:
        return int(stripped)
    except ValueError:
        return stripped


def load_toml(path: Path) -> dict:
    # Minimal TOML reader for the simple config/agent files in this repository.
    result: dict[str, object] = {}
    current: dict[str, object] = result
    multiline_key: str | None = None
    multiline_buffer: list[str] = []

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        if multiline_key is not None:
            if line.endswith('"""'):
                multiline_buffer.append(raw_line.rsplit('"""', 1)[0])
                current[multiline_key] = "\n".join(multiline_buffer)
                multiline_key = None
                multiline_buffer = []
            else:
                multiline_buffer.append(raw_line)
            continue

        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            current = result.setdefault(section, {})
            continue

        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if value.startswith('"""') and not value.endswith('"""'):
            multiline_key = key
            multiline_buffer = [raw_line.split('"""', 1)[1]]
            continue

        current[key] = parse_toml_value(value)

    return result


def add_if(condition: bool, findings: list[Finding], path: Path, message: str) -> None:
    if condition:
        findings.append(Finding(path, message))


def check_repo_config(repo_root: Path, findings: list[Finding]) -> None:
    path = repo_root / ".codex/config.toml"
    add_if(not path.exists(), findings, path, "config file is missing")
    if not path.exists():
        return

    config = load_toml(path)
    add_if(config.get("sandbox_mode") != "danger-full-access", findings, path, "sandbox_mode must be danger-full-access")
    add_if(config.get("approval_policy") != "never", findings, path, "approval_policy must be never")

    features = config.get("features", {})
    add_if(features.get("hooks") is not True, findings, path, "[features].hooks must be true")

    agents = config.get("agents", {})
    add_if(agents.get("max_threads") != 3, findings, path, "[agents].max_threads must be 3")
    add_if(agents.get("max_depth") != 1, findings, path, "[agents].max_depth must be 1")
    add_if(agents.get("job_max_runtime_seconds") != 300, findings, path, "[agents].job_max_runtime_seconds must be 300")


def check_agent_tomls(repo_root: Path, findings: list[Finding]) -> None:
    agents_dir = repo_root / ".codex/agents"
    actual_agent_names = {path.stem for path in agents_dir.glob("*.toml")}

    for name in sorted(set(REQUIRED_AGENTS) - actual_agent_names):
        findings.append(Finding(agents_dir / f"{name}.toml", "required runtime agent is missing"))

    for name in sorted(actual_agent_names - set(REQUIRED_AGENTS)):
        findings.append(Finding(agents_dir / f"{name}.toml", "unexpected runtime agent is not documented"))

    for name, expected_sandbox in REQUIRED_AGENTS.items():
        path = agents_dir / f"{name}.toml"
        if not path.exists():
            continue
        config = load_toml(path)
        add_if(config.get("name") != name, findings, path, f"name must be {name}")
        add_if(config.get("sandbox_mode") != expected_sandbox, findings, path, f"sandbox_mode must be {expected_sandbox}")
        add_if("description" not in config, findings, path, "description is required")
        add_if("developer_instructions" not in config, findings, path, "developer_instructions is required")


def read_policy_allow_implicit(path: Path) -> bool | None:
    lines = path.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        if line.strip() != "policy:":
            continue
        for policy_line in lines[index + 1 : index + 5]:
            stripped = policy_line.strip()
            if stripped.startswith("allow_implicit_invocation:"):
                return stripped.split(":", 1)[1].strip().lower() == "true"
    return None


def check_skill_frontmatter(skill_dir: Path, findings: list[Finding]) -> None:
    path = skill_dir / "SKILL.md"
    add_if(not path.exists(), findings, path, "SKILL.md is missing")
    if not path.exists():
        return

    text = path.read_text(encoding="utf-8")
    add_if(not text.startswith("---\n"), findings, path, "frontmatter must start with ---")
    add_if(f"name: {skill_dir.name}" not in text.split("---", 2)[1], findings, path, "frontmatter name must match folder")
    add_if("description:" not in text.split("---", 2)[1], findings, path, "frontmatter description is required")


def check_skill_metadata(repo_root: Path, findings: list[Finding]) -> None:
    skills_dir = repo_root / ".codex/skills"
    expected = set(REQUIRED_AGENTS) | DOMAIN_SKILLS
    actual = {path.name for path in skills_dir.iterdir() if path.is_dir()}

    for name in sorted(expected - actual):
        findings.append(Finding(skills_dir / name, "required skill is missing"))

    for name in sorted(actual - expected):
        findings.append(Finding(skills_dir / name, "unexpected skill is not documented"))

    for name in sorted(actual):
        skill_dir = skills_dir / name
        metadata_path = skill_dir / "skill-metadata.yaml"
        check_skill_frontmatter(skill_dir, findings)
        add_if(not metadata_path.exists(), findings, metadata_path, "skill-metadata.yaml is missing")
        if name in IMPLICIT_SKILLS and metadata_path.exists():
            allow_implicit = read_policy_allow_implicit(metadata_path)
            add_if(allow_implicit is not True, findings, metadata_path, "allow_implicit_invocation must be true")


def check_active_text(repo_root: Path, findings: list[Finding]) -> None:
    joined = ""
    for relative_path in ACTIVE_TEXT_FILES:
        path = repo_root / relative_path
        add_if(not path.exists(), findings, path, "active policy file is missing")
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        joined += "\n" + text
        for pattern in FORBIDDEN_ACTIVE_PATTERNS:
            add_if(pattern in text, findings, path, f"forbidden active policy text remains: {pattern}")

    for pattern in REQUIRED_ACTIVE_PATTERNS:
        add_if(pattern not in joined, findings, repo_root / "docs", f"required active policy text missing: {pattern}")


def check_docs_reference_scripts(repo_root: Path, findings: list[Finding]) -> None:
    path = repo_root / "docs/40-agents/token-optimization-playbook.md"
    text = path.read_text(encoding="utf-8")
    for command in [
        "python3 scripts/ci/check_agent_config.py",
        "python3 scripts/ci/check_agent_routing.py",
        "python3 scripts/ci/check_agent_trace.py",
        "python3 scripts/ci/write_agent_trace.py",
    ]:
        add_if(command not in text, findings, path, f"playbook must document command: {command}")


def run(repo_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    check_repo_config(repo_root, findings)
    check_agent_tomls(repo_root, findings)
    check_skill_metadata(repo_root, findings)
    check_active_text(repo_root, findings)
    check_docs_reference_scripts(repo_root, findings)
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description="Check BucksCopy Codex agent configuration drift.")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    findings = run(repo_root)
    if findings:
        print("agent config check failed:")
        for finding in findings:
            try:
                display = finding.path.relative_to(repo_root)
            except ValueError:
                display = finding.path
            print(f"- {display}: {finding.message}")
        return 1

    print("agent config check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
