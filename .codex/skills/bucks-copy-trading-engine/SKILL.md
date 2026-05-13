---
name: bucks-copy-trading-engine
description: >
  Use for BucksCopy trading-engine work, including 15m/1H/4H/12H/1D candle
  aggregation, Watchlist-scoped strategy execution, closed-candle strategy
  boundaries, order intent generation, risk policy, paper execution, and
  live-trading safety gates.
---

# BucksCopy Trading Engine

## 읽기 순서

1. `AGENTS.md`
2. `docs/20-architecture/system-overview.md`
3. `docs/30-quality/test-strategy.md`
4. `docs/30-quality/security-checklist.md` if order or live policy is touched

## 핵심 규칙

- Treat Paper trading as the default execution mode.
- Execute strategy only for user-selected Watchlist symbols.
- Treat USDT-M Futures as the only v1 product line.
- Consume closed candles unless a future feature explicitly models in-progress candles.
- Prefer local closed candle history for warmup; use Bitget REST only to seed or fill missing gaps.
- Keep strategy logic separate from Bitget order API calls.
- Represent strategy output as order intent, then pass through risk policy and paper execution.
- Require decision-log, security review, and acceptance tests before any live execution path.

## 테스트 우선순위

- Bucket boundaries for 15m, 1H, 4H, 12H, 1D.
- Watchlist-only subscription, strategy, and paper order behavior.
- 50-channel subscription limit validation or explicit connection splitting.
- Out-of-order, duplicate, missing, and partial market inputs.
- Startup gap fill from local history plus REST backfill without duplicate candles.
- Duplicate signal prevention.
- Paper accepted, rejected, risk-blocked, and simulated fill states.
