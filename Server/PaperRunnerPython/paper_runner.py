#!/usr/bin/env python3
from __future__ import annotations

import json
import base64
import hashlib
import hmac
import os
import re
import secrets
import ssl
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, ROUND_DOWN, ROUND_UP, getcontext
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import Request, urlopen

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    AESGCM = None

getcontext().prec = 34

TIMEFRAME = "15m"
TIMEFRAME_SECONDS = 15 * 60
PRODUCT_TYPE = "USDT-FUTURES"
DEFAULT_BASE_URL = "https://api.bitget.com"
DEFAULT_API_HOST = "0.0.0.0"
DEFAULT_API_PORT = 8787
DEFAULT_USER_ID = "local-admin"
DEFAULT_CANDLE_STORAGE_LIMIT = 0
MAX_CANDLE_FETCH_LIMIT = 1_000
USER_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,80}$")
CREDENTIAL_ENCRYPTION_ALGORITHM = "AES-256-GCM"
WEB_ACCESS_COOKIE_NAME = "bucks_copy_web_access"
DEFAULT_WEB_ACCESS_SESSION_SECONDS = 12 * 60 * 60
OWNER_WEB_ACCESS_PROFILE_ID = "owner"


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


def clamp_int(value: str | None, default: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value) if value is not None else default
    except ValueError:
        parsed = default
    return min(max(parsed, minimum), maximum)


def parse_decimal_env(value: str | None, default: Decimal = Decimal("0")) -> Decimal:
    if value is None or not value.strip():
        return default
    try:
        return Decimal(value.strip())
    except Exception:
        return default


def validate_user_id(value: str) -> str:
    user_id = value.strip()
    if not USER_ID_PATTERN.fullmatch(user_id):
        raise ValueError("userID must contain only letters, numbers, dot, underscore, or hyphen.")
    return user_id


def redacted_identifier(value: str) -> str:
    text = value.strip()
    if len(text) <= 8:
        return "****"
    return f"{text[:4]}...{text[-4:]}"


def form_decode(value: str) -> str:
    return parse_qs(value, keep_blank_values=True).get("accessKey", [""])[0]


def bitget_signature(
    timestamp: str,
    method: str,
    request_path: str,
    query_string: str,
    body: str,
    secret_key: str,
) -> str:
    normalized_query = f"?{query_string}" if query_string else ""
    message = f"{timestamp}{method.upper()}{request_path}{normalized_query}{body}"
    digest = hmac.new(secret_key.encode("utf-8"), message.encode("utf-8"), hashlib.sha256).digest()
    return base64.b64encode(digest).decode("ascii")


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


def read_json_file(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return default


def encryption_key_from_env(value: str | None) -> bytes | None:
    if value is None or not value.strip():
        return None
    text = value.strip()
    try:
        padded = text + "=" * (-len(text) % 4)
        decoded = base64.urlsafe_b64decode(padded.encode("ascii"))
        if len(decoded) == 32:
            return decoded
    except Exception:
        pass
    if len(text) < 32:
        raise ValueError("BUCKS_COPY_CREDENTIAL_ENCRYPTION_KEY must be at least 32 characters.")
    return hashlib.sha256(text.encode("utf-8")).digest()


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
class BitgetCredential:
    api_key: str
    secret_key: str
    passphrase: str

    @property
    def redacted_identifier(self) -> str:
        return redacted_identifier(self.api_key)


@dataclass(frozen=True)
class WebAccessProfile:
    profile_id: str
    name: str
    access_key: str
    allowed_strategy_ids: tuple[str, ...]

    @property
    def allows_all_strategies(self) -> bool:
        return "*" in self.allowed_strategy_ids

    def public_record(self, active_strategy_ids: list[str]) -> dict[str, Any]:
        allowed = active_strategy_ids if self.allows_all_strategies else [
            strategy_id for strategy_id in active_strategy_ids if strategy_id in set(self.allowed_strategy_ids)
        ]
        return {
            "profileID": self.profile_id,
            "name": self.name,
            "allowedStrategyIDs": allowed,
            "allowsAllStrategies": self.allows_all_strategies,
        }


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

BTC_REGIME_SESSION_FADE_PARAMS = {
    "strategy_id": "btc-15m-regime-session-fade",
    "name": "BTC 15m Regime Session Fade",
    "symbol": "BTCUSDT",
    "lookback": 8,
    "threshold": dec("0.005"),
    "stop_percent": dec("0.006"),
    "reward_risk_ratio": dec("3.0"),
    "trend_ema_period": 192,
    "macro_ma_period": 200,
    "macro_slope_days": 60,
    "macro_return_days": 90,
    "bull_return_threshold": dec("0.05"),
    "bear_return_threshold": dec("-0.03"),
    "bear_drawdown_threshold": dec("0.25"),
    "near_high_drawdown_threshold": dec("-0.05"),
    "low_atr_percent_threshold": dec("0.004"),
    "atr_period": 14,
    "maximum_holding_candles": 12,
    "leverage": 10,
}

BTC_BULL_PULLBACK_LONG_PARAMS = {
    "strategy_id": "btc-15m-bull-pullback-long",
    "name": "BTC 15m Bull Pullback Long",
    "symbol": "BTCUSDT",
    "lookback": 8,
    "threshold": dec("0.005"),
    "stop_percent": dec("0.006"),
    "tight_reward_risk_ratio": dec("2.2"),
    "loose_reward_risk_ratio": dec("3.5"),
    "loose_drawdown_threshold": dec("-0.02"),
    "trend_ema_period": 192,
    "macro_ma_period": 200,
    "macro_slope_days": 60,
    "macro_return_days": 90,
    "bull_return_threshold": dec("0.05"),
    "maximum_holding_candles": 12,
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
    "BTCUSDT": [
        BTC_PULSE_PARAMS,
        BTC_REGIME_SESSION_FADE_PARAMS,
        BTC_BULL_PULLBACK_LONG_PARAMS,
    ],
    "ETHUSDT": [ETH_PULSE_PARAMS],
}

DEFAULT_OWNER_STRATEGY_IDS = (
    BTC_PULSE_PARAMS["strategy_id"],
    BTC_REGIME_SESSION_FADE_PARAMS["strategy_id"],
    BTC_BULL_PULLBACK_LONG_PARAMS["strategy_id"],
    ETH_PULSE_PARAMS["strategy_id"],
)

STRATEGY_BACKTESTS = {
    "btc-15m-vacuum-pulse": {
        "label": "최근 4년 · 공식 러너 · 10x · 5% risk",
        "period": "2022-05-24 03:00 ~ 2026-05-24 03:00 UTC",
        "source": "paper_runner.evaluate_strategy",
        "initialCapital": "100",
        "finalBalance": "734.03",
        "netReturnPercent": "+634.03",
        "winRatePercent": "50.64",
        "maxDrawdownPercent": "33.77",
        "profitFactor": "1.51",
        "totalTrades": 156,
        "annualTrades": "39.0",
        "tp1Count": 79,
        "tp2Count": 33,
        "profitLockStopCount": 46,
        "pureStopCount": 77,
        "timeExitCount": 0,
        "robustness": "낮음",
        "robustnessCode": "LOWER",
        "robustnessNote": "4개 연도 모두 플러스, 반기 6/8 플러스, 최악 반기 -4.41%.",
    },
    "btc-15m-regime-session-fade": {
        "label": "최근 4년 · 공식 러너 · 10x · 5% risk",
        "period": "2022-05-24 03:00 ~ 2026-05-24 03:00 UTC",
        "source": "paper_runner.evaluate_strategy",
        "initialCapital": "100",
        "finalBalance": "854601.14",
        "netReturnPercent": "+854501.14",
        "winRatePercent": "59.20",
        "maxDrawdownPercent": "33.16",
        "profitFactor": "1.77",
        "totalTrades": 696,
        "annualTrades": "174.0",
        "tp1Count": 279,
        "tp2Count": 93,
        "profitLockStopCount": 118,
        "pureStopCount": 206,
        "timeExitCount": 279,
        "robustness": "중간",
        "robustnessCode": "MEDIUM",
        "robustnessNote": "4개 연도/8개 반기 모두 플러스. 단, 극단적 복리 결과라 forward 검증 필요.",
    },
    "btc-15m-bull-pullback-long": {
        "label": "최근 4년 · 공식 러너 · 10x · 5% risk",
        "period": "2022-05-24 03:00 ~ 2026-05-24 03:00 UTC",
        "source": "paper_runner.evaluate_strategy",
        "initialCapital": "100",
        "finalBalance": "2154.93",
        "netReturnPercent": "+2054.93",
        "winRatePercent": "68.21",
        "maxDrawdownPercent": "21.91",
        "profitFactor": "2.66",
        "totalTrades": 173,
        "annualTrades": "43.3",
        "tp1Count": 56,
        "tp2Count": 18,
        "profitLockStopCount": 22,
        "pureStopCount": 33,
        "timeExitCount": 100,
        "robustness": "낮음",
        "robustnessCode": "LOWER",
        "robustnessNote": "4개 연도 모두 플러스, 반기 6/8 플러스, MDD 21.91%.",
    },
    "eth-15m-vacuum-pulse": {
        "label": "최근 4년 · 공식 러너 · 10x · 5% risk",
        "period": "2022-05-24 03:00 ~ 2026-05-24 03:00 UTC",
        "source": "paper_runner.evaluate_strategy",
        "initialCapital": "100",
        "finalBalance": "630.27",
        "netReturnPercent": "+530.27",
        "winRatePercent": "49.14",
        "maxDrawdownPercent": "22.00",
        "profitFactor": "1.47",
        "totalTrades": 116,
        "annualTrades": "29.0",
        "tp1Count": 57,
        "tp2Count": 22,
        "profitLockStopCount": 35,
        "pureStopCount": 59,
        "timeExitCount": 0,
        "robustness": "낮음",
        "robustnessCode": "LOWER",
        "robustnessNote": "4개 연도 모두 플러스, 반기 7/8 플러스, 최악 반기 -9.73%.",
    },
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


def exponential_moving_average(candles: list[Candle], period: int) -> Decimal | None:
    if period <= 0 or len(candles) < period:
        return None
    current = sum((c.close for c in candles[:period]), dec(0)) / dec(period)
    alpha = dec(2) / dec(period + 1)
    for candle in candles[period:]:
        current = candle.close * alpha + current * (dec(1) - alpha)
    return current


def daily_closes(candles: list[Candle]) -> list[tuple[int, Decimal]]:
    output: list[tuple[int, Decimal]] = []
    for candle in candles:
        day = candle.open_time // 86_400
        if output and output[-1][0] == day:
            output[-1] = (day, candle.close)
        else:
            output.append((day, candle.close))
    return output


def daily_sma(days: list[tuple[int, Decimal]], period: int, ending_at: int) -> Decimal | None:
    if period <= 0 or ending_at < 0 or ending_at >= len(days) or ending_at - period + 1 < 0:
        return None
    return sum((close for _, close in days[ending_at - period + 1 : ending_at + 1]), dec(0)) / dec(period)


def btc_macro_snapshot(
    candles: list[Candle],
    ma_period: int,
    slope_days: int,
    return_days: int,
    bull_return_threshold: Decimal,
    bear_return_threshold: Decimal,
    bear_drawdown_threshold: Decimal,
) -> dict[str, Any]:
    days = daily_closes(candles)
    if not candles or len(days) < 2:
        return {"regime": 0, "drawdown": None}
    current_day = candles[-1].open_time // 86_400
    current_index = next((index for index, item in enumerate(days) if item[0] == current_day), len(days) - 1)
    if current_index <= 0:
        return {"regime": 0, "drawdown": None}

    previous_index = current_index - 1
    previous_close = days[previous_index][1]
    rolling_high = max(close for _, close in days[: previous_index + 1])
    drawdown = previous_close / rolling_high - dec(1) if rolling_high > 0 else dec(0)

    previous_ma = daily_sma(days, ma_period, previous_index)
    prior_ma = daily_sma(days, ma_period, previous_index - slope_days)
    if (
        previous_ma is None
        or prior_ma is None
        or previous_index - return_days < 0
        or prior_ma <= 0
        or previous_ma <= 0
        or days[previous_index - return_days][1] <= 0
    ):
        return {"regime": 0, "drawdown": drawdown}

    slope = previous_ma / prior_ma - dec(1)
    period_return = previous_close / days[previous_index - return_days][1] - dec(1)
    if previous_close >= previous_ma and slope > 0 and period_return >= bull_return_threshold:
        regime = 1
    elif previous_close <= previous_ma and (
        slope < 0 or period_return <= bear_return_threshold or drawdown <= -bear_drawdown_threshold
    ):
        regime = -1
    else:
        regime = 0
    return {
        "regime": regime,
        "drawdown": drawdown,
        "periodReturn": period_return,
        "slope": slope,
    }


class StrategyEvaluationContext:
    """Precomputed indicators for historical evaluation.

    Live execution calls the same strategy functions without this context. Long
    backtests pass it in so those functions do not recalculate EMA/ATR/macro
    history from the first candle on every step.
    """

    def __init__(self, candles: list[Candle]):
        self.candles = candles
        self.close_prefix = self._prefix([candle.close for candle in candles])
        self.volume_prefix = self._prefix([candle.volume for candle in candles])
        self.true_range_prefix = self._true_range_prefix(candles)
        self.ema_by_period: dict[int, list[Decimal | None]] = {}
        self.day_index_by_candle: list[int] = []
        self.days: list[tuple[int, Decimal]] = []
        for candle in candles:
            day = candle.open_time // 86_400
            if self.days and self.days[-1][0] == day:
                self.days[-1] = (day, candle.close)
            else:
                self.days.append((day, candle.close))
            self.day_index_by_candle.append(len(self.days) - 1)
        self.daily_close_prefix = self._prefix([close for _, close in self.days])
        self.daily_rolling_high: list[Decimal] = []
        high = dec(0)
        for _, close in self.days:
            high = max(high, close)
            self.daily_rolling_high.append(high)

    @staticmethod
    def _prefix(values: list[Decimal]) -> list[Decimal]:
        output = [dec(0)]
        total = dec(0)
        for value in values:
            total += value
            output.append(total)
        return output

    @staticmethod
    def _range_sum(prefix: list[Decimal], start: int, end: int) -> Decimal:
        return prefix[end + 1] - prefix[start]

    @classmethod
    def _true_range_prefix(cls, candles: list[Candle]) -> list[Decimal]:
        ranges = [dec(0)]
        total = dec(0)
        for index, candle in enumerate(candles):
            if index == 0:
                ranges.append(total)
                continue
            previous_close = candles[index - 1].close
            total += max(candle.high - candle.low, abs(candle.high - previous_close), abs(candle.low - previous_close))
            ranges.append(total)
        return ranges

    def simple_moving_average(self, period: int, ending_at: int) -> Decimal | None:
        if period <= 0 or ending_at < 0 or ending_at >= len(self.candles) or ending_at - period + 1 < 0:
            return None
        return self._range_sum(self.close_prefix, ending_at - period + 1, ending_at) / dec(period)

    def average_volume(self, period: int, ending_at: int) -> Decimal | None:
        if period <= 0 or ending_at < 0 or ending_at >= len(self.candles) or ending_at - period + 1 < 0:
            return None
        return self._range_sum(self.volume_prefix, ending_at - period + 1, ending_at) / dec(period)

    def average_true_range(self, period: int, ending_at: int) -> Decimal | None:
        if period <= 0 or ending_at <= 0 or ending_at >= len(self.candles) or ending_at - period + 1 <= 0:
            return None
        return self._range_sum(self.true_range_prefix, ending_at - period + 1, ending_at) / dec(period)

    def exponential_moving_average(self, period: int, ending_at: int) -> Decimal | None:
        if period <= 0 or ending_at < period - 1 or ending_at >= len(self.candles):
            return None
        if period not in self.ema_by_period:
            values: list[Decimal | None] = [None] * len(self.candles)
            current = self._range_sum(self.close_prefix, 0, period - 1) / dec(period)
            values[period - 1] = current
            alpha = dec(2) / dec(period + 1)
            for index in range(period, len(self.candles)):
                current = self.candles[index].close * alpha + current * (dec(1) - alpha)
                values[index] = current
            self.ema_by_period[period] = values
        return self.ema_by_period[period][ending_at]

    def daily_sma(self, period: int, ending_at: int) -> Decimal | None:
        if period <= 0 or ending_at < 0 or ending_at >= len(self.days) or ending_at - period + 1 < 0:
            return None
        return self._range_sum(self.daily_close_prefix, ending_at - period + 1, ending_at) / dec(period)

    def btc_macro_snapshot(
        self,
        ending_at: int,
        ma_period: int,
        slope_days: int,
        return_days: int,
        bull_return_threshold: Decimal,
        bear_return_threshold: Decimal,
        bear_drawdown_threshold: Decimal,
    ) -> dict[str, Any]:
        if not self.candles or ending_at < 0 or ending_at >= len(self.candles) or len(self.days) < 2:
            return {"regime": 0, "drawdown": None}
        current_index = self.day_index_by_candle[ending_at]
        if current_index <= 0:
            return {"regime": 0, "drawdown": None}

        previous_index = current_index - 1
        previous_close = self.days[previous_index][1]
        rolling_high = self.daily_rolling_high[previous_index]
        drawdown = previous_close / rolling_high - dec(1) if rolling_high > 0 else dec(0)

        previous_ma = self.daily_sma(ma_period, previous_index)
        prior_ma = self.daily_sma(ma_period, previous_index - slope_days)
        if (
            previous_ma is None
            or prior_ma is None
            or previous_index - return_days < 0
            or prior_ma <= 0
            or previous_ma <= 0
            or self.days[previous_index - return_days][1] <= 0
        ):
            return {"regime": 0, "drawdown": drawdown}

        slope = previous_ma / prior_ma - dec(1)
        period_return = previous_close / self.days[previous_index - return_days][1] - dec(1)
        if previous_close >= previous_ma and slope > 0 and period_return >= bull_return_threshold:
            regime = 1
        elif previous_close <= previous_ma and (
            slope < 0 or period_return <= bear_return_threshold or drawdown <= -bear_drawdown_threshold
        ):
            regime = -1
        else:
            regime = 0
        return {
            "regime": regime,
            "drawdown": drawdown,
            "periodReturn": period_return,
            "slope": slope,
        }


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


def evaluate_btc_phase(
    candles: list[Candle],
    params: dict[str, Any],
    generated_at: datetime,
    context: StrategyEvaluationContext | None = None,
) -> Signal | None:
    del generated_at
    if len(candles) < params["slow_mean_period"] or len(candles) < params["reclaim_lookback"] + 1:
        return None

    ending_at = len(candles) - 1
    fast_mean = context.simple_moving_average(params["fast_mean_period"], ending_at) if context else simple_moving_average(candles, params["fast_mean_period"])
    slow_mean = context.simple_moving_average(params["slow_mean_period"], ending_at) if context else simple_moving_average(candles, params["slow_mean_period"])
    atr = context.average_true_range(params["atr_period"], ending_at) if context else average_true_range(candles, params["atr_period"])
    avg_volume = context.average_volume(params["volume_lookback"], ending_at) if context else average_volume(candles, params["volume_lookback"])
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


def evaluate_vacuum_pulse(
    candles: list[Candle],
    params: dict[str, Any],
    generated_at: datetime,
    context: StrategyEvaluationContext | None = None,
) -> Signal | None:
    if not allowed_weekday(params["weekday_mask"], generated_at):
        return None
    if (
        len(candles) < params["slow_mean_period"]
        or len(candles) < params["reclaim_lookback"] + 1
        or len(candles) <= params["return_lookback"]
    ):
        return None

    ending_at = len(candles) - 1
    fast_mean = context.simple_moving_average(params["fast_mean_period"], ending_at) if context else simple_moving_average(candles, params["fast_mean_period"])
    slow_mean = context.simple_moving_average(params["slow_mean_period"], ending_at) if context else simple_moving_average(candles, params["slow_mean_period"])
    atr = context.average_true_range(params["atr_period"], ending_at) if context else average_true_range(candles, params["atr_period"])
    avg_volume = context.average_volume(params["volume_lookback"], ending_at) if context else average_volume(candles, params["volume_lookback"])
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


BTC_REGIME_BULL_HOURS = {
    128, 135, 140, 15, 144, 16, 150, 151,
    155, 163, 164, 165, 36, 48, 56, 59,
    71, 72, 84, 109, 111, 120, 122, 127,
}
BTC_REGIME_BEAR_HOURS = {
    137, 11, 12, 16, 145, 22, 154, 162,
    36, 165, 166, 38, 48, 54, 55, 63,
    75, 81, 95, 98, 100, 101, 110, 120,
}
BTC_REGIME_NEUTRAL_HOURS = {
    130, 132, 5, 135, 13, 146, 147, 148,
    18, 23, 30, 159, 162, 36, 165, 166,
    167, 53, 63, 65, 100, 108, 113, 114,
}
BTC_BULL_PULLBACK_HOURS = {
    128, 4, 135, 144, 19, 21, 150, 151,
    32, 164, 165, 59, 69, 70, 72, 81,
    105, 107, 109, 111, 112, 114, 122, 127,
}


def candle_week_hour(candle: Candle) -> int:
    dt = datetime.fromtimestamp(candle.open_time, timezone.utc)
    return dt.weekday() * 24 + dt.hour


def fixed_percent_signal(
    params: dict[str, Any],
    side: str,
    entry: Decimal,
    stop_percent: Decimal,
    reward_risk_ratio: Decimal,
    reason: str,
) -> Signal | None:
    if side == "buy":
        stop = entry * (dec(1) - stop_percent)
        take_profit = entry + (entry - stop) * reward_risk_ratio
    else:
        stop = entry * (dec(1) + stop_percent)
        take_profit = entry - (stop - entry) * reward_risk_ratio
    return Signal(
        strategy_id=params["strategy_id"],
        symbol=params["symbol"],
        side=side,
        entry=entry,
        stop=stop,
        take_profit=take_profit,
        reason=reason,
        leverage=params["leverage"],
    )


def evaluate_btc_regime_session_fade(
    candles: list[Candle],
    params: dict[str, Any],
    context: StrategyEvaluationContext | None = None,
) -> Signal | None:
    if len(candles) <= params["lookback"]:
        return None
    latest = candles[-1]
    ending_at = len(candles) - 1
    trend_ema = context.exponential_moving_average(params["trend_ema_period"], ending_at) if context else exponential_moving_average(candles, params["trend_ema_period"])
    atr = context.average_true_range(params["atr_period"], ending_at) if context else average_true_range(candles, params["atr_period"])
    if trend_ema is None or atr is None or latest.close <= 0:
        return None

    macro = (
        context.btc_macro_snapshot(
            ending_at,
            params["macro_ma_period"],
            params["macro_slope_days"],
            params["macro_return_days"],
            params["bull_return_threshold"],
            params["bear_return_threshold"],
            params["bear_drawdown_threshold"],
        )
        if context
        else btc_macro_snapshot(
            candles,
            params["macro_ma_period"],
            params["macro_slope_days"],
            params["macro_return_days"],
            params["bull_return_threshold"],
            params["bear_return_threshold"],
            params["bear_drawdown_threshold"],
        )
    )
    regime = int(macro.get("regime", 0))
    allowed_hours = BTC_REGIME_BULL_HOURS if regime == 1 else BTC_REGIME_BEAR_HOURS if regime == -1 else BTC_REGIME_NEUTRAL_HOURS
    if candle_week_hour(latest) not in allowed_hours:
        return None

    drawdown = macro.get("drawdown")
    atr_percent = atr / latest.close
    if (
        isinstance(drawdown, Decimal)
        and drawdown >= params["near_high_drawdown_threshold"]
        and atr_percent <= params["low_atr_percent_threshold"]
    ):
        return None

    base = candles[-1 - params["lookback"]]
    if base.close <= 0:
        return None
    return_value = latest.close / base.close - dec(1)
    if abs(return_value) < params["threshold"]:
        return None
    side = "sell" if return_value > 0 else "buy"
    trend_side = "buy" if latest.close >= trend_ema else "sell"
    if side != trend_side:
        return None

    return fixed_percent_signal(
        params,
        side,
        latest.close,
        params["stop_percent"],
        params["reward_risk_ratio"],
        "BTC 15m Regime Session Fade: 장세별 허용 시간대에서 8봉 impulse를 EMA192 방향으로 fade",
    )


def evaluate_btc_bull_pullback_long(
    candles: list[Candle],
    params: dict[str, Any],
    context: StrategyEvaluationContext | None = None,
) -> Signal | None:
    if len(candles) <= params["lookback"]:
        return None
    latest = candles[-1]
    ending_at = len(candles) - 1
    trend_ema = context.exponential_moving_average(params["trend_ema_period"], ending_at) if context else exponential_moving_average(candles, params["trend_ema_period"])
    if trend_ema is None or latest.close <= 0:
        return None

    macro = (
        context.btc_macro_snapshot(
            ending_at,
            params["macro_ma_period"],
            params["macro_slope_days"],
            params["macro_return_days"],
            params["bull_return_threshold"],
            dec("-0.03"),
            dec("0.25"),
        )
        if context
        else btc_macro_snapshot(
            candles,
            params["macro_ma_period"],
            params["macro_slope_days"],
            params["macro_return_days"],
            params["bull_return_threshold"],
            dec("-0.03"),
            dec("0.25"),
        )
    )
    if int(macro.get("regime", 0)) != 1:
        return None
    if candle_week_hour(latest) not in BTC_BULL_PULLBACK_HOURS:
        return None
    if latest.close < trend_ema:
        return None

    base = candles[-1 - params["lookback"]]
    if base.close <= 0:
        return None
    return_value = latest.close / base.close - dec(1)
    if return_value > -params["threshold"]:
        return None

    drawdown = macro.get("drawdown")
    reward_risk_ratio = (
        params["loose_reward_risk_ratio"]
        if isinstance(drawdown, Decimal) and drawdown <= params["loose_drawdown_threshold"]
        else params["tight_reward_risk_ratio"]
    )
    return fixed_percent_signal(
        params,
        "buy",
        latest.close,
        params["stop_percent"],
        reward_risk_ratio,
        "BTC 15m Bull Pullback Long: 상승장 눌림 long, 고점 대비 눌림폭에 따라 TP 동적 조정",
    )


def evaluate_strategy(
    candles: list[Candle],
    params: dict[str, Any],
    generated_at: datetime,
    context: StrategyEvaluationContext | None = None,
) -> Signal | None:
    if params["strategy_id"] == BTC_PHASE_PARAMS["strategy_id"]:
        signal = evaluate_btc_phase(candles, params, generated_at, context)
    elif params["strategy_id"] == BTC_REGIME_SESSION_FADE_PARAMS["strategy_id"]:
        signal = evaluate_btc_regime_session_fade(candles, params, context)
    elif params["strategy_id"] == BTC_BULL_PULLBACK_LONG_PARAMS["strategy_id"]:
        signal = evaluate_btc_bull_pullback_long(candles, params, context)
    else:
        signal = evaluate_vacuum_pulse(candles, params, generated_at, context)
    if signal and risk_allowed(signal):
        return signal
    return None


class BitgetLoginError(Exception):
    pass


class LiveExecutionError(Exception):
    pass


class PaperRunnerAPIHandler(BaseHTTPRequestHandler):
    runner: "PaperRunner"

    def log_message(self, format: str, *args: Any) -> None:
        return

    def do_HEAD(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path in {"/", "/app"}:
            if not self.runner.web_access_gate_enabled:
                self.send_response(HTTPStatus.SERVICE_UNAVAILABLE.value)
            elif self.web_access_allowed():
                self.send_response(HTTPStatus.OK.value)
            else:
                self.send_response(HTTPStatus.UNAUTHORIZED.value)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        self.send_response(HTTPStatus.NOT_FOUND.value)
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path in {"/", "/app"}:
            if not self.runner.web_access_gate_enabled:
                self.write_html(self.web_access_not_configured_page(), HTTPStatus.SERVICE_UNAVAILABLE)
            elif self.web_access_allowed():
                self.write_html(self.web_app_shell())
            else:
                self.write_html(self.web_access_page(), HTTPStatus.UNAUTHORIZED)
            return

        if parsed.path == "/health":
            payload: dict[str, Any] = {
                "ok": True,
                "mode": "paper",
                "authRequired": self.runner.auth_required,
                "webAccessGateEnabled": self.runner.web_access_gate_enabled,
                "configuredUsers": len(self.runner.auth_tokens_by_user_id),
                "updatedAt": iso(now_utc()),
            }
            if not self.runner.auth_required:
                payload["control"] = self.runner.load_control(self.runner.default_user_id)
            self.write_json(payload)
            return

        action = self.route_action(parsed.path)
        if action is None:
            self.write_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
            return
        user_id = self.authorize_user()
        if user_id is None:
            return

        if action == "status":
            status = self.runner.load_status(user_id)
            status["control"] = self.runner.load_control(user_id)
            self.write_json(status)
            return
        if action == "control":
            self.write_json(self.runner.load_control(user_id))
            return
        if action == "strategies":
            self.write_json(self.runner.strategy_status(user_id))
            return
        if action == "logs":
            query = parse_qs(parsed.query)
            limit = clamp_int(query.get("limit", [None])[0], default=50, minimum=1, maximum=500)
            self.write_json({"items": self.runner.load_recent_logs(user_id, limit), "limit": limit})
            return
        if action == "candles":
            query = parse_qs(parsed.query)
            symbol = query.get("symbol", [""])[0].upper()
            raw_limit = str(query.get("limit", [None])[0] or "100").strip().lower()
            all_candles = raw_limit in {"0", "all", "full", "none", "unlimited"}
            limit = None if all_candles else clamp_int(raw_limit, default=100, minimum=1, maximum=1_000_000)
            before_raw = query.get("before", query.get("beforeOpenTime", [None]))[0]
            if symbol not in self.runner.symbols:
                self.write_json({"error": "symbol is not configured for this runner"}, HTTPStatus.BAD_REQUEST)
                return
            loaded_candles = self.runner.load_candles(symbol)
            end_index = len(loaded_candles)
            if before_raw not in {None, ""}:
                try:
                    before_open_time = int(str(before_raw))
                except ValueError:
                    self.write_json({"error": "before must be a candle openTime integer"}, HTTPStatus.BAD_REQUEST)
                    return
                for index, candle in enumerate(loaded_candles):
                    if candle.open_time >= before_open_time:
                        end_index = index
                        break
            start_index = 0 if limit is None else max(0, end_index - limit)
            selected_candles = loaded_candles[start_index:end_index]
            candles = [candle.to_record() for candle in selected_candles]
            oldest = selected_candles[0].open_time if selected_candles else None
            newest = selected_candles[-1].open_time if selected_candles else None
            self.write_json({
                "symbol": symbol,
                "timeframe": TIMEFRAME,
                "items": candles,
                "limit": limit or 0,
                "returned": len(candles),
                "totalAvailable": len(loaded_candles),
                "hasMoreBefore": start_index > 0,
                "hasMoreAfter": end_index < len(loaded_candles),
                "oldestOpenTime": oldest,
                "oldestOpenTimeISO": open_time_iso(oldest) if oldest else None,
                "newestOpenTime": newest,
                "newestOpenTimeISO": open_time_iso(newest) if newest else None,
            })
            return
        if action == "account":
            try:
                self.write_json({"items": self.runner.fetch_user_accounts(user_id)})
            except BitgetLoginError as error:
                self.write_json({"error": str(error)}, HTTPStatus.CONFLICT)
            return
        if action == "positions":
            try:
                self.write_json({"items": self.runner.fetch_user_positions(user_id)})
            except BitgetLoginError as error:
                self.write_json({"error": str(error)}, HTTPStatus.CONFLICT)
            return
        if action == "live/status":
            self.write_json(self.runner.live_status(user_id))
            return
        self.write_json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/web/access/login":
            self.handle_web_access_login()
            return
        if parsed.path == "/web/access/logout":
            self.handle_web_access_logout()
            return

        if parsed.path == "/auth/bitget/login":
            self.handle_bitget_login()
            return

        action = self.route_action(parsed.path)
        if action not in {"control", "live/control", "strategies"}:
            self.write_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
            return
        user_id = self.authorize_user()
        if user_id is None:
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        body = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError:
            self.write_json({"error": "invalid json body"}, HTTPStatus.BAD_REQUEST)
            return

        if action == "live/control":
            if "enabled" not in payload or not isinstance(payload["enabled"], bool):
                self.write_json({"error": "enabled boolean is required"}, HTTPStatus.BAD_REQUEST)
                return
            if payload["enabled"] and payload.get("acknowledgedRisk") is not True:
                self.write_json({"error": "acknowledgedRisk true is required to enable live trading"}, HTTPStatus.BAD_REQUEST)
                return
            self.write_json(self.runner.save_live_control(
                user_id,
                enabled=payload["enabled"],
                acknowledged_risk=bool(payload.get("acknowledgedRisk", False)),
                updated_by="api",
            ))
            return

        if action == "strategies":
            enabled_strategy_ids = payload.get("enabledStrategyIDs")
            if not isinstance(enabled_strategy_ids, list) or not all(isinstance(item, str) for item in enabled_strategy_ids):
                self.write_json({"error": "enabledStrategyIDs string array is required"}, HTTPStatus.BAD_REQUEST)
                return
            try:
                self.write_json(self.runner.save_strategy_selection(
                    user_id,
                    enabled_strategy_ids=enabled_strategy_ids,
                    updated_by="api",
                ))
            except ValueError as error:
                self.write_json({"error": str(error)}, HTTPStatus.BAD_REQUEST)
            return

        if "enabled" not in payload or not isinstance(payload["enabled"], bool):
            self.write_json({"error": "enabled boolean is required"}, HTTPStatus.BAD_REQUEST)
            return
        control = self.runner.save_control(user_id, payload["enabled"], updated_by="api")
        self.write_json(control)

    def handle_web_access_login(self) -> None:
        access_key = self.read_access_key()
        if not self.runner.web_access_gate_enabled:
            self.write_html(self.web_access_not_configured_page(), HTTPStatus.SERVICE_UNAVAILABLE)
            return
        profile = self.runner.web_access_profile_for_key(access_key)
        if profile is None:
            self.write_html(self.web_access_page(failed=True), HTTPStatus.UNAUTHORIZED)
            return

        token, expires_at = self.runner.issue_web_access_token(profile.profile_id)
        self.send_response(HTTPStatus.SEE_OTHER.value)
        self.send_header("Location", "/app")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Set-Cookie", self.runner.web_access_cookie_header(token, expires_at))
        self.end_headers()

    def handle_web_access_logout(self) -> None:
        self.send_response(HTTPStatus.SEE_OTHER.value)
        self.send_header("Location", "/")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Set-Cookie", self.runner.expired_web_access_cookie_header())
        self.end_headers()

    def do_DELETE(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path != "/users/me/session":
            self.write_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
            return
        user_id = self.authorize_user()
        if user_id is None:
            return
        self.runner.revoke_user_session(user_id)
        self.write_json({"ok": True, "revoked": True, "updatedAt": iso(now_utc())})

    def handle_bitget_login(self) -> None:
        try:
            payload = self.read_json_body()
        except ValueError as error:
            self.write_json({"error": str(error)}, HTTPStatus.BAD_REQUEST)
            return

        api_key = str(payload.get("apiKey", "")).strip()
        secret_key = str(payload.get("secretKey", "")).strip()
        passphrase = str(payload.get("passphrase", "")).strip()
        if not api_key or not secret_key or not passphrase:
            self.write_json({"error": "apiKey, secretKey, and passphrase are required"}, HTTPStatus.BAD_REQUEST)
            return

        try:
            self.write_json(self.runner.login_with_bitget(
                api_key,
                secret_key,
                passphrase,
                web_access_profile_id=self.web_access_profile_id(),
            ))
        except BitgetLoginError as error:
            self.write_json({"error": str(error)}, HTTPStatus.UNAUTHORIZED)
        except Exception:
            self.write_json({"error": "Bitget login failed"}, HTTPStatus.BAD_GATEWAY)

    def read_json_body(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        body = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError as error:
            raise ValueError("invalid json body") from error
        if not isinstance(payload, dict):
            raise ValueError("json object body is required")
        return payload

    def read_access_key(self) -> str:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        body = self.rfile.read(length) if length > 0 else b""
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type == "application/json":
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
            except json.JSONDecodeError:
                return ""
            return str(payload.get("accessKey", "")).strip() if isinstance(payload, dict) else ""
        return form_decode(body.decode("utf-8")).strip()

    def route_action(self, path: str) -> str | None:
        legacy_routes = {
            "/status": "status",
            "/control": "control",
            "/logs": "logs",
            "/candles": "candles",
        }
        if path in legacy_routes:
            return legacy_routes[path]

        prefix = "/users/me/"
        if not path.startswith(prefix):
            return None
        action = path[len(prefix) :]
        if action in {
            "status",
            "control",
            "strategies",
            "logs",
            "candles",
            "account",
            "positions",
            "live/status",
            "live/control",
        }:
            return action
        return None

    def authorize_user(self) -> str | None:
        header = self.headers.get("Authorization", "").strip()
        if header:
            scheme, _, token = header.partition(" ")
            if scheme.lower() == "bearer" and token:
                user_id = self.runner.user_id_for_token(token.strip())
                if user_id is not None:
                    return user_id
            self.write_json({"error": "unauthorized"}, HTTPStatus.UNAUTHORIZED)
            return None
        if self.runner.auth_required:
            self.write_json({"error": "authorization bearer token is required"}, HTTPStatus.UNAUTHORIZED)
            return None
        return self.runner.default_user_id

    def web_access_allowed(self) -> bool:
        if not self.runner.web_access_gate_enabled:
            return True
        cookies = self.headers.get("Cookie", "")
        token = self.runner.web_access_token_from_cookie(cookies)
        return token is not None and self.runner.web_access_token_valid(token)

    def web_access_profile_id(self) -> str | None:
        if not self.runner.web_access_gate_enabled:
            return OWNER_WEB_ACCESS_PROFILE_ID
        cookies = self.headers.get("Cookie", "")
        token = self.runner.web_access_token_from_cookie(cookies)
        return self.runner.web_access_profile_id_from_token(token) if token else None

    def web_access_page(self, failed: bool = False) -> str:
        error = '<p class="error">키가 맞지 않습니다.</p>' if failed else ""
        return f"""<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>BucksCopy Access</title>
  <style>
    :root {{ color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
    body {{ margin: 0; min-height: 100vh; display: grid; place-items: center; background: #111; color: #eee; }}
    main {{ width: min(360px, calc(100vw - 40px)); }}
    h1 {{ margin: 0 0 10px; font-size: 24px; }}
    p {{ margin: 0 0 20px; color: #aaa; line-height: 1.5; }}
    form {{ display: grid; gap: 10px; }}
    input, button {{ height: 42px; border-radius: 8px; border: 1px solid #3a3a3a; font: inherit; }}
    input {{ background: #1f1f1f; color: #fff; padding: 0 12px; }}
    button {{ background: #2f7d46; color: #fff; border: 0; font-weight: 700; cursor: pointer; }}
    .error {{ color: #ff6b6b; margin-bottom: 10px; }}
  </style>
</head>
<body>
  <main>
    <h1>BucksCopy</h1>
    <p>접속 키를 입력해야 대시보드로 이동할 수 있습니다.</p>
    {error}
    <form method="post" action="/web/access/login">
      <input name="accessKey" type="password" autocomplete="current-password" autofocus required>
      <button type="submit">입장</button>
    </form>
  </main>
</body>
</html>"""

    def web_access_not_configured_page(self) -> str:
        return """<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>BucksCopy Locked</title>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #111; color: #eee; }
    main { width: min(460px, calc(100vw - 40px)); }
    h1 { margin: 0 0 10px; font-size: 24px; }
    p { margin: 0; color: #aaa; line-height: 1.5; }
  </style>
</head>
<body>
  <main>
    <h1>BucksCopy Locked</h1>
    <p>웹 접속 키가 서버에 설정되지 않아 대시보드를 열 수 없습니다.</p>
  </main>
</body>
</html>"""

    def web_app_shell(self) -> str:
        return """<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>BucksCopy</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #2f2f2f;
      --panel: #1c1c1c;
      --panel-2: #292929;
      --line: #3a3a3a;
      --text: #eeeeee;
      --muted: #a6a6a6;
      --green: #32d74b;
      --green-strong: #1f6f3d;
      --amber: #ff9f0a;
      --red: #ff453a;
      --blue: #5ac8fa;
      --cyan-soft: rgba(90, 200, 250, 0.14);
      --green-soft: rgba(50, 215, 75, 0.13);
      --amber-soft: rgba(255, 159, 10, 0.13);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      background: var(--bg);
      color: var(--text);
      font-size: 14px;
      letter-spacing: 0;
    }
    button, input { font: inherit; }
    button {
      min-height: 34px;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 0 12px;
      background: #383838;
      color: var(--text);
      cursor: pointer;
      white-space: nowrap;
    }
    button:hover { border-color: #555; background: #434343; }
    button:disabled { opacity: 0.45; cursor: not-allowed; }
    button.primary { background: var(--green-strong); border-color: var(--green-strong); }
    button.primary:hover { background: #26864d; border-color: #2c9a59; }
    button.danger { border-color: #6f3232; color: #ffd5d5; }
    input {
      width: 100%;
      min-height: 36px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #252525;
      color: var(--text);
      padding: 0 10px;
    }
    input[type="checkbox"] {
      width: 16px;
      min-height: 16px;
      height: 16px;
      accent-color: var(--green);
    }
    label { color: var(--muted); font-size: 12px; }
    .shell {
      width: 100%;
      margin: 0 auto;
      padding: 4px 0 0;
    }
    .topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 14px;
      margin-bottom: 8px;
    }
    h1 {
      margin: 0;
      font-size: 22px;
      line-height: 1.1;
      font-weight: 800;
    }
    .eyebrow {
      margin: 0 0 3px;
      color: var(--muted);
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }
    .top-actions, .button-row, .command-actions {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 8px;
    }
    .panel {
      display: grid;
      grid-template-rows: auto minmax(0, 1fr);
      min-width: 0;
      min-height: 0;
      overflow: hidden;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
      box-shadow: inset 0 1px rgba(255, 255, 255, 0.035);
    }
    .panel-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 10px;
      min-height: 42px;
      padding: 10px 12px;
      border-bottom: 1px solid var(--line);
      background: linear-gradient(90deg, rgba(90, 200, 250, 0.08), rgba(50, 215, 75, 0.035) 46%, transparent 78%);
    }
    .panel-title {
      margin: 0;
      font-size: 14px;
      font-weight: 750;
    }
    .panel-body {
      min-height: 0;
      overflow: hidden;
      padding: 12px;
    }
    .notice {
      display: none;
      position: fixed;
      top: 18px;
      right: 18px;
      z-index: 20;
      width: min(320px, calc(100vw - 36px));
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 9px 11px;
      color: var(--muted);
      background: #202020;
      box-shadow: 0 14px 32px rgba(0, 0, 0, 0.28);
    }
    .notice.show { display: block; }
    .notice.error { border-color: #6f3232; color: #ffd5d5; }
    .notice.ok { border-color: #2f6948; color: #cef5dc; }
    .login-card {
      width: min(560px, 100%);
      margin-top: 18px;
    }
    .login-grid {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 10px;
    }
    .field { display: grid; gap: 5px; }
    .login-actions {
      display: flex;
      justify-content: flex-end;
      gap: 8px;
      margin-top: 10px;
    }
    .command-panel { margin-bottom: 10px; }
    .command-body {
      display: grid;
      gap: 8px;
      padding: 10px;
    }
    .command-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 14px;
    }
    .command-state {
      display: flex;
      align-items: center;
      gap: 10px;
      min-width: 0;
    }
    .state-icon {
      display: grid;
      place-items: center;
      flex: 0 0 34px;
      width: 34px;
      height: 34px;
      border-radius: 50%;
      background: rgba(142, 142, 147, 0.14);
      color: var(--muted);
      font-size: 16px;
      font-weight: 800;
    }
    .state-icon.ok {
      background: rgba(50, 215, 75, 0.14);
      color: var(--green);
    }
    .state-icon.warn {
      background: rgba(255, 159, 10, 0.14);
      color: var(--amber);
    }
    .state-icon.bad {
      background: rgba(255, 69, 58, 0.14);
      color: var(--red);
    }
    .state-title {
      margin: 0 0 6px;
      font-size: 18px;
      line-height: 1.15;
      font-weight: 800;
    }
    .command-actions {
      justify-content: flex-end;
      flex: 0 0 auto;
    }
    .command-footer {
      min-height: 0;
    }
    .evaluation-strip {
      display: grid;
      gap: 6px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: linear-gradient(90deg, rgba(90, 200, 250, 0.06), #202020 36%);
      padding: 8px 10px;
    }
    .evaluation-main {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 10px;
      min-width: 0;
    }
    .evaluation-title {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      font-weight: 800;
      font-size: 13px;
    }
    .evaluation-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 5px;
    }
    .evaluation-items {
      display: flex;
      gap: 5px;
      overflow: auto;
      padding-bottom: 1px;
    }
    .evaluation-item {
      flex: 0 0 auto;
      max-width: 280px;
      border: 1px solid #343434;
      border-radius: 999px;
      padding: 3px 8px;
      color: var(--muted);
      font-size: 11px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      background: #262626;
    }
    .evaluation-item.signal {
      color: #c9f5d5;
      border-color: rgba(50, 215, 75, 0.36);
      background: rgba(50, 215, 75, 0.10);
    }
    .dashboard {
      display: grid;
      grid-template-columns: minmax(360px, 1fr) 10px minmax(320px, var(--right-pane-width, 38%));
      gap: 0;
      align-items: stretch;
      min-height: calc(100vh - 184px);
    }
    .full { grid-column: 1 / -1; }
    .metrics {
      display: grid;
      grid-template-columns: repeat(6, minmax(0, 1fr));
      gap: 8px;
    }
    .metric {
      position: relative;
      min-height: 56px;
      padding: 8px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel-2);
      overflow: hidden;
    }
    .metric::before {
      content: "";
      position: absolute;
      inset: 0 0 auto;
      height: 2px;
      background: var(--blue);
      opacity: 0.8;
    }
    .metric:nth-child(3n + 2)::before { background: var(--green); }
    .metric:nth-child(3n)::before { background: var(--amber); }
    .metric span {
      display: block;
      color: var(--muted);
      font-size: 11px;
      margin-bottom: 6px;
    }
    .metric strong {
      display: block;
      overflow-wrap: anywhere;
      font-size: 15px;
      line-height: 1.1;
    }
    .metric small {
      display: block;
      margin-top: 5px;
      color: var(--muted);
      line-height: 1.25;
    }
    .status-line {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      align-items: center;
    }
    .pill {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      min-height: 24px;
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 0 8px;
      color: var(--muted);
      font-size: 12px;
      white-space: nowrap;
    }
    .pill.ok {
      border-color: rgba(50, 215, 75, 0.34);
      background: var(--green-soft);
      color: #d8ffe3;
    }
    .pill.warn {
      border-color: rgba(255, 159, 10, 0.34);
      background: var(--amber-soft);
      color: #ffe0a3;
    }
    .pill.bad {
      border-color: rgba(255, 69, 58, 0.34);
      background: rgba(255, 69, 58, 0.12);
      color: #ffd4d1;
    }
    .pill.info {
      border-color: rgba(90, 200, 250, 0.34);
      background: var(--cyan-soft);
      color: #d7f2ff;
    }
    .dot {
      width: 7px;
      height: 7px;
      border-radius: 50%;
      background: var(--muted);
    }
    .ok .dot, .dot.ok { background: var(--green); }
    .warn .dot, .dot.warn { background: var(--amber); }
    .bad .dot, .dot.bad { background: var(--red); }
    .info .dot, .dot.info { background: var(--blue); }
    .stack {
      display: grid;
      gap: 0;
      min-height: 0;
    }
    .left-stack {
      grid-template-rows:
        minmax(96px, var(--position-pane-height, 150px))
        8px
        minmax(220px, var(--chart-pane-height, 420px))
        8px
        310px;
    }
    .right-stack { min-height: calc(100vh - 184px); }
    .trade-log-panel {
      position: relative;
      min-height: 100%;
    }
    .trade-log-panel .panel-body {
      display: grid;
      grid-template-rows: auto minmax(0, 1fr);
    }
    .splitter {
      position: relative;
      z-index: 2;
      background: transparent;
      touch-action: none;
      align-self: stretch;
    }
    .splitter::before {
      content: "";
      position: absolute;
      inset: 2px 3px;
      border-radius: 999px;
      background: linear-gradient(180deg, rgba(90, 200, 250, 0.55), rgba(50, 215, 75, 0.32));
      opacity: 0.42;
      transition: opacity 0.12s ease, background 0.12s ease;
    }
    .splitter:hover::before,
    .splitter.dragging::before {
      opacity: 1;
      background: #5a5a5a;
    }
    .vertical-splitter {
      width: 10px;
      min-height: 100%;
      cursor: col-resize;
    }
    .horizontal-splitter {
      height: 8px;
      min-height: 8px;
      cursor: row-resize;
    }
    .compact-list {
      display: grid;
      gap: 8px;
      max-height: calc(100vh - 312px);
      overflow: auto;
    }
    .row-card {
      border: 1px solid var(--line);
      border-left: 3px solid rgba(90, 200, 250, 0.42);
      border-radius: 8px;
      padding: 9px;
      background: #222;
    }
    .row-title {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 10px;
      margin-bottom: 5px;
    }
    .row-title strong {
      line-height: 1.25;
      overflow-wrap: anywhere;
    }
    .muted { color: var(--muted); }
    .mini { font-size: 12px; }
    .kv {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 6px;
      margin-top: 8px;
    }
    .kv div {
      min-width: 0;
      border-top: 1px solid #3a3a3a;
      padding-top: 6px;
    }
    .kv span {
      display: block;
      color: var(--muted);
      font-size: 11px;
      margin-bottom: 2px;
    }
    .kv strong {
      display: block;
      overflow-wrap: anywhere;
      font-size: 13px;
      font-weight: 700;
    }
    .position-list {
      display: grid;
      gap: 7px;
      max-height: 100%;
      overflow: auto;
    }
    .position-card {
      display: grid;
      gap: 8px;
      border: 1px solid var(--line);
      border-left: 3px solid rgba(50, 215, 75, 0.42);
      border-radius: 8px;
      padding: 9px;
      background: #222;
    }
    .position-top {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 12px;
      min-width: 0;
    }
    .position-symbol {
      display: flex;
      align-items: center;
      flex-wrap: wrap;
      gap: 6px;
      min-width: 0;
      font-weight: 750;
    }
    .side-chip {
      display: inline-flex;
      min-height: 18px;
      align-items: center;
      border-radius: 999px;
      padding: 0 7px;
      background: #303030;
      color: var(--muted);
      font-size: 11px;
      font-weight: 800;
    }
    .side-chip.long {
      color: var(--green);
      background: rgba(50, 215, 75, 0.12);
    }
    .side-chip.short {
      color: var(--red);
      background: rgba(255, 69, 58, 0.12);
    }
    .position-meta {
      margin-top: 3px;
      color: var(--muted);
      font-size: 11px;
    }
    .position-pnl {
      text-align: right;
      font-weight: 800;
      white-space: nowrap;
    }
    .position-metrics {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 5px;
    }
    .position-metrics div {
      min-width: 0;
      border-top: 1px solid #3a3a3a;
      padding-top: 6px;
    }
    .position-metrics span {
      display: block;
      color: var(--muted);
      font-size: 10px;
      margin-bottom: 2px;
    }
    .position-metrics strong {
      display: block;
      overflow-wrap: anywhere;
      font-size: 12px;
      line-height: 1.15;
    }
    .table-wrap {
      overflow: auto;
      max-height: 220px;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      min-width: 540px;
    }
    th, td {
      border-bottom: 1px solid var(--line);
      padding: 8px 8px;
      text-align: left;
      vertical-align: top;
      white-space: nowrap;
    }
    th {
      color: var(--muted);
      font-size: 11px;
      font-weight: 700;
      background: #222;
      position: sticky;
      top: 0;
      z-index: 1;
    }
    td { font-size: 12px; }
    .strategy-list {
      display: grid;
      gap: 6px;
      max-height: 100%;
      overflow: auto;
    }
    .strategy-item {
      display: grid;
      gap: 9px;
      border: 1px solid var(--line);
      border-left: 3px solid rgba(255, 159, 10, 0.42);
      border-radius: 8px;
      padding: 8px;
      background: #222;
      color: var(--text);
      font-size: 12px;
    }
    .strategy-top {
      display: grid;
      grid-template-columns: 18px 1fr auto;
      gap: 9px;
      align-items: center;
      min-width: 0;
    }
    .strategy-item input { margin-top: 1px; }
    .strategy-content {
      display: grid;
      gap: 4px;
      min-width: 0;
    }
    .strategy-main {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      min-width: 0;
    }
    .strategy-name {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      font-size: 13px;
      font-weight: 750;
    }
    .strategy-stats {
      display: flex;
      flex-wrap: wrap;
      gap: 4px;
    }
    .strategy-id {
      color: var(--muted);
      font-size: 11px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .strategy-detail {
      display: none;
      border-top: 1px solid #363636;
      padding-top: 8px;
      color: var(--muted);
    }
    .strategy-item.expanded .strategy-detail {
      display: grid;
      gap: 7px;
    }
    .strategy-detail-grid {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 5px;
    }
    .strategy-detail-grid div {
      min-width: 0;
      border: 1px solid #343434;
      border-radius: 7px;
      padding: 6px;
      background: #252525;
    }
    .strategy-detail-grid span {
      display: block;
      font-size: 10px;
      margin-bottom: 2px;
    }
    .strategy-detail-grid strong {
      display: block;
      overflow-wrap: anywhere;
      color: var(--text);
      font-size: 12px;
    }
    .detail-toggle {
      min-height: 26px;
      padding: 0 8px;
      font-size: 11px;
    }
    .tagline {
      display: flex;
      flex-wrap: wrap;
      gap: 5px;
      margin-top: 5px;
    }
    .tag {
      display: inline-flex;
      align-items: center;
      min-height: 20px;
      border-radius: 999px;
      padding: 0 7px;
      background: #303030;
      color: var(--muted);
      font-size: 11px;
    }
    .alert-text {
      color: var(--muted);
      font-size: 12px;
      line-height: 1.35;
    }
    .chart-toolbar {
      display: flex;
      align-items: center;
      gap: 6px;
    }
    .chart-tools {
      display: flex;
      align-items: center;
      gap: 4px;
    }
    .chart-tools button {
      min-width: 28px;
      min-height: 28px;
      padding: 0 8px;
      font-size: 12px;
      line-height: 1;
    }
    select {
      min-height: 28px;
      border: 1px solid var(--line);
      border-radius: 7px;
      background: #252525;
      color: var(--text);
      padding: 0 8px;
      font: inherit;
      font-size: 12px;
    }
    .chart-panel-body {
      display: grid;
      grid-template-rows: minmax(0, 1fr) auto;
      gap: 6px;
      cursor: grab;
      user-select: none;
      touch-action: none;
    }
    .chart-panel-body:active { cursor: grabbing; }
    .chart-wrap {
      width: 100%;
      height: auto;
      min-height: 0;
      border-radius: 7px;
      background: #151515;
      overflow: hidden;
      cursor: grab;
      user-select: none;
      touch-action: none;
    }
    .chart-wrap:active { cursor: grabbing; }
    #chart-canvas {
      width: 100%;
      height: 100%;
      display: block;
    }
    .chart-legend {
      display: flex;
      flex-wrap: wrap;
      gap: 5px;
      color: var(--muted);
      font-size: 11px;
    }
    .legend-item {
      display: inline-flex;
      align-items: center;
      gap: 4px;
    }
    .legend-swatch {
      width: 14px;
      height: 2px;
      border-radius: 999px;
      background: var(--muted);
    }
    .log-summary {
      display: grid;
      grid-template-columns: repeat(5, minmax(0, 1fr));
      gap: 4px;
      margin-bottom: 8px;
    }
    .summary-cell {
      min-width: 0;
      border: 1px solid var(--line);
      border-radius: 7px;
      background: var(--panel-2);
      padding: 7px;
    }
    .summary-cell span {
      display: block;
      color: var(--muted);
      font-size: 11px;
      margin-bottom: 3px;
    }
    .summary-cell strong {
      display: block;
      overflow-wrap: anywhere;
      font-size: 13px;
      line-height: 1.15;
    }
    .profit { color: var(--green); }
    .loss { color: var(--red); }
    .empty {
      color: var(--muted);
      padding: 10px;
      border: 1px dashed var(--line);
      border-radius: 8px;
      background: #222;
    }
    [hidden] { display: none !important; }
    @media (max-width: 900px) {
      .shell { padding: 0; }
      .dashboard, .metrics { grid-template-columns: 1fr; }
      .dashboard { min-height: 0; }
      .login-grid { grid-template-columns: 1fr; }
      .topbar { margin-bottom: 4px; }
      .topbar, .command-row { align-items: flex-start; flex-direction: column; }
      .command-body { gap: 6px; padding: 8px; }
      .command-row { gap: 8px; }
      .command-state { gap: 8px; }
      .state-icon { width: 28px; height: 28px; flex-basis: 28px; font-size: 13px; }
      .state-title { font-size: 15px; margin-bottom: 4px; }
      .metrics { gap: 5px; }
      .metric { min-height: 44px; padding: 6px; }
      .metric span { font-size: 10px; margin-bottom: 3px; }
      .metric strong { font-size: 13px; }
      .metric small { display: none; }
      .evaluation-strip { padding: 6px; gap: 4px; }
      .evaluation-main { align-items: flex-start; flex-direction: column; gap: 4px; }
      .evaluation-title { white-space: normal; font-size: 12px; }
      .top-actions { width: 100%; }
      .top-actions button, .top-actions form { flex: 1; }
      .top-actions form button { width: 100%; }
      .command-actions { width: 100%; }
      .command-actions button { flex: 1; }
      .splitter { display: none; }
      .left-stack { grid-template-rows: auto; gap: 8px; }
      .right-stack { min-height: 0; }
      .stack { gap: 8px; }
      .trade-log-panel { min-height: 0; }
      .compact-list { max-height: 360px; }
      .chart-panel-body { grid-template-rows: 280px auto; }
      .strategy-detail-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .log-summary { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      table { min-width: 460px; }
    }
  </style>
</head>
<body>
  <main class="shell">
    <header class="topbar">
      <div></div>
      <div class="top-actions">
        <span class="pill ok"><span class="dot"></span>접속키 통과됨</span>
        <form id="lock-form" method="post" action="/web/access/logout">
          <button type="submit">웹 잠금</button>
        </form>
      </div>
    </header>

    <div id="notice" class="notice" role="status" aria-live="polite"></div>

    <section id="login-panel" class="panel login-card">
      <div class="panel-head">
        <h2 class="panel-title">Bitget Login</h2>
        <span class="pill bad"><span class="dot"></span>세션 없음</span>
      </div>
      <div class="panel-body">
        <form id="bitget-login-form" autocomplete="off">
          <div class="login-grid">
            <div class="field">
              <label for="api-key">API Key</label>
              <input id="api-key" name="apiKey" type="password" autocomplete="off" required>
            </div>
            <div class="field">
              <label for="secret-key">API Secret</label>
              <input id="secret-key" name="secretKey" type="password" autocomplete="off" required>
            </div>
            <div class="field">
              <label for="passphrase">Passphrase</label>
              <input id="passphrase" name="passphrase" type="password" autocomplete="off" required>
            </div>
          </div>
          <div class="login-actions">
            <button type="submit" class="primary">로그인</button>
          </div>
        </form>
      </div>
    </section>

    <section id="dashboard" hidden>
      <section class="panel command-panel">
        <div class="command-body">
          <div class="command-row">
            <div class="command-state">
              <div id="automation-icon" class="state-icon">II</div>
              <div>
                <h2 class="state-title" id="automation-title">자동매매 정지</h2>
                <div class="status-line" id="runner-status"></div>
              </div>
            </div>
            <div class="command-actions">
              <button type="button" data-action="refresh">새로고침</button>
              <button type="button" data-action="bitget-logout">로그아웃</button>
              <button type="button" data-action="automation-toggle" id="automation-toggle" class="primary">자동매매 시작</button>
            </div>
          </div>
          <div class="metrics" id="metrics"></div>
          <div class="evaluation-strip" id="last-evaluation"></div>
          <div class="command-footer">
            <div id="live-blockers" class="alert-text"></div>
          </div>
        </div>
      </section>

      <div class="dashboard">
        <div class="stack left-stack">
          <section class="panel">
            <div class="panel-head">
              <h2 class="panel-title">포지션</h2>
              <span class="mini muted" id="position-count"></span>
            </div>
            <div class="panel-body" id="positions"></div>
          </section>

          <div class="splitter horizontal-splitter" data-resize="position-chart"></div>

          <section class="panel">
            <div class="panel-head">
              <h2 class="panel-title">차트</h2>
              <div class="chart-toolbar">
                <select id="chart-symbol"></select>
                <span class="pill info"><span class="dot"></span>15m</span>
                <div class="chart-tools" aria-label="차트 조작">
                  <button type="button" data-action="chart-zoom-out" title="축소">-</button>
                  <button type="button" data-action="chart-reset" title="최신 봉으로 복귀">Reset</button>
                  <button type="button" data-action="chart-zoom-in" title="확대">+</button>
                </div>
              </div>
            </div>
            <div class="panel-body chart-panel-body">
              <div class="chart-wrap">
                <canvas id="chart-canvas"></canvas>
              </div>
              <div class="chart-legend" id="chart-legend"></div>
            </div>
          </section>

          <div class="splitter horizontal-splitter" data-resize="chart-strategy"></div>

          <section class="panel">
            <div class="panel-head">
              <h2 class="panel-title">매매전략</h2>
              <button type="button" data-action="strategies-save">저장</button>
            </div>
            <div class="panel-body">
              <div id="strategy-list" class="strategy-list"></div>
            </div>
          </section>
        </div>

        <div class="splitter vertical-splitter" data-resize="columns" title="매매기록 너비 조절" aria-label="매매기록 너비 조절"></div>

        <div class="stack right-stack">
          <section class="panel trade-log-panel">
            <div class="panel-head">
              <h2 class="panel-title">매매기록</h2>
              <span class="mini muted" id="log-count"></span>
            </div>
            <div class="panel-body">
              <div id="log-summary" class="log-summary"></div>
              <div id="logs" class="compact-list"></div>
            </div>
          </section>
        </div>
      </div>
    </section>
  </main>

  <script>
    (() => {
      "use strict";

      const TOKEN_KEY = "bucksCopy.paperRunner.authToken";
      const LAYOUT_KEY = "bucksCopy.web.layout";
      const REFRESH_MS = 60000;
      const DEFAULT_CHART_VISIBLE = 160;
      const MIN_CHART_VISIBLE = 5;
      const CHART_CANDLE_PAGE_LIMIT = 2000;
      const CHART_PREFETCH_THRESHOLD = 240;
      const INDICATORS = [
        { key: "ma25", label: "MA25", period: 25, color: "#ff9f0a", type: "sma" },
        { key: "ma50", label: "MA50", period: 50, color: "#32d74b", type: "sma" },
        { key: "ma100", label: "MA100", period: 100, color: "#5ac8fa", type: "sma" },
        { key: "ma200", label: "MA200", period: 200, color: "#ff453a", type: "sma" },
        { key: "vwma100", label: "VWMA100", period: 100, color: "#eeeeee", type: "vwma" }
      ];
      const SAFE_DETAIL_KEYS = new Set([
        "strategyID",
        "timeframe",
        "symbol",
        "side",
        "entry",
        "stopLoss",
        "partialTakeProfit",
        "takeProfit",
        "profitLockStopLossAfterPartialTakeProfit",
        "plannedRewardRiskRatio",
        "leverage",
        "mode",
        "reason",
        "filledSize",
        "averagePrice",
        "size",
        "availableBalanceRatio",
        "requestedMarginUSDT",
        "minimumTest",
        "closeSubmitted",
        "closeConfirmed",
        "failureReason",
        "failClosedAttempted",
        "tp1",
        "tp2",
        "protectionOrders",
        "enabledStrategies",
        "enabledCount",
        "symbols",
        "savedCandles",
        "evaluations",
        "skippedEvaluations",
        "enabled",
        "signals",
        "failures"
      ]);

      const state = {
        status: null,
        control: null,
        live: null,
        strategies: null,
        account: null,
        positions: null,
        logs: null,
        candles: null,
        selectedSymbol: "",
        chart: {
          visibleCount: DEFAULT_CHART_VISIBLE,
          rightOffset: 0,
          dragging: false,
          lastX: 0,
          lastY: 0,
          dragMode: "",
          wheelRemainder: 0,
          zoomRemainder: 0,
          priceOffsetRatio: 0,
          priceScaleRatio: 1,
          loadingMore: false,
          activePointers: new Map(),
          pinchDistance: 0,
          pinchVisibleCount: DEFAULT_CHART_VISIBLE,
          gestureVisibleCount: DEFAULT_CHART_VISIBLE
        },
        errors: {},
        redactedIdentifier: "",
        busy: false,
        lastUpdated: null
      };
      let noticeTimer = null;

      const els = {
        notice: document.getElementById("notice"),
        loginPanel: document.getElementById("login-panel"),
        dashboard: document.getElementById("dashboard"),
        metrics: document.getElementById("metrics"),
        automationIcon: document.getElementById("automation-icon"),
        automationTitle: document.getElementById("automation-title"),
        runnerStatus: document.getElementById("runner-status"),
        automationToggle: document.getElementById("automation-toggle"),
        liveBlockers: document.getElementById("live-blockers"),
        lastEvaluation: document.getElementById("last-evaluation"),
        chartSymbol: document.getElementById("chart-symbol"),
        chartCanvas: document.getElementById("chart-canvas"),
        chartLegend: document.getElementById("chart-legend"),
        strategyList: document.getElementById("strategy-list"),
        positionCount: document.getElementById("position-count"),
        positions: document.getElementById("positions"),
        logSummary: document.getElementById("log-summary"),
        logCount: document.getElementById("log-count"),
        logs: document.getElementById("logs"),
        loginForm: document.getElementById("bitget-login-form"),
        lockForm: document.getElementById("lock-form")
      };

      class ApiError extends Error {
        constructor(message, status) {
          super(message);
          this.status = status;
        }
      }

      const token = () => localStorage.getItem(TOKEN_KEY) || "";
      const setToken = (value) => {
        if (value) {
          localStorage.setItem(TOKEN_KEY, value);
        } else {
          localStorage.removeItem(TOKEN_KEY);
        }
      };

      const escapeHTML = (value) => String(value ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#039;");

      const numberText = (value, digits = 2) => {
        const raw = String(value ?? "").trim();
        if (!raw) {
          return "-";
        }
        const parsed = Number(raw);
        if (!Number.isFinite(parsed)) {
          return raw;
        }
        return parsed.toLocaleString("ko-KR", { maximumFractionDigits: digits });
      };

      const signedNumber = (value) => {
        const parsed = Number(value ?? 0);
        if (!Number.isFinite(parsed)) {
          return numberText(value);
        }
        const text = numberText(parsed, 3);
        return parsed > 0 ? `+${text}` : text;
      };

      const percentText = (ratio) => {
        const parsed = Number(ratio ?? 0);
        if (!Number.isFinite(parsed)) {
          return "-";
        }
        return `${numberText(parsed * 100, 2)}%`;
      };

      const decimalNumberText = (value, digits = 2, signed = false) => {
        const raw = String(value ?? "").replaceAll(",", "").trim();
        if (!raw) {
          return "-";
        }
        const parsed = Number(raw);
        if (!Number.isFinite(parsed)) {
          return String(value ?? "");
        }
        const sign = parsed < 0 ? "-" : signed && (parsed > 0 || raw.startsWith("+")) ? "+" : "";
        return `${sign}${Math.abs(parsed).toLocaleString("ko-KR", {
          minimumFractionDigits: digits,
          maximumFractionDigits: digits
        })}`;
      };

      const percentValueText = (value) => {
        const text = decimalNumberText(value, 2, true);
        return text === "-" ? "-" : `${text}%`;
      };

      const amountText = (value) => decimalNumberText(value, 2, false);
      const countText = (value) => decimalNumberText(value, 0, false);
      const ratioText = (value, digits = 2) => decimalNumberText(value, digits, false);

      const durationText = (seconds) => {
        const safeSeconds = Math.max(Number(seconds) || 0, 0);
        const days = Math.floor(safeSeconds / 86400);
        const hours = Math.floor((safeSeconds % 86400) / 3600);
        const minutes = Math.floor((safeSeconds % 3600) / 60);
        if (days > 0) {
          return `${days}d ${hours}h`;
        }
        if (hours > 0) {
          return `${hours}h ${minutes}m`;
        }
        return `${minutes}m`;
      };

      const timeText = (value) => {
        if (value === null || value === undefined || value === "") {
          return "-";
        }
        const raw = String(value);
        const numeric = /^\\d{11,}$/.test(raw) ? Number(raw) : NaN;
        const date = Number.isFinite(numeric) ? new Date(numeric) : new Date(raw);
        if (Number.isNaN(date.getTime())) {
          return raw;
        }
        return date.toLocaleString("ko-KR", {
          month: "2-digit",
          day: "2-digit",
          hour: "2-digit",
          minute: "2-digit",
          hour12: false
        });
      };

      const dateFromValue = (value) => {
        if (value === null || value === undefined || value === "") {
          return null;
        }
        const raw = String(value);
        const numeric = /^\\d{11,}$/.test(raw) ? Number(raw) : NaN;
        const date = Number.isFinite(numeric) ? new Date(numeric) : new Date(raw);
        return Number.isNaN(date.getTime()) ? null : date;
      };

      const latestClosedText = () => {
        const source = state.status?.latestClosedCandleOpenTimeISO || state.status?.latestClosedCandleOpenTime;
        const date = dateFromValue(source);
        if (!date) {
          return "-";
        }
        return timeText(new Date(date.getTime() + 15 * 60 * 1000).toISOString());
      };

      const elapsedText = () => {
        const control = state.control || state.status?.control || {};
        if (!control.enabled || !control.updatedAt) {
          return "-";
        }
        const startedAt = dateFromValue(control.updatedAt);
        if (!startedAt) {
          return "-";
        }
        return durationText((Date.now() - startedAt.getTime()) / 1000);
      };

      const orderLimitText = (config) => {
        const ratio = config?.availableBalanceRatio;
        if (ratio === null || ratio === undefined || ratio === "") {
          return "가용잔고 기준";
        }
        return `가용 ${percentText(ratio)} 기준`;
      };

      const severityClass = (severity) => {
        const text = String(severity || "").toLowerCase();
        if (text === "error" || text === "critical") {
          return "bad";
        }
        if (text === "warning" || text === "warn") {
          return "warn";
        }
        if (text === "info") {
          return "info";
        }
        return "ok";
      };

      const pill = (text, tone = "") => `
        <span class="pill ${tone}">
          <span class="dot ${tone}"></span>${escapeHTML(text)}
        </span>
      `;

      const empty = (text) => `<div class="empty">${escapeHTML(text)}</div>`;

      const friendlyErrorText = (message, key = "") => {
        const text = String(message || "").trim();
        const lower = text.toLowerCase();
        const isGatewayError = lower.includes("502") || lower.includes("bad gateway") || lower.includes("gateway");
        const isServerError = isGatewayError || /^5\\d\\d\\b/.test(lower);
        if (isServerError) {
          if (key === "positions") {
            return "포지션 정보를 불러오지 못했습니다. 잠시 후 새로고침해 주세요.";
          }
          if (key === "account") {
            return "계정 정보를 불러오지 못했습니다. 잠시 후 새로고침해 주세요.";
          }
          return "서버 응답이 지연 중입니다. 잠시 후 새로고침해 주세요.";
        }
        return text || "요청을 완료하지 못했습니다.";
      };

      const localizedLiveBlocker = (text) => {
        switch (text) {
          case "live order execution env switch is disabled":
            return "서버 실주문 스위치 꺼짐";
          case "live order margin USDT is not configured":
            return "주문한도 미설정";
          case "live consent is disabled":
            return "자동매매 실주문 동의 꺼짐";
          case "Bitget credential is not loaded":
            return "Bitget 로그인 필요";
          case "fresh account/position snapshot is required":
            return "계정/포지션 최신 정보 대기";
          case "paper runner disabled":
            return "자동매매 꺼짐";
          default:
            return friendlyErrorText(text);
        }
      };

      const isPaperLog = (item) => {
        const metadata = item.metadata || {};
        const details = metadata.details || {};
        const tags = Array.isArray(metadata.tags) ? metadata.tags.map((tag) => String(tag).toUpperCase()) : [];
        const title = String(metadata.title || "");
        const message = String(item.message || "");
        return tags.includes("PAPER") ||
          String(details.mode || "").toLowerCase().includes("paper") ||
          title.toLowerCase().includes("paper runner") ||
          title.toLowerCase().includes("paper signal") ||
          message.toLowerCase().includes("paper runner") ||
          message.toLowerCase().includes("paper signal");
      };

      const visibleTradeLogs = () => (state.logs?.items || []).filter((item) => !isPaperLog(item));

      const availableSymbols = () => {
        const statusSymbols = Array.isArray(state.status?.symbols) ? state.status.symbols : [];
        const strategySymbols = Array.isArray(state.strategies?.available)
          ? state.strategies.available.map((strategy) => strategy.symbol).filter(Boolean)
          : [];
        return [...new Set([...statusSymbols, ...strategySymbols].map((symbol) => String(symbol).toUpperCase()))]
          .filter(Boolean);
      };

      const ensureSelectedSymbol = () => {
        const symbols = availableSymbols();
        if (!state.selectedSymbol || !symbols.includes(state.selectedSymbol)) {
          state.selectedSymbol = symbols[0] || "BTCUSDT";
        }
      };

      const chartCandlePath = (symbol, beforeOpenTime = null) => {
        const params = new URLSearchParams({
          symbol: String(symbol || "").toUpperCase(),
          limit: String(CHART_CANDLE_PAGE_LIMIT)
        });
        if (beforeOpenTime) {
          params.set("before", String(beforeOpenTime));
        }
        return `/users/me/candles?${params.toString()}`;
      };

      const sortedCandleItems = (items) => [...(items || [])]
        .filter((item) => Number.isFinite(Number(item.openTime)))
        .sort((first, second) => Number(first.openTime) - Number(second.openTime));

      const normalizedCandleResponse = (response) => ({
        ...response,
        items: sortedCandleItems(response?.items || [])
      });

      const mergeCandleResponse = (response) => {
        const current = normalizedCandleResponse(state.candles || {});
        const incoming = normalizedCandleResponse(response || {});
        const byOpenTime = new Map();
        [...current.items, ...incoming.items].forEach((item) => {
          byOpenTime.set(String(item.openTime), item);
        });
        const items = sortedCandleItems([...byOpenTime.values()]);
        const oldest = items[0]?.openTime || null;
        const newest = items[items.length - 1]?.openTime || null;
        state.candles = {
          ...current,
          ...incoming,
          items,
          returned: items.length,
          oldestOpenTime: oldest,
          oldestOpenTimeISO: items[0]?.openTimeISO || null,
          newestOpenTime: newest,
          newestOpenTimeISO: items[items.length - 1]?.openTimeISO || null,
          hasMoreBefore: Boolean(incoming.hasMoreBefore),
          hasMoreAfter: Boolean(current.hasMoreAfter || incoming.hasMoreAfter)
        };
      };

      const rawLivePositions = () => (state.positions?.items || []).filter((position) => (
        Number(position.total || position.available || 0) !== 0
      ));

      const nonEmptyValue = (value) => {
        const text = String(value ?? "").trim();
        return text && text !== "0" ? text : "";
      };

      const normalizedPositionSide = (value) => {
        const text = String(value || "").toLowerCase();
        if (text === "buy" || text === "long") {
          return "long";
        }
        if (text === "sell" || text === "short") {
          return "short";
        }
        return text;
      };

      const latestLiveEntryDetailsForPosition = (position) => {
        const symbol = String(position.symbol || "").toUpperCase();
        const positionSide = normalizedPositionSide(position.holdSide);
        const logs = state.logs?.items || [];
        for (const item of logs.slice().reverse()) {
          if (String(item.category || "") !== "liveOrder") {
            continue;
          }
          if (String(item.symbol || "").toUpperCase() !== symbol) {
            continue;
          }
          const details = item.metadata?.details || {};
          const detailSide = normalizedPositionSide(details.side);
          if (positionSide && detailSide && positionSide !== detailSide) {
            continue;
          }
          return details;
        }
        return {};
      };

      const enrichedPosition = (position) => {
        const details = latestLiveEntryDetailsForPosition(position);
        return {
          ...position,
          openPriceAvg: nonEmptyValue(position.openPriceAvg) || nonEmptyValue(details.entry) || position.openPriceAvg,
          partialTakeProfit: nonEmptyValue(position.partialTakeProfit) || nonEmptyValue(details.tp1) || nonEmptyValue(details.partialTakeProfit),
          takeProfit: nonEmptyValue(position.takeProfit) || nonEmptyValue(details.tp2) || nonEmptyValue(details.takeProfit) || position.takeProfit,
          stopLoss: nonEmptyValue(position.stopLoss) || nonEmptyValue(details.stopLoss) || position.stopLoss
        };
      };

      const livePositions = () => rawLivePositions().map(enrichedPosition);

      const currentUnrealizedPnl = () => livePositions()
        .reduce((sum, position) => sum + (Number(position.unrealizedPL) || 0), 0);

      const valueToneClass = (value) => {
        const parsed = Number(value ?? 0);
        if (parsed > 0) {
          return "profit";
        }
        if (parsed < 0) {
          return "loss";
        }
        return "";
      };

      const sideText = (value) => {
        const text = String(value || "").toLowerCase();
        if (text.includes("long") || text === "buy") {
          return "Long";
        }
        if (text.includes("short") || text === "sell") {
          return "Short";
        }
        return value || "-";
      };

      const sideClass = (value) => {
        const text = String(value || "").toLowerCase();
        if (text.includes("long") || text === "buy") {
          return "long";
        }
        if (text.includes("short") || text === "sell") {
          return "short";
        }
        return "";
      };

      const loadLayout = () => {
        try {
          return JSON.parse(localStorage.getItem(LAYOUT_KEY) || "{}");
        } catch {
          return {};
        }
      };

      const saveLayout = (next) => {
        const layout = { ...loadLayout(), ...next };
        localStorage.setItem(LAYOUT_KEY, JSON.stringify(layout));
      };

      const applyLayout = () => {
        const layout = loadLayout();
        const root = document.documentElement;
        if (layout.rightPaneWidth) {
          root.style.setProperty("--right-pane-width", `${layout.rightPaneWidth}px`);
        }
        if (layout.positionPaneHeight) {
          root.style.setProperty("--position-pane-height", `${layout.positionPaneHeight}px`);
        }
        if (layout.chartPaneHeight) {
          root.style.setProperty("--chart-pane-height", `${layout.chartPaneHeight}px`);
        }
      };

      const chartCandles = () => (state.candles?.items || [])
        .map((candle) => ({
          openTime: Number(candle.openTime),
          openTimeISO: candle.openTimeISO,
          open: Number(candle.open),
          high: Number(candle.high),
          low: Number(candle.low),
          close: Number(candle.close),
          volume: Number(candle.volume)
        }))
        .filter((candle) => (
          Number.isFinite(candle.open) &&
          Number.isFinite(candle.high) &&
          Number.isFinite(candle.low) &&
          Number.isFinite(candle.close)
        ));

      const visibleChartWindow = (candles) => {
        const total = candles.length;
        const visibleCount = Math.max(MIN_CHART_VISIBLE, Math.round(Number(state.chart.visibleCount) || DEFAULT_CHART_VISIBLE));
        const minimumVisibleCandles = Math.min(total, 5);
        const maxFutureBlank = Math.max(visibleCount - minimumVisibleCandles, 0);
        const maxPastOffset = Math.max(total - minimumVisibleCandles, 0);
        state.chart.rightOffset = Math.max(-maxFutureBlank, Math.min(state.chart.rightOffset, maxPastOffset));
        const end = total - state.chart.rightOffset;
        const start = end - visibleCount;
        const renderStart = Math.max(0, start);
        const renderEnd = Math.min(total, end);
        return { start, end, renderStart, renderEnd, visibleCount };
      };

      const movingAverageSeries = (candles, period, type) => {
        const values = new Array(candles.length).fill(null);
        let sum = 0;
        let volumeSum = 0;
        let priceVolumeSum = 0;
        for (let index = 0; index < candles.length; index += 1) {
          const candle = candles[index];
          if (type === "vwma") {
            const volume = Number.isFinite(candle.volume) ? candle.volume : 0;
            volumeSum += volume;
            priceVolumeSum += candle.close * volume;
            if (index >= period) {
              const old = candles[index - period];
              const oldVolume = Number.isFinite(old.volume) ? old.volume : 0;
              volumeSum -= oldVolume;
              priceVolumeSum -= old.close * oldVolume;
            }
            if (index >= period - 1 && volumeSum > 0) {
              values[index] = priceVolumeSum / volumeSum;
            }
          } else {
            sum += candle.close;
            if (index >= period) {
              sum -= candles[index - period].close;
            }
            if (index >= period - 1) {
              values[index] = sum / period;
            }
          }
        }
        return values;
      };

      const setNotice = (message, tone = "") => {
        if (noticeTimer) {
          window.clearTimeout(noticeTimer);
          noticeTimer = null;
        }
        els.notice.textContent = message || "";
        els.notice.className = `notice${message ? " show" : ""}${tone ? ` ${tone}` : ""}`;
        if (message && tone === "ok") {
          noticeTimer = window.setTimeout(() => {
            els.notice.textContent = "";
            els.notice.className = "notice";
            noticeTimer = null;
          }, 2200);
        }
      };

      const automationMode = () => {
        const control = state.control || state.status?.control || {};
        const live = state.live || state.status?.live || {};
        const judging = Boolean(control.enabled);
        const liveConsent = Boolean(live.control?.enabled);
        const orderReady = Boolean(live.orderExecutionEnabled);
        if (judging && liveConsent && orderReady) {
          return {
            id: "live",
            tone: "ok",
            icon: "▶",
            title: "자동매매 실행 중",
            note: "서버가 15분봉 마감마다 판단하고, 신호가 나오면 실제 주문까지 실행합니다."
          };
        }
        if (judging && liveConsent && !orderReady) {
          return {
            id: "blocked",
            tone: "warn",
            icon: "!",
            title: "자동매매 준비 확인 필요",
            note: "자동매매는 켜져 있지만 실제 주문 조건 중 확인할 항목이 남아 있습니다."
          };
        }
        if (judging) {
          return {
            id: "judging",
            tone: "warn",
            icon: "…",
            title: "자동매매 준비 중",
            note: "서버 판단은 켜져 있고, 실제 주문 시작 확인을 기다리는 상태입니다."
          };
        }
        return {
          id: "off",
          tone: "bad",
          icon: "II",
          title: "자동매매 정지",
          note: "서버가 새 신호를 주문으로 실행하지 않습니다."
        };
      };

      const api = async (path, options = {}) => {
        const headers = { "Accept": "application/json" };
        const body = options.body === undefined ? undefined : JSON.stringify(options.body);
        if (body !== undefined) {
          headers["Content-Type"] = "application/json";
        }
        const authToken = token();
        if (authToken) {
          headers["Authorization"] = `Bearer ${authToken}`;
        }
        const response = await fetch(path, {
          method: options.method || "GET",
          headers,
          body,
          cache: "no-store"
        });
        let payload = {};
        try {
          payload = await response.json();
        } catch {
          payload = {};
        }
        if (!response.ok) {
          throw new ApiError(payload.error || `${response.status} ${response.statusText}`, response.status);
        }
        return payload;
      };

      const setBusy = (busy) => {
        state.busy = busy;
        document.querySelectorAll("button").forEach((button) => {
          if (button.dataset.action === "refresh") {
            button.disabled = busy;
          }
        });
      };

      const clearSession = () => {
        setToken("");
        state.status = null;
        state.control = null;
        state.live = null;
        state.strategies = null;
        state.account = null;
        state.positions = null;
        state.logs = null;
        state.candles = null;
        state.selectedSymbol = "";
        state.errors = {};
        state.redactedIdentifier = "";
        els.loginForm.reset();
      };

      const guardedLoad = async (key, loader) => {
        try {
          state[key] = await loader();
          state.errors[key] = "";
        } catch (error) {
          if (error.status === 401) {
            throw error;
          }
          state[key] = null;
          state.errors[key] = friendlyErrorText(error.message, key);
        }
      };

      const refreshAll = async ({ silent = false } = {}) => {
        if (!token()) {
          render();
          return;
        }
        setBusy(true);
        if (!silent) {
          setNotice("동기화 중입니다.");
        }
        try {
          state.status = await api("/users/me/status");
          await Promise.all([
            guardedLoad("control", () => api("/users/me/control")),
            guardedLoad("live", () => api("/users/me/live/status")),
            guardedLoad("strategies", () => api("/users/me/strategies")),
            guardedLoad("logs", () => api("/users/me/logs?limit=500")),
            guardedLoad("account", () => api("/users/me/account")),
            guardedLoad("positions", () => api("/users/me/positions"))
          ]);
          ensureSelectedSymbol();
          await guardedLoad(
            "candles",
            async () => normalizedCandleResponse(await api(chartCandlePath(state.selectedSymbol)))
          );
          state.lastUpdated = new Date();
          render();
          if (!silent) {
            setNotice("동기화 완료.", "ok");
          }
        } catch (error) {
          if (error.status === 401) {
            clearSession();
            render();
            setNotice("Bitget 세션이 만료되었습니다.", "error");
          } else {
            render();
            setNotice(error.message || "동기화 실패", "error");
          }
        } finally {
          setBusy(false);
          if (token()) {
            render();
          }
        }
      };

      const renderMetrics = () => {
        const strategies = state.strategies || state.status?.strategies || {};
        const live = state.live || state.status?.live || {};
        const config = live.executionConfig || {};
        const accountItems = state.account?.items || [];
        const positions = livePositions();
        const equity = accountItems.reduce((sum, account) => sum + (Number(account.accountEquity) || 0), 0);
        const available = accountItems.reduce((sum, account) => sum + (Number(account.available) || 0), 0);
        const enabledCount = Array.isArray(strategies.enabledStrategyIDs) ? strategies.enabledStrategyIDs.length : 0;
        const availableCount = Array.isArray(strategies.available) ? strategies.available.length : 0;
        els.metrics.innerHTML = `
          <article class="metric">
            <span>경과</span>
            <strong>${escapeHTML(elapsedText())}</strong>
            <small>자동매매 활성 시간</small>
          </article>
          <article class="metric">
            <span>최근 마감</span>
            <strong>${escapeHTML(latestClosedText())}</strong>
            <small>15분봉 기준</small>
          </article>
          <article class="metric">
            <span>포지션</span>
            <strong>${positions.length}개</strong>
            <small>열린 포지션</small>
          </article>
          <article class="metric">
            <span>전략</span>
            <strong>${enabledCount}/${availableCount}</strong>
            <small>활성 전략</small>
          </article>
          <article class="metric">
            <span>Equity</span>
            <strong>${accountItems.length ? numberText(equity, 3) : "-"}</strong>
            <small>${state.errors.account ? escapeHTML(state.errors.account) : "USDT-M Futures"}</small>
          </article>
          <article class="metric">
            <span>가용</span>
            <strong>${accountItems.length ? numberText(available, 3) : "-"}</strong>
            <small>${escapeHTML(orderLimitText(config))}</small>
          </article>
        `;
      };

      const renderLastEvaluation = () => {
        const evaluation = state.status?.lastEvaluation;
        if (!evaluation) {
          els.lastEvaluation.innerHTML = `
            <div class="evaluation-main">
              <div class="evaluation-title">아직 표시할 15분봉 평가가 없습니다.</div>
            </div>
          `;
          return;
        }
        const items = Array.isArray(evaluation.items) ? evaluation.items : [];
        const headlineTone = Number(evaluation.signalCount || 0) > 0 ? "ok" : "info";
        els.lastEvaluation.innerHTML = `
          <div class="evaluation-main">
            <div class="evaluation-title">
              마지막 평가 · ${escapeHTML(evaluation.headline || "-")}
            </div>
            <div class="evaluation-meta">
              ${pill(`${timeText(evaluation.candleCloseTimeISO)} 마감`, "info")}
              ${pill(`평가 ${evaluation.evaluatedCount || 0}`, headlineTone)}
              ${pill(`신호 ${evaluation.signalCount || 0}`, Number(evaluation.signalCount || 0) > 0 ? "ok" : "info")}
              ${Number(evaluation.failureCount || 0) > 0 ? pill(`확인 ${evaluation.failureCount}`, "warn") : ""}
            </div>
          </div>
          <div class="evaluation-items">
            ${items.slice(0, 8).map((item) => {
              const signal = item.signal || {};
              const text = item.producedSignal
                ? `${item.strategyName || item.strategyID} ${sideText(signal.side)} @ ${signal.entry || "-"}`
                : `${item.strategyName || item.strategyID}: ${item.skippedReason ? localizedLiveBlocker(item.skippedReason) : "신호 없음"}`;
              return `<span class="evaluation-item ${item.producedSignal ? "signal" : ""}">${escapeHTML(text)}</span>`;
            }).join("")}
          </div>
        `;
      };

      const renderAutomation = () => {
        const control = state.control || state.status?.control || {};
        const live = state.live || state.status?.live || {};
        const config = live.executionConfig || {};
        const blockers = [...(live.blockers || []), ...(live.orderBlockers || [])];
        const mode = automationMode();
        els.automationTitle.textContent = mode.title;
        els.automationIcon.textContent = mode.icon || "";
        els.automationIcon.className = `state-icon ${mode.tone}`;
        els.runnerStatus.innerHTML = [
          pill(control.enabled ? "ON" : "OFF", control.enabled ? "ok" : "bad"),
          pill(live.orderExecutionEnabled ? "실주문" : "대기", live.orderExecutionEnabled ? "warn" : "info"),
          pill(`${timeText(state.lastUpdated)} 갱신`, "info")
        ].join("");
        els.liveBlockers.textContent = blockers.length ? `대기 사유: ${localizedLiveBlocker(blockers[0])}` : "";
        const shouldStop = Boolean(control.enabled);
        els.automationToggle.textContent = shouldStop ? "자동매매 중단" : "자동매매 시작";
        els.automationToggle.className = shouldStop ? "danger" : "primary";
        els.automationToggle.dataset.intent = shouldStop ? "stop" : "start";
        els.automationToggle.disabled = state.busy;
      };

      const renderStrategies = () => {
        if (state.errors.strategies) {
          els.strategyList.innerHTML = empty(state.errors.strategies);
          return;
        }
        const strategies = state.strategies || state.status?.strategies || {};
        const available = Array.isArray(strategies.available) ? strategies.available : [];
        if (!available.length) {
          els.strategyList.innerHTML = empty("사용 가능한 전략이 없습니다.");
          return;
        }
        els.strategyList.innerHTML = available.map((strategy) => {
          const backtest = strategy.backtest || {};
          const parameters = strategy.parameters || {};
          const tags = [
            strategy.symbol,
            strategy.timeframe,
            backtest.profitFactor ? `PF ${ratioText(backtest.profitFactor, 2)}` : "",
            backtest.winRatePercent ? `승률 ${percentValueText(backtest.winRatePercent)}` : "",
            backtest.maxDrawdownPercent ? `MDD ${percentValueText(backtest.maxDrawdownPercent)}` : ""
          ].filter(Boolean);
          const details = [
            ["수익률", backtest.netReturnPercent ? percentValueText(backtest.netReturnPercent) : "-"],
            ["최종 자산", backtest.finalBalance ? amountText(backtest.finalBalance) : "-"],
            ["승률", backtest.winRatePercent ? percentValueText(backtest.winRatePercent) : "-"],
            ["MDD", backtest.maxDrawdownPercent ? percentValueText(backtest.maxDrawdownPercent) : "-"],
            ["PF", backtest.profitFactor ? ratioText(backtest.profitFactor, 2) : "-"],
            ["총 거래", backtest.totalTrades ? countText(backtest.totalTrades) : "-"],
            ["연 거래", backtest.annualTrades ? ratioText(backtest.annualTrades, 1) : "-"],
            ["과최적화", backtest.robustness || "-"],
            ["레버리지", parameters.leverage ? `${parameters.leverage}x` : "-"],
            ["RR", parameters.reward_risk_ratio || parameters.tight_reward_risk_ratio || "-"]
          ];
          const paramTags = Object.entries(parameters)
            .filter(([key]) => !["leverage", "reward_risk_ratio", "tight_reward_risk_ratio"].includes(key))
            .slice(0, 14);
          return `
            <article class="strategy-item" data-strategy-card="${escapeHTML(strategy.id)}">
              <div class="strategy-top">
                <input type="checkbox" data-strategy-id="${escapeHTML(strategy.id)}" ${strategy.enabled ? "checked" : ""}>
                <span class="strategy-content">
                  <span class="strategy-main">
                    <span class="strategy-name">${escapeHTML(strategy.name || strategy.id)}</span>
                    <span class="strategy-stats">${tags.map((tag) => `<span class="tag">${escapeHTML(tag)}</span>`).join("")}</span>
                  </span>
                  <span class="strategy-id">${escapeHTML(strategy.id)}</span>
                </span>
                <button type="button" class="detail-toggle" data-action="strategy-detail">상세</button>
              </div>
              <div class="strategy-detail">
                <div class="strategy-detail-grid">
                  ${details.map(([label, value]) => `
                    <div><span>${escapeHTML(label)}</span><strong>${escapeHTML(value)}</strong></div>
                  `).join("")}
                </div>
                <div class="tagline">
                  ${backtest.label ? `<span class="tag">${escapeHTML(backtest.label)}</span>` : ""}
                  ${backtest.period ? `<span class="tag">${escapeHTML(backtest.period)}</span>` : ""}
                  ${backtest.robustnessNote ? `<span class="tag">${escapeHTML(backtest.robustnessNote)}</span>` : ""}
                  <span class="tag">과최적화 기준: 연도/반기 플러스 비율, 최악 구간 손실, 수익 집중도, 거래 수, MDD, 극단 복리</span>
                  ${paramTags.map(([key, value]) => `<span class="tag">${escapeHTML(key)} ${escapeHTML(value)}</span>`).join("")}
                </div>
              </div>
            </article>
          `;
        }).join("");
      };

      const renderChartControls = () => {
        ensureSelectedSymbol();
        const symbols = availableSymbols();
        const options = (symbols.length ? symbols : [state.selectedSymbol || "BTCUSDT"])
          .map((symbol) => `<option value="${escapeHTML(symbol)}">${escapeHTML(symbol)}</option>`)
          .join("");
        if (els.chartSymbol.innerHTML !== options) {
          els.chartSymbol.innerHTML = options;
        }
        els.chartSymbol.value = state.selectedSymbol || symbols[0] || "BTCUSDT";
        els.chartSymbol.disabled = !symbols.length || state.busy;
      };

      const renderChartMessage = (message) => {
        els.chartLegend.innerHTML = "";
        const canvas = els.chartCanvas;
        const rect = canvas.getBoundingClientRect();
        const width = Math.max(320, Math.floor(rect.width || 640));
        const height = Math.max(180, Math.floor(rect.height || 260));
        const dpr = window.devicePixelRatio || 1;
        canvas.width = Math.floor(width * dpr);
        canvas.height = Math.floor(height * dpr);
        const ctx = canvas.getContext("2d");
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.fillStyle = "#151515";
        ctx.fillRect(0, 0, width, height);
        ctx.fillStyle = "#a8a8a8";
        ctx.font = "12px system-ui, -apple-system, BlinkMacSystemFont, sans-serif";
        ctx.fillText(message, 14, 24);
      };

      const renderChart = () => {
        renderChartControls();
        if (state.errors.candles) {
          renderChartMessage(state.errors.candles);
          return;
        }
        const candles = chartCandles();
        if (!candles.length) {
          renderChartMessage("표시할 캔들이 없습니다.");
          return;
        }

        const canvas = els.chartCanvas;
        const wrapper = canvas.parentElement;
        const rect = canvas.getBoundingClientRect();
        const width = Math.max(320, Math.floor(rect.width || 640));
        const height = Math.max(180, Math.floor(rect.height || 260));
        const dpr = window.devicePixelRatio || 1;
        canvas.width = Math.floor(width * dpr);
        canvas.height = Math.floor(height * dpr);
        const ctx = canvas.getContext("2d");
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.fillStyle = "#151515";
        ctx.fillRect(0, 0, width, height);

        const viewport = visibleChartWindow(candles);
        maybeLoadOlderChartCandles(viewport);
        const { start, renderStart, renderEnd, visibleCount } = viewport;
        const visible = candles.slice(renderStart, renderEnd);
        const seriesByKey = Object.fromEntries(
          INDICATORS.map((indicator) => [
            indicator.key,
            movingAverageSeries(candles, indicator.period, indicator.type)
          ])
        );
        const indicatorValues = INDICATORS.flatMap((indicator) => (
          seriesByKey[indicator.key].slice(renderStart, renderEnd).filter((value) => Number.isFinite(value))
        ));

        const padLeft = 12;
        const padRight = 62;
        const padTop = 18;
        const padBottom = 24;
        const chartWidth = width - padLeft - padRight;
        const chartHeight = height - padTop - padBottom;
        const highs = visible.map((candle) => candle.high);
        const lows = visible.map((candle) => candle.low);
        const maxPrice = Math.max(...highs);
        const minPrice = Math.min(...lows);
        const indicatorMax = indicatorValues.length ? Math.max(...indicatorValues) : maxPrice;
        const indicatorMin = indicatorValues.length ? Math.min(...indicatorValues) : minPrice;
        const upper = Math.max(maxPrice, indicatorMax);
        const lower = Math.min(minPrice, indicatorMin);
        const baseRange = Math.max(upper - lower, upper * 0.001, 1);
        const priceScale = Math.max(0.05, Number(state.chart.priceScaleRatio || 1));
        const range = baseRange * priceScale;
        const priceCenter = (upper + lower) / 2;
        const priceOffset = Number(state.chart.priceOffsetRatio || 0) * range;
        const viewUpper = priceCenter + range / 2 + priceOffset;
        const y = (price) => padTop + ((viewUpper - price) / range) * chartHeight;

        ctx.strokeStyle = "#2c2c2c";
        ctx.lineWidth = 1;
        for (let i = 0; i <= 4; i += 1) {
          const gy = padTop + (chartHeight / 4) * i;
          ctx.beginPath();
          ctx.moveTo(padLeft, gy);
          ctx.lineTo(width - padRight, gy);
          ctx.stroke();
          const price = viewUpper - (range / 4) * i;
          ctx.fillStyle = "#8e8e93";
          ctx.font = "10px system-ui, -apple-system, BlinkMacSystemFont, sans-serif";
          ctx.fillText(numberText(price, 2), width - padRight + 8, gy + 3);
        }

        const slot = chartWidth / visibleCount;
        const bodyWidth = Math.max(2, Math.min(8, slot * 0.58));
        visible.forEach((candle, index) => {
          const absoluteIndex = renderStart + index;
          const rising = candle.close >= candle.open;
          const x = padLeft + slot * (absoluteIndex - start) + slot / 2;
          const color = rising ? "#35d06f" : "#ff5b57";
          const highY = y(candle.high);
          const lowY = y(candle.low);
          const openY = y(candle.open);
          const closeY = y(candle.close);
          const top = Math.min(openY, closeY);
          const bodyHeight = Math.max(Math.abs(openY - closeY), 1.5);

          ctx.strokeStyle = color;
          ctx.beginPath();
          ctx.moveTo(x, highY);
          ctx.lineTo(x, lowY);
          ctx.stroke();
          ctx.fillStyle = color;
          ctx.fillRect(x - bodyWidth / 2, top, bodyWidth, bodyHeight);
        });

        INDICATORS.forEach((indicator) => {
          const values = seriesByKey[indicator.key];
          ctx.strokeStyle = indicator.color;
          ctx.lineWidth = indicator.type === "vwma" ? 1.45 : 1.1;
          ctx.beginPath();
          let started = false;
          for (let absoluteIndex = renderStart; absoluteIndex < renderEnd; absoluteIndex += 1) {
            const value = values[absoluteIndex];
            if (!Number.isFinite(value)) {
              started = false;
              continue;
            }
            const x = padLeft + slot * (absoluteIndex - start) + slot / 2;
            const yy = y(value);
            if (!started) {
              ctx.moveTo(x, yy);
              started = true;
            } else {
              ctx.lineTo(x, yy);
            }
          }
          ctx.stroke();
        });

        const drawLevelLine = (label, price, color, dash = []) => {
          const numeric = Number(price);
          if (!Number.isFinite(numeric) || numeric <= 0) {
            return;
          }
          const yy = y(numeric);
          if (yy < padTop - 28 || yy > padTop + chartHeight + 28) {
            return;
          }
          const text = `${label} ${numberText(numeric, 2)}`;
          const labelY = Math.max(padTop + 10, Math.min(yy - 4, height - padBottom - 5));
          ctx.save();
          ctx.strokeStyle = color;
          ctx.lineWidth = 1;
          ctx.setLineDash(dash);
          ctx.beginPath();
          ctx.moveTo(padLeft, yy);
          ctx.lineTo(width - padRight, yy);
          ctx.stroke();
          ctx.setLineDash([]);
          ctx.font = "10px system-ui, -apple-system, BlinkMacSystemFont, sans-serif";
          const labelWidth = Math.min(ctx.measureText(text).width + 10, chartWidth - 10);
          ctx.globalAlpha = 0.78;
          ctx.fillStyle = "#151515";
          ctx.fillRect(padLeft + 4, labelY - 11, labelWidth, 15);
          ctx.globalAlpha = 1;
          ctx.fillStyle = color;
          ctx.fillText(text, padLeft + 8, labelY);
          ctx.restore();
        };

        livePositions()
          .filter((position) => String(position.symbol || "").toUpperCase() === state.selectedSymbol)
          .forEach((position) => {
            drawLevelLine("현재", position.markPrice, "#f2f2f7", [2, 4]);
            drawLevelLine("진입", position.openPriceAvg, "#ffcc00");
            drawLevelLine("TP1", position.partialTakeProfit, "#30d158", [6, 4]);
            drawLevelLine("TP2", position.takeProfit, "#35d06f");
            drawLevelLine("SL", position.stopLoss, "#ff453a");
          });

        const latest = visible[visible.length - 1];
        ctx.fillStyle = "#a8a8a8";
        ctx.font = "11px system-ui, -apple-system, BlinkMacSystemFont, sans-serif";
        ctx.fillText(`${state.selectedSymbol} · ${numberText(latest.close, 2)}`, padLeft, 13);
        ctx.fillText(timeText(latest.openTimeISO), padLeft, height - 7);
        if (state.chart.rightOffset > 0) {
          ctx.fillStyle = "#ff9f0a";
          ctx.fillText(`${state.chart.rightOffset}봉 전`, width - padRight - 54, height - 7);
        } else if (state.chart.rightOffset < 0) {
          ctx.fillStyle = "#8e8e93";
          ctx.fillText(`${Math.abs(state.chart.rightOffset)}봉 여백`, width - padRight - 58, height - 7);
        }
        els.chartLegend.innerHTML = INDICATORS.map((indicator) => `
          <span class="legend-item">
            <span class="legend-swatch" style="background:${indicator.color}"></span>${escapeHTML(indicator.label)}
          </span>
        `).join("");
        if (wrapper) {
          wrapper.title = "차트 패널 상하좌우 이동, 오른쪽 가격축 드래그로 가격 줌, 두 손가락 핀치/트랙패드 줌, 더블클릭으로 복귀";
        }
      };

      const renderPositions = () => {
        if (state.errors.positions) {
          els.positionCount.textContent = "";
          els.positions.innerHTML = empty(state.errors.positions);
          return;
        }
        const items = livePositions();
        els.positionCount.textContent = `${items.length}개`;
        if (!items.length) {
          els.positions.innerHTML = empty("열린 포지션이 없습니다.");
          return;
        }
        els.positions.innerHTML = `
          <div class="position-list">
            ${items.map((position) => {
              const pnl = Number(position.unrealizedPL || 0);
              return `
                <article class="position-card">
                  <div class="position-top">
                    <div>
                      <div class="position-symbol">
                        <span>${escapeHTML(position.symbol || "-")}</span>
                        <span class="side-chip ${sideClass(position.holdSide)}">${escapeHTML(sideText(position.holdSide))}</span>
                      </div>
                      <div class="position-meta">
                        ${escapeHTML(position.marginMode || "-")} · ${escapeHTML(position.leverage || "-")}x · ${escapeHTML(numberText(position.total || position.available, 6))}
                      </div>
                    </div>
                    <div class="position-pnl ${valueToneClass(pnl)}">${escapeHTML(signedNumber(pnl))}</div>
                  </div>
                  <div class="position-metrics">
                    <div><span>Entry</span><strong>${escapeHTML(numberText(position.openPriceAvg, 4))}</strong></div>
                    <div><span>Mark</span><strong>${escapeHTML(numberText(position.markPrice, 4))}</strong></div>
                    <div><span>Size</span><strong>${escapeHTML(numberText(position.total || position.available, 6))}</strong></div>
                    <div><span>Liq</span><strong>${escapeHTML(numberText(position.liquidationPrice, 4))}</strong></div>
                    <div><span>TP1</span><strong>${escapeHTML(position.partialTakeProfit || "-")}</strong></div>
                    <div><span>TP2</span><strong>${escapeHTML(position.takeProfit || "-")}</strong></div>
                    <div><span>SL</span><strong>${escapeHTML(position.stopLoss || "-")}</strong></div>
                    <div><span>Mode</span><strong>${escapeHTML(position.posMode || "-")}</strong></div>
                  </div>
                </article>
              `;
            }).join("")}
          </div>
        `;
      };

      const renderLogSummary = (items) => {
        const riskCount = items.filter((item) => (
          String(item.category || "").toLowerCase() === "risk" ||
          String(item.severity || "").toLowerCase() === "error"
        )).length;
        const orderCount = items.filter((item) => String(item.category || "") === "liveOrder").length;
        const unrealized = currentUnrealizedPnl();
        const latest = items.length ? timeText(items[items.length - 1].timestamp) : "-";
        els.logSummary.innerHTML = `
          <div class="summary-cell">
            <span>기록</span>
            <strong>${items.length}</strong>
          </div>
          <div class="summary-cell">
            <span>주문</span>
            <strong>${orderCount}</strong>
          </div>
          <div class="summary-cell">
            <span>승률</span>
            <strong>-</strong>
          </div>
          <div class="summary-cell">
            <span>미실현</span>
            <strong class="${valueToneClass(unrealized)}">${signedNumber(unrealized)}</strong>
          </div>
          <div class="summary-cell">
            <span>최근</span>
            <strong>${escapeHTML(latest)}</strong>
          </div>
          ${riskCount ? `
            <div class="summary-cell">
              <span>주의</span>
              <strong class="loss">${riskCount}</strong>
            </div>
          ` : ""}
        `;
      };

      const renderLogs = () => {
        if (state.errors.logs) {
          els.logCount.textContent = "";
          els.logSummary.innerHTML = "";
          els.logs.innerHTML = empty(state.errors.logs);
          return;
        }
        const items = visibleTradeLogs();
        els.logCount.textContent = `${items.length}`;
        renderLogSummary(items);
        if (!items.length) {
          els.logs.innerHTML = empty("실거래 매매기록이 없습니다.");
          return;
        }
        els.logs.innerHTML = items.slice().reverse().map((item) => {
          const metadata = item.metadata || {};
          const details = metadata.details || {};
          const tags = Array.isArray(metadata.tags) ? metadata.tags : [];
          const isError = String(item.severity || "").toLowerCase() === "error";
          const subtitle = isError && item.message
            ? item.message
            : (metadata.subtitle || item.message || "");
          const safeDetails = Object.entries(details)
            .filter(([key]) => SAFE_DETAIL_KEYS.has(key))
            .slice(0, 8);
          return `
            <article class="row-card">
              <div class="row-title">
                <div>
                  <strong>${escapeHTML(metadata.title || item.category || "record")}</strong>
                  <div class="mini muted">${escapeHTML(subtitle)}</div>
                </div>
                ${pill(item.severity || "info", severityClass(item.severity))}
              </div>
              <div class="tagline">
                <span class="tag">${escapeHTML(timeText(item.timestamp))}</span>
                ${item.symbol ? `<span class="tag">${escapeHTML(item.symbol)}</span>` : ""}
                ${tags.slice(0, 5).map((tag) => `<span class="tag">${escapeHTML(tag)}</span>`).join("")}
              </div>
              ${safeDetails.length ? `
                <div class="kv">
                  ${safeDetails.map(([key, value]) => `
                    <div><span>${escapeHTML(key)}</span><strong>${escapeHTML(value)}</strong></div>
                  `).join("")}
                </div>
              ` : ""}
            </article>
          `;
        }).join("");
      };

      const render = () => {
        const authenticated = Boolean(token());
        els.loginPanel.hidden = authenticated;
        els.dashboard.hidden = !authenticated;
        document.querySelector('[data-action="bitget-logout"]').hidden = !authenticated;
        if (!authenticated) {
          els.metrics.innerHTML = "";
          els.lastEvaluation.innerHTML = "";
          return;
        }
        renderMetrics();
        renderLastEvaluation();
        renderAutomation();
        renderStrategies();
        renderPositions();
        renderChart();
        renderLogs();
      };

      const saveStrategies = async () => {
        const checked = [...els.strategyList.querySelectorAll("input[data-strategy-id]:checked")]
          .map((input) => input.dataset.strategyId)
          .filter(Boolean);
        if (!checked.length) {
          setNotice("최소 1개 전략을 선택해야 합니다.", "error");
          return;
        }
        await api("/users/me/strategies", {
          method: "POST",
          body: { enabledStrategyIDs: checked }
        });
        await refreshAll();
      };

      const startAutomation = async () => {
        await api("/users/me/control", {
          method: "POST",
          body: { enabled: true }
        });
        await api("/users/me/live/control", {
          method: "POST",
          body: { enabled: true, acknowledgedRisk: true }
        });
        await refreshAll();
      };

      const stopAutomation = async () => {
        await api("/users/me/live/control", {
          method: "POST",
          body: { enabled: false, acknowledgedRisk: false }
        });
        await api("/users/me/control", {
          method: "POST",
          body: { enabled: false }
        });
        await refreshAll();
      };

      const logoutBitget = async () => {
        try {
          if (token()) {
            await api("/users/me/session", { method: "DELETE" });
          }
        } catch {
          // Remove the browser token even if the server already revoked it.
        } finally {
          clearSession();
          render();
          setNotice("Bitget 세션을 종료했습니다.", "ok");
        }
      };

      const clamp = (value, minimum, maximum) => Math.max(minimum, Math.min(value, maximum));

      const setupResizablePanels = () => {
        applyLayout();
        const root = document.documentElement;
        const dashboard = document.querySelector(".dashboard");
        const leftStack = document.querySelector(".left-stack");
        document.querySelectorAll(".splitter[data-resize]").forEach((splitter) => {
          splitter.addEventListener("pointerdown", (event) => {
            if (window.matchMedia("(max-width: 900px)").matches) {
              return;
            }
            event.preventDefault();
            splitter.classList.add("dragging");
            splitter.setPointerCapture(event.pointerId);
            const mode = splitter.dataset.resize;
            const move = (moveEvent) => {
              if (mode === "columns" && dashboard) {
                const rect = dashboard.getBoundingClientRect();
                const width = clamp(rect.right - moveEvent.clientX, 320, rect.width - 360);
                root.style.setProperty("--right-pane-width", `${width}px`);
                saveLayout({ rightPaneWidth: Math.round(width) });
              } else if (mode === "position-chart" && leftStack) {
                const rect = leftStack.getBoundingClientRect();
                const height = clamp(moveEvent.clientY - rect.top, 96, rect.height - 390);
                root.style.setProperty("--position-pane-height", `${height}px`);
                saveLayout({ positionPaneHeight: Math.round(height) });
              } else if (mode === "chart-strategy" && leftStack) {
                const chartPanel = els.chartCanvas.closest(".panel");
                if (!chartPanel) {
                  return;
                }
                const chartRect = chartPanel.getBoundingClientRect();
                const stackRect = leftStack.getBoundingClientRect();
                const maxHeight = Math.max(420, stackRect.bottom - chartRect.top - 270);
                const height = clamp(moveEvent.clientY - chartRect.top, 220, maxHeight);
                root.style.setProperty("--chart-pane-height", `${height}px`);
                saveLayout({ chartPaneHeight: Math.round(height) });
              }
              renderChart();
            };
            const up = () => {
              splitter.classList.remove("dragging");
              splitter.removeEventListener("pointermove", move);
              splitter.removeEventListener("pointerup", up);
              splitter.removeEventListener("pointercancel", up);
            };
            splitter.addEventListener("pointermove", move);
            splitter.addEventListener("pointerup", up);
            splitter.addEventListener("pointercancel", up);
          });
        });
      };

      const loadOlderChartCandles = async () => {
        if (state.chart.loadingMore || !state.candles?.hasMoreBefore || !token()) {
          return;
        }
        const candles = chartCandles();
        const oldestOpenTime = candles[0]?.openTime;
        if (!oldestOpenTime) {
          return;
        }
        state.chart.loadingMore = true;
        try {
          const response = await api(chartCandlePath(state.selectedSymbol, oldestOpenTime));
          mergeCandleResponse(response);
          state.chart.loadingMore = false;
          renderChart();
        } catch (error) {
          if (error.status === 401) {
            clearSession();
            render();
            setNotice("Bitget 세션이 만료되었습니다.", "error");
          } else {
            setNotice(error.message || "과거 캔들 로딩 실패", "error");
          }
        } finally {
          state.chart.loadingMore = false;
        }
      };

      const maybeLoadOlderChartCandles = (viewport) => {
        if (!viewport || !state.candles?.hasMoreBefore || state.chart.loadingMore) {
          return;
        }
        if (viewport.start <= CHART_PREFETCH_THRESHOLD) {
          void loadOlderChartCandles();
        }
      };

      const chartSlotWidth = () => {
        const candles = chartCandles();
        const { visibleCount } = visibleChartWindow(candles);
        const rect = els.chartCanvas.getBoundingClientRect();
        const count = Math.max(visibleCount, 1);
        return Math.max((rect.width - 74) / count, 2);
      };

      const clampChartViewport = () => {
        const total = chartCandles().length;
        state.chart.visibleCount = Math.max(MIN_CHART_VISIBLE, Math.round(Number(state.chart.visibleCount) || DEFAULT_CHART_VISIBLE));
        const minimumVisibleCandles = Math.min(total, 5);
        const maxFutureBlank = Math.max(state.chart.visibleCount - minimumVisibleCandles, 0);
        const maxPastOffset = Math.max(total - minimumVisibleCandles, 0);
        state.chart.rightOffset = clamp(state.chart.rightOffset, -maxFutureBlank, maxPastOffset);
      };

      const panChartByCandles = (delta) => {
        if (!delta) {
          return;
        }
        state.chart.rightOffset += delta;
        clampChartViewport();
        renderChart();
      };

      const zoomChartByCandles = (delta) => {
        if (!delta) {
          return;
        }
        state.chart.visibleCount += delta;
        clampChartViewport();
        renderChart();
      };

      const resetChartViewport = () => {
        state.chart.rightOffset = 0;
        state.chart.visibleCount = DEFAULT_CHART_VISIBLE;
        state.chart.priceOffsetRatio = 0;
        state.chart.priceScaleRatio = 1;
        state.chart.wheelRemainder = 0;
        state.chart.zoomRemainder = 0;
        clampChartViewport();
        renderChart();
      };

      const setupChartInteractions = () => {
        const wrapper = els.chartCanvas.parentElement;
        const surface = els.chartCanvas.closest(".chart-panel-body") || wrapper;
        if (!wrapper || !surface) {
          return;
        }
        const pointerDistance = () => {
          const pointers = [...state.chart.activePointers.values()];
          if (pointers.length < 2) {
            return 0;
          }
          return Math.hypot(pointers[0].x - pointers[1].x, pointers[0].y - pointers[1].y);
        };
        const startPinch = () => {
          state.chart.dragging = false;
          state.chart.dragMode = "pinch";
          state.chart.pinchDistance = pointerDistance();
          state.chart.pinchVisibleCount = state.chart.visibleCount;
        };
        const updatePinch = () => {
          const distance = pointerDistance();
          if (state.chart.pinchDistance <= 0 || distance <= 0) {
            startPinch();
            return;
          }
          const ratio = distance / state.chart.pinchDistance;
          if (!Number.isFinite(ratio) || ratio <= 0) {
            return;
          }
          state.chart.visibleCount = Math.round(state.chart.pinchVisibleCount / ratio);
          clampChartViewport();
          renderChart();
        };
        const isPriceAxisPointer = (event) => {
          const rect = els.chartCanvas.getBoundingClientRect();
          return event.clientX >= rect.right - 70 &&
            event.clientX <= rect.right &&
            event.clientY >= rect.top &&
            event.clientY <= rect.bottom;
        };
        surface.addEventListener("pointerdown", (event) => {
          if (!token()) {
            return;
          }
          state.chart.activePointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
          surface.setPointerCapture(event.pointerId);
          if (state.chart.activePointers.size >= 2) {
            event.preventDefault();
            startPinch();
            return;
          }
          if (isPriceAxisPointer(event)) {
            event.preventDefault();
            state.chart.dragging = true;
            state.chart.lastX = event.clientX;
            state.chart.lastY = event.clientY;
            state.chart.dragMode = "priceZoom";
            return;
          }
          state.chart.dragging = true;
          state.chart.lastX = event.clientX;
          state.chart.lastY = event.clientY;
          state.chart.dragMode = "";
        });
        surface.addEventListener("pointermove", (event) => {
          if (state.chart.activePointers.has(event.pointerId)) {
            state.chart.activePointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
          }
          if (state.chart.activePointers.size >= 2) {
            event.preventDefault();
            updatePinch();
            return;
          }
          if (!state.chart.dragging) {
            return;
          }
          const deltaX = event.clientX - state.chart.lastX;
          const deltaY = event.clientY - state.chart.lastY;
          if (state.chart.dragMode === "priceZoom") {
            event.preventDefault();
            if (Math.abs(deltaY) >= 1) {
              state.chart.priceScaleRatio = Math.max(0.05, Number(state.chart.priceScaleRatio || 1) * Math.exp(deltaY / 160));
              state.chart.lastY = event.clientY;
              renderChart();
            }
            return;
          }
          if (!state.chart.dragMode) {
            if (Math.max(Math.abs(deltaX), Math.abs(deltaY)) < 4) {
              return;
            }
            state.chart.dragMode = "pan";
          }
          event.preventDefault();
          const slot = chartSlotWidth();
          let changed = false;
          if (Math.abs(deltaX) >= slot) {
            const candleDelta = Math.trunc(deltaX / slot);
            state.chart.lastX = event.clientX;
            state.chart.rightOffset += candleDelta;
            changed = true;
          }
          if (Math.abs(deltaY) >= 1) {
            const rect = els.chartCanvas.getBoundingClientRect();
            const chartHeight = Math.max(rect.height - 42, 1);
            state.chart.priceOffsetRatio += deltaY / chartHeight;
            state.chart.lastY = event.clientY;
            changed = true;
          }
          if (changed) {
            clampChartViewport();
            renderChart();
          }
        });
        const endDrag = (event) => {
          if (event && state.chart.activePointers.has(event.pointerId)) {
            state.chart.activePointers.delete(event.pointerId);
          }
          if (state.chart.activePointers.size >= 2) {
            startPinch();
            return;
          }
          state.chart.dragging = false;
          state.chart.dragMode = "";
          state.chart.pinchDistance = 0;
        };
        surface.addEventListener("pointerup", endDrag);
        surface.addEventListener("pointercancel", endDrag);
        surface.addEventListener("lostpointercapture", endDrag);
        surface.addEventListener("wheel", (event) => {
          if (!token()) {
            return;
          }
          event.preventDefault();
          if (Math.abs(event.deltaY) >= Math.abs(event.deltaX)) {
            state.chart.zoomRemainder += event.deltaY;
            const zoomSteps = Math.trunc(state.chart.zoomRemainder / 80);
            if (zoomSteps) {
              state.chart.zoomRemainder -= zoomSteps * 80;
              zoomChartByCandles(zoomSteps * 12);
            }
          } else {
            state.chart.wheelRemainder += event.deltaX;
            const candleDelta = Math.trunc(state.chart.wheelRemainder / 24);
            if (candleDelta) {
              state.chart.wheelRemainder -= candleDelta * 24;
              panChartByCandles(candleDelta);
            }
          }
        }, { passive: false });
        surface.addEventListener("dblclick", () => {
          resetChartViewport();
        });
        surface.addEventListener("gesturestart", (event) => {
          if (!token()) {
            return;
          }
          event.preventDefault();
          state.chart.gestureVisibleCount = state.chart.visibleCount;
        }, { passive: false });
        surface.addEventListener("gesturechange", (event) => {
          if (!token()) {
            return;
          }
          event.preventDefault();
          const scale = Number(event.scale || 1);
          if (!Number.isFinite(scale) || scale <= 0) {
            return;
          }
          state.chart.visibleCount = Math.round(state.chart.gestureVisibleCount / scale);
          clampChartViewport();
          renderChart();
        }, { passive: false });
      };

      els.loginForm.addEventListener("submit", async (event) => {
        event.preventDefault();
        const form = new FormData(els.loginForm);
        const payload = {
          apiKey: String(form.get("apiKey") || "").trim(),
          secretKey: String(form.get("secretKey") || "").trim(),
          passphrase: String(form.get("passphrase") || "").trim()
        };
        setBusy(true);
        setNotice("Bitget 로그인 중입니다.");
        try {
          const response = await api("/auth/bitget/login", {
            method: "POST",
            body: payload
          });
          els.loginForm.reset();
          if (!response.authToken) {
            throw new ApiError("로그인 응답에 토큰이 없습니다.", 500);
          }
          setToken(response.authToken);
          state.redactedIdentifier = response.redactedIdentifier || "";
          setNotice("Bitget 로그인 완료.", "ok");
          await refreshAll({ silent: true });
        } catch (error) {
          els.loginForm.reset();
          setNotice(error.message || "Bitget 로그인 실패", "error");
        } finally {
          payload.apiKey = "";
          payload.secretKey = "";
          payload.passphrase = "";
          setBusy(false);
        }
      });

      els.lockForm.addEventListener("submit", () => {
        clearSession();
      });

      els.chartSymbol.addEventListener("change", async (event) => {
        if (state.busy || !token()) {
          return;
        }
        state.selectedSymbol = String(event.target.value || "").toUpperCase();
        state.chart.rightOffset = 0;
        state.chart.visibleCount = DEFAULT_CHART_VISIBLE;
        state.chart.priceOffsetRatio = 0;
        state.chart.priceScaleRatio = 1;
        setBusy(true);
        try {
          await guardedLoad(
            "candles",
            async () => normalizedCandleResponse(await api(chartCandlePath(state.selectedSymbol)))
          );
          renderChart();
        } catch (error) {
          if (error.status === 401) {
            clearSession();
            render();
            setNotice("Bitget 세션이 만료되었습니다.", "error");
          } else {
            setNotice(error.message || "차트 로딩 실패", "error");
            renderChart();
          }
        } finally {
          setBusy(false);
          if (token()) {
            render();
          }
        }
      });

      document.addEventListener("click", async (event) => {
        const button = event.target.closest("button[data-action]");
        if (!button || state.busy) {
          return;
        }
        const action = button.dataset.action;
        try {
          if (action === "refresh") {
            await refreshAll();
          } else if (action === "bitget-logout") {
            await logoutBitget();
          } else if (action === "automation-toggle") {
            if (button.dataset.intent === "stop") {
              await stopAutomation();
            } else {
              await startAutomation();
            }
          } else if (action === "strategies-save") {
            await saveStrategies();
          } else if (action === "strategy-detail") {
            const card = button.closest(".strategy-item");
            if (card) {
              card.classList.toggle("expanded");
              button.textContent = card.classList.contains("expanded") ? "접기" : "상세";
            }
          } else if (action === "chart-zoom-in") {
            zoomChartByCandles(-20);
          } else if (action === "chart-zoom-out") {
            zoomChartByCandles(20);
          } else if (action === "chart-reset") {
            resetChartViewport();
          }
        } catch (error) {
          if (error.status === 401) {
            clearSession();
            render();
            setNotice("Bitget 세션이 만료되었습니다.", "error");
          } else {
            setNotice(error.message || "요청 실패", "error");
          }
        }
      });

      setupResizablePanels();
      setupChartInteractions();
      render();
      refreshAll({ silent: true });
      window.setInterval(() => refreshAll({ silent: true }), REFRESH_MS);
      window.addEventListener("resize", () => {
        if (token()) {
          renderChart();
        }
      });
    })();
  </script>
</body>
</html>"""

    def write_json(self, payload: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def write_html(self, payload: str, status: HTTPStatus = HTTPStatus.OK) -> None:
        body = payload.encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


class PaperRunner:
    def __init__(self) -> None:
        self.data_dir = Path(os.environ.get("BUCKS_COPY_DATA_DIR", "/var/lib/bucks-copy"))
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.symbols = self.parse_symbols(os.environ.get("BUCKS_COPY_SYMBOLS", "BTCUSDT,ETHUSDT"))
        configured_candle_limit = int(os.environ.get("BUCKS_COPY_CANDLE_LIMIT", str(DEFAULT_CANDLE_STORAGE_LIMIT)))
        self.candle_limit = max(configured_candle_limit, 0)
        self.fetch_candle_limit = min(
            max(int(os.environ.get("BUCKS_COPY_FETCH_CANDLE_LIMIT", str(MAX_CANDLE_FETCH_LIMIT))), 1),
            MAX_CANDLE_FETCH_LIMIT,
        )
        self.history_backfill_pages_per_cycle = clamp_int(
            os.environ.get("BUCKS_COPY_HISTORY_BACKFILL_PAGES_PER_CYCLE"),
            default=100,
            minimum=0,
            maximum=2_000,
        )
        self.poll_seconds = max(int(os.environ.get("BUCKS_COPY_POLL_SECONDS", "30")), 5)
        self.private_poll_seconds = max(int(os.environ.get("BUCKS_COPY_PRIVATE_POLL_SECONDS", "60")), 30)
        self.base_url = os.environ.get("BUCKS_COPY_BITGET_BASE_URL", DEFAULT_BASE_URL).rstrip("/")
        self.live_order_execution_enabled = parse_bool(os.environ.get("BUCKS_COPY_LIVE_ORDER_EXECUTION_ENABLED"))
        self.live_order_margin_usdt = max(
            parse_decimal_env(os.environ.get("BUCKS_COPY_LIVE_ORDER_MARGIN_USDT")),
            dec(0),
        )
        self.live_available_balance_ratio = min(
            max(parse_decimal_env(os.environ.get("BUCKS_COPY_LIVE_AVAILABLE_BALANCE_RATIO"), dec(1)), dec(0)),
            dec(1),
        )
        self.live_margin_mode = os.environ.get("BUCKS_COPY_LIVE_MARGIN_MODE", "isolated").strip().lower() or "isolated"
        self.live_position_mode = self.normalized_live_position_mode(
            os.environ.get("BUCKS_COPY_LIVE_POSITION_MODE", "hedge")
        )
        self.live_confirmation_attempts = clamp_int(
            os.environ.get("BUCKS_COPY_LIVE_CONFIRMATION_ATTEMPTS"),
            default=8,
            minimum=1,
            maximum=20,
        )
        self.live_confirmation_delay_seconds = max(
            parse_decimal_env(os.environ.get("BUCKS_COPY_LIVE_CONFIRMATION_DELAY_SECONDS"), Decimal("0.35")),
            dec(0),
        )
        self.live_protection_retry_attempts = max(
            clamp_int(os.environ.get("BUCKS_COPY_LIVE_PROTECTION_RETRY_ATTEMPTS"), default=5, minimum=5, maximum=12),
            5,
        )
        self.run_once = parse_bool(os.environ.get("BUCKS_COPY_RUN_ONCE"))
        self.api_host = os.environ.get("BUCKS_COPY_API_HOST", DEFAULT_API_HOST)
        self.api_port = clamp_int(os.environ.get("BUCKS_COPY_API_PORT"), DEFAULT_API_PORT, 1, 65535)
        self.api_enabled = parse_bool(os.environ.get("BUCKS_COPY_API_ENABLED"), default=not self.run_once)
        self.default_user_id = validate_user_id(os.environ.get("BUCKS_COPY_DEFAULT_USER_ID", DEFAULT_USER_ID))
        self.auth_users_path = Path(
            os.environ.get("BUCKS_COPY_AUTH_USERS_PATH", str(self.data_dir / "auth-users.json"))
        )
        self.require_auth = parse_bool(os.environ.get("BUCKS_COPY_REQUIRE_AUTH"), default=False)
        self.web_access_key = os.environ.get("BUCKS_COPY_WEB_ACCESS_KEY", "").strip()
        if self.web_access_key and len(self.web_access_key) < 8:
            raise ValueError("BUCKS_COPY_WEB_ACCESS_KEY must be at least 8 characters.")
        self.web_access_profiles_path = Path(
            os.environ.get("BUCKS_COPY_WEB_ACCESS_PROFILES_PATH", str(self.data_dir / "web-access-profiles.json"))
        )
        self.web_access_profiles_by_id = self.load_web_access_profiles()
        self.web_access_gate_enabled = bool(self.web_access_key or self.web_access_profiles_by_id)
        self.web_access_session_seconds = clamp_int(
            os.environ.get("BUCKS_COPY_WEB_ACCESS_SESSION_SECONDS"),
            default=DEFAULT_WEB_ACCESS_SESSION_SECONDS,
            minimum=60,
            maximum=30 * 24 * 60 * 60,
        )
        self.web_access_cookie_name = os.environ.get("BUCKS_COPY_WEB_ACCESS_COOKIE_NAME", WEB_ACCESS_COOKIE_NAME).strip()
        self.web_access_cookie_secure = parse_bool(os.environ.get("BUCKS_COPY_WEB_ACCESS_COOKIE_SECURE"), default=True)
        self.web_access_session_secret = self.web_access_session_secret_from_env(
            os.environ.get("BUCKS_COPY_WEB_ACCESS_SESSION_SECRET")
        )
        self.credential_encryption_key = encryption_key_from_env(
            os.environ.get("BUCKS_COPY_CREDENTIAL_ENCRYPTION_KEY")
        )
        if self.credential_encryption_key is not None and AESGCM is None:
            raise ValueError("cryptography package is required for persistent credential encryption.")
        self.lock = threading.RLock()
        self.bitget_credentials_by_user_id: dict[str, BitgetCredential] = {}
        self.auth_tokens_by_user_id = self.load_auth_users()
        self.auth_required = self.require_auth or bool(self.auth_tokens_by_user_id)
        self.user_ids = sorted(self.auth_tokens_by_user_id.keys()) if self.auth_tokens_by_user_id else [self.default_user_id]
        self.migrate_legacy_default_user_files()
        for user_id in self.user_ids:
            self.ensure_user_storage(user_id)
            self.restore_persistent_credential(user_id)
        self.evaluated_keys_by_user = {user_id: self.load_evaluated_keys(user_id) for user_id in self.user_ids}

    @staticmethod
    def parse_symbols(value: str) -> list[str]:
        symbols = [symbol.strip().upper() for symbol in value.split(",") if symbol.strip()]
        if not symbols:
            raise ValueError("BUCKS_COPY_SYMBOLS must include at least one symbol.")
        return symbols

    @staticmethod
    def normalized_live_position_mode(value: str | None) -> str:
        mode = (value or "hedge").strip().lower().replace("_", "-")
        if mode in {"hedge", "hedge-mode", "two-way", "two-way-mode"}:
            return "hedge"
        if mode in {"oneway", "one-way", "one-way-mode"}:
            return "one-way"
        return mode or "hedge"

    def web_access_session_secret_from_env(self, value: str | None) -> bytes:
        if value is not None and value.strip():
            text = value.strip()
            if len(text) < 32:
                raise ValueError("BUCKS_COPY_WEB_ACCESS_SESSION_SECRET must be at least 32 characters.")
            return hashlib.sha256(text.encode("utf-8")).digest()
        if self.web_access_gate_enabled:
            return secrets.token_bytes(32)
        return b""

    def owner_web_access_profile(self) -> WebAccessProfile:
        return WebAccessProfile(
            profile_id=OWNER_WEB_ACCESS_PROFILE_ID,
            name="Owner",
            access_key=self.web_access_key,
            allowed_strategy_ids=tuple(DEFAULT_OWNER_STRATEGY_IDS),
        )

    def all_web_access_profiles_by_id(self) -> dict[str, WebAccessProfile]:
        profiles = dict(self.web_access_profiles_by_id)
        profiles[OWNER_WEB_ACCESS_PROFILE_ID] = self.owner_web_access_profile()
        return profiles

    def load_web_access_profiles(self) -> dict[str, WebAccessProfile]:
        if not self.web_access_profiles_path.exists():
            return {}
        try:
            payload = json.loads(self.web_access_profiles_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise ValueError("web access profiles file must be valid JSON.") from error
        profiles = payload.get("profiles", []) if isinstance(payload, dict) else []
        if not isinstance(profiles, list):
            raise ValueError("web access profiles file must contain a profiles array.")

        active_ids = set(self.active_strategy_ids())
        loaded: dict[str, WebAccessProfile] = {}
        access_keys: set[str] = set()
        for item in profiles:
            if not isinstance(item, dict):
                raise ValueError("web access profile entries must be objects.")
            raw_profile_id = item.get("profileID") or item.get("profileId")
            name = item.get("name")
            access_key = item.get("accessKey")
            raw_allowed = item.get("allowedStrategyIDs") or item.get("allowedStrategyIds")
            if not isinstance(raw_profile_id, str) or not isinstance(name, str) or not isinstance(access_key, str):
                raise ValueError("web access profiles require profileID, name, and accessKey strings.")
            profile_id = validate_user_id(raw_profile_id)
            if profile_id == OWNER_WEB_ACCESS_PROFILE_ID:
                raise ValueError("owner web access profile is reserved for BUCKS_COPY_WEB_ACCESS_KEY.")
            if profile_id in loaded:
                raise ValueError(f"duplicate web access profileID: {profile_id}")
            access_key = access_key.strip()
            if len(access_key) < 8:
                raise ValueError("web access profile accessKey must be at least 8 characters.")
            if access_key in access_keys:
                raise ValueError("duplicate web access profile accessKey.")
            access_keys.add(access_key)

            if raw_allowed == "*":
                allowed_strategy_ids = ("*",)
            elif isinstance(raw_allowed, list) and all(isinstance(value, str) for value in raw_allowed):
                allowed_strategy_ids = tuple(strategy_id.strip() for strategy_id in raw_allowed if strategy_id.strip())
            else:
                raise ValueError("web access profile allowedStrategyIDs must be a string array or '*'.")
            unknown = sorted(set(allowed_strategy_ids) - active_ids - {"*"})
            if unknown:
                raise ValueError(f"web access profile references unknown strategy id: {unknown[0]}")
            loaded[profile_id] = WebAccessProfile(
                profile_id=profile_id,
                name=name.strip() or profile_id,
                access_key=access_key,
                allowed_strategy_ids=allowed_strategy_ids,
            )
        return loaded

    def web_access_profile_for_key(self, access_key: str) -> WebAccessProfile | None:
        if not self.web_access_gate_enabled:
            return self.owner_web_access_profile()
        if self.web_access_key and secrets.compare_digest(access_key, self.web_access_key):
            return self.owner_web_access_profile()
        for profile in self.web_access_profiles_by_id.values():
            if secrets.compare_digest(access_key, profile.access_key):
                return profile
        return None

    def issue_web_access_token(self, profile_id: str) -> tuple[str, int]:
        expires_at = int(time.time()) + self.web_access_session_seconds
        nonce = secrets.token_urlsafe(24)
        message = f"{profile_id}:{expires_at}:{nonce}"
        signature = base64.urlsafe_b64encode(
            hmac.new(self.web_access_session_secret, message.encode("utf-8"), hashlib.sha256).digest()
        ).decode("ascii").rstrip("=")
        return f"v2:{message}:{signature}", expires_at

    def web_access_profile_id_from_token(self, token: str) -> str | None:
        parts = token.split(":")
        if len(parts) == 4 and parts[0] == "v1":
            try:
                expires_at = int(parts[1])
            except ValueError:
                return None
            if expires_at < int(time.time()):
                return None
            message = f"{parts[1]}:{parts[2]}"
            expected = base64.urlsafe_b64encode(
                hmac.new(self.web_access_session_secret, message.encode("utf-8"), hashlib.sha256).digest()
            ).decode("ascii").rstrip("=")
            return OWNER_WEB_ACCESS_PROFILE_ID if secrets.compare_digest(expected, parts[3]) else None

        if len(parts) != 5 or parts[0] != "v2":
            return None
        profile_id = parts[1]
        if profile_id not in self.all_web_access_profiles_by_id():
            return None
        try:
            expires_at = int(parts[2])
        except ValueError:
            return None
        if expires_at < int(time.time()):
            return None
        message = f"{parts[1]}:{parts[2]}:{parts[3]}"
        expected = base64.urlsafe_b64encode(
            hmac.new(self.web_access_session_secret, message.encode("utf-8"), hashlib.sha256).digest()
        ).decode("ascii").rstrip("=")
        return profile_id if secrets.compare_digest(expected, parts[4]) else None

    def web_access_token_valid(self, token: str) -> bool:
        return self.web_access_profile_id_from_token(token) is not None

    def web_access_token_from_cookie(self, cookie_header: str) -> str | None:
        for item in cookie_header.split(";"):
            name, separator, value = item.strip().partition("=")
            if separator and name == self.web_access_cookie_name and value:
                return value
        return None

    def web_access_cookie_header(self, token: str, expires_at: int) -> str:
        max_age = max(expires_at - int(time.time()), 0)
        flags = [
            f"{self.web_access_cookie_name}={token}",
            "Path=/",
            f"Max-Age={max_age}",
            "HttpOnly",
            "SameSite=Strict",
        ]
        if self.web_access_cookie_secure:
            flags.append("Secure")
        return "; ".join(flags)

    def expired_web_access_cookie_header(self) -> str:
        flags = [
            f"{self.web_access_cookie_name}=",
            "Path=/",
            "Max-Age=0",
            "HttpOnly",
            "SameSite=Strict",
        ]
        if self.web_access_cookie_secure:
            flags.append("Secure")
        return "; ".join(flags)

    def load_auth_users(self) -> dict[str, str]:
        if not self.auth_users_path.exists():
            return {}
        try:
            payload = json.loads(self.auth_users_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise ValueError("auth users file must be valid JSON.") from error
        users = payload.get("users", []) if isinstance(payload, dict) else []
        if not isinstance(users, list):
            raise ValueError("auth users file must contain a users array.")

        tokens_by_user: dict[str, str] = {}
        for user in users:
            if not isinstance(user, dict):
                raise ValueError("auth user entries must be objects.")
            user_id_value = user.get("userID") or user.get("userId")
            token = user.get("token")
            if not isinstance(user_id_value, str) or not isinstance(token, str):
                raise ValueError("auth user entries require userID and token strings.")
            user_id = validate_user_id(user_id_value)
            if len(token.strip()) < 32:
                raise ValueError("auth tokens must be at least 32 characters.")
            if user_id in tokens_by_user:
                raise ValueError(f"duplicate auth userID: {user_id}")
            tokens_by_user[user_id] = token.strip()
        return tokens_by_user

    def save_auth_users(self) -> None:
        users = [
            {
                "userID": user_id,
                "token": token,
                "updatedAt": iso(now_utc()),
            }
            for user_id, token in sorted(self.auth_tokens_by_user_id.items())
        ]
        self.auth_users_path.parent.mkdir(parents=True, exist_ok=True)
        self.atomic_write_json(self.auth_users_path, {"users": users}, pretty=True)
        try:
            self.auth_users_path.chmod(0o600)
        except OSError:
            pass

    def user_id_for_api_key(self, api_key: str) -> str:
        digest = hashlib.sha256(api_key.strip().encode("utf-8")).hexdigest()[:24]
        return validate_user_id(f"bitget-{digest}")

    @property
    def persistent_credential_enabled(self) -> bool:
        return self.credential_encryption_key is not None

    def login_with_bitget(
        self,
        api_key: str,
        secret_key: str,
        passphrase: str,
        web_access_profile_id: str | None = None,
    ) -> dict[str, Any]:
        credential = BitgetCredential(
            api_key=api_key,
            secret_key=secret_key,
            passphrase=passphrase,
        )
        accounts = self.fetch_bitget_accounts(credential)
        user_id = self.user_id_for_api_key(api_key)
        with self.lock:
            token = self.auth_tokens_by_user_id.get(user_id) or secrets.token_urlsafe(48)
            self.auth_tokens_by_user_id[user_id] = token
            self.bitget_credentials_by_user_id[user_id] = credential
            self.auth_required = self.require_auth or bool(self.auth_tokens_by_user_id)
            if user_id not in self.user_ids:
                self.user_ids = sorted(set(self.user_ids + [user_id]))
            self.ensure_user_storage(user_id)
            self.evaluated_keys_by_user.setdefault(user_id, self.load_evaluated_keys(user_id))
            if web_access_profile_id is not None:
                self.assign_web_access_profile(user_id, web_access_profile_id)
            self.save_persistent_credential(user_id, credential)
            self.save_auth_users()
        return {
            "authToken": token,
            "mode": "paper",
            "credentialScope": "encrypted" if self.persistent_credential_enabled else "memory",
            "redactedIdentifier": credential.redacted_identifier,
            "userID": user_id,
            "accessProfile": self.web_access_profile_public_record(user_id),
            "accounts": accounts,
            "updatedAt": iso(now_utc()),
        }

    def revoke_user_session(self, user_id: str) -> None:
        with self.lock:
            self.auth_tokens_by_user_id.pop(user_id, None)
            self.bitget_credentials_by_user_id.pop(user_id, None)
            self.auth_required = self.require_auth or bool(self.auth_tokens_by_user_id)
            self.delete_persistent_credential(user_id)
            self.save_auth_users()

    def credential_record_path(self, user_id: str) -> Path:
        return self.user_dir(user_id) / "bitget-credential.enc.json"

    def save_persistent_credential(self, user_id: str, credential: BitgetCredential) -> None:
        if not self.persistent_credential_enabled:
            return
        assert self.credential_encryption_key is not None
        assert AESGCM is not None
        plaintext = json.dumps(
            {
                "apiKey": credential.api_key,
                "secretKey": credential.secret_key,
                "passphrase": credential.passphrase,
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        nonce = secrets.token_bytes(12)
        ciphertext = AESGCM(self.credential_encryption_key).encrypt(
            nonce,
            plaintext,
            user_id.encode("utf-8"),
        )
        record = {
            "version": 1,
            "algorithm": CREDENTIAL_ENCRYPTION_ALGORITHM,
            "nonce": base64.urlsafe_b64encode(nonce).decode("ascii"),
            "ciphertext": base64.urlsafe_b64encode(ciphertext).decode("ascii"),
            "redactedIdentifier": credential.redacted_identifier,
            "updatedAt": iso(now_utc()),
        }
        path = self.credential_record_path(user_id)
        self.atomic_write_json(path, record, pretty=True)
        try:
            path.chmod(0o600)
        except OSError:
            pass

    def restore_persistent_credential(self, user_id: str) -> None:
        if not self.persistent_credential_enabled:
            return
        path = self.credential_record_path(user_id)
        if not path.exists():
            return
        try:
            credential = self.load_persistent_credential(user_id)
        except Exception:
            return
        self.bitget_credentials_by_user_id[user_id] = credential

    def load_persistent_credential(self, user_id: str) -> BitgetCredential:
        if not self.persistent_credential_enabled:
            raise BitgetLoginError("Persistent credential storage is disabled.")
        assert self.credential_encryption_key is not None
        assert AESGCM is not None
        payload = json.loads(self.credential_record_path(user_id).read_text(encoding="utf-8"))
        if payload.get("version") != 1 or payload.get("algorithm") != CREDENTIAL_ENCRYPTION_ALGORITHM:
            raise ValueError("unsupported encrypted credential record")
        nonce = base64.urlsafe_b64decode(str(payload["nonce"]).encode("ascii"))
        ciphertext = base64.urlsafe_b64decode(str(payload["ciphertext"]).encode("ascii"))
        plaintext = AESGCM(self.credential_encryption_key).decrypt(
            nonce,
            ciphertext,
            user_id.encode("utf-8"),
        )
        record = json.loads(plaintext.decode("utf-8"))
        api_key = str(record.get("apiKey", "")).strip()
        secret_key = str(record.get("secretKey", "")).strip()
        passphrase = str(record.get("passphrase", "")).strip()
        if not api_key or not secret_key or not passphrase:
            raise ValueError("encrypted credential record is incomplete")
        return BitgetCredential(api_key=api_key, secret_key=secret_key, passphrase=passphrase)

    def delete_persistent_credential(self, user_id: str) -> None:
        path = self.credential_record_path(user_id)
        try:
            path.unlink()
        except FileNotFoundError:
            pass

    def fetch_user_accounts(self, user_id: str) -> list[dict[str, Any]]:
        return self.refresh_user_private_snapshot(user_id)["accounts"]

    def fetch_user_positions(self, user_id: str) -> list[dict[str, Any]]:
        return self.refresh_user_private_snapshot(user_id)["positions"]

    def credential_for_user(self, user_id: str) -> BitgetCredential:
        credential = self.bitget_credentials_by_user_id.get(user_id)
        if credential is None:
            raise BitgetLoginError("Bitget login is required for private account data.")
        return credential

    def private_snapshot_path(self, user_id: str) -> Path:
        return self.user_dir(user_id) / "private-snapshot.json"

    def load_private_snapshot(self, user_id: str) -> dict[str, Any] | None:
        path = self.private_snapshot_path(user_id)
        if not path.exists():
            return None
        snapshot = read_json_file(path, {})
        return snapshot if isinstance(snapshot, dict) else None

    def refresh_user_private_snapshot(self, user_id: str) -> dict[str, Any]:
        credential = self.credential_for_user(user_id)
        accounts = self.fetch_bitget_accounts(credential)
        positions = self.fetch_bitget_positions(credential)
        updated_at = now_utc()
        snapshot = {
            "updatedAt": iso(updated_at),
            "mode": "read-only",
            "productType": PRODUCT_TYPE,
            "accounts": accounts,
            "positions": positions,
            "accountCount": len(accounts),
            "positionCount": len(positions),
        }
        self.atomic_write_json(self.private_snapshot_path(user_id), snapshot, pretty=True)
        return snapshot

    def maybe_refresh_user_private_snapshot(self, user_id: str, now: datetime) -> str | None:
        if user_id not in self.bitget_credentials_by_user_id:
            return None
        snapshot = self.load_private_snapshot(user_id)
        if snapshot is not None:
            try:
                updated_at = datetime.fromisoformat(str(snapshot["updatedAt"]).replace("Z", "+00:00"))
                if (now - updated_at).total_seconds() < self.private_poll_seconds:
                    return None
            except (KeyError, ValueError):
                pass
        try:
            self.refresh_user_private_snapshot(user_id)
        except BitgetLoginError as error:
            return f"private snapshot: {error}"
        except Exception:
            return "private snapshot refresh failed"
        return None

    def bitget_signed_get(
        self,
        credential: BitgetCredential,
        path: str,
        params: dict[str, str],
    ) -> Any:
        query_string = urlencode(sorted(params.items()))
        url = f"{self.base_url}{path}?{query_string}" if query_string else f"{self.base_url}{path}"
        timestamp = str(int(time.time() * 1000))
        request = Request(
            url,
            headers={
                "ACCESS-KEY": credential.api_key,
                "ACCESS-SIGN": bitget_signature(timestamp, "GET", path, query_string, "", credential.secret_key),
                "ACCESS-PASSPHRASE": credential.passphrase,
                "ACCESS-TIMESTAMP": timestamp,
                "Content-Type": "application/json",
                "locale": "en-US",
                "User-Agent": "BucksCopyPaperRunner/1.0",
            },
            method="GET",
        )
        try:
            with urlopen(request, timeout=20, context=ssl_context()) as response:
                body = response.read()
        except Exception as error:
            raise BitgetLoginError("Bitget private request failed") from error

        try:
            decoded = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError as error:
            raise BitgetLoginError("Bitget private request returned invalid JSON") from error

        if decoded.get("code") != "00000":
            code = str(decoded.get("code") or "unknown")
            message = str(decoded.get("msg") or "private request rejected")[:160]
            raise BitgetLoginError(f"Bitget API {code}: {message}")
        return decoded.get("data", [])

    def bitget_signed_post(
        self,
        credential: BitgetCredential,
        path: str,
        payload: dict[str, Any],
    ) -> Any:
        body = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        url = f"{self.base_url}{path}"
        timestamp = str(int(time.time() * 1000))
        request = Request(
            url,
            data=body.encode("utf-8"),
            headers={
                "ACCESS-KEY": credential.api_key,
                "ACCESS-SIGN": bitget_signature(timestamp, "POST", path, "", body, credential.secret_key),
                "ACCESS-PASSPHRASE": credential.passphrase,
                "ACCESS-TIMESTAMP": timestamp,
                "Content-Type": "application/json",
                "locale": "en-US",
                "User-Agent": "BucksCopyPaperRunner/1.0",
            },
            method="POST",
        )
        try:
            with urlopen(request, timeout=20, context=ssl_context()) as response:
                raw_body = response.read()
        except Exception as error:
            raise LiveExecutionError("Bitget private order request failed") from error

        try:
            decoded = json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError as error:
            raise LiveExecutionError("Bitget private order request returned invalid JSON") from error

        if decoded.get("code") != "00000":
            code = str(decoded.get("code") or "unknown")
            message = str(decoded.get("msg") or "order request rejected")[:160]
            raise LiveExecutionError(f"Bitget API {code}: {message}")
        return decoded.get("data", {})

    def fetch_bitget_accounts(self, credential: BitgetCredential) -> list[dict[str, Any]]:
        data = self.bitget_signed_get(
            credential,
            "/api/v2/mix/account/accounts",
            {"productType": PRODUCT_TYPE},
        )
        if not isinstance(data, list):
            raise BitgetLoginError("Bitget private request returned invalid account data")
        return [self.normalized_account(record) for record in data if isinstance(record, dict)]

    def fetch_bitget_positions(self, credential: BitgetCredential) -> list[dict[str, Any]]:
        data = self.bitget_signed_get(
            credential,
            "/api/v2/mix/position/all-position",
            {"marginCoin": "USDT", "productType": PRODUCT_TYPE},
        )
        if not isinstance(data, list):
            raise BitgetLoginError("Bitget private request returned invalid position data")
        return [self.normalized_position(record) for record in data if isinstance(record, dict)]

    def fetch_contract_specs(self, symbol: str) -> dict[str, Any]:
        params = {"productType": PRODUCT_TYPE, "symbol": symbol}
        url = f"{self.base_url}/api/v2/mix/market/contracts?{urlencode(sorted(params.items()))}"
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
            raise LiveExecutionError(f"Bitget API {decoded.get('code')}: contract config rejected")
        data = decoded.get("data", [])
        if not isinstance(data, list):
            raise LiveExecutionError("Bitget contract config returned invalid data")
        for record in data:
            if isinstance(record, dict) and str(record.get("symbol") or "").upper() == symbol.upper():
                support_margin_coins = record.get("supportMarginCoins") or []
                if str(record.get("symbolStatus") or "").lower() != "normal" or "USDT" not in support_margin_coins:
                    raise LiveExecutionError(f"{symbol} is not a normal USDT-M Futures symbol")
                return {
                    "symbol": symbol.upper(),
                    "minTradeNum": dec(record.get("minTradeNum") or "0"),
                    "minTradeUSDT": dec(record.get("minTradeUSDT") or "0"),
                    "sizeMultiplier": dec(record.get("sizeMultiplier") or "0"),
                    "volumePlace": int(record.get("volumePlace") or "8"),
                    "pricePlace": int(record.get("pricePlace") or "2"),
                    "maxLeverage": int(record.get("maxLever") or "1"),
                }
        raise LiveExecutionError(f"{symbol} contract config was not found")

    @staticmethod
    def rounded_order_size(raw_size: Decimal, contract_spec: dict[str, Any]) -> Decimal:
        multiplier = contract_spec.get("sizeMultiplier")
        if not isinstance(multiplier, Decimal) or multiplier <= 0:
            volume_place = int(contract_spec.get("volumePlace") or 8)
            multiplier = dec(1) / (dec(10) ** volume_place)
        units = (raw_size / multiplier).to_integral_value(rounding=ROUND_DOWN)
        return units * multiplier

    @staticmethod
    def rounded_order_size_up(raw_size: Decimal, contract_spec: dict[str, Any]) -> Decimal:
        multiplier = contract_spec.get("sizeMultiplier")
        if not isinstance(multiplier, Decimal) or multiplier <= 0:
            volume_place = int(contract_spec.get("volumePlace") or 8)
            multiplier = dec(1) / (dec(10) ** volume_place)
        units = (raw_size / multiplier).to_integral_value(rounding=ROUND_UP)
        return units * multiplier

    @staticmethod
    def rounded_price(price: Decimal, contract_spec: dict[str, Any], rounding: str) -> Decimal:
        price_place = max(int(contract_spec.get("pricePlace") or 2), 0)
        quantum = dec(1) / (dec(10) ** price_place)
        return price.quantize(quantum, rounding=rounding)

    def order_size_for_signal(self, signal: Signal, account_available: Decimal, contract_spec: dict[str, Any]) -> Decimal:
        if self.live_order_margin_usdt <= 0:
            raise LiveExecutionError("live order margin is not configured")
        leverage = min(signal.leverage, int(contract_spec.get("maxLeverage") or signal.leverage))
        planned_margin = min(self.live_order_margin_usdt, account_available * self.live_available_balance_ratio)
        if planned_margin <= 0:
            raise LiveExecutionError("USDT available balance is not enough for live order")
        notional = planned_margin * dec(leverage)
        if notional < contract_spec.get("minTradeUSDT", dec(0)):
            raise LiveExecutionError("planned notional is below Bitget minimum trade USDT")
        size = self.rounded_order_size(notional / signal.entry, contract_spec)
        if size <= 0 or size < contract_spec.get("minTradeNum", dec(0)):
            raise LiveExecutionError("calculated order size is below Bitget minimum trade size")
        return size

    def minimum_test_order_size_for_signal(
        self,
        signal: Signal,
        account_available: Decimal,
        contract_spec: dict[str, Any],
    ) -> Decimal:
        min_trade_num = contract_spec.get("minTradeNum", dec(0))
        min_trade_usdt = contract_spec.get("minTradeUSDT", dec(0))
        size_from_notional = min_trade_usdt / signal.entry if min_trade_usdt > 0 else dec(0)
        size = self.rounded_order_size_up(max(min_trade_num, size_from_notional), contract_spec)
        multiplier = contract_spec.get("sizeMultiplier")
        if not isinstance(multiplier, Decimal) or multiplier <= 0:
            volume_place = int(contract_spec.get("volumePlace") or 8)
            multiplier = dec(1) / (dec(10) ** volume_place)
        while min_trade_usdt > 0 and size * signal.entry < min_trade_usdt:
            size += multiplier
        required_margin = size * signal.entry / dec(signal.leverage)
        if required_margin > account_available:
            raise LiveExecutionError("USDT available balance is not enough for minimum live test order")
        if size <= 0 or size < min_trade_num:
            raise LiveExecutionError("calculated minimum live test size is below Bitget minimum trade size")
        return size

    @staticmethod
    def normalized_account(record: dict[str, Any]) -> dict[str, Any]:
        return {
            "marginCoin": str(record.get("marginCoin") or "USDT"),
            "available": str(record.get("available") or "0"),
            "accountEquity": str(record.get("accountEquity") or "0"),
            "unrealizedPL": str(record.get("unrealizedPL") or "0"),
            "updatedAt": iso(now_utc()),
        }

    @staticmethod
    def normalized_position(record: dict[str, Any]) -> dict[str, Any]:
        return {
            "symbol": str(record.get("symbol") or record.get("instId") or "").upper(),
            "marginCoin": str(record.get("marginCoin") or "USDT"),
            "holdSide": str(record.get("holdSide") or ""),
            "available": str(record.get("available") or "0"),
            "total": str(record.get("total") or "0"),
            "leverage": str(record.get("leverage") or "0"),
            "openPriceAvg": str(record.get("openPriceAvg") or "0"),
            "marginMode": str(record.get("marginMode") or ""),
            "posMode": str(record.get("posMode") or ""),
            "unrealizedPL": str(record.get("unrealizedPL") or "0"),
            "liquidationPrice": str(record.get("liquidationPrice") or ""),
            "markPrice": str(record.get("markPrice") or "0"),
            "takeProfit": str(record.get("takeProfit") or ""),
            "stopLoss": str(record.get("stopLoss") or ""),
            "cTime": str(record.get("cTime") or ""),
            "uTime": str(record.get("uTime") or ""),
        }

    def account_available_usdt(self, snapshot: dict[str, Any] | None) -> Decimal:
        if not isinstance(snapshot, dict):
            return dec(0)
        accounts = snapshot.get("accounts", [])
        if not isinstance(accounts, list):
            return dec(0)
        for account in accounts:
            if isinstance(account, dict) and str(account.get("marginCoin") or "").upper() == "USDT":
                return dec(account.get("available") or "0")
        return dec(0)

    def latest_closed_reference_price(self, symbol: str) -> Decimal:
        remote_candles = self.fetch_candles(symbol)
        if remote_candles:
            try:
                self.upsert_candles(symbol, remote_candles)
            except Exception:
                pass
        candles = [candle for candle in remote_candles if candle.is_closed]
        if not candles:
            candles = [candle for candle in self.load_candles(symbol) if candle.is_closed]
        if not candles:
            raise LiveExecutionError(f"{symbol} closed candle price is unavailable")
        price = candles[-1].close
        if price <= 0:
            raise LiveExecutionError(f"{symbol} reference price is invalid")
        return price

    def minimum_live_test_signal(
        self,
        symbol: str,
        side: str,
        entry: Decimal,
        contract_spec: dict[str, Any],
    ) -> Signal:
        if side == "buy":
            stop = self.rounded_price(entry * dec("0.995"), contract_spec, ROUND_DOWN)
            take_profit = self.rounded_price(entry * dec("1.005"), contract_spec, ROUND_UP)
        else:
            stop = self.rounded_price(entry * dec("1.005"), contract_spec, ROUND_UP)
            take_profit = self.rounded_price(entry * dec("0.995"), contract_spec, ROUND_DOWN)
        if stop <= 0 or take_profit <= 0 or stop == entry or take_profit == entry:
            raise LiveExecutionError("minimum live test protection prices are invalid")
        return Signal(
            strategy_id="manual-minimum-live-test",
            symbol=symbol,
            side=side,
            entry=entry,
            stop=stop,
            take_profit=take_profit,
            reason="manual minimum live test",
            leverage=1,
        )

    @staticmethod
    def position_order_size(position: dict[str, Any] | None) -> Decimal:
        if not isinstance(position, dict):
            return dec(0)
        return max(dec(position.get("total") or "0"), dec(position.get("available") or "0"))

    @staticmethod
    def hold_side_for_signal(signal: Signal) -> str:
        return "long" if signal.side == "buy" else "short"

    def acquire_live_lock(self, user_id: str, reason: str) -> None:
        path = self.live_lock_path(user_id)
        checked_at = now_utc()
        available, note = self.live_lock_available(user_id, checked_at)
        if not available:
            raise LiveExecutionError(note or "live runner lock is unavailable")
        self.atomic_write_json(
            path,
            {
                "updatedAt": iso(checked_at),
                "reason": reason,
            },
            pretty=True,
        )

    def release_live_lock(self, user_id: str) -> None:
        try:
            self.live_lock_path(user_id).unlink()
        except FileNotFoundError:
            pass

    def record_live_event(
        self,
        user_id: str,
        signal: Signal,
        severity: str,
        message: str,
        details: dict[str, str],
    ) -> None:
        tags = ["LIVE", TIMEFRAME, signal.side.upper(), signal.strategy_id]
        subtitle = (
            details.get("failureReason")
            if severity == "error" and details.get("failureReason")
            else "서버 runner가 실거래 주문 경로를 처리했습니다."
        )
        self.append_jsonl(
            self.user_dir(user_id) / "trade-event-logs.jsonl",
            {
                "id": str(uuid.uuid4()),
                "timestamp": iso(now_utc()),
                "category": "liveOrder" if severity == "info" else "risk",
                "severity": severity,
                "symbol": signal.symbol,
                "message": message,
                "metadata": {
                    "title": f"{signal.symbol} server live execution",
                    "subtitle": subtitle,
                    "tags": tags,
                    "details": details,
                },
            },
        )

    def set_bitget_leverage(self, credential: BitgetCredential, signal: Signal) -> None:
        payload = {
            "symbol": signal.symbol,
            "productType": PRODUCT_TYPE,
            "marginCoin": "USDT",
            "leverage": str(signal.leverage),
        }
        if self.live_margin_mode == "isolated" and self.live_position_mode == "hedge":
            payload["holdSide"] = self.hold_side_for_signal(signal)
        self.bitget_signed_post(credential, "/api/v2/mix/account/set-leverage", payload)

    def place_market_order(self, credential: BitgetCredential, signal: Signal, size: Decimal, client_oid: str) -> dict[str, Any]:
        payload = {
            "symbol": signal.symbol,
            "productType": PRODUCT_TYPE,
            "marginMode": self.live_margin_mode,
            "marginCoin": "USDT",
            "size": decimal_text(size),
            "side": signal.side,
            "tradeSide": "open",
            "orderType": "market",
            "clientOid": client_oid,
        }
        if self.live_position_mode == "one-way":
            payload["reduceOnly"] = "NO"
        data = self.bitget_signed_post(credential, "/api/v2/mix/order/place-order", payload)
        return data if isinstance(data, dict) else {}

    def fetch_order_detail(
        self,
        credential: BitgetCredential,
        signal: Signal,
        order_id: str | None,
        client_oid: str,
    ) -> dict[str, Any]:
        params = {
            "clientOid": client_oid,
            "productType": PRODUCT_TYPE,
            "symbol": signal.symbol,
        }
        if order_id:
            params["orderId"] = order_id
        data = self.bitget_signed_get(credential, "/api/v2/mix/order/detail", params)
        return data if isinstance(data, dict) else {}

    def confirm_filled_order(
        self,
        credential: BitgetCredential,
        signal: Signal,
        order_id: str | None,
        client_oid: str,
    ) -> dict[str, Any]:
        latest: dict[str, Any] = {}
        for attempt in range(self.live_confirmation_attempts):
            if attempt > 0 and self.live_confirmation_delay_seconds > 0:
                time.sleep(float(self.live_confirmation_delay_seconds))
            latest = self.fetch_order_detail(credential, signal, order_id, client_oid)
            state = str(latest.get("state") or latest.get("status") or "").lower()
            if state in {"filled", "full-fill", "full_filled"}:
                return latest
        raise LiveExecutionError(f"entry fill was not confirmed for {redacted_identifier(client_oid)}")

    def find_open_position(self, positions: list[dict[str, Any]], signal: Signal) -> dict[str, Any] | None:
        hold_side = self.hold_side_for_signal(signal)
        for position in positions:
            if not isinstance(position, dict):
                continue
            if str(position.get("symbol") or "").upper() != signal.symbol:
                continue
            total = dec(position.get("total") or "0")
            available = dec(position.get("available") or "0")
            if max(total, available) <= 0:
                continue
            position_side = str(position.get("holdSide") or "").lower()
            if position_side in {hold_side, "", "net"}:
                return position
        return None

    def place_tpsl_order(
        self,
        credential: BitgetCredential,
        signal: Signal,
        kind: str,
        trigger_price: Decimal,
        execute_price: Decimal,
        size: Decimal,
        client_oid: str,
    ) -> dict[str, Any]:
        data = self.bitget_signed_post(
            credential,
            "/api/v2/mix/order/place-tpsl-order",
            {
                "marginCoin": "USDT",
                "productType": PRODUCT_TYPE,
                "symbol": signal.symbol,
                "planType": "profit_plan" if kind == "takeProfit" else "loss_plan",
                "triggerPrice": decimal_text(trigger_price),
                "triggerType": "mark_price",
                "executePrice": decimal_text(execute_price),
                "holdSide": self.hold_side_for_signal(signal) if self.live_position_mode == "hedge" else signal.side,
                "size": decimal_text(size),
                "rangeRate": "",
                "clientOid": client_oid,
            },
        )
        return data if isinstance(data, dict) else {}

    def install_protection_orders(
        self,
        credential: BitgetCredential,
        signal: Signal,
        size: Decimal,
        contract_spec: dict[str, Any],
        parent_client_oid: str,
    ) -> list[dict[str, Any]]:
        half_size = self.rounded_order_size(size / dec(2), contract_spec)
        final_size = size - half_size
        if half_size <= 0 or final_size <= 0:
            raise LiveExecutionError("calculated protection order size is invalid")
        orders = [
            ("takeProfit", signal.partial_take_profit, signal.partial_take_profit, half_size, "tp1"),
            ("takeProfit", signal.take_profit, signal.take_profit, final_size, "tp2"),
            ("stopLoss", signal.stop, dec(0), size, "sl"),
        ]
        receipts: list[dict[str, Any]] = []
        for kind, trigger_price, execute_price, order_size, suffix in orders:
            trigger_price = self.rounded_protection_price(signal, kind, trigger_price, contract_spec)
            execute_price = (
                dec(0)
                if execute_price <= 0
                else self.rounded_protection_price(signal, kind, execute_price, contract_spec)
            )
            last_error: Exception | None = None
            for attempt in range(1, self.live_protection_retry_attempts + 2):
                client_oid = f"{parent_client_oid}-{suffix}-{attempt}"
                try:
                    receipt = self.place_tpsl_order(
                        credential,
                        signal,
                        kind,
                        trigger_price,
                        execute_price,
                        order_size,
                        client_oid,
                    )
                    receipts.append(
                        {
                            "kind": kind,
                            "clientOid": redacted_identifier(client_oid),
                            "attempts": attempt,
                            "size": decimal_text(order_size),
                        }
                    )
                    break
                except Exception as error:
                    last_error = error
                    if attempt <= self.live_protection_retry_attempts:
                        time.sleep(0.4)
            else:
                raise LiveExecutionError(
                    f"{kind} protection order retry exhausted: {last_error}"
                )
        return receipts

    def rounded_protection_price(
        self,
        signal: Signal,
        kind: str,
        price: Decimal,
        contract_spec: dict[str, Any],
    ) -> Decimal:
        if kind == "takeProfit":
            rounding = ROUND_UP if signal.side == "buy" else ROUND_DOWN
        else:
            rounding = ROUND_DOWN if signal.side == "buy" else ROUND_UP
        return self.rounded_price(price, contract_spec, rounding)

    def close_position_fail_closed(self, credential: BitgetCredential, signal: Signal) -> Any:
        payload = {
            "symbol": signal.symbol,
            "productType": PRODUCT_TYPE,
        }
        if self.live_position_mode == "hedge":
            payload["holdSide"] = self.hold_side_for_signal(signal)
        return self.bitget_signed_post(credential, "/api/v2/mix/order/close-positions", payload)

    def confirm_position_closed(self, user_id: str, signal: Signal) -> None:
        for attempt in range(self.live_confirmation_attempts):
            if attempt > 0 and self.live_confirmation_delay_seconds > 0:
                time.sleep(float(self.live_confirmation_delay_seconds))
            snapshot = self.refresh_user_private_snapshot(user_id)
            if self.find_open_position(snapshot["positions"], signal) is None:
                return
        raise LiveExecutionError(f"{signal.symbol} {self.hold_side_for_signal(signal)} close was not confirmed")

    @staticmethod
    def public_live_error_text(error: Exception) -> str:
        message = str(error).strip()
        if not message:
            message = type(error).__name__
        return message[:240]

    def execute_minimum_live_test_order(self, user_id: str, symbol: str, side: str = "buy") -> dict[str, Any]:
        symbol = symbol.upper()
        side = side.lower()
        if symbol not in self.symbols:
            raise ValueError("symbol is not configured for this runner")
        if side not in {"buy", "sell"}:
            raise ValueError("side must be buy or sell")
        live = self.live_status(user_id)
        if not live["ready"]:
            blocker = next(iter(live.get("blockers") or []), "live gate is not ready")
            raise LiveExecutionError(blocker)
        if not self.live_order_execution_enabled:
            raise LiveExecutionError("live order execution env switch is disabled")

        credential = self.credential_for_user(user_id)
        parent_client_oid = f"bc-test-{symbol.lower()}-{side}-{int(time.time())}-{uuid.uuid4().hex[:10]}"
        self.acquire_live_lock(user_id, parent_client_oid)
        entry_confirmed = False
        close_submitted = False
        requested_size = dec(0)
        active_signal: Signal | None = None
        try:
            contract_spec = self.fetch_contract_specs(symbol)
            reference_price = self.latest_closed_reference_price(symbol)
            active_signal = self.minimum_live_test_signal(symbol, side, reference_price, contract_spec)
            private_snapshot = self.refresh_user_private_snapshot(user_id)
            if self.find_open_position(private_snapshot["positions"], active_signal) is not None:
                raise LiveExecutionError(f"{symbol} {self.hold_side_for_signal(active_signal)} position is already open")
            account_available = self.account_available_usdt(private_snapshot)
            requested_size = self.minimum_test_order_size_for_signal(active_signal, account_available, contract_spec)
            requested_margin = requested_size * active_signal.entry / dec(active_signal.leverage)

            self.set_bitget_leverage(credential, active_signal)
            order = self.place_market_order(credential, active_signal, requested_size, parent_client_oid)
            order_id = str(order.get("orderId") or "") or None
            detail = self.confirm_filled_order(credential, active_signal, order_id, parent_client_oid)
            entry_confirmed = True

            average_price = dec(detail.get("priceAvg") or active_signal.entry)
            filled_size = dec(detail.get("baseVolume") or detail.get("size") or requested_size)
            active_signal = self.minimum_live_test_signal(symbol, side, average_price, contract_spec)
            snapshot = self.refresh_user_private_snapshot(user_id)
            position = self.find_open_position(snapshot["positions"], active_signal)
            if position is None:
                raise LiveExecutionError("entry was filled but fresh position snapshot did not confirm an open position")
            close_size = self.position_order_size(position) or filled_size
            self.close_position_fail_closed(credential, active_signal)
            close_submitted = True
            self.confirm_position_closed(user_id, active_signal)
            details = {
                "mode": "server-live-test",
                "minimumTest": "true",
                "clientOid": redacted_identifier(parent_client_oid),
                "filledSize": decimal_text(filled_size),
                "averagePrice": decimal_text(average_price),
                "entry": decimal_text(active_signal.entry),
                "size": decimal_text(close_size),
                "requestedMarginUSDT": decimal_text(requested_margin),
                "leverage": "1x",
                "closeSubmitted": "true",
                "closeConfirmed": "true",
                "protectionOrders": "0",
            }
            self.record_live_event(
                user_id,
                active_signal,
                "info",
                (
                    f"Minimum live round-trip test completed. Side {side}, size {decimal_text(close_size)}, "
                    f"entry {decimal_text(active_signal.entry)}, market close confirmed."
                ),
                details,
            )
            return {
                "ok": True,
                "symbol": symbol,
                "side": side,
                "mode": "server-live-test",
                "size": decimal_text(close_size),
                "requestedMarginUSDT": decimal_text(requested_margin),
                "leverage": "1x",
                "entry": decimal_text(active_signal.entry),
                "closeSubmitted": True,
                "closeConfirmed": True,
                "protectionOrders": 0,
                "message": f"{symbol} 1x minimum live round-trip test completed.",
            }
        except Exception as error:
            failure_reason = self.public_live_error_text(error)
            if entry_confirmed and active_signal is not None:
                try:
                    snapshot = self.refresh_user_private_snapshot(user_id)
                    if self.find_open_position(snapshot["positions"], active_signal) is not None:
                        self.close_position_fail_closed(credential, active_signal)
                        close_submitted = True
                except Exception:
                    pass
            log_signal = active_signal or Signal(
                strategy_id="manual-minimum-live-test",
                symbol=symbol,
                side=side,
                entry=dec(0),
                stop=dec(0),
                take_profit=dec(0),
                reason="manual minimum live test",
                leverage=1,
            )
            self.record_live_event(
                user_id,
                log_signal,
                "error",
                f"Minimum live test execution failed: {failure_reason}",
                {
                    "mode": "server-live-test",
                    "minimumTest": "true",
                    "failureReason": failure_reason,
                    "clientOid": redacted_identifier(parent_client_oid),
                    "failClosedAttempted": str(entry_confirmed).lower(),
                    "closeSubmitted": str(close_submitted).lower(),
                    "entry": decimal_text(log_signal.entry),
                    "size": decimal_text(requested_size),
                    "leverage": "1x",
                },
            )
            raise
        finally:
            self.release_live_lock(user_id)

    def maybe_execute_live_signal(
        self,
        user_id: str,
        signal: Signal,
        candle_open_time: int,
        generated_at: datetime,
        private_snapshot: dict[str, Any] | None,
    ) -> bool:
        live = self.live_status(user_id)
        if not live["ready"] or not live["orderExecutionEnabled"]:
            live_blockers = [
                str(item)
                for item in [
                    *(live.get("blockers") or []),
                    *(live.get("orderBlockers") or []),
                ]
                if str(item).strip()
            ]
            failure_reason = "; ".join(live_blockers) or "live gate is not ready"
            self.record_live_event(
                user_id,
                signal,
                "error",
                f"Server live signal was not executed: {failure_reason}",
                {
                    "mode": "server-live",
                    "failureReason": failure_reason,
                    "liveReady": str(live.get("ready", False)).lower(),
                    "orderExecutionEnabled": str(live.get("orderExecutionEnabled", False)).lower(),
                    "entry": decimal_text(signal.entry),
                    "tp1": decimal_text(signal.partial_take_profit),
                    "tp2": decimal_text(signal.take_profit),
                    "stopLoss": decimal_text(signal.stop),
                },
            )
            return False
        credential = self.credential_for_user(user_id)
        parent_client_oid = (
            f"bc-{signal.symbol.lower()}-{TIMEFRAME}-{signal.strategy_id[:16]}-"
            f"{candle_open_time}-{uuid.uuid4().hex[:10]}"
        )
        self.acquire_live_lock(user_id, parent_client_oid)
        entry_confirmed = False
        try:
            contract_spec = self.fetch_contract_specs(signal.symbol)
            available = self.account_available_usdt(private_snapshot)
            size = self.order_size_for_signal(signal, available, contract_spec)
            self.set_bitget_leverage(credential, signal)
            order = self.place_market_order(credential, signal, size, parent_client_oid)
            order_id = str(order.get("orderId") or "") or None
            detail = self.confirm_filled_order(credential, signal, order_id, parent_client_oid)
            entry_confirmed = True
            snapshot = self.refresh_user_private_snapshot(user_id)
            position = self.find_open_position(snapshot["positions"], signal)
            if position is None:
                raise LiveExecutionError("entry was filled but fresh position snapshot did not confirm an open position")
            receipts = self.install_protection_orders(
                credential,
                signal,
                size,
                contract_spec,
                parent_client_oid,
            )
            self.record_live_event(
                user_id,
                signal,
                "info",
                (
                    f"Server live entry protected. Side {signal.side}, size {decimal_text(size)}, "
                    f"entry {decimal_text(signal.entry)}, TP1 {decimal_text(signal.partial_take_profit)}, "
                    f"TP2 {decimal_text(signal.take_profit)}, SL {decimal_text(signal.stop)}."
                ),
                {
                    "mode": "server-live",
                    "clientOid": redacted_identifier(parent_client_oid),
                    "filledSize": str(detail.get("baseVolume") or detail.get("size") or decimal_text(size)),
                    "averagePrice": str(detail.get("priceAvg") or "-"),
                    "entry": decimal_text(signal.entry),
                    "size": decimal_text(size),
                    "marginUSDT": decimal_text(self.live_order_margin_usdt),
                    "availableBalanceRatio": decimal_text(self.live_available_balance_ratio),
                    "leverage": f"{signal.leverage}x",
                    "tp1": decimal_text(signal.partial_take_profit),
                    "tp2": decimal_text(signal.take_profit),
                    "stopLoss": decimal_text(signal.stop),
                    "protectionOrders": str(len(receipts)),
                },
            )
            return True
        except Exception as error:
            failure_reason = self.public_live_error_text(error)
            if entry_confirmed:
                try:
                    snapshot = self.refresh_user_private_snapshot(user_id)
                    if self.find_open_position(snapshot["positions"], signal) is not None:
                        self.close_position_fail_closed(credential, signal)
                except Exception:
                    pass
            self.record_live_event(
                user_id,
                signal,
                "error",
                f"Server live execution failed: {failure_reason}",
                {
                    "mode": "server-live",
                    "failureReason": failure_reason,
                    "clientOid": redacted_identifier(parent_client_oid),
                    "failClosedAttempted": str(entry_confirmed).lower(),
                    "entry": decimal_text(signal.entry),
                    "tp1": decimal_text(signal.partial_take_profit),
                    "tp2": decimal_text(signal.take_profit),
                    "stopLoss": decimal_text(signal.stop),
                },
            )
            raise
        finally:
            self.release_live_lock(user_id)

    def user_id_for_token(self, token: str) -> str | None:
        for user_id, expected in self.auth_tokens_by_user_id.items():
            if hmac.compare_digest(token, expected):
                return user_id
        return None

    def user_dir(self, user_id: str) -> Path:
        return self.data_dir / "users" / validate_user_id(user_id)

    def web_access_profile_assignment_path(self, user_id: str) -> Path:
        return self.user_dir(user_id) / "web-access-profile.json"

    def assign_web_access_profile(self, user_id: str, profile_id: str) -> None:
        profiles = self.all_web_access_profiles_by_id()
        if profile_id not in profiles:
            raise ValueError("web access profile is not configured")
        profile = profiles[profile_id]
        self.atomic_write_json(
            self.web_access_profile_assignment_path(user_id),
            {
                "profileID": profile.profile_id,
                "name": profile.name,
                "assignedAt": iso(now_utc()),
            },
            pretty=True,
        )

    def assigned_web_access_profile_id(self, user_id: str) -> str | None:
        payload = read_json_file(self.web_access_profile_assignment_path(user_id), {})
        profile_id = payload.get("profileID")
        return str(profile_id) if isinstance(profile_id, str) and profile_id.strip() else None

    def web_access_profile_for_user(self, user_id: str) -> WebAccessProfile | None:
        profile_id = self.assigned_web_access_profile_id(user_id)
        if profile_id is None:
            return self.owner_web_access_profile()
        return self.all_web_access_profiles_by_id().get(profile_id)

    def web_access_profile_public_record(self, user_id: str) -> dict[str, Any] | None:
        active_ids = self.active_strategy_ids()
        profile_id = self.assigned_web_access_profile_id(user_id)
        profile = self.web_access_profile_for_user(user_id)
        if profile is None:
            return {
                "profileID": profile_id,
                "name": "Missing profile",
                "allowedStrategyIDs": [],
                "allowsAllStrategies": False,
                "configured": False,
            }
        record = profile.public_record(active_ids)
        record["configured"] = True
        return record

    def ensure_user_storage(self, user_id: str) -> None:
        directory = self.user_dir(user_id)
        directory.mkdir(parents=True, exist_ok=True)
        if not (directory / "paper-runner-control.json").exists():
            self.save_control(user_id, True, updated_by="runner")

    def migrate_legacy_default_user_files(self) -> None:
        destination_dir = self.user_dir(self.default_user_id)
        destination_dir.mkdir(parents=True, exist_ok=True)
        legacy_names = [
            "paper-runner-control.json",
            "paper-runner-status.json",
            "paper-runner-evaluations.jsonl",
            "paper-runner-heartbeat.json",
            "trade-event-logs.jsonl",
        ]
        for name in legacy_names:
            source = self.data_dir / name
            destination = destination_dir / name
            if source.exists() and not destination.exists():
                destination.write_bytes(source.read_bytes())

    def load_live_control(self, user_id: str) -> dict[str, Any]:
        control = read_json_file(self.user_dir(user_id) / "server-live-control.json", {})
        return {
            "enabled": bool(control.get("enabled", False)),
            "acknowledgedRisk": bool(control.get("acknowledgedRisk", False)),
            "mode": "server-live-gate",
            "updatedAt": control.get("updatedAt"),
            "updatedBy": control.get("updatedBy"),
        }

    def save_live_control(self, user_id: str, enabled: bool, acknowledged_risk: bool, updated_by: str) -> dict[str, Any]:
        with self.lock:
            control = {
                "enabled": enabled,
                "acknowledgedRisk": acknowledged_risk if enabled else False,
                "mode": "server-live-gate",
                "updatedAt": iso(now_utc()),
                "updatedBy": updated_by,
            }
            self.user_dir(user_id).mkdir(parents=True, exist_ok=True)
            self.atomic_write_json(self.user_dir(user_id) / "server-live-control.json", control, pretty=True)
            return self.live_status(user_id)

    def live_lock_path(self, user_id: str) -> Path:
        return self.user_dir(user_id) / "server-live-lock.json"

    def live_lock_available(self, user_id: str, checked_at: datetime) -> tuple[bool, str | None]:
        path = self.live_lock_path(user_id)
        if not path.exists():
            return True, None
        lock = read_json_file(path, {})
        try:
            updated_at = datetime.fromisoformat(str(lock["updatedAt"]).replace("Z", "+00:00"))
        except (KeyError, ValueError):
            return False, "live lock exists but has invalid timestamp"
        stale_after = max(self.private_poll_seconds * 2, 120)
        if (checked_at - updated_at).total_seconds() > stale_after:
            return True, "stale live lock ignored"
        return False, "another live runner lock is active"

    def live_status(self, user_id: str) -> dict[str, Any]:
        checked_at = now_utc()
        control = self.load_live_control(user_id)
        credential_available = user_id in self.bitget_credentials_by_user_id
        encrypted_credential_stored = self.credential_record_path(user_id).exists()
        snapshot = self.load_private_snapshot(user_id)
        snapshot_fresh = False
        snapshot_updated_at: str | None = None
        if isinstance(snapshot, dict):
            snapshot_updated_at = snapshot.get("updatedAt")
            try:
                updated_at = datetime.fromisoformat(str(snapshot_updated_at).replace("Z", "+00:00"))
                snapshot_fresh = (checked_at - updated_at).total_seconds() <= max(self.private_poll_seconds * 2, 120)
            except ValueError:
                snapshot_fresh = False
        lock_available, lock_note = self.live_lock_available(user_id, checked_at)
        blockers: list[str] = []
        if not control["enabled"]:
            blockers.append("live consent is disabled")
        if not credential_available:
            blockers.append("Bitget credential is not loaded")
        if not snapshot_fresh:
            blockers.append("fresh account/position snapshot is required")
        if not lock_available:
            blockers.append(lock_note or "live runner lock is unavailable")
        ready = not blockers
        order_blockers: list[str] = []
        if not self.live_order_execution_enabled:
            order_blockers.append("live order execution env switch is disabled")
        if self.live_order_margin_usdt <= 0:
            order_blockers.append("live order margin USDT is not configured")
        order_execution_enabled = ready and not order_blockers
        minimum_test_order_enabled = ready and self.live_order_execution_enabled
        return {
            "updatedAt": iso(checked_at),
            "mode": "server-live-gate",
            "ready": ready,
            "orderExecutionEnabled": order_execution_enabled,
            "minimumTestOrderEnabled": minimum_test_order_enabled,
            "blockers": blockers,
            "orderBlockers": order_blockers,
            "control": control,
            "executionConfig": {
                "marginUSDT": decimal_text(self.live_order_margin_usdt),
                "availableBalanceRatio": decimal_text(self.live_available_balance_ratio),
                "marginMode": self.live_margin_mode,
                "positionMode": self.live_position_mode,
            },
            "checks": {
                "credentialAvailable": credential_available,
                "encryptedCredentialStored": encrypted_credential_stored,
                "privateSnapshotFresh": snapshot_fresh,
                "privateSnapshotUpdatedAt": snapshot_updated_at,
                "liveLockAvailable": lock_available,
                "liveLockNote": lock_note,
            },
        }

    def strategy_selection_path(self, user_id: str) -> Path:
        return self.user_dir(user_id) / "server-strategy-selection.json"

    def configured_strategy_params(self) -> list[dict[str, Any]]:
        params: list[dict[str, Any]] = []
        for symbol in self.symbols:
            params.extend(ACTIVE_STRATEGIES_BY_SYMBOL.get(symbol, []))
        return params

    def active_strategy_ids(self) -> list[str]:
        ids: list[str] = []
        seen: set[str] = set()
        for params in self.configured_strategy_params():
            strategy_id = str(params["strategy_id"])
            if strategy_id not in seen:
                seen.add(strategy_id)
                ids.append(strategy_id)
        return ids

    def allowed_strategy_ids_for_user(self, user_id: str) -> list[str]:
        active_ids = self.active_strategy_ids()
        profile = self.web_access_profile_for_user(user_id)
        if profile is None:
            return []
        if profile.allows_all_strategies:
            return active_ids
        allowed_set = set(profile.allowed_strategy_ids)
        return [strategy_id for strategy_id in active_ids if strategy_id in allowed_set]

    def load_enabled_strategy_ids(self, user_id: str) -> list[str]:
        active_ids = self.allowed_strategy_ids_for_user(user_id)
        if not active_ids:
            return []
        active_set = set(active_ids)
        payload = read_json_file(self.strategy_selection_path(user_id), {})
        raw_ids = payload.get("enabledStrategyIDs")
        if not isinstance(raw_ids, list):
            return active_ids
        enabled: list[str] = []
        seen: set[str] = set()
        for raw_id in raw_ids:
            strategy_id = str(raw_id)
            if strategy_id in active_set and strategy_id not in seen:
                seen.add(strategy_id)
                enabled.append(strategy_id)
        return enabled or active_ids

    def strategy_status(self, user_id: str) -> dict[str, Any]:
        enabled_ids = self.load_enabled_strategy_ids(user_id)
        enabled_set = set(enabled_ids)
        allowed_ids = set(self.allowed_strategy_ids_for_user(user_id))
        selection = read_json_file(self.strategy_selection_path(user_id), {})
        available: list[dict[str, Any]] = []
        for symbol in self.symbols:
            for params in ACTIVE_STRATEGIES_BY_SYMBOL.get(symbol, []):
                strategy_id = str(params["strategy_id"])
                if strategy_id not in allowed_ids:
                    continue
                available.append({
                    "id": strategy_id,
                    "name": str(params.get("name") or strategy_id),
                    "symbol": symbol,
                    "timeframe": TIMEFRAME,
                    "enabled": strategy_id in enabled_set,
                    "backtest": STRATEGY_BACKTESTS.get(strategy_id),
                    "parameters": self.safe_strategy_parameters(params),
                })
        return {
            "available": available,
            "enabledStrategyIDs": enabled_ids,
            "accessProfile": self.web_access_profile_public_record(user_id),
            "updatedAt": selection.get("updatedAt"),
            "updatedBy": selection.get("updatedBy"),
        }

    @staticmethod
    def safe_strategy_parameters(params: dict[str, Any]) -> dict[str, Any]:
        hidden = {"strategy_id", "name", "symbol"}
        public: dict[str, Any] = {}
        for key, value in params.items():
            if key in hidden:
                continue
            if isinstance(value, Decimal):
                public[key] = decimal_text(value)
            elif isinstance(value, (str, int, float, bool)) or value is None:
                public[key] = value
        return public

    def save_strategy_selection(
        self,
        user_id: str,
        enabled_strategy_ids: list[str],
        updated_by: str,
    ) -> dict[str, Any]:
        active_ids = self.allowed_strategy_ids_for_user(user_id)
        active_set = set(active_ids)
        requested_ids = [strategy_id.strip() for strategy_id in enabled_strategy_ids if strategy_id.strip()]
        unknown_ids = sorted(set(requested_ids) - active_set)
        if unknown_ids:
            raise ValueError(f"strategy is not available for this account: {unknown_ids[0]}")
        if not active_ids:
            raise ValueError("no strategies are available for this account")

        enabled: list[str] = []
        seen: set[str] = set()
        for strategy_id in active_ids:
            if strategy_id in requested_ids and strategy_id not in seen:
                seen.add(strategy_id)
                enabled.append(strategy_id)
        if not enabled:
            raise ValueError("at least one strategy must be enabled")

        previous_enabled = set(self.load_enabled_strategy_ids(user_id))
        newly_enabled = set(enabled) - previous_enabled
        with self.lock:
            self.user_dir(user_id).mkdir(parents=True, exist_ok=True)
            self.atomic_write_json(
                self.strategy_selection_path(user_id),
                {
                    "enabledStrategyIDs": enabled,
                    "updatedAt": iso(now_utc()),
                    "updatedBy": updated_by,
                },
                pretty=True,
            )
            self.prime_newly_enabled_strategies(user_id, newly_enabled)
            self.record_strategy_selection_event(user_id, enabled)
        return self.strategy_status(user_id)

    def prime_newly_enabled_strategies(self, user_id: str, strategy_ids: set[str]) -> None:
        if not strategy_ids:
            return
        evaluated_at = now_utc()
        for symbol in self.symbols:
            closed_candles = [candle for candle in self.load_candles(symbol) if candle.is_closed]
            if not closed_candles:
                continue
            latest_closed = closed_candles[-1]
            for params in ACTIVE_STRATEGIES_BY_SYMBOL.get(symbol, []):
                strategy_id = str(params["strategy_id"])
                if strategy_id not in strategy_ids:
                    continue
                key = f"{symbol}:{TIMEFRAME}:{strategy_id}:{latest_closed.open_time}"
                self.mark_evaluated(
                    user_id,
                    key,
                    symbol,
                    strategy_id,
                    latest_closed.open_time,
                    produced_signal=False,
                    evaluated_at=evaluated_at,
                    skipped_reason="strategy enabled after latest closed candle; waiting for next close",
                )

    def record_strategy_selection_event(self, user_id: str, enabled_strategy_ids: list[str]) -> None:
        names = {
            str(params["strategy_id"]): str(params.get("name") or params["strategy_id"])
            for params in self.configured_strategy_params()
        }
        self.append_jsonl(
            self.user_dir(user_id) / "trade-event-logs.jsonl",
            {
                "id": str(uuid.uuid4()),
                "timestamp": iso(now_utc()),
                "category": "automation",
                "severity": "info",
                "symbol": None,
                "message": f"Server strategy selection updated: {','.join(enabled_strategy_ids)}",
                "metadata": {
                    "title": "전략 선택 변경",
                    "subtitle": "앱에서 선택한 전략만 다음 closed 15m candle부터 평가합니다.",
                    "tags": ["LIVE", "STRATEGY", TIMEFRAME],
                    "details": {
                        "enabledStrategies": ", ".join(names.get(strategy_id, strategy_id) for strategy_id in enabled_strategy_ids),
                        "enabledCount": str(len(enabled_strategy_ids)),
                    },
                },
            },
        )

    def fetch_candles(self, symbol: str) -> list[Candle]:
        params = {
            "granularity": TIMEFRAME,
            "limit": str(self.fetch_candle_limit),
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

    def fetch_history_candles(self, symbol: str, end_time_ms: int, limit: int = 200) -> list[Candle]:
        params = {
            "endTime": str(end_time_ms),
            "granularity": TIMEFRAME,
            "limit": str(min(max(limit, 1), 200)),
            "productType": PRODUCT_TYPE,
            "symbol": symbol,
        }
        url = f"{self.base_url}/api/v2/mix/market/history-candles?{urlencode(sorted(params.items()))}"
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
                    is_closed=True,
                )
            )
        return sorted(candles, key=lambda candle: candle.open_time)

    def trimmed_candles(self, candles: list[Candle]) -> list[Candle]:
        if self.candle_limit <= 0:
            return candles
        return candles[-self.candle_limit :]

    def required_candle_count(self, symbol: str) -> int | None:
        if symbol not in ACTIVE_STRATEGIES_BY_SYMBOL:
            return self.fetch_candle_limit
        if self.candle_limit <= 0:
            return None
        return self.candle_limit

    def backfill_history_if_needed(self, symbol: str, candles: list[Candle]) -> list[Candle]:
        required = self.required_candle_count(symbol)
        closed_count = len([candle for candle in candles if candle.is_closed])
        if (required is not None and closed_count >= required) or self.history_backfill_pages_per_cycle <= 0:
            trimmed = self.trimmed_candles(candles)
            self.save_candles(symbol, trimmed)
            return trimmed
        if not candles:
            return candles

        merged = {candle.key: candle for candle in candles}
        oldest_open_time = min(candle.open_time for candle in candles)
        pages = 0
        self.save_candles(symbol, self.trimmed_candles(candles))
        while (required is None or closed_count < required) and pages < self.history_backfill_pages_per_cycle:
            try:
                history = self.fetch_history_candles(symbol, oldest_open_time * 1000 - 1)
            except Exception:
                self.save_candles(symbol, self.trimmed_candles(candles))
                raise
            if not history:
                break
            previous_oldest = oldest_open_time
            for candle in history:
                merged[candle.key] = candle
            oldest_open_time = min(candle.open_time for candle in merged.values())
            candles = sorted(merged.values(), key=lambda candle: candle.open_time)
            closed_count = len([candle for candle in candles if candle.is_closed])
            pages += 1
            if oldest_open_time >= previous_oldest:
                break
            if pages % 25 == 0:
                self.save_candles(symbol, self.trimmed_candles(candles))
            time.sleep(0.06)
        trimmed = self.trimmed_candles(candles)
        self.save_candles(symbol, trimmed)
        return trimmed

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
        return self.backfill_history_if_needed(symbol, candles)

    def load_evaluated_keys(self, user_id: str) -> set[str]:
        path = self.user_dir(user_id) / "paper-runner-evaluations.jsonl"
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

    def has_evaluated(self, user_id: str, key: str) -> bool:
        return key in self.evaluated_keys_by_user.setdefault(user_id, set())

    def mark_evaluated(
        self,
        user_id: str,
        key: str,
        symbol: str,
        strategy_id: str,
        open_time: int,
        produced_signal: bool,
        evaluated_at: datetime,
        skipped_reason: str | None = None,
        strategy_name: str | None = None,
        signal_details: dict[str, Any] | None = None,
    ) -> dict[str, Any] | None:
        evaluated_keys = self.evaluated_keys_by_user.setdefault(user_id, set())
        if key in evaluated_keys:
            return None
        evaluated_keys.add(key)
        record = {
            "evaluationKey": key,
            "symbol": symbol,
            "timeframe": TIMEFRAME,
            "strategyID": strategy_id,
            "strategyName": strategy_name or strategy_id,
            "candleOpenTime": open_time,
            "candleOpenTimeISO": open_time_iso(open_time),
            "candleCloseTimeISO": open_time_iso(open_time + 15 * 60),
            "producedSignal": produced_signal,
            "skippedReason": skipped_reason,
            "signal": signal_details if signal_details else None,
            "evaluatedAt": iso(evaluated_at),
        }
        self.append_jsonl(
            self.user_dir(user_id) / "paper-runner-evaluations.jsonl",
            record,
        )
        return record

    @staticmethod
    def signal_evaluation_details(signal: Signal) -> dict[str, Any]:
        return {
            "side": signal.side,
            "entry": decimal_text(signal.entry),
            "stopLoss": decimal_text(signal.stop),
            "partialTakeProfit": decimal_text(signal.partial_take_profit),
            "takeProfit": decimal_text(signal.take_profit),
            "leverage": signal.leverage,
            "rewardRiskRatio": decimal_text(signal.reward_risk_ratio) if signal.reward_risk_ratio else None,
            "reason": signal.reason,
        }

    @staticmethod
    def evaluation_summary(records: list[dict[str, Any]], failures: list[str] | None = None) -> dict[str, Any] | None:
        if not records:
            return None
        latest_open_time = max(int(record.get("candleOpenTime") or 0) for record in records)
        latest_records = [
            record for record in records
            if int(record.get("candleOpenTime") or 0) == latest_open_time
        ]
        if not latest_records:
            return None
        signal_records = [record for record in latest_records if bool(record.get("producedSignal"))]
        skipped_records = [record for record in latest_records if record.get("skippedReason")]
        evaluated_records = [record for record in latest_records if not record.get("skippedReason")]
        if signal_records:
            headline = f"신호 {len(signal_records)}개 발생"
        elif skipped_records and not evaluated_records:
            headline = "평가 건너뜀"
        else:
            headline = "신호 없음"
        if failures:
            headline = f"{headline} · 확인 필요 {len(failures)}"
        return {
            "headline": headline,
            "candleOpenTime": latest_open_time,
            "candleOpenTimeISO": open_time_iso(latest_open_time),
            "candleCloseTimeISO": open_time_iso(latest_open_time + 15 * 60),
            "evaluatedAt": max(str(record.get("evaluatedAt") or "") for record in latest_records),
            "evaluatedCount": len(evaluated_records),
            "skippedCount": len(skipped_records),
            "signalCount": len(signal_records),
            "failureCount": len(failures or []),
            "failures": list(failures or [])[:3],
            "items": [
                {
                    "symbol": str(record.get("symbol") or ""),
                    "timeframe": str(record.get("timeframe") or TIMEFRAME),
                    "strategyID": str(record.get("strategyID") or ""),
                    "strategyName": str(record.get("strategyName") or record.get("strategyID") or ""),
                    "producedSignal": bool(record.get("producedSignal")),
                    "skippedReason": record.get("skippedReason"),
                    "signal": record.get("signal") if isinstance(record.get("signal"), dict) else None,
                    "evaluatedAt": record.get("evaluatedAt"),
                }
                for record in latest_records[:20]
            ],
        }

    def load_latest_evaluation_summary(self, user_id: str) -> dict[str, Any] | None:
        path = self.user_dir(user_id) / "paper-runner-evaluations.jsonl"
        if not path.exists():
            return None
        records: list[dict[str, Any]] = []
        latest_open_time: int | None = None
        for line in reversed(path.read_text(encoding="utf-8").splitlines()):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            try:
                candle_open_time = int(record.get("candleOpenTime") or 0)
            except (TypeError, ValueError):
                continue
            if latest_open_time is None:
                latest_open_time = candle_open_time
            if candle_open_time != latest_open_time:
                break
            records.append(record)
        records.reverse()
        return self.evaluation_summary(records)

    def load_status(self, user_id: str) -> dict[str, Any]:
        user_directory = self.user_dir(user_id)
        status = read_json_file(
            user_directory / "paper-runner-status.json",
            {
                "updatedAt": None,
                "mode": "paper",
                "userID": user_id,
                "symbols": self.symbols,
                "latestClosedCandleOpenTime": None,
                "latestClosedCandleOpenTimeISO": None,
                "savedCandles": 0,
                "evaluations": 0,
                "signals": 0,
                "failures": [],
                "storagePath": str(user_directory),
                "marketStoragePath": str(self.data_dir),
                "strategies": self.strategy_status(user_id),
                "lastEvaluation": None,
            },
        )
        if not status.get("lastEvaluation"):
            status["lastEvaluation"] = self.load_latest_evaluation_summary(user_id)
        return status

    def load_control(self, user_id: str) -> dict[str, Any]:
        control = read_json_file(self.user_dir(user_id) / "paper-runner-control.json", {})
        enabled = bool(control.get("enabled", True))
        return {
            "enabled": enabled,
            "mode": "paper",
            "updatedAt": control.get("updatedAt"),
            "updatedBy": control.get("updatedBy"),
        }

    def save_control(self, user_id: str, enabled: bool, updated_by: str) -> dict[str, Any]:
        with self.lock:
            control = {
                "enabled": enabled,
                "mode": "paper",
                "updatedAt": iso(now_utc()),
                "updatedBy": updated_by,
            }
            self.user_dir(user_id).mkdir(parents=True, exist_ok=True)
            self.atomic_write_json(self.user_dir(user_id) / "paper-runner-control.json", control, pretty=True)
            return control

    @staticmethod
    def is_paper_trade_event(record: dict[str, Any]) -> bool:
        metadata = record.get("metadata")
        if not isinstance(metadata, dict):
            metadata = {}
        details = metadata.get("details")
        if not isinstance(details, dict):
            details = {}
        raw_tags = metadata.get("tags")
        tags = [str(tag).upper() for tag in raw_tags] if isinstance(raw_tags, list) else []
        title = str(metadata.get("title") or "").lower()
        message = str(record.get("message") or "").lower()
        mode = str(details.get("mode") or "").lower()
        return (
            "PAPER" in tags
            or "paper" in mode
            or "paper runner" in title
            or "paper signal" in title
            or "paper runner" in message
            or "paper signal" in message
        )

    def load_recent_logs(self, user_id: str, limit: int) -> list[dict[str, Any]]:
        path = self.user_dir(user_id) / "trade-event-logs.jsonl"
        if not path.exists():
            return []
        lines = path.read_text(encoding="utf-8").splitlines()
        records: list[dict[str, Any]] = []
        for line in reversed(lines):
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if self.is_paper_trade_event(record):
                continue
            records.append(record)
            if len(records) >= limit:
                break
        return list(reversed(records))

    def append_jsonl(self, path: Path, record: dict[str, Any]) -> None:
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
            handle.write("\n")

    def atomic_write_json(self, path: Path, record: Any, pretty: bool = False) -> None:
        tmp_path = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
        text = json.dumps(
            record,
            ensure_ascii=False,
            sort_keys=True,
            indent=2 if pretty else None,
            separators=None if pretty else (",", ":"),
        )
        try:
            tmp_path.write_text(text + "\n", encoding="utf-8")
            tmp_path.replace(path)
        finally:
            try:
                tmp_path.unlink()
            except FileNotFoundError:
                pass

    def record_signal(self, user_id: str, signal: Signal, candle_open_time: int, generated_at: datetime) -> None:
        ratio = signal.reward_risk_ratio
        self.append_jsonl(
            self.user_dir(user_id) / "trade-event-logs.jsonl",
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
                    "Server live execution is handled by the separate live gate."
                ),
                "metadata": {
                    "title": f"{signal.symbol} {TIMEFRAME} paper signal",
                    "subtitle": f"{signal.strategy_id} 전략이 closed 15m candle 기준 paper 후보를 만들었습니다.",
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

    def maybe_record_heartbeat(self, user_id: str, status: dict[str, Any], started_at: datetime, updated_at: datetime) -> None:
        user_directory = self.user_dir(user_id)
        path = user_directory / "paper-runner-heartbeat.json"
        if path.exists():
            try:
                previous = json.loads(path.read_text(encoding="utf-8"))
                logged_at = datetime.fromisoformat(str(previous["loggedAt"]).replace("Z", "+00:00"))
                if (updated_at - logged_at).total_seconds() < 15 * 60:
                    return
            except (KeyError, ValueError, json.JSONDecodeError):
                pass

        elapsed = max((updated_at - started_at).total_seconds(), 0)
        live_text = (
            "Live order env switch enabled."
            if self.live_order_execution_enabled and self.live_order_margin_usdt > 0
            else "Live order env switch disabled."
        )
        self.append_jsonl(
            user_directory / "trade-event-logs.jsonl",
            {
                "id": str(uuid.uuid4()),
                "timestamp": iso(updated_at),
                "category": "automation",
                "severity": "info" if not status["failures"] else "warning",
                "symbol": None,
                "message": (
                    f"Paper runner heartbeat. Symbols {','.join(status['symbols'])}, "
                    f"saved candles {status['savedCandles']}, evaluations {status['evaluations']}, "
                    f"skipped {status.get('skippedEvaluations', 0)}, signals {status['signals']}, failures {len(status['failures'])}, "
                    f"elapsed {elapsed:.2f}s. {live_text}"
                ),
                "metadata": {
                    "title": "Paper runner heartbeat",
                    "subtitle": "서버 runner가 15m closed candle 기준 paper 평가를 수행했습니다.",
                    "tags": ["PAPER", TIMEFRAME, "OK" if not status["failures"] else "CHECK"],
                    "details": {
                        "symbols": ",".join(status["symbols"]),
                        "savedCandles": str(status["savedCandles"]),
                        "evaluations": str(status["evaluations"]),
                        "skippedEvaluations": str(status.get("skippedEvaluations", 0)),
                        "enabled": str(status.get("control", {}).get("enabled", True)).lower(),
                        "signals": str(status["signals"]),
                        "failures": str(len(status["failures"])),
                        "storagePath": str(user_directory),
                        "marketStoragePath": str(self.data_dir),
                    },
                },
            },
        )
        self.atomic_write_json(path, {"loggedAt": iso(updated_at)})

    def run_once_cycle(self) -> None:
        started_at = now_utc()
        saved_candles = 0
        market_failures: list[str] = []
        closed_candles_by_symbol: dict[str, list[Candle]] = {}
        latest_closed_open_time: int | None = None

        for symbol in self.symbols:
            try:
                remote_candles = self.fetch_candles(symbol)
                stored_candles = self.upsert_candles(symbol, remote_candles)
                saved_candles += len(stored_candles)
                closed_candles = [candle for candle in stored_candles if candle.is_closed]
                if not closed_candles:
                    market_failures.append(f"{symbol}: no closed 15m candle available")
                    continue
                latest_closed = closed_candles[-1]
                latest_closed_open_time = max(latest_closed_open_time or latest_closed.open_time, latest_closed.open_time)
                closed_candles_by_symbol[symbol] = closed_candles
            except Exception as error:
                market_failures.append(f"{symbol}: {error}")

        updated_at = now_utc()
        total_evaluations = 0
        total_skipped_evaluations = 0
        total_signals = 0
        total_failures = len(market_failures)

        for user_id in self.user_ids:
            control = self.load_control(user_id)
            strategy_enabled = bool(control["enabled"])
            enabled_strategy_ids = set(self.load_enabled_strategy_ids(user_id))
            evaluations = 0
            skipped_evaluations = 0
            signals = 0
            failures = list(market_failures)
            private_failure = self.maybe_refresh_user_private_snapshot(user_id, updated_at)
            if private_failure is not None:
                failures.append(private_failure)
            private_snapshot = self.load_private_snapshot(user_id)
            live_candidates: list[tuple[Signal, int, datetime, str]] = []
            evaluation_records: list[dict[str, Any]] = []

            for symbol, closed_candles in closed_candles_by_symbol.items():
                latest_closed = closed_candles[-1]
                for params in ACTIVE_STRATEGIES_BY_SYMBOL.get(symbol, []):
                    strategy_id = params["strategy_id"]
                    if strategy_id not in enabled_strategy_ids:
                        continue
                    key = f"{symbol}:{TIMEFRAME}:{strategy_id}:{latest_closed.open_time}"
                    if self.has_evaluated(user_id, key):
                        continue
                    if not strategy_enabled:
                        skipped_evaluations += 1
                        record = self.mark_evaluated(
                            user_id,
                            key,
                            symbol,
                            strategy_id,
                            latest_closed.open_time,
                            produced_signal=False,
                            evaluated_at=now_utc(),
                            skipped_reason="paper runner disabled",
                            strategy_name=str(params.get("name") or strategy_id),
                        )
                        if record:
                            evaluation_records.append(record)
                        continue
                    evaluations += 1
                    evaluated_at = now_utc()
                    try:
                        signal = evaluate_strategy(closed_candles, params, evaluated_at)
                        if signal:
                            signals += 1
                            self.record_signal(user_id, signal, latest_closed.open_time, evaluated_at)
                            live_candidates.append((signal, latest_closed.open_time, evaluated_at, strategy_id))
                        record = self.mark_evaluated(
                            user_id,
                            key,
                            symbol,
                            strategy_id,
                            latest_closed.open_time,
                            signal is not None,
                            evaluated_at,
                            strategy_name=str(params.get("name") or strategy_id),
                            signal_details=self.signal_evaluation_details(signal) if signal else None,
                        )
                        if record:
                            evaluation_records.append(record)
                    except Exception as error:
                        failures.append(f"{symbol} {strategy_id}: {error}")

            if live_candidates:
                live_candidates.sort(
                    key=lambda item: item[0].reward_risk_ratio or dec(0),
                    reverse=True,
                )
                signal, candle_open_time, evaluated_at, strategy_id = live_candidates[0]
                try:
                    self.maybe_execute_live_signal(
                        user_id,
                        signal,
                        candle_open_time,
                        evaluated_at,
                        private_snapshot,
                    )
                except Exception:
                    failures.append(f"{signal.symbol} {strategy_id}: live execution failed")

            total_evaluations += evaluations
            total_skipped_evaluations += skipped_evaluations
            total_signals += signals
            total_failures += len(failures) - len(market_failures)
            user_directory = self.user_dir(user_id)
            status = {
                "updatedAt": iso(updated_at),
                "mode": "paper",
                "userID": user_id,
                "symbols": self.symbols,
                "latestClosedCandleOpenTime": latest_closed_open_time,
                "latestClosedCandleOpenTimeISO": open_time_iso(latest_closed_open_time) if latest_closed_open_time else None,
                "savedCandles": saved_candles,
                "evaluations": evaluations,
                "skippedEvaluations": skipped_evaluations,
                "signals": signals,
                "failures": failures,
                "storagePath": str(user_directory),
                "marketStoragePath": str(self.data_dir),
                "control": control,
                "live": self.live_status(user_id),
                "strategies": self.strategy_status(user_id),
                "lastEvaluation": (
                    self.evaluation_summary(evaluation_records, failures)
                    if evaluation_records
                    else self.load_latest_evaluation_summary(user_id)
                ),
                "privateSnapshot": {
                    "updatedAt": private_snapshot.get("updatedAt"),
                    "accountCount": private_snapshot.get("accountCount", 0),
                    "positionCount": private_snapshot.get("positionCount", 0),
                } if isinstance(private_snapshot, dict) else None,
            }
            self.atomic_write_json(user_directory / "paper-runner-status.json", status, pretty=True)
            self.maybe_record_heartbeat(user_id, status, started_at, updated_at)

        latest_text = str(latest_closed_open_time) if latest_closed_open_time else "-"
        status_text = "ok" if total_failures == 0 else "check"
        print(
            f"[{iso(updated_at)}] paper-runner={status_text} "
            f"symbols={','.join(self.symbols)} latestClosed={latest_text} "
            f"saved={saved_candles} users={len(self.user_ids)} "
            f"evaluations={total_evaluations} skipped={total_skipped_evaluations} "
            f"signals={total_signals} failures={total_failures}",
            flush=True,
        )

    def run(self) -> None:
        if self.api_enabled:
            self.start_api_server()
        while True:
            self.run_once_cycle()
            if self.run_once:
                return
            time.sleep(self.poll_seconds)

    def start_api_server(self) -> None:
        handler = type("BoundPaperRunnerAPIHandler", (PaperRunnerAPIHandler,), {"runner": self})
        server = ThreadingHTTPServer((self.api_host, self.api_port), handler)
        thread = threading.Thread(target=server.serve_forever, name="paper-runner-api", daemon=True)
        thread.start()
        print(f"paper-runner-api=listening host={self.api_host} port={self.api_port}", flush=True)


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
