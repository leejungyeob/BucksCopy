#!/usr/bin/env python3
from __future__ import annotations

import argparse
import bisect
import csv
import json
import math
import sqlite3
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import paper_runner


INITIAL = 100.0
LEVERAGE = 10.0
MAX_RISK = 5.0
TAKER = 0.0006 * 0.8
MAKER = 0.0002 * 0.8


@dataclass(frozen=True)
class Candle:
    open_time: float
    open: float
    high: float
    low: float
    close: float
    volume: float


def utc_text(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M")


def parse_time(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def load_candles(db: Path, symbol: str, start: float, end: float) -> list[Candle]:
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=30)
    conn.execute("PRAGMA busy_timeout = 30000")
    try:
        rows = conn.execute(
            """
            SELECT open_time, open, high, low, close, volume
            FROM candles
            WHERE product_type = 'USDT-FUTURES'
              AND symbol = ?
              AND timeframe = '15m'
              AND is_closed = 1
              AND open_time >= ?
              AND open_time <= ?
            ORDER BY open_time ASC
            """,
            (symbol, start, end),
        ).fetchall()
    finally:
        conn.close()
    if not rows:
        raise RuntimeError(f"no closed 15m candles for {symbol}")
    return [Candle(float(t), float(o), float(h), float(l), float(c), float(v)) for t, o, h, l, c, v in rows]


def rolling_sma(values: list[float], period: int) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    total = 0.0
    for i, value in enumerate(values):
        total += value
        if i >= period:
            total -= values[i - period]
        if i + 1 >= period:
            out[i] = total / period
    return out


def rolling_std(values: list[float], period: int) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    total = 0.0
    total_sq = 0.0
    q: deque[float] = deque()
    for i, value in enumerate(values):
        q.append(value)
        total += value
        total_sq += value * value
        if len(q) > period:
            old = q.popleft()
            total -= old
            total_sq -= old * old
        if len(q) == period:
            mean = total / period
            out[i] = math.sqrt(max(total_sq / period - mean * mean, 0.0))
    return out


def rolling_quantile(values: list[float | None], period: int, min_periods: int, q: float) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    sorted_values: list[float] = []
    window: deque[float | None] = deque()
    for i, value in enumerate(values):
        window.append(value)
        if value is not None:
            bisect.insort(sorted_values, value)
        if len(window) > period:
            old = window.popleft()
            if old is not None:
                old_i = bisect.bisect_left(sorted_values, old)
                if old_i < len(sorted_values):
                    sorted_values.pop(old_i)
        if len(sorted_values) >= min_periods:
            pos = (len(sorted_values) - 1) * q
            lo = int(math.floor(pos))
            hi = int(math.ceil(pos))
            if lo == hi:
                out[i] = sorted_values[lo]
            else:
                out[i] = sorted_values[lo] * (hi - pos) + sorted_values[hi] * (pos - lo)
    return out


def rolling_atr(candles: list[Candle], period: int) -> list[float | None]:
    out: list[float | None] = [None] * len(candles)
    tr = [0.0] * len(candles)
    for i, candle in enumerate(candles):
        if i == 0:
            tr[i] = candle.high - candle.low
        else:
            prev = candles[i - 1].close
            tr[i] = max(candle.high - candle.low, abs(candle.high - prev), abs(candle.low - prev))
    total = 0.0
    for i, value in enumerate(tr):
        total += value
        if i >= period:
            total -= tr[i - period]
        if i + 1 >= period:
            out[i] = total / period
    return out


def ewm(values: list[float], alpha: float, min_periods: int) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    current: float | None = None
    count = 0
    for i, value in enumerate(values):
        count += 1
        current = value if current is None else alpha * value + (1.0 - alpha) * current
        if count >= min_periods:
            out[i] = current
    return out


def ema(values: list[float], period: int) -> list[float | None]:
    return ewm(values, 2.0 / (period + 1), period)


def previous_extreme(values: list[float], period: int, mode: str) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    for i in range(period, len(values)):
        window = values[i - period:i]
        out[i] = max(window) if mode == "max" else min(window)
    return out


def rolling_all(values: list[bool], period: int) -> list[bool]:
    out = [False] * len(values)
    total = 0
    q: deque[int] = deque()
    for i, value in enumerate(values):
        bit = 1 if value else 0
        q.append(bit)
        total += bit
        if len(q) > period:
            total -= q.popleft()
        out[i] = len(q) == period and total == period
    return out


def h1_indicators(candles: list[Candle]) -> dict[float, dict[str, float | None]]:
    buckets: dict[float, list[Candle]] = {}
    for candle in candles:
        close_time = candle.open_time + 15 * 60
        end = math.ceil(close_time / 3600.0) * 3600.0
        buckets.setdefault(end, []).append(candle)
    ends = sorted(buckets)
    closes = [buckets[end][-1].close for end in ends]
    ema20 = ema(closes, 20)
    ema50 = ema(closes, 50)
    ema100 = ema(closes, 100)
    return {
        end: {"ema20": ema20[i], "ema50": ema50[i], "ema100": ema100[i]}
        for i, end in enumerate(ends)
    }


def h1_for_open(h1: dict[float, dict[str, float | None]], open_time: float) -> dict[str, float | None]:
    end = math.floor(open_time / 3600.0) * 3600.0
    return h1.get(end, {"ema20": None, "ema50": None, "ema100": None})


def clip(value: float, low: float, high: float) -> float:
    return min(max(value, low), high)


def fee_percent(exit_kind: str, margin_ratio: float, leverage: float = LEVERAGE) -> float:
    exit_fee = MAKER if exit_kind == "tp" else TAKER
    return (TAKER + exit_fee) * leverage * margin_ratio * 100.0


def position_margin(entry: float, stop: float, leverage: float = LEVERAGE) -> tuple[bool, float, float]:
    if entry <= 0:
        return False, 0.0, 0.0
    full_risk = abs(entry - stop) / entry * 100.0 * leverage
    if full_risk <= 0:
        return False, 0.0, 0.0
    ratio = min(1.0, MAX_RISK / full_risk)
    return True, ratio, full_risk * ratio


def active_leg_return(side: str, entry: float, exit_price: float, margin_ratio: float) -> float:
    move = (exit_price - entry) / entry if side == "buy" else (entry - exit_price) / entry
    return move * 100.0 * LEVERAGE * margin_ratio


def active_signal(
    strategy: dict[str, Any],
    candles: list[Candle],
    i: int,
    cache: dict[str, Any],
) -> dict[str, Any] | None:
    sid = strategy["strategy_id"]
    p = {k: float(v) if hasattr(v, "as_tuple") else v for k, v in strategy.items()}
    c = candles[i]
    if sid in {"btc-15m-vacuum-pulse", "eth-15m-vacuum-pulse"}:
        if not (int(p["weekday_mask"]) & (1 << datetime.fromtimestamp(c.open_time, timezone.utc).weekday())):
            return None
        slow = int(p["slow_mean_period"])
        fast = int(p["fast_mean_period"])
        atr_period = int(p["atr_period"])
        vol_period = int(p["volume_lookback"])
        reclaim = int(p["reclaim_lookback"])
        ret_lookback = int(p["return_lookback"])
        if i + 1 < slow or i < reclaim or i < ret_lookback:
            return None
        fast_mean = cache[f"sma_{fast}"][i]
        slow_mean = cache[f"sma_{slow}"][i]
        atr = cache[f"atr_{atr_period}"][i]
        avg_vol = cache[f"vol_{vol_period}"][i]
        if fast_mean is None or slow_mean is None or atr is None or avg_vol is None:
            return None
        base = candles[i - ret_lookback]
        rng = c.high - c.low
        if c.close <= 0 or base.close <= 0 or rng <= 0 or atr <= 0 or avg_vol <= 0:
            return None
        if c.volume < avg_vol * p["volume_multiplier"]:
            return None
        trend_spread = abs(fast_mean - slow_mean) / c.close
        atr_pct = atr / c.close
        if not (p["minimum_trend_spread"] <= trend_spread <= p["maximum_trend_spread"]):
            return None
        if not (p["minimum_atr_percent"] <= atr_pct <= p["maximum_atr_percent"]):
            return None
        close_loc = (c.close - c.low) / rng
        ret = (c.close - base.close) / base.close
        prev_high = max(x.high for x in candles[i - reclaim:i])
        prev_low = min(x.low for x in candles[i - reclaim:i])
        allows_long = int(p["side_mode"]) >= 0
        allows_short = int(p["side_mode"]) <= 0
        side = None
        stop = 0.0
        if (
            allows_long and fast_mean > slow_mean and ret >= p["return_threshold"]
            and c.low <= fast_mean + atr * p["pullback_atr_buffer"]
            and c.close > fast_mean and c.close > prev_high + atr * p["breakout_atr_buffer"]
            and c.close > c.open and close_loc >= p["minimum_close_location"]
        ):
            side = "buy"
            if int(p["stop_mode"]) == 1:
                stop = c.low - atr * p["stop_atr_buffer"]
            elif int(p["stop_mode"]) == 2:
                stop = c.close - atr * p["stop_atr_buffer"]
            else:
                stop = min(c.low, fast_mean - atr * p["stop_atr_buffer"])
        elif (
            allows_short and fast_mean < slow_mean and ret <= -p["return_threshold"]
            and c.high >= fast_mean - atr * p["pullback_atr_buffer"]
            and c.close < fast_mean and c.close < prev_low - atr * p["breakout_atr_buffer"]
            and c.close < c.open and close_loc <= 1.0 - p["minimum_close_location"]
        ):
            side = "sell"
            if int(p["stop_mode"]) == 1:
                stop = c.high + atr * p["stop_atr_buffer"]
            elif int(p["stop_mode"]) == 2:
                stop = c.close + atr * p["stop_atr_buffer"]
            else:
                stop = max(c.high, fast_mean + atr * p["stop_atr_buffer"])
        if side is None:
            return None
        risk = abs(c.close - stop)
        stop_pct = risk / c.close
        if risk <= 0 or not (p["minimum_stop_percent"] <= stop_pct <= p["maximum_stop_percent"]):
            return None
        take = c.close + risk * p["reward_risk_ratio"] if side == "buy" else c.close - risk * p["reward_risk_ratio"]
        return {"side": side, "entry": c.close, "stop": stop, "take": take, "max_hold": int(p.get("maximum_holding_candles") or 0) or None}

    if sid == "btc-15m-regime-session-fade":
        lookback = int(p["lookback"])
        if i <= lookback:
            return None
        trend = cache[f"ema_{int(p['trend_ema_period'])}"][i]
        atr = cache[f"atr_{int(p['atr_period'])}"][i]
        macro = cache[sid][i]
        if trend is None or atr is None or c.close <= 0:
            return None
        week_hour = datetime.fromtimestamp(c.open_time, timezone.utc).weekday() * 24 + datetime.fromtimestamp(c.open_time, timezone.utc).hour
        allowed = paper_runner.BTC_REGIME_BULL_HOURS if macro["regime"] == 1 else paper_runner.BTC_REGIME_BEAR_HOURS if macro["regime"] == -1 else paper_runner.BTC_REGIME_NEUTRAL_HOURS
        if week_hour not in allowed:
            return None
        drawdown = macro["drawdown"]
        if drawdown is not None and drawdown >= p["near_high_drawdown_threshold"] and atr / c.close <= p["low_atr_percent_threshold"]:
            return None
        ret = c.close / candles[i - lookback].close - 1.0
        if abs(ret) < p["threshold"]:
            return None
        side = "sell" if ret > 0 else "buy"
        if side != ("buy" if c.close >= trend else "sell"):
            return None
        stop = c.close * (1.0 - p["stop_percent"]) if side == "buy" else c.close * (1.0 + p["stop_percent"])
        risk = abs(c.close - stop)
        take = c.close + risk * p["reward_risk_ratio"] if side == "buy" else c.close - risk * p["reward_risk_ratio"]
        return {"side": side, "entry": c.close, "stop": stop, "take": take, "max_hold": int(p["maximum_holding_candles"])}

    if sid == "btc-15m-bull-pullback-long":
        lookback = int(p["lookback"])
        if i <= lookback:
            return None
        trend = cache[f"ema_{int(p['trend_ema_period'])}"][i]
        macro = cache[sid][i]
        if trend is None or c.close <= 0 or macro["regime"] != 1:
            return None
        week_hour = datetime.fromtimestamp(c.open_time, timezone.utc).weekday() * 24 + datetime.fromtimestamp(c.open_time, timezone.utc).hour
        if week_hour not in paper_runner.BTC_BULL_PULLBACK_HOURS or c.close < trend:
            return None
        ret = c.close / candles[i - lookback].close - 1.0
        if ret > -p["threshold"]:
            return None
        rr = p["loose_reward_risk_ratio"] if macro["drawdown"] is not None and macro["drawdown"] <= p["loose_drawdown_threshold"] else p["tight_reward_risk_ratio"]
        stop = c.close * (1.0 - p["stop_percent"])
        take = c.close + (c.close - stop) * rr
        return {"side": "buy", "entry": c.close, "stop": stop, "take": take, "max_hold": int(p["maximum_holding_candles"])}

    return None


def build_macro(candles: list[Candle], p: dict[str, Any], bear_return: float, bear_dd: float) -> list[dict[str, float | int | None]]:
    days: list[tuple[int, float]] = []
    day_index_by_candle: list[int] = []
    for c in candles:
        day = int(c.open_time // 86400)
        if days and days[-1][0] == day:
            days[-1] = (day, c.close)
        else:
            days.append((day, c.close))
        day_index_by_candle.append(len(days) - 1)
    closes = [x[1] for x in days]
    prefix: list[float] = []
    total = 0.0
    highs: list[float] = []
    high = 0.0
    for close in closes:
        total += close
        prefix.append(total)
        high = max(high, close)
        highs.append(high)
    def sma(end: int, period: int) -> float | None:
        if end < 0 or end - period + 1 < 0:
            return None
        prev = prefix[end - period] if end - period >= 0 else 0.0
        return (prefix[end] - prev) / period
    daily: list[dict[str, float | int | None]] = []
    ma = int(p["macro_ma_period"])
    slope_days = int(p["macro_slope_days"])
    return_days = int(p["macro_return_days"])
    for di in range(len(days)):
        prev = di - 1
        if prev <= 0:
            daily.append({"regime": 0, "drawdown": None})
            continue
        prev_close = closes[prev]
        drawdown = prev_close / highs[prev] - 1.0 if highs[prev] > 0 else 0.0
        prev_ma = sma(prev, ma)
        prior_ma = sma(prev - slope_days, ma)
        if prev_ma is None or prior_ma is None or prev - return_days < 0 or prior_ma <= 0 or prev_ma <= 0 or closes[prev - return_days] <= 0:
            daily.append({"regime": 0, "drawdown": drawdown})
            continue
        slope = prev_ma / prior_ma - 1.0
        period_ret = prev_close / closes[prev - return_days] - 1.0
        if prev_close >= prev_ma and slope > 0 and period_ret >= float(p["bull_return_threshold"]):
            regime = 1
        elif prev_close <= prev_ma and (slope < 0 or period_ret <= bear_return or drawdown <= -bear_dd):
            regime = -1
        else:
            regime = 0
        daily.append({"regime": regime, "drawdown": drawdown})
    return [daily[idx] for idx in day_index_by_candle]


def build_active_cache(candles: list[Candle], strategies: list[dict[str, Any]]) -> dict[str, Any]:
    closes = [c.close for c in candles]
    volumes = [c.volume for c in candles]
    cache: dict[str, Any] = {}
    for p in strategies:
        for key in ("fast_mean_period", "slow_mean_period"):
            if key in p:
                period = int(p[key])
                cache.setdefault(f"sma_{period}", rolling_sma(closes, period))
        if "volume_lookback" in p:
            period = int(p["volume_lookback"])
            cache.setdefault(f"vol_{period}", rolling_sma(volumes, period))
        if "atr_period" in p:
            period = int(p["atr_period"])
            cache.setdefault(f"atr_{period}", rolling_atr(candles, period))
        if "trend_ema_period" in p:
            period = int(p["trend_ema_period"])
            cache.setdefault(f"ema_{period}", ema(closes, period))
        if p["strategy_id"] == "btc-15m-regime-session-fade":
            cache[p["strategy_id"]] = build_macro(candles, p, float(p["bear_return_threshold"]), float(p["bear_drawdown_threshold"]))
        if p["strategy_id"] == "btc-15m-bull-pullback-long":
            cache[p["strategy_id"]] = build_macro(candles, p, -0.03, 0.25)
    return cache


def run_active_strategy(strategy: dict[str, Any], candles: list[Candle], cache: dict[str, Any]) -> dict[str, Any]:
    balance = INITIAL
    peak = INITIAL
    max_dd = 0.0
    trades: list[dict[str, Any]] = []
    equity = [{"time": utc_text(candles[0].open_time), "equity": balance}]
    i = 0
    while i < len(candles):
        sig = active_signal(strategy, candles, i, cache)
        if sig is None:
            i += 1
            continue
        rr = abs(sig["take"] - sig["entry"]) / abs(sig["entry"] - sig["stop"]) if abs(sig["entry"] - sig["stop"]) > 0 else 0
        ok, margin, risk_pct = position_margin(sig["entry"], sig["stop"])
        scaled_reward = abs((sig["entry"] + sig["take"]) / 2 - sig["entry"]) * 0.5 + abs(sig["take"] - sig["entry"]) * 0.5
        if not ok or rr < 2 or scaled_reward / sig["entry"] * 100 * LEVERAGE * margin <= fee_percent("tp", margin):
            i += 1
            continue
        tp1 = (sig["entry"] + sig["take"]) / 2.0
        lock = sig["entry"] + (sig["take"] - sig["entry"]) * 0.25
        did_tp1 = False
        exit_index = None
        ret_pct = 0.0
        reason = ""
        for j in range(i + 1, len(candles)):
            c = candles[j]
            active_stop = lock if did_tp1 else sig["stop"]
            if sig["side"] == "buy":
                hit_stop = c.low <= active_stop
                hit_tp1 = c.high >= tp1
                hit_tp2 = c.high >= sig["take"]
            else:
                hit_stop = c.high >= active_stop
                hit_tp1 = c.low <= tp1
                hit_tp2 = c.low <= sig["take"]
            if hit_stop:
                if did_tp1:
                    ret_pct = active_leg_return(sig["side"], sig["entry"], tp1, margin * 0.5) - fee_percent("tp", margin * 0.5) + active_leg_return(sig["side"], sig["entry"], lock, margin * 0.5) - fee_percent("sl", margin * 0.5)
                    reason = "profit_lock_stop"
                else:
                    ret_pct = active_leg_return(sig["side"], sig["entry"], sig["stop"], margin) - fee_percent("sl", margin)
                    reason = "pure_stop"
                exit_index = j
                break
            if hit_tp2:
                ret_pct = active_leg_return(sig["side"], sig["entry"], tp1, margin * 0.5) - fee_percent("tp", margin * 0.5) + active_leg_return(sig["side"], sig["entry"], sig["take"], margin * 0.5) - fee_percent("tp", margin * 0.5)
                reason = "tp2"
                exit_index = j
                break
            if hit_tp1:
                did_tp1 = True
            if sig["max_hold"] and j - (i + 1) + 1 >= sig["max_hold"]:
                ret_pct = 0.0
                if did_tp1:
                    ret_pct += active_leg_return(sig["side"], sig["entry"], tp1, margin * 0.5) - fee_percent("tp", margin * 0.5)
                    ret_pct += active_leg_return(sig["side"], sig["entry"], c.close, margin * 0.5) - fee_percent("sl", margin * 0.5)
                    reason = "time_exit_after_tp1"
                else:
                    ret_pct = active_leg_return(sig["side"], sig["entry"], c.close, margin) - fee_percent("sl", margin)
                    reason = "time_exit"
                exit_index = j
                break
        if exit_index is None:
            break
        start_balance = balance
        balance *= 1.0 + ret_pct / 100.0
        peak = max(peak, balance)
        max_dd = max(max_dd, (peak - balance) / peak * 100.0 if peak > 0 else 0.0)
        trades.append({"pnl": balance - start_balance, "return_pct": ret_pct, "reason": reason})
        equity.append({"time": utc_text(candles[exit_index].open_time), "equity": balance})
        i = max(exit_index + 1, i + 1)
    return summarize(strategy["strategy_id"], strategy["name"], strategy["symbol"], candles, trades, equity, balance, max_dd)


def run_dynamic_top1(candles: list[Candle]) -> dict[str, Any]:
    close = [c.close for c in candles]
    high = [c.high for c in candles]
    low = [c.low for c in candles]
    ret = [0.0] + [close[i] / close[i - 1] - 1.0 if close[i - 1] > 0 else 0.0 for i in range(1, len(candles))]
    tr = [high[0] - low[0]]
    for i in range(1, len(candles)):
        tr.append(max(high[i] - low[i], abs(high[i] - close[i - 1]), abs(low[i] - close[i - 1])))
    atr = ewm(tr, 1.0 / 10.0, 10)
    upper = previous_extreme(high, 3, "max")
    lower = previous_extreme(low, 3, "min")
    raw_long = [upper[i] is not None and close[i] > upper[i] for i in range(len(candles))]
    raw_short = [lower[i] is not None and close[i] < lower[i] for i in range(len(candles))]
    long_break = rolling_all(raw_long, 5)
    short_break = rolling_all(raw_short, 4)
    vol = rolling_std(ret, 40)
    vol_q = rolling_quantile(vol, 800, 250, 0.05)
    h1 = h1_indicators(candles)
    balance = 10000.0
    peak = balance
    max_dd = 0.0
    trades: list[dict[str, Any]] = []
    equity = [{"time": utc_text(candles[0].open_time), "equity": balance}]
    position: dict[str, Any] | None = None
    for i, c in enumerate(candles):
        if position:
            side = position["side"]
            if side == "long":
                hit_sl = c.low <= position["stop"]
                hit_tp = c.high >= position["take"]
                if not (hit_sl or hit_tp):
                    continue
                exit_raw = position["stop"] if hit_sl else position["take"]
                exit_fill = exit_raw * (1.0 - 0.0003)
                pnl_pct = (exit_fill - position["entry_fill"]) / position["entry_fill"]
                reason = "stop_loss" if hit_sl else "take_profit"
            else:
                hit_sl = c.high >= position["stop"]
                hit_tp = c.low <= position["take"]
                if not (hit_sl or hit_tp):
                    continue
                exit_raw = position["stop"] if hit_sl else position["take"]
                exit_fill = exit_raw * (1.0 + 0.0003)
                pnl_pct = (position["entry_fill"] - exit_fill) / position["entry_fill"]
                reason = "stop_loss" if hit_sl else "take_profit"
            gross = position["notional"] * pnl_pct
            exit_fee = position["notional"] * 0.0005
            net = gross - position["entry_fee"] - exit_fee
            before = balance
            balance += net
            peak = max(peak, balance)
            max_dd = max(max_dd, (peak - balance) / peak * 100.0)
            trades.append({"pnl": net, "return_pct": net / before * 100.0, "reason": reason, "side": side})
            equity.append({"time": utc_text(c.open_time), "equity": balance})
            position = None
            continue
        if atr[i] is None or atr[i] <= 0 or close[i] <= 0:
            continue
        h = h1_for_open(h1, c.open_time)
        ema20, ema50, ema100 = h["ema20"], h["ema50"], h["ema100"]
        long_ok = long_break[i] and vol[i] is not None and vol_q[i] is not None and vol[i] >= vol_q[i]
        short_ok = short_break[i] and ema20 is not None and ema50 is not None and ema100 is not None and ema20 < ema50 < ema100
        if long_ok == short_ok:
            continue
        natr = atr[i] / close[i]
        margin = clip(0.004 / natr, 0.5, 1.0)
        if long_ok:
            strength = clip(((ema20 - ema100) / ema100) * 100.0 / 5.0, 0.0, 1.0) if ema20 and ema100 and ema100 > 0 else 0.0
            base = clip(0.005 / natr, 0.2, 4.0) ** 0.60
            scaled = (clip(base, 0.5, 1.75) - 0.5) / 1.25
            lev = clip((1.25 + (3.25 - 1.25) * scaled) * (1.0 + strength * 0.15 * 0.20), 1.25, 3.25)
            entry = c.close * (1.0 + 0.0003)
            stop = entry * (1.0 - 0.01)
            take = entry * (1.0 + 0.035)
            side = "long"
        else:
            strength = clip(((ema100 - ema20) / ema100) * 100.0 / 5.0, 0.0, 1.0) if ema20 and ema100 and ema100 > 0 else 0.0
            base = clip(0.005 / natr, 0.2, 4.0) ** 1.10
            scaled = (clip(base, 0.5, 1.75) - 0.5) / 1.25
            lev = clip((1.0 + (2.0 - 1.0) * scaled) * (1.0 + strength * 0.25 * 0.20), 1.0, 2.0)
            entry = c.close * (1.0 - 0.0003)
            stop = entry * (1.0 + 0.015)
            take = entry * (1.0 - 0.02)
            side = "short"
        notional = balance * margin * lev
        position = {"side": side, "entry_fill": entry, "stop": stop, "take": take, "notional": notional, "entry_fee": notional * 0.0005}
    return summarize("dynamic-top1-conservative-v2", "Dynamic Top1 Conservative v2", "BTCUSDT", candles, trades, equity, balance, max_dd, initial=10000.0)


def summarize(strategy_id: str, name: str, symbol: str, candles: list[Candle], trades: list[dict[str, Any]], equity: list[dict[str, Any]], balance: float, max_dd: float, initial: float = INITIAL) -> dict[str, Any]:
    gross_profit = sum(t["pnl"] for t in trades if t["pnl"] > 0)
    gross_loss = sum(t["pnl"] for t in trades if t["pnl"] < 0)
    wins = sum(1 for t in trades if t["pnl"] > 0)
    return {
        "strategy_id": strategy_id,
        "strategy_name": name,
        "symbol": symbol,
        "first_candle": utc_text(candles[0].open_time),
        "last_candle": utc_text(candles[-1].open_time),
        "initial_capital": initial,
        "final_balance": balance,
        "net_return_percent": (balance / initial - 1.0) * 100.0,
        "max_drawdown_percent": max_dd,
        "profit_factor": gross_profit / abs(gross_loss) if gross_loss < 0 else None,
        "win_rate_percent": wins / len(trades) * 100.0 if trades else 0.0,
        "trade_count": len(trades),
        "tp2_or_take_profit_count": sum(1 for t in trades if t["reason"] in {"tp2", "take_profit"}),
        "pure_stop_count": sum(1 for t in trades if t["reason"] in {"pure_stop", "stop_loss"}),
        "profit_lock_stop_count": sum(1 for t in trades if t["reason"] == "profit_lock_stop"),
        "time_exit_count": sum(1 for t in trades if "time_exit" in t["reason"]),
        "equity_curve": equity,
    }


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    keys = [k for k in rows[0].keys() if k != "equity_curve"]
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=keys)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key) for key in keys})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=str(Path.home() / "Library/Application Support/BucksCopy/BucksCopy.sqlite"))
    parser.add_argument("--start", default="2022-05-24T03:00:00Z")
    parser.add_argument("--end", default="2026-05-24T03:00:00Z")
    parser.add_argument("--output-prefix", default="Derived/Reports/recent4y-strategy-comparison")
    args = parser.parse_args()
    db = Path(args.db).expanduser()
    start = parse_time(args.start)
    end = parse_time(args.end)
    btc = load_candles(db, "BTCUSDT", start, end)
    eth = load_candles(db, "ETHUSDT", start, end)
    strategies = [
        dict(paper_runner.BTC_PULSE_PARAMS),
        dict(paper_runner.BTC_REGIME_SESSION_FADE_PARAMS),
        dict(paper_runner.BTC_BULL_PULLBACK_LONG_PARAMS),
        dict(paper_runner.ETH_PULSE_PARAMS),
    ]
    btc_strategies = [s for s in strategies if s["symbol"] == "BTCUSDT"]
    eth_strategies = [s for s in strategies if s["symbol"] == "ETHUSDT"]
    btc_cache = build_active_cache(btc, btc_strategies)
    eth_cache = build_active_cache(eth, eth_strategies)
    results = [
        run_dynamic_top1(btc),
        *(run_active_strategy(s, btc, btc_cache) for s in btc_strategies),
        *(run_active_strategy(s, eth, eth_cache) for s in eth_strategies),
    ]
    prefix = Path(args.output_prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    summary_json = prefix.with_name(prefix.name + "-summary.json")
    summary_csv = prefix.with_name(prefix.name + "-summary.csv")
    equity_csv = prefix.with_name(prefix.name + "-equity.csv")
    summary_json.write_text(json.dumps([{k: v for k, v in row.items() if k != "equity_curve"} for row in results], ensure_ascii=False, indent=2), encoding="utf-8")
    write_csv(summary_csv, results)
    equity_rows = []
    for row in results:
        for point in row["equity_curve"]:
            equity_rows.append({
                "strategy_id": row["strategy_id"],
                "strategy_name": row["strategy_name"],
                "time": point["time"],
                "equity": point["equity"],
            })
    write_csv(equity_csv, equity_rows)
    print(json.dumps([{k: v for k, v in row.items() if k != "equity_curve"} for row in results], ensure_ascii=False, indent=2))
    print(f"summary={summary_json}")
    print(f"summary_csv={summary_csv}")
    print(f"equity_csv={equity_csv}")


if __name__ == "__main__":
    main()
