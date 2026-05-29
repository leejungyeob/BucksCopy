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
from decimal import Decimal, getcontext
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
USER_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,80}$")
CREDENTIAL_ENCRYPTION_ALGORITHM = "AES-256-GCM"


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


class BitgetLoginError(Exception):
    pass


class PaperRunnerAPIHandler(BaseHTTPRequestHandler):
    runner: "PaperRunner"

    def log_message(self, format: str, *args: Any) -> None:
        return

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            payload: dict[str, Any] = {
                "ok": True,
                "mode": "paper",
                "authRequired": self.runner.auth_required,
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
        if action == "logs":
            query = parse_qs(parsed.query)
            limit = clamp_int(query.get("limit", [None])[0], default=50, minimum=1, maximum=500)
            self.write_json({"items": self.runner.load_recent_logs(user_id, limit), "limit": limit})
            return
        if action == "candles":
            query = parse_qs(parsed.query)
            symbol = query.get("symbol", [""])[0].upper()
            limit = clamp_int(query.get("limit", [None])[0], default=100, minimum=1, maximum=1000)
            if symbol not in self.runner.symbols:
                self.write_json({"error": "symbol is not configured for this runner"}, HTTPStatus.BAD_REQUEST)
                return
            candles = [candle.to_record() for candle in self.runner.load_candles(symbol)[-limit:]]
            self.write_json({"symbol": symbol, "timeframe": TIMEFRAME, "items": candles, "limit": limit})
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
        self.write_json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/auth/bitget/login":
            self.handle_bitget_login()
            return

        if self.route_action(parsed.path) != "control":
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

        if "enabled" not in payload or not isinstance(payload["enabled"], bool):
            self.write_json({"error": "enabled boolean is required"}, HTTPStatus.BAD_REQUEST)
            return
        control = self.runner.save_control(user_id, payload["enabled"], updated_by="api")
        self.write_json(control)

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
            self.write_json(self.runner.login_with_bitget(api_key, secret_key, passphrase))
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
        if action in {"status", "control", "logs", "candles", "account", "positions"}:
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

    def write_json(self, payload: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class PaperRunner:
    def __init__(self) -> None:
        self.data_dir = Path(os.environ.get("BUCKS_COPY_DATA_DIR", "/var/lib/bucks-copy"))
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.symbols = self.parse_symbols(os.environ.get("BUCKS_COPY_SYMBOLS", "BTCUSDT,ETHUSDT"))
        self.candle_limit = min(max(int(os.environ.get("BUCKS_COPY_CANDLE_LIMIT", "500")), 1), 1000)
        self.poll_seconds = max(int(os.environ.get("BUCKS_COPY_POLL_SECONDS", "30")), 5)
        self.private_poll_seconds = max(int(os.environ.get("BUCKS_COPY_PRIVATE_POLL_SECONDS", "60")), 30)
        self.base_url = os.environ.get("BUCKS_COPY_BITGET_BASE_URL", DEFAULT_BASE_URL).rstrip("/")
        self.run_once = parse_bool(os.environ.get("BUCKS_COPY_RUN_ONCE"))
        self.api_host = os.environ.get("BUCKS_COPY_API_HOST", DEFAULT_API_HOST)
        self.api_port = clamp_int(os.environ.get("BUCKS_COPY_API_PORT"), DEFAULT_API_PORT, 1, 65535)
        self.api_enabled = parse_bool(os.environ.get("BUCKS_COPY_API_ENABLED"), default=not self.run_once)
        self.default_user_id = validate_user_id(os.environ.get("BUCKS_COPY_DEFAULT_USER_ID", DEFAULT_USER_ID))
        self.auth_users_path = Path(
            os.environ.get("BUCKS_COPY_AUTH_USERS_PATH", str(self.data_dir / "auth-users.json"))
        )
        self.require_auth = parse_bool(os.environ.get("BUCKS_COPY_REQUIRE_AUTH"), default=False)
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

    def login_with_bitget(self, api_key: str, secret_key: str, passphrase: str) -> dict[str, Any]:
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
            self.save_persistent_credential(user_id, credential)
            self.save_auth_users()
        return {
            "authToken": token,
            "mode": "paper",
            "credentialScope": "encrypted" if self.persistent_credential_enabled else "memory",
            "redactedIdentifier": credential.redacted_identifier,
            "userID": user_id,
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

    def user_id_for_token(self, token: str) -> str | None:
        for user_id, expected in self.auth_tokens_by_user_id.items():
            if hmac.compare_digest(token, expected):
                return user_id
        return None

    def user_dir(self, user_id: str) -> Path:
        return self.data_dir / "users" / validate_user_id(user_id)

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
    ) -> None:
        evaluated_keys = self.evaluated_keys_by_user.setdefault(user_id, set())
        if key in evaluated_keys:
            return
        evaluated_keys.add(key)
        self.append_jsonl(
            self.user_dir(user_id) / "paper-runner-evaluations.jsonl",
            {
                "evaluationKey": key,
                "symbol": symbol,
                "timeframe": TIMEFRAME,
                "strategyID": strategy_id,
                "candleOpenTime": open_time,
                "candleOpenTimeISO": open_time_iso(open_time),
                "producedSignal": produced_signal,
                "skippedReason": skipped_reason,
                "evaluatedAt": iso(evaluated_at),
            },
        )

    def load_status(self, user_id: str) -> dict[str, Any]:
        user_directory = self.user_dir(user_id)
        return read_json_file(
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
            },
        )

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

    def load_recent_logs(self, user_id: str, limit: int) -> list[dict[str, Any]]:
        path = self.user_dir(user_id) / "trade-event-logs.jsonl"
        if not path.exists():
            return []
        lines = path.read_text(encoding="utf-8").splitlines()
        records: list[dict[str, Any]] = []
        for line in lines[-limit:]:
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return records

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
                saved_candles += len(remote_candles)
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
            evaluations = 0
            skipped_evaluations = 0
            signals = 0
            failures = list(market_failures)
            private_failure = self.maybe_refresh_user_private_snapshot(user_id, updated_at)
            if private_failure is not None:
                failures.append(private_failure)
            private_snapshot = self.load_private_snapshot(user_id)

            for symbol, closed_candles in closed_candles_by_symbol.items():
                latest_closed = closed_candles[-1]
                for params in ACTIVE_STRATEGIES_BY_SYMBOL.get(symbol, []):
                    strategy_id = params["strategy_id"]
                    key = f"{symbol}:{TIMEFRAME}:{strategy_id}:{latest_closed.open_time}"
                    if self.has_evaluated(user_id, key):
                        continue
                    if not strategy_enabled:
                        skipped_evaluations += 1
                        self.mark_evaluated(
                            user_id,
                            key,
                            symbol,
                            strategy_id,
                            latest_closed.open_time,
                            produced_signal=False,
                            evaluated_at=now_utc(),
                            skipped_reason="paper runner disabled",
                        )
                        continue
                    evaluations += 1
                    evaluated_at = now_utc()
                    try:
                        signal = evaluate_strategy(closed_candles, params, evaluated_at)
                        if signal:
                            signals += 1
                            self.record_signal(user_id, signal, latest_closed.open_time, evaluated_at)
                        self.mark_evaluated(user_id, key, symbol, strategy_id, latest_closed.open_time, signal is not None, evaluated_at)
                    except Exception as error:
                        failures.append(f"{symbol} {strategy_id}: {error}")

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
