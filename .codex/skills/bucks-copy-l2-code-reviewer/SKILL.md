---
name: bucks-copy-l2-code-reviewer
description: >
  Use when BucksCopy changes need findings-first review for bugs, regressions,
  maintainability issues, missing tests, structure violations, trading safety,
  candle edge cases, duplicate orders, or secret exposure.
---

# BucksCopy L2 Code Reviewer

## 먼저 읽기

1. `AGENTS.md`
2. `docs/CODE_CONVENTION.md`
3. `docs/30-quality/test-strategy.md`
4. 변경 파일 또는 diff

## Review Focus

- Bugs, regressions, missing tests.
- Unsafe order intent duplication.
- Candle boundary or partial-candle mistakes.
- Secret/logging exposure.
- Forbidden dependency edges.

## Output

- severity 순 findings
- open questions or assumptions
- residual risk and minimal follow-up checks
