import importlib.util
import json
import sys
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path


def load_runner_module():
    module_path = Path(__file__).with_name("paper_runner.py")
    spec = importlib.util.spec_from_file_location("paper_runner", module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ServerLiveExecutionTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_runner_module()
        self.user_id = "local-admin"

    def make_runner(self, data_dir):
        runner = self.mod.PaperRunner.__new__(self.mod.PaperRunner)
        runner.data_dir = Path(data_dir)
        runner.live_margin_mode = "isolated"
        runner.live_position_mode = "hedge"
        runner.live_order_execution_enabled = True
        runner.live_order_margin_usdt = Decimal("10")
        runner.live_available_balance_ratio = Decimal("1")
        runner.live_confirmation_attempts = 1
        runner.live_confirmation_delay_seconds = Decimal("0")
        runner.live_protection_retry_attempts = 5
        runner.private_poll_seconds = 60
        runner.symbols = ["BTCUSDT"]
        runner.bitget_credentials_by_user_id = {
            self.user_id: self.mod.BitgetCredential(
                api_key="fixture-api-key",
                secret_key="fixture-secret",
                passphrase="fixture-passphrase",
            )
        }
        (runner.data_dir / "users" / self.user_id).mkdir(parents=True)
        runner.live_status = lambda user_id: {"ready": True, "orderExecutionEnabled": True}
        runner.fetch_contract_specs = lambda symbol: {
            "symbol": symbol,
            "minTradeNum": Decimal("0.0001"),
            "minTradeUSDT": Decimal("5"),
            "sizeMultiplier": Decimal("0.0001"),
            "volumePlace": 4,
            "pricePlace": 2,
            "maxLeverage": 10,
        }
        runner.refresh_user_private_snapshot = lambda user_id: {
            "positions": [
                {
                    "symbol": "BTCUSDT",
                    "holdSide": "long",
                    "total": "0.0013",
                    "available": "0.0013",
                }
            ]
        }
        return runner

    def signal(self):
        return self.mod.Signal(
            strategy_id="btc-15m-vacuum-pulse",
            symbol="BTCUSDT",
            side="buy",
            entry=Decimal("73865"),
            stop=Decimal("73716"),
            take_profit=Decimal("74386.5"),
            reason="fixture",
            leverage=10,
        )

    def private_snapshot(self):
        return {
            "accounts": [
                {
                    "marginCoin": "USDT",
                    "available": "100",
                }
            ]
        }

    def read_logs(self, data_dir):
        path = Path(data_dir) / "users" / self.user_id / "trade-event-logs.jsonl"
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def test_live_signal_runs_full_hedge_order_sequence_with_bitget_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = self.make_runner(directory)
            posts = []

            def signed_post(_credential, path, payload):
                posts.append((path, payload))
                if path == "/api/v2/mix/order/place-order":
                    return {"orderId": "entry-1", "clientOid": payload["clientOid"]}
                if path == "/api/v2/mix/order/place-tpsl-order":
                    return {"orderId": f"protection-{len(posts)}", "clientOid": payload["clientOid"]}
                return {}

            def signed_get(_credential, path, params):
                self.assertEqual(path, "/api/v2/mix/order/detail")
                self.assertEqual(params["symbol"], "BTCUSDT")
                return {
                    "orderId": "entry-1",
                    "clientOid": params["clientOid"],
                    "state": "filled",
                    "baseVolume": "0.0013",
                    "priceAvg": "73865",
                }

            runner.bitget_signed_post = signed_post
            runner.bitget_signed_get = signed_get

            did_execute = runner.maybe_execute_live_signal(
                self.user_id,
                self.signal(),
                1_748_742_300_000,
                self.mod.now_utc(),
                self.private_snapshot(),
            )

            self.assertTrue(did_execute)
            self.assertEqual(posts[0][0], "/api/v2/mix/account/set-leverage")
            self.assertEqual(posts[0][1]["holdSide"], "long")
            self.assertEqual(posts[1][0], "/api/v2/mix/order/place-order")
            self.assertNotIn("reduceOnly", posts[1][1])
            self.assertEqual(posts[1][1]["tradeSide"], "open")
            self.assertEqual(posts[1][1]["side"], "buy")

            protection_payloads = [payload for path, payload in posts if path == "/api/v2/mix/order/place-tpsl-order"]
            self.assertEqual(len(protection_payloads), 3)
            self.assertEqual([payload["holdSide"] for payload in protection_payloads], ["long", "long", "long"])
            self.assertEqual([payload["planType"] for payload in protection_payloads], ["profit_plan", "profit_plan", "loss_plan"])

            logs = self.read_logs(directory)
            self.assertEqual(logs[-1]["severity"], "info")
            self.assertEqual(logs[-1]["metadata"]["details"]["protectionOrders"], "3")

    def test_live_signal_failure_log_keeps_sanitized_bitget_reason(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = self.make_runner(directory)
            posts = []

            def signed_post(_credential, path, payload):
                posts.append((path, payload))
                raise self.mod.LiveExecutionError("Bitget API 40774: holdSide required")

            runner.bitget_signed_post = signed_post
            runner.bitget_signed_get = lambda *_args: {}

            with self.assertRaises(self.mod.LiveExecutionError):
                runner.maybe_execute_live_signal(
                    self.user_id,
                    self.signal(),
                    1_748_742_300_000,
                    self.mod.now_utc(),
                    self.private_snapshot(),
                )

            self.assertEqual(posts[0][0], "/api/v2/mix/account/set-leverage")
            logs = self.read_logs(directory)
            self.assertEqual(logs[-1]["severity"], "error")
            self.assertEqual(
                logs[-1]["metadata"]["details"]["failureReason"],
                "Bitget API 40774: holdSide required",
            )
            self.assertEqual(logs[-1]["metadata"]["details"]["failClosedAttempted"], "false")

    def test_minimum_live_test_order_enters_then_closes_position(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = self.make_runner(directory)
            posts = []
            snapshots = [
                {
                    "accounts": [{"marginCoin": "USDT", "available": "100"}],
                    "positions": [],
                },
                {
                    "accounts": [{"marginCoin": "USDT", "available": "100"}],
                    "positions": [
                        {
                            "symbol": "BTCUSDT",
                            "holdSide": "long",
                            "total": "0.0001",
                            "available": "0.0001",
                        }
                    ],
                },
                {
                    "accounts": [{"marginCoin": "USDT", "available": "100"}],
                    "positions": [],
                },
            ]

            def refresh_snapshot(_user_id):
                return snapshots.pop(0) if snapshots else {
                    "accounts": [{"marginCoin": "USDT", "available": "100"}],
                    "positions": [
                        {
                            "symbol": "BTCUSDT",
                            "holdSide": "long",
                            "total": "0.0001",
                            "available": "0.0001",
                        }
                    ],
                }

            def signed_post(_credential, path, payload):
                posts.append((path, payload))
                if path == "/api/v2/mix/order/place-order":
                    return {"orderId": "entry-1", "clientOid": payload["clientOid"]}
                if path == "/api/v2/mix/order/close-positions":
                    return {"successList": [{"orderId": "close-1", "clientOid": "close-client", "symbol": "BTCUSDT"}]}
                return {}

            def signed_get(_credential, path, params):
                return {
                    "orderId": "entry-1",
                    "clientOid": params["clientOid"],
                    "state": "filled",
                    "baseVolume": "0.0001",
                    "priceAvg": "73865",
                }

            runner.refresh_user_private_snapshot = refresh_snapshot
            runner.fetch_candles = lambda _symbol: [
                self.mod.Candle(
                    symbol="BTCUSDT",
                    open_time=1_748_742_300,
                    open=Decimal("73800"),
                    high=Decimal("73900"),
                    low=Decimal("73700"),
                    close=Decimal("73865"),
                    volume=Decimal("1"),
                    is_closed=True,
                )
            ]
            runner.upsert_candles = lambda _symbol, candles: candles
            runner.load_candles = lambda _symbol: []
            runner.bitget_signed_post = signed_post
            runner.bitget_signed_get = signed_get

            response = runner.execute_minimum_live_test_order(self.user_id, "BTCUSDT", "buy")

            self.assertTrue(response["ok"])
            self.assertEqual(response["leverage"], "1x")
            self.assertEqual(response["size"], "0.0001")
            self.assertEqual(posts[0][0], "/api/v2/mix/account/set-leverage")
            self.assertEqual(posts[0][1]["leverage"], "1")
            self.assertEqual(posts[0][1]["holdSide"], "long")
            self.assertEqual(posts[1][0], "/api/v2/mix/order/place-order")
            self.assertEqual(posts[1][1]["size"], "0.0001")
            self.assertNotIn("reduceOnly", posts[1][1])
            self.assertEqual(posts[2][0], "/api/v2/mix/order/close-positions")
            self.assertEqual(posts[2][1]["holdSide"], "long")
            self.assertFalse(any(path == "/api/v2/mix/order/place-tpsl-order" for path, _ in posts))
            logs = self.read_logs(directory)
            self.assertEqual(logs[-1]["metadata"]["details"]["minimumTest"], "true")
            self.assertEqual(logs[-1]["metadata"]["details"]["closeConfirmed"], "true")
            self.assertEqual(logs[-1]["metadata"]["details"]["protectionOrders"], "0")


if __name__ == "__main__":
    unittest.main()
