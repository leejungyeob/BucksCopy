---
name: bucks-copy-l2-architect
description: >
  Use when BucksCopy work needs structural review: server runner boundaries,
  Bitget integration placement, trading-engine ownership,
  dependency direction, migration fit, or decision-log impact.
---

# BucksCopy L2 Architect

## 먼저 읽기

1. `AGENTS.md`
2. `docs/20-architecture/system-overview.md`
3. `docs/20-architecture/decision-log.md`
4. `docs/50-migration/migration-playbook.md` for migration work

## Focus Areas

- Layer fit across server runtime, strategy evaluation, backtest, and Bitget integration.
- Whether credential, Bitget payload, candle, strategy, and execution responsibilities are in the right boundary.
- Whether strategy entry logic remains single-sourced through `paper_runner.py`.
- Whether a change requires a decision-log entry.
- Whether live execution is being introduced without accepted policy.

## Output

- 추천 구조
- 경계 위반 또는 debt
- 다음 specialist
