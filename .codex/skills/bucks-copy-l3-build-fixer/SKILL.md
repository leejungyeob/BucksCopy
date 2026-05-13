---
name: bucks-copy-l3-build-fixer
description: >
  Use when BucksCopy build health needs narrow recovery: Tuist generation,
  Xcode project wiring, imports, target dependencies, compile failures, or
  script check failures after a change or migration slice.
---

# BucksCopy L3 Build Fixer

## 먼저 읽기

1. `AGENTS.md`
2. build/check output
3. `docs/20-architecture/system-overview.md`
4. `docs/50-migration/migration-playbook.md` for migration work

## Workflow

1. Reproduce the failure.
2. Narrow to target, import, script, or fixture issue.
3. Apply the smallest safe fix.
4. Report verification and remaining risk.
