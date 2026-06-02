---
name: bucks-copy-strategy-validation
description: >
  Use for BucksCopy strategy validation and backtest-result requests, especially
  after adding or changing a trading strategy, TP/SL/risk policy, timeframe
  routing, or when the user asks whether a strategy is usable in practice.
---

# BucksCopy Strategy Validation

## 기본 원칙

- Use local closed candle history from SQLite. For 15m BTC strategy validation, prefer full available history or explicitly pass `--15m-limit 0` when the user asks for 4-year or full-history validation.
- Treat backtest validation as mandatory before judging any strategy as usable for live monitoring.
- Keep auxiliary indicators out of the primary result unless the user explicitly asks to test them.
- Current routed portfolio is symbol-scoped and server runtime is 15m-only. Active routes: BTCUSDT 15m BTC Vacuum Pulse, BTCUSDT 15m BTC Pulse 107, and ETHUSDT 15m ETH Wick Reclaim. Backtest tools must call the server runtime evaluator instead of reimplementing entry logic.
- Report practical metrics, not just final balance: final balance, net return, win rate, trade count, MDD, PF, TP1/TP2/profit-lock stop/time-exit counts.
- Explain jargon in Korean when showing results. At minimum define MDD, PF, TP1, TP2, TP1후 SL, 순수 SL.

## 표준 실행

Run the runtime-equivalent backtest from the repository root:

```bash
python3 Server/PaperRunnerPython/paper_runner_backtest.py \
  --db fixtures/market-history/BucksCopyCandles.sqlite.gz \
  --strategy btc-15m-vacuum-pulse
```

For a focused timeframe run, pass explicit bounds:

```bash
python3 Server/PaperRunnerPython/paper_runner_backtest.py \
  --db fixtures/market-history/BucksCopyCandles.sqlite.gz \
  --strategy btc-15m-pulse-107 \
  --start 2026-01-01T00:00:00Z \
  --end 2026-02-01T00:00:00Z \
  --output-prefix Derived/Reports/paper-runner-pulse-107-check
```

The default outputs are:

```text
Derived/Reports/paper-runner-backtest-summary.json
Derived/Reports/paper-runner-backtest-trades.csv
Derived/Reports/paper-runner-backtest-equity.csv
```

Current deterministic fixture coverage:

```text
Server/PaperRunnerPython/test_paper_runner_backtest.py
```

## 전략 추가/변경 후 절차

1. Confirm the strategy is registered in `paper_runner.ACTIVE_STRATEGIES_BY_SYMBOL`.
2. Confirm the server live loop uses the strategy ID on closed 15m candles.
3. Run the runtime backtest script.
4. Open the generated Markdown report and summarize:
   - 실전 후보
   - 제외할 조합
   - MDD가 큰 조건부 후보
   - 거래 수가 너무 적어 과신하면 안 되는 후보
5. If code changed, also run the Python validation suite:

```bash
python3 -m unittest \
  Server/PaperRunnerPython/test_paper_runner_backtest.py \
  Server/PaperRunnerPython/test_paper_runner_live_execution.py
```

## 실전 후보 판단 기준

- Prefer positive final balance with enough trades and acceptable MDD.
- A high final balance with very high MDD is conditional, not automatically deployable.
- A high win rate with low trade count is only a hypothesis.
- Exclude strategies with negative return or MDD too large for the expected capital size.
