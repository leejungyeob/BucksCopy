---
name: bucks-copy-l2-tdd-guide
description: >
  Use when BucksCopy requirements need acceptance scenarios, edge cases, and
  minimum safe validation for macOS UI, Bitget integration, credential storage,
  candle aggregation, strategy, paper execution, or live-trading policy.
---

# BucksCopy L2 TDD Guide

## 먼저 읽기

1. `AGENTS.md`
2. `docs/30-quality/test-strategy.md`
3. 요구사항 또는 변경 요약
4. `docs/20-architecture/system-overview.md` when structure matters

## Workflow

1. Convert requirements into acceptance scenarios.
2. Split validation by layer.
3. Add success, failure, and boundary cases.
4. Mark optional checks and reasons.

## Output

- acceptance scenario
- layer별 테스트 목록
- edge case
- 최소 안전 검증 세트
