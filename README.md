# BucksCopy

Server-side Bitget USDT-M Futures auto-trading runner.

## Current Runtime

| Area | Decision |
| --- | --- |
| Runtime | Python server runner |
| Primary engine | `Server/PaperRunnerPython/paper_runner.py` |
| Backtest engine | `Server/PaperRunnerPython/paper_runner_backtest.py`, which imports the runtime strategy evaluator |
| Exchange | Bitget USDT-M Futures (`productType=USDT-FUTURES`) |
| Trading mode | Explicit-consent live auto-trading behind server live gate and order switch |
| Active timeframe | Closed `15m` candles only |
| Active routes | BTCUSDT Vacuum Pulse, BTCUSDT Pulse 107, ETHUSDT Vacuum Pulse |

The macOS Swift app and Swift backtest engine were removed from the active project. Strategy validation and live signal generation must use the server Python runner path so the entry-decision logic stays unified.

## Server Commands

```bash
BUCKS_COPY_DATA_DIR=.server-data \
BUCKS_COPY_RUN_ONCE=true \
python3 Server/PaperRunnerPython/paper_runner.py
```

```bash
docker compose --env-file .env \
  -f Server/docker-compose.paper.yml \
  -f Server/docker-compose.https.yml \
  up -d --build
```

## Runtime Backtest

Use this path for strategy validation because it calls the same `paper_runner.evaluate_strategy(...)` function used by live server evaluation.

```bash
python3 Server/PaperRunnerPython/paper_runner_backtest.py \
  --db fixtures/market-history/BucksCopyCandles.sqlite.gz \
  --strategy btc-15m-vacuum-pulse \
  --start 2026-01-01T00:00:00Z \
  --end 2026-02-01T00:00:00Z \
  --output-prefix Derived/Reports/paper-runner-btc-pulse-check
```

Outputs:

- `*-summary.json`
- `*-trades.csv`
- `*-equity.csv`

## Validation

```bash
python3 -m unittest \
  Server/PaperRunnerPython/test_paper_runner_backtest.py \
  Server/PaperRunnerPython/test_paper_runner_live_execution.py
```

The backtest test uses the sanitized fixture database and checks deterministic results for all active strategies. The live execution test checks Bitget order payloads, live gate blocking, protection-order registration, and sanitized error logging.

## Server Docs

- [Server README](./Server/README.md)
- [System overview](./docs/20-architecture/system-overview.md)
- [Test strategy](./docs/30-quality/test-strategy.md)
- [Security checklist](./docs/30-quality/security-checklist.md)
- [Decision log](./docs/20-architecture/decision-log.md)
