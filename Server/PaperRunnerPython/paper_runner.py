#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import ssl
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, getcontext
from pathlib import Path
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen

getcontext().prec = 34

TIMEFRAME = "15m"
TIMEFRAME_SECONDS = 15 * 60
PRODUCT_TYPE = "USDT-FUTURES"
DEFAULT_BASE_URL = "https://api.bitget.com"


def dec(value: str | int | float | Decimal) -> Decimal:
    return Decimal(str(value))


def decimal_text(value: Decimal) -> str:
    text = format(value.normalize(), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def open_time_iso(open_time: int) -> str:
    return iso(datetime.fromtimestamp(open_time, timezone.utc))


def parse_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def ssl_context() -> ssl.SSLContext:
    cafile = os.environ.get("SSL_CERT_FILE")
    candidates = [
        cafile,
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/ssl/cert.pem",
        "/opt/homebrew/etc/ca-certificates/cert.pem",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return ssl.create_default_context(cafile=candidate)
    return ssl.create_default_context()


@dataclass(frozen=True)
class Candle:
    symbol: str
    open_time: int
    open: Decimal
    high: Decimal
    low: Decimal
    close: Decimal
    volume: Decimal
    is_closed: bool

    @property
    def key(self) -> str:
        return f"{self.symbol}:{TIMEFRAME}:{self.open_time}"

    def to_record(self) -> dict[str, Any]:
        return {
            "productType": PRODUCT_TYPE,
            "symbol": self.symbol,
            "timeframe": TIMEFRAME,
            "openTime": self.open_time,
            "openTimeISO": open_time_iso(self.open_time),
            "open": decimal_text(self.open),
            "high": decimal_text(self.high),
            "low": decimal_text(self.low),
            "close": decimal_text(self.close),
            "volume": decimal_text(self.volume),
            "isClosed": self.is_closed,
        }

    @staticmethod
    def from_record(record: dict[str, Any]) -> "Candle":
        open_time = int(record["openTime"])
        return Candle(
            symbol=str(record["symbol"]),
            open_time=open_time,
            open=dec(record["open"]),
            high=dec(record["high"]),
            low=dec(record["low"]),
            close=dec(record["close"]),
            volume=dec(record["volume"]),
            is_closed=bool(record.get("isClosed", True)),
        )


@dataclass(frozen=True)
class Signal:
    strategy_id: str
    symbol: str
    side: str
    entry: Decimal
    stop: Decimal
    take_profit: Decimal
    reason: str
    leverage: int

    @property
    def partial_take_profit(self) -> Decimal:
        return (self.entry + self.take_profit) / dec(2)

    @property
    def profit_lock_stop(self) -> Decimal:
        return self.entry + (self.take_profit - self.entry) * dec("0.25")

    @property
    def reward_risk_ratio(self) -> Decimal | None:
        if not has_valid_price_layout(self):
            return None
        risk = abs(self.entry - self.stop)
        reward = abs(self.take_profit - self.entry)
        if risk <= 0:
            return None
        return reward / risk


BTC_PHASE_PARAMS = {
    "strategy_id": "btc-15m-phase-vacuum-reclaim",
    "name": "BTC 15m Phase Vacuum Reclaim",
    "symbol": "BTCUSDT",
    "fast_mean_period": 96,
    "slow_mean_period": 384,
    "atr_period": 14,
    "volume_lookback": 144,
    "reclaim_lookback": 2,
    "minimum_trend_spread": dec("0.002"),
    "maximum_trend_spread": dec("0.020"),
    "minimum_atr_percent": dec("0.001"),
    "maximum_atr_percent": dec("0.0075"),
    "minimum_close_location": dec("0.76"),
    "volume_multiplier": dec("2.0"),
    "stop_atr_buffer": dec("0.45"),
    "reward_risk_ratio": dec("3.5"),
    "leverage": 10,
}

BTC_PULSE_PARAMS = {
    "strategy_id": "btc-15m-vacuum-pulse",
    "name": "BTC 15m Vacuum Pulse",
    "symbol": "BTCUSDT",
    "fast_mean_period": 96,
    "slow_mean_period": 384,
    "atr_period": 14,
    "volume_lookback": 144,
    "reclaim_lookback": 2,
    "return_lookback": 2,
    "return_threshold": dec("0"),
    "minimum_trend_spread": dec("0.002"),
    "maximum_trend_spread": dec("0.020"),
    "minimum_atr_percent": dec("0.001"),
    "maximum_atr_percent": dec("0.0075"),
    "minimum_close_location": dec("0.76"),
    "volume_multiplier": dec("2.0"),
    "pullback_atr_buffer": dec("0"),
    "breakout_atr_buffer": dec("0"),
    "stop_atr_buffer": dec("0.45"),
    "minimum_stop_percent": dec("0"),
    "maximum_stop_percent": dec("1"),
    "reward_risk_ratio": dec("3.5"),
    "stop_mode": 0,
    "side_mode": 0,
    "weekday_mask": 127,
    "leverage": 10,
}

ETH_PULSE_PARAMS = {
    "strategy_id": "eth-15m-vacuum-pulse",
    "name": "ETH 15m Vacuum Pulse",
    "symbol": "ETHUSDT",
    "fast_mean_period": 48,
    "slow_mean_period": 256,
    "atr_period": 10,
    "volume_lookback": 32,
    "reclaim_lookback": 6,
    "return_lookback": 6,
    "return_threshold": dec("0.0025"),
    "minimum_trend_spread": dec("0.001"),
    "maximum_trend_spread": dec("0.015"),
    "minimum_atr_percent": dec("0.0004"),
    "maximum_atr_percent": dec("0.010"),
    "minimum_close_location": dec("0.52"),
    "volume_multiplier": dec("0.85"),
    "pullback_atr_buffer": dec("-0.1"),
    "breakout_atr_buffer": dec("0.2"),
    "stop_atr_buffer": dec("1.25"),
    "minimum_stop_percent": dec("0.0008"),
    "maximum_stop_percent": dec("0.012"),
    "reward_risk_ratio": dec("4.0"),
    "stop_mode": 1,
    "side_mode": -1,
    "weekday_mask": 124,
    "leverage": 10,
}

ACTIVE_STRATEGIES_BY_SYMBOL = {
    "BTCUSDT": [BTC_PHASE_PARAMS, BTC_PULSE_PARAMS],
    "ETHUSDT": [ETH_PULSE_PARAMS],
}


def simple_moving_average(candles: list[Candle], period: int, ending_at: int | None = None) -> Decimal | None:
    end_index = len(candles) - 1 if ending_at is None else ending_at
    if period <= 0 or end_index < 0 or end_index >= len(candles) or end_index - period + 1 < 0:
        return None
    return sum((c.close for c in candles[end_index - period + 1 : end_index + 1]), dec(0)) / dec(period)


def average_volume(candles: list[Candle], period: int, ending_at: int | None = None) -> Decimal | None:
    end_index = len(candles) - 1 if ending_at is None else ending_at
    if period <= 0 or end_index < 0 or end_index >= len(candles) or end_index - period + 1 < 0:
        return None
    return sum((c.volume for c in candles[end_index - period + 1 : end_index + 1]), dec(0)) / dec(period)


def highest_high(candles: list[Candle], lookback: int, ending_at: int) -> Decimal | None:
    if lookback <= 0 or ending_at < 0 or ending_at >= len(candles) or ending_at - lookback + 1 < 0:
        return None
    return max(c.high for c in candles[ending_at - lookback + 1 : ending_at + 1])


def lowest_low(candles: list[Candle], lookback: int, ending_at: int) -> Decimal | None:
    if lookback <= 0 or ending_at < 0 or ending_at >= len(candles) or ending_at - lookback + 1 < 0:
        return None
    return min(c.low for c in candles[ending_at - lookback + 1 : ending_at + 1])


def average_true_range(candles: list[Candle], period: int, ending_at: int | None = None) -> Decimal | None:
    end_index = len(candles) - 1 if ending_at is None else ending_at
    if period <= 0 or end_index <= 0 or end_index >= len(candles) or end_index - period + 1 <= 0:
        return None
    total = dec(0)
    for index in range(end_index - period + 1, end_index + 1):
        candle = candles[index]
        previous_close = candles[index - 1].close
        total += max(candle.high - candle.low, abs(candle.high - previous_close), abs(candle.low - previous_close))
    return total / dec(period)


def has_valid_price_layout(signal: Signal) -> bool:
    if signal.side == "buy":
        return signal.stop < signal.entry < signal.take_profit
    return signal.take_profit < signal.entry < signal.stop


def risk_allowed(signal: Signal) -> bool:
    ratio = signal.reward_risk_ratio
    if ratio is None or ratio < dec(2):
        return False
    if signal.leverage <= 0 or signal.leverage > 10:
        return False
    return True


def stop_percent_allowed(params: dict[str, Any], risk: Decimal, entry: Decimal) -> bool:
    stop_percent = risk / entry
    return params["minimum_stop_percent"] <= stop_percent <= params["maximum_stop_percent"]


def allowed_weekday(mask: int, generated_at: datetime) -> bool:
    weekday = generated_at.astimezone(timezone.utc).weekday()
    return mask & (1 << weekday) != 0


def evaluate_btc_phase(candles: list[Candle], params: dict[str, Any], generated_at: datetime) -> Signal | None:
    del generated_at
    if len(candles) < params["slow_mean_period"] or len(candles) < params["reclaim_lookback"] + 1:
        return None

    fast_mean = simple_moving_average(candles, params["fast_mean_period"])
    slow_mean = simple_moving_average(candles, params["slow_mean_period"])
    atr = average_true_range(candles, params["atr_period"])
    avg_volume = average_volume(candles, params["volume_lookback"])
    previous_high = highest_high(candles, params["reclaim_lookback"], len(candles) - 2)
    previous_low = lowest_low(candles, params["reclaim_lookback"], len(candles) - 2)
    if None in {fast_mean, slow_mean, atr, avg_volume, previous_high, previous_low}:
        return None

    latest = candles[-1]
    entry = latest.close
    candle_range = latest.high - latest.low
    if entry <= 0 or candle_range <= 0 or atr <= 0 or avg_volume <= 0:
        return None
    if latest.volume < avg_volume * params["volume_multiplier"]:
        return None

    trend_spread = abs(fast_mean - slow_mean) / entry
    atr_percent = atr / entry
    if not (params["minimum_trend_spread"] <= trend_spread <= params["maximum_trend_spread"]):
        return None
    if not (params["minimum_atr_percent"] <= atr_percent <= params["maximum_atr_percent"]):
        return None

    close_location = (latest.close - latest.low) / candle_range
    if (
        fast_mean > slow_mean
        and latest.low <= fast_mean
        and latest.close > fast_mean
        and latest.close > previous_high
        and latest.close > latest.open
        and close_location >= params["minimum_close_location"]
    ):
        stop = min(latest.low, fast_mean - atr * params["stop_atr_buffer"])
        risk = entry - stop
        if risk <= 0:
            return None
        return Signal(
            strategy_id=params["strategy_id"],
            symbol=params["symbol"],
            side="buy",
            entry=entry,
            stop=stop,
            take_profit=entry + risk * params["reward_risk_ratio"],
            reason="BTC 15m Phase Vacuum Reclaim: SMA96/SMA384 phase에서 2봉 고가 reclaim",
            leverage=params["leverage"],
        )

    if (
        fast_mean < slow_mean
        and latest.high >= fast_mean
        and latest.close < fast_mean
        and latest.close < previous_low
        and latest.close < latest.open
        and close_location <= dec(1) - params["minimum_close_location"]
    ):
        stop = max(latest.high, fast_mean + atr * params["stop_atr_buffer"])
        risk = stop - entry
        if risk <= 0:
            return None
        return Signal(
            strategy_id=params["strategy_id"],
            symbol=params["symbol"],
            side="sell",
            entry=entry,
            stop=stop,
            take_profit=entry - risk * params["reward_risk_ratio"],
            reason="BTC 15m Phase Vacuum Reclaim: SMA96/SMA384 phase에서 2봉 저가 reclaim",
            leverage=params["leverage"],
        )
    return None


def pulse_stop_price(side: str, mode: int, latest: Candle, entry: Decimal, fast_mean: Decimal, atr: Decimal, buffer: Decimal) -> Decimal:
    if side == "buy" and mode == 1:
        return latest.low - atr * buffer
    if side == "sell" and mode == 1:
        return latest.high + atr * buffer
    if side == "buy" and mode == 2:
        return entry - atr * buffer
    if side == "sell" and mode == 2:
        return entry + atr * buffer
    if side == "buy":
        return min(latest.low, fast_mean - atr * buffer)
    return max(latest.high, fast_mean + atr * buffer)


def evaluate_vacuum_pulse(candles: list[Candle], params: dict[str, Any], generated_at: datetime) -> Signal | None:
    if not allowed_weekday(params["weekday_mask"], generated_at):
        return None
    if (
        len(candles) < params["slow_mean_period"]
        or len(candles) < params["reclaim_lookback"] + 1
        or len(candles) <= params["return_lookback"]
    ):
        return None

    fast_mean = simple_moving_average(candles, params["fast_mean_period"])
    slow_mean = simple_moving_average(candles, params["slow_mean_period"])
    atr = average_true_range(candles, params["atr_period"])
    avg_volume = average_volume(candles, params["volume_lookback"])
    previous_high = highest_high(candles, params["reclaim_lookback"], len(candles) - 2)
    previous_low = lowest_low(candles, params["reclaim_lookback"], len(candles) - 2)
    if None in {fast_mean, slow_mean, atr, avg_volume, previous_high, previous_low}:
        return None

    latest = candles[-1]
    base = candles[-1 - params["return_lookback"]]
    entry = latest.close
    candle_range = latest.high - latest.low
    if entry <= 0 or base.close <= 0 or candle_range <= 0 or atr <= 0 or avg_volume <= 0:
        return None
    if latest.volume < avg_volume * params["volume_multiplier"]:
        return None

    trend_spread = abs(fast_mean - slow_mean) / entry
    atr_percent = atr / entry
    close_location = (latest.close - latest.low) / candle_range
    return_value = (latest.close - base.close) / base.close
    if not (params["minimum_trend_spread"] <= trend_spread <= params["maximum_trend_spread"]):
        return None
    if not (params["minimum_atr_percent"] <= atr_percent <= params["maximum_atr_percent"]):
        return None

    allows_long = params["side_mode"] >= 0
    allows_short = params["side_mode"] <= 0
    if (
        allows_long
        and fast_mean > slow_mean
        and return_value >= params["return_threshold"]
        and latest.low <= fast_mean + atr * params["pullback_atr_buffer"]
        and latest.close > fast_mean
        and latest.close > previous_high + atr * params["breakout_atr_buffer"]
        and latest.close > latest.open
        and close_location >= params["minimum_close_location"]
    ):
        stop = pulse_stop_price("buy", params["stop_mode"], latest, entry, fast_mean, atr, params["stop_atr_buffer"])
        risk = entry - stop
        if risk <= 0 or not stop_percent_allowed(params, risk, entry):
            return None
        return Signal(
            strategy_id=params["strategy_id"],
            symbol=params["symbol"],
            side="buy",
            entry=entry,
            stop=stop,
            take_profit=entry + risk * params["reward_risk_ratio"],
            reason=f"{params['name']}: SMA{params['fast_mean_period']}/SMA{params['slow_mean_period']} 상승 phase reclaim",
            leverage=params["leverage"],
        )

    if (
        allows_short
        and fast_mean < slow_mean
        and return_value <= -params["return_threshold"]
        and latest.high >= fast_mean - atr * params["pullback_atr_buffer"]
        and latest.close < fast_mean
        and latest.close < previous_low - atr * params["breakout_atr_buffer"]
        and latest.close < latest.open
        and close_location <= dec(1) - params["minimum_close_location"]
    ):
        stop = pulse_stop_price("sell", params["stop_mode"], latest, entry, fast_mean, atr, params["stop_atr_buffer"])
        risk = stop - entry
        if risk <= 0 or not stop_percent_allowed(params, risk, entry):
            return None
        return Signal(
            strategy_id=params["strategy_id"],
            symbol=params["symbol"],
            side="sell",
            entry=entry,
            stop=stop,
            take_profit=entry - risk * params["reward_risk_ratio"],
            reason=f"{params['name']}: SMA{params['fast_mean_period']}/SMA{params['slow_mean_period']} 하락 phase reclaim",
            leverage=params["leverage"],
        )

    return None


def evaluate_strategy(candles: list[Candle], params: dict[str, Any], generated_at: datetime) -> Signal | None:
    if params["strategy_id"] == BTC_PHASE_PARAMS["strategy_id"]:
        signal = evaluate_btc_phase(candles, params, generated_at)
    else:
        signal = evaluate_vacuum_pulse(candles, params, generated_at)
    if signal and risk_allowed(signal):
        return signal
    return None


class PaperRunner:
    def __init__(self) -> None:
        self.data_dir = Path(os.environ.get("BUCKS_COPY_DATA_DIR", "/var/lib/bucks-copy"))
        self.symbols = self.parse_symbols(os.environ.get("BUCKS_COPY_SYMBOLS", "BTCUSDT,ETHUSDT"))
        self.candle_limit = min(max(int(os.environ.get("BUCKS_COPY_CANDLE_LIMIT", "500")), 1), 1000)
        self.poll_seconds = max(int(os.environ.get("BUCKS_COPY_POLL_SECONDS", "30")), 5)
        self.base_url = os.environ.get("BUCKS_COPY_BITGET_BASE_URL", DEFAULT_BASE_URL).rstrip("/")
        self.run_once = parse_bool(os.environ.get("BUCKS_COPY_RUN_ONCE"))
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.evaluated_keys = self.load_evaluated_keys()

    @staticmethod
    def parse_symbols(value: str) -> list[str]:
        symbols = [symbol.strip().upper() for symbol in value.split(",") if symbol.strip()]
        if not symbols:
            raise ValueError("BUCKS_COPY_SYMBOLS must include at least one symbol.")
        return symbols

    def fetch_candles(self, symbol: str) -> list[Candle]:
        params = {
            "granularity": TIMEFRAME,
            "limit": str(self.candle_limit),
            "productType": PRODUCT_TYPE,
            "symbol": symbol,
        }
        url = f"{self.base_url}/api/v2/mix/market/candles?{urlencode(sorted(params.items()))}"
        request = Request(
            url,
            headers={
                "Content-Type": "application/json",
                "locale": "en-US",
                "User-Agent": "BucksCopyPaperRunner/1.0",
            },
            method="GET",
        )
        with urlopen(request, timeout=20, context=ssl_context()) as response:
            body = response.read()
        decoded = json.loads(body.decode("utf-8"))
        if decoded.get("code") != "00000":
            raise RuntimeError(f"Bitget API {decoded.get('code')}: {decoded.get('msg')}")
        received_at = int(time.time())
        candles: list[Candle] = []
        for row in decoded.get("data", []):
            if len(row) < 6:
                continue
            open_time = int(dec(row[0]) / dec(1000))
            candles.append(
                Candle(
                    symbol=symbol,
                    open_time=open_time,
                    open=dec(row[1]),
                    high=dec(row[2]),
                    low=dec(row[3]),
                    close=dec(row[4]),
                    volume=dec(row[5]),
                    is_closed=open_time + TIMEFRAME_SECONDS <= received_at,
                )
            )
        return sorted(candles, key=lambda candle: candle.open_time)

    def candles_path(self, symbol: str) -> Path:
        return self.data_dir / f"candles-{symbol}-{TIMEFRAME}.json"

    def load_candles(self, symbol: str) -> list[Candle]:
        path = self.candles_path(symbol)
        if not path.exists():
            return []
        records = json.loads(path.read_text(encoding="utf-8"))
        return sorted((Candle.from_record(record) for record in records), key=lambda candle: candle.open_time)

    def save_candles(self, symbol: str, candles: list[Candle]) -> None:
        records = [candle.to_record() for candle in sorted(candles, key=lambda candle: candle.open_time)]
        self.atomic_write_json(self.candles_path(symbol), records, pretty=True)

    def upsert_candles(self, symbol: str, incoming: list[Candle]) -> list[Candle]:
        merged = {candle.key: candle for candle in self.load_candles(symbol)}
        for candle in incoming:
            merged[candle.key] = candle
        candles = sorted(merged.values(), key=lambda candle: candle.open_time)
        self.save_candles(symbol, candles)
        return candles[-self.candle_limit :]

    def load_evaluated_keys(self) -> set[str]:
        path = self.data_dir / "paper-runner-evaluations.jsonl"
        if not path.exists():
            return set()
        keys: set[str] = set()
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                record = json.loads(line)
                key = record.get("evaluationKey")
                if key:
                    keys.add(str(key))
            except json.JSONDecodeError:
                continue
        return keys

    def has_evaluated(self, key: str) -> bool:
        return key in self.evaluated_keys

    def mark_evaluated(self, key: str, symbol: str, strategy_id: str, open_time: int, produced_signal: bool, evaluated_at: datetime) -> None:
        if key in self.evaluated_keys:
            return
        self.evaluated_keys.add(key)
        self.append_jsonl(
            self.data_dir / "paper-runner-evaluations.jsonl",
            {
                "evaluationKey": key,
                "symbol": symbol,
                "timeframe": TIMEFRAME,
                "strategyID": strategy_id,
                "candleOpenTime": open_time,
                "candleOpenTimeISO": open_time_iso(open_time),
                "producedSignal": produced_signal,
                "evaluatedAt": iso(evaluated_at),
            },
        )

    def append_jsonl(self, path: Path, record: dict[str, Any]) -> None:
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
            handle.write("\n")

    def atomic_write_json(self, path: Path, record: Any, pretty: bool = False) -> None:
        tmp_path = path.with_suffix(path.suffix + ".tmp")
        text = json.dumps(
            record,
            ensure_ascii=False,
            sort_keys=True,
            indent=2 if pretty else None,
            separators=None if pretty else (",", ":"),
        )
        tmp_path.write_text(text + "\n", encoding="utf-8")
        tmp_path.replace(path)

    def record_signal(self, signal: Signal, candle_open_time: int, generated_at: datetime) -> None:
        ratio = signal.reward_risk_ratio
        self.append_jsonl(
            self.data_dir / "trade-event-logs.jsonl",
            {
                "id": str(uuid.uuid4()),
                "timestamp": iso(generated_at),
                "category": "signal",
                "severity": "info",
                "symbol": signal.symbol,
                "message": (
                    f"Paper signal generated by {signal.strategy_id} on {TIMEFRAME}. "
                    f"Side {signal.side}, entry {decimal_text(signal.entry)}, "
                    f"stop {decimal_text(signal.stop)}, TP1 {decimal_text(signal.partial_take_profit)}, "
                    f"TP2 {decimal_text(signal.take_profit)}. Reason: {signal.reason}. "
                    "No live order was submitted."
                ),
                "metadata": {
                    "title": f"{signal.symbol} {TIMEFRAME} paper signal",
                    "subtitle": f"{signal.strategy_id} 전략이 closed 15m candle 기준 paper 후보를 만들었습니다. 실주문은 전송하지 않았습니다.",
                    "tags": ["PAPER", TIMEFRAME, signal.side.upper(), signal.strategy_id],
                    "details": {
                        "strategyID": signal.strategy_id,
                        "timeframe": TIMEFRAME,
                        "symbol": signal.symbol,
                        "side": signal.side,
                        "candleOpenTime": candle_open_time,
                        "entry": decimal_text(signal.entry),
                        "stopLoss": decimal_text(signal.stop),
                        "partialTakeProfit": decimal_text(signal.partial_take_profit),
                        "takeProfit": decimal_text(signal.take_profit),
                        "profitLockStopLossAfterPartialTakeProfit": decimal_text(signal.profit_lock_stop),
                        "plannedRewardRiskRatio": decimal_text(ratio) if ratio else "-",
                        "leverage": f"{signal.leverage}x",
                        "mode": "paper-only",
                        "reason": signal.reason,
                    },
                },
            },
        )

    def maybe_record_heartbeat(self, status: dict[str, Any], started_at: datetime, updated_at: datetime) -> None:
        path = self.data_dir / "paper-runner-heartbeat.json"
        if path.exists():
            try:
                previous = json.loads(path.read_text(encoding="utf-8"))
                logged_at = datetime.fromisoformat(str(previous["loggedAt"]).replace("Z", "+00:00"))
                if (updated_at - logged_at).total_seconds() < 15 * 60:
                    return
            except (KeyError, ValueError, json.JSONDecodeError):
                pass

        elapsed = max((updated_at - started_at).total_seconds(), 0)
        self.append_jsonl(
            self.data_dir / "trade-event-logs.jsonl",
            {
                "id": str(uuid.uuid4()),
                "timestamp": iso(updated_at),
                "category": "automation",
                "severity": "info" if not status["failures"] else "warning",
                "symbol": None,
                "message": (
                    f"Paper runner heartbeat. Symbols {','.join(status['symbols'])}, "
                    f"saved candles {status['savedCandles']}, evaluations {status['evaluations']}, "
                    f"signals {status['signals']}, failures {len(status['failures'])}, "
                    f"elapsed {elapsed:.2f}s. No live orders enabled."
                ),
                "metadata": {
                    "title": "Paper runner heartbeat",
                    "subtitle": "서버 runner가 15m closed candle 기준 paper 평가를 수행했습니다.",
                    "tags": ["PAPER", TIMEFRAME, "OK" if not status["failures"] else "CHECK"],
                    "details": {
                        "symbols": ",".join(status["symbols"]),
                        "savedCandles": str(status["savedCandles"]),
                        "evaluations": str(status["evaluations"]),
                        "signals": str(status["signals"]),
                        "failures": str(len(status["failures"])),
                        "storagePath": str(self.data_dir),
                    },
                },
            },
        )
        self.atomic_write_json(path, {"loggedAt": iso(updated_at)})

    def run_once_cycle(self) -> None:
        started_at = now_utc()
        saved_candles = 0
        evaluations = 0
        signals = 0
        failures: list[str] = []
        latest_closed_open_time: int | None = None

        for symbol in self.symbols:
            try:
                remote_candles = self.fetch_candles(symbol)
                stored_candles = self.upsert_candles(symbol, remote_candles)
                saved_candles += len(remote_candles)
                closed_candles = [candle for candle in stored_candles if candle.is_closed]
                if not closed_candles:
                    failures.append(f"{symbol}: no closed 15m candle available")
                    continue
                latest_closed = closed_candles[-1]
                latest_closed_open_time = max(latest_closed_open_time or latest_closed.open_time, latest_closed.open_time)

                for params in ACTIVE_STRATEGIES_BY_SYMBOL.get(symbol, []):
                    strategy_id = params["strategy_id"]
                    key = f"{symbol}:{TIMEFRAME}:{strategy_id}:{latest_closed.open_time}"
                    if self.has_evaluated(key):
                        continue
                    evaluations += 1
                    evaluated_at = now_utc()
                    try:
                        signal = evaluate_strategy(closed_candles, params, evaluated_at)
                        if signal:
                            signals += 1
                            self.record_signal(signal, latest_closed.open_time, evaluated_at)
                        self.mark_evaluated(key, symbol, strategy_id, latest_closed.open_time, signal is not None, evaluated_at)
                    except Exception as error:
                        failures.append(f"{symbol} {strategy_id}: {error}")
            except Exception as error:
                failures.append(f"{symbol}: {error}")

        updated_at = now_utc()
        status = {
            "updatedAt": iso(updated_at),
            "mode": "paper",
            "symbols": self.symbols,
            "latestClosedCandleOpenTime": latest_closed_open_time,
            "latestClosedCandleOpenTimeISO": open_time_iso(latest_closed_open_time) if latest_closed_open_time else None,
            "savedCandles": saved_candles,
            "evaluations": evaluations,
            "signals": signals,
            "failures": failures,
            "storagePath": str(self.data_dir),
        }
        self.atomic_write_json(self.data_dir / "paper-runner-status.json", status, pretty=True)
        self.maybe_record_heartbeat(status, started_at, updated_at)
        latest_text = str(latest_closed_open_time) if latest_closed_open_time else "-"
        status_text = "ok" if not failures else "check"
        print(
            f"[{iso(updated_at)}] paper-runner={status_text} "
            f"symbols={','.join(self.symbols)} latestClosed={latest_text} "
            f"saved={saved_candles} evaluations={evaluations} signals={signals} failures={len(failures)}",
            flush=True,
        )

    def run(self) -> None:
        while True:
            self.run_once_cycle()
            if self.run_once:
                return
            time.sleep(self.poll_seconds)


def main() -> None:
    try:
        PaperRunner().run()
    except KeyboardInterrupt:
        return
    except Exception as error:
        print(f"BucksCopyPaperRunner fatal: {type(error).__name__}: {error}", flush=True)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
