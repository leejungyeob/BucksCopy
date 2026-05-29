---
name: bucks-copy-strategy-validation
description: >
  Use for BucksCopy strategy validation and backtest-result requests, especially
  after adding or changing a trading strategy, TP/SL/risk policy, timeframe
  routing, or when the user asks whether a strategy is usable in practice.
---

# BucksCopy Strategy Validation

## 기본 원칙

- Use local closed candle history from SQLite. Current default scope is 15m and 1H latest 20,000 candles, with 4H/12H/1D full history.
- Treat backtest validation as mandatory before judging any strategy as usable for live monitoring.
- Keep auxiliary indicators out of the primary result unless the user explicitly asks to test them.
- Current routed portfolio is symbol-scoped. Active routes: BTCUSDT 15m BTC Phase Vacuum Reclaim, ETHUSDT 1H ETH Momentum Burst, BTCUSDT 15m BTC Vacuum Pulse, and ETHUSDT 15m ETH Vacuum Pulse. These routes also carry maximum holding windows: 15m routes 96 candles and ETH 1H Momentum Burst 72 candles. BTCUSDT 12H VWMA100 touch trend and other removed symbol routes must stay excluded unless the user explicitly asks to re-enable them.
- Report practical metrics, not just final balance: final balance, net return, win rate, trade count, MDD, PF, TP1/TP2/profit-lock stop/time-exit counts.
- Explain jargon in Korean when showing results. At minimum define MDD, PF, TP1, TP2, TP1후 SL, 순수 SL.

## 표준 실행

Run the repo script from the repository root:

```bash
scripts/backtest/run_split_tp_backtest_report.sh --symbol BTCUSDT --all
```

For a focused timeframe/risk run, pass explicit parameters:

```bash
scripts/backtest/run_split_tp_backtest_report.sh --symbol BTCUSDT --all --timeframe 15m --leverage 10 --risk 5
```

The default output is:

```text
Derived/Reports/split-tp-backtest-BTCUSDT-all.md
```

The default cache is:

```text
Derived/Reports/split-tp-backtest-BTCUSDT-cache.json
```

By default, the script reuses cached rows for combinations that were already run. Use `--refresh-cache` only when the user explicitly wants to recompute prior combinations.
The default 15m and 1H scope is latest 20,000 candles. Use `--15m-limit 0` or `--1h-limit 0` only when the user explicitly wants full history for that timeframe.
Use `--leverage`, `--risk`, and `--margin` to match the user's requested risk settings instead of editing the runner source.

Use `--recommended-only` only when the user specifically wants current app-routing candidates.

Current 4-year reference reports for the `10x` leverage / `5%` risk Vacuum Pulse routes:

```text
Derived/Reports/vacuum-pulse-BTCUSDT-4y-10x-risk5.md
Derived/Reports/vacuum-pulse-ETHUSDT-4y-10x-risk5.md
Derived/Reports/vacuum-pulse-4y-10x-risk5-summary.csv
```

## 전략 추가/변경 후 절차

1. Confirm the strategy is registered in `StrategyRegistry`.
2. Confirm `StrategyTimeframeRouting` includes or intentionally excludes the strategy.
3. Run the standard script.
4. Open the generated Markdown report and summarize:
   - 실전 후보
   - 제외할 조합
   - MDD가 큰 조건부 후보
   - 거래 수가 너무 적어 과신하면 안 되는 후보
5. If code changed, also run the project test suite:

```bash
xcodebuild -workspace BucksCopy.xcworkspace -scheme BucksCopy -destination 'platform=macOS' test
```

## 실전 후보 판단 기준

- Prefer positive final balance with enough trades and acceptable MDD.
- A high final balance with very high MDD is conditional, not automatically deployable.
- A high win rate with low trade count is only a hypothesis.
- Exclude strategies with negative return or MDD too large for the expected capital size.
