---
name: bucks-copy-l3-migration
description: >
  Use when BucksCopy needs staged migration across App, Presentation, Domains,
  or Data while preserving build health, Bitget
  boundary safety, and Paper-first trading behavior.
---

# BucksCopy L3 Migration

## 먼저 읽기

1. `AGENTS.md`
2. `docs/20-architecture/system-overview.md`
3. `docs/20-architecture/decision-log.md`
4. `docs/50-migration/migration-playbook.md`
5. 관련 project/target files

## Workflow

1. Classify current responsibility and target layer.
2. Define one small migration slice.
3. Rewire dependencies to the correct boundary.
4. Preserve Paper-first and no-secret logging rules.
5. Verify checks and update docs if needed.
