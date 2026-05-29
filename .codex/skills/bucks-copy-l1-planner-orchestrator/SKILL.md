---
name: bucks-copy-l1-planner-orchestrator
description: >
  Use to route complex BucksCopy work, choose the minimum specialist path,
  define scope, prepare handoff, and preserve the single-writer rule.
---

# BucksCopy L1 Planner Orchestrator

## 읽기 순서

1. `AGENTS.md`
2. `docs/40-agents/orchestration-model.md`
3. `docs/40-agents/routing-matrix.md`
4. `.codex/contracts/handoff-template.yaml` when delegation is chosen

## Workflow

1. Classify direct-handle vs orchestration.
2. Fix scope-in, scope-out, risk, and done criteria.
3. Choose the minimum route from the routing matrix.
4. Keep one write-capable owner per cycle.
5. Synthesize specialist results into one decision.

## Guardrails

- Do not attach specialists to trivial work.
- Treat Bitget private API, credential, Keychain, order, and live trading as high risk.
- Treat live trading as active only behind the accepted explicit-consent and protection-order policy.
