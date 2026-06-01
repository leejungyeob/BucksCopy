import sys
import unittest
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch


SERVER_DIR = Path(__file__).resolve().parent
REPO_ROOT = SERVER_DIR.parents[1]
sys.path.insert(0, str(SERVER_DIR))

import paper_runner  # noqa: E402
import paper_runner_backtest  # noqa: E402


class PaperRunnerBacktestTests(unittest.TestCase):
    fixture_db = REPO_ROOT / "fixtures/market-history/BucksCopyCandles.sqlite.gz"
    start = paper_runner_backtest.parse_timestamp("2026-01-01T00:00:00Z")
    end = paper_runner_backtest.parse_timestamp("2026-02-01T00:00:00Z")

    def config(self, strategy_id):
        params = paper_runner_backtest.strategy_params(strategy_id)
        return paper_runner_backtest.BacktestConfig(
            db_path=self.fixture_db,
            strategy_id=strategy_id,
            symbol=params["symbol"],
            start=self.start,
            end=self.end,
            output_prefix=Path("Derived/Reports/test-runtime-backtest"),
        )

    def test_active_backtest_uses_runtime_strategy_evaluator(self):
        original = paper_runner.evaluate_strategy
        calls = 0

        def wrapped(candles, params, generated_at, context=None):
            nonlocal calls
            calls += 1
            return original(candles, params, generated_at, context=context)

        with patch.object(paper_runner_backtest.paper_runner, "evaluate_strategy", side_effect=wrapped):
            result = paper_runner_backtest.run_backtest(self.config("eth-15m-vacuum-pulse"))

        self.assertGreater(calls, 0)
        self.assertEqual(result["summary"]["trade_count"], 1)

    def test_cached_strategy_context_matches_uncached_runtime_evaluator(self):
        for strategy_id in paper_runner.DEFAULT_OWNER_STRATEGY_IDS:
            with self.subTest(strategy_id=strategy_id):
                config = self.config(strategy_id)
                params = paper_runner_backtest.strategy_params(strategy_id)
                candles = paper_runner_backtest.load_candles(config)
                context = paper_runner.StrategyEvaluationContext(candles)
                history = []
                for candle in candles:
                    history.append(candle)
                    evaluated_at = datetime.fromtimestamp(candle.open_time + paper_runner.TIMEFRAME_SECONDS, paper_runner.timezone.utc)
                    uncached = paper_runner.evaluate_strategy(history, params, evaluated_at)
                    cached = paper_runner.evaluate_strategy(history, params, evaluated_at, context=context)
                    self.assertEqual(uncached is None, cached is None)
                    if uncached is None or cached is None:
                        continue
                    self.assertEqual(uncached.strategy_id, cached.strategy_id)
                    self.assertEqual(uncached.symbol, cached.symbol)
                    self.assertEqual(uncached.side, cached.side)
                    self.assertEqual(uncached.entry, cached.entry)
                    self.assertEqual(uncached.stop, cached.stop)
                    self.assertEqual(uncached.take_profit, cached.take_profit)
                    self.assertEqual(uncached.leverage, cached.leverage)

    def test_active_strategy_backtests_are_deterministic_on_fixture_snapshot(self):
        expected = {
            "btc-15m-vacuum-pulse": {
                "final_balance": Decimal("87.711678"),
                "trade_count": 7,
                "max_drawdown_percent": Decimal("20.472450"),
            },
            "btc-15m-regime-session-fade": {
                "final_balance": Decimal("103.427024"),
                "trade_count": 13,
                "max_drawdown_percent": Decimal("14.294658"),
            },
            "btc-15m-bull-pullback-long": {
                "final_balance": Decimal("100.000000"),
                "trade_count": 0,
                "max_drawdown_percent": Decimal("0.000000"),
            },
            "eth-15m-vacuum-pulse": {
                "final_balance": Decimal("94.548444"),
                "trade_count": 1,
                "max_drawdown_percent": Decimal("5.451556"),
            },
        }

        for strategy_id, expectation in expected.items():
            with self.subTest(strategy_id=strategy_id):
                summary = paper_runner_backtest.run_backtest(self.config(strategy_id))["summary"]
                self.assertEqual(summary["trade_count"], expectation["trade_count"])
                self.assertEqual(
                    Decimal(summary["final_balance"]).quantize(Decimal("0.000001")),
                    expectation["final_balance"],
                )
                self.assertEqual(
                    Decimal(summary["max_drawdown_percent"]).quantize(Decimal("0.000001")),
                    expectation["max_drawdown_percent"],
                )


if __name__ == "__main__":
    unittest.main()
