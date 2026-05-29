#!/usr/bin/env python3
import argparse
import math
import random
import sqlite3
import time
from collections import deque
from datetime import datetime, timezone


TAKER_FEE = 0.0006 * 0.8
MAKER_FEE = 0.0002 * 0.8
LEVERAGE = 10
MAX_RISK_PERCENT = 5.0
MAX_MARGIN_RATIO = 1.0
INITIAL_BALANCE = 100.0


def load_candles(db_path, symbol, timeframe, limit):
    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute(
            """
            SELECT open_time, open, high, low, close, volume
            FROM (
                SELECT open_time, open, high, low, close, volume
                FROM candles
                WHERE product_type = 'USDT-FUTURES'
                  AND symbol = ?
                  AND timeframe = ?
                  AND is_closed = 1
                ORDER BY open_time DESC
                LIMIT ?
            )
            ORDER BY open_time ASC
            """,
            (symbol, timeframe, limit),
        ).fetchall()
    finally:
        conn.close()
    if not rows:
        raise RuntimeError(f"No candles for {symbol} {timeframe}")
    return {
        "time": [float(r[0]) for r in rows],
        "open": [float(r[1]) for r in rows],
        "high": [float(r[2]) for r in rows],
        "low": [float(r[3]) for r in rows],
        "close": [float(r[4]) for r in rows],
        "volume": [float(r[5]) for r in rows],
    }


def rolling_mean(values, period):
    out = [None] * len(values)
    total = 0.0
    q = deque()
    for i, value in enumerate(values):
        total += value
        q.append(value)
        if len(q) > period:
            total -= q.popleft()
        if len(q) == period:
            out[i] = total / period
    return out


def rolling_max_prev(values, period):
    out = [None] * len(values)
    q = deque()
    for i, value in enumerate(values):
        if i > 0:
            prev_index = i - 1
            prev_value = values[prev_index]
            while q and q[-1][1] <= prev_value:
                q.pop()
            q.append((prev_index, prev_value))
        while q and q[0][0] < i - period:
            q.popleft()
        if i >= period and q:
            out[i] = q[0][1]
    return out


def rolling_min_prev(values, period):
    out = [None] * len(values)
    q = deque()
    for i, value in enumerate(values):
        if i > 0:
            prev_index = i - 1
            prev_value = values[prev_index]
            while q and q[-1][1] >= prev_value:
                q.pop()
            q.append((prev_index, prev_value))
        while q and q[0][0] < i - period:
            q.popleft()
        if i >= period and q:
            out[i] = q[0][1]
    return out


def rolling_std(values, period):
    out = [None] * len(values)
    total = 0.0
    total_sq = 0.0
    q = deque()
    for i, value in enumerate(values):
        total += value
        total_sq += value * value
        q.append(value)
        if len(q) > period:
            old = q.popleft()
            total -= old
            total_sq -= old * old
        if len(q) == period:
            mean = total / period
            variance = max(total_sq / period - mean * mean, 0.0)
            out[i] = math.sqrt(variance)
    return out


def average_true_range(high, low, close, period):
    tr = [0.0] * len(close)
    for i in range(1, len(close)):
        tr[i] = max(
            high[i] - low[i],
            abs(high[i] - close[i - 1]),
            abs(low[i] - close[i - 1]),
        )
    return rolling_mean(tr, period)


class IndicatorCache:
    def __init__(self, candles):
        self.c = candles
        self.sma_cache = {}
        self.vol_cache = {}
        self.atr_cache = {}
        self.high_cache = {}
        self.low_cache = {}
        self.std_cache = {}
        self.hour_cache = None
        self.weekday_cache = None

    def sma(self, period):
        if period not in self.sma_cache:
            self.sma_cache[period] = rolling_mean(self.c["close"], period)
        return self.sma_cache[period]

    def avg_volume(self, period):
        if period not in self.vol_cache:
            self.vol_cache[period] = rolling_mean(self.c["volume"], period)
        return self.vol_cache[period]

    def atr(self, period):
        if period not in self.atr_cache:
            self.atr_cache[period] = average_true_range(
                self.c["high"], self.c["low"], self.c["close"], period
            )
        return self.atr_cache[period]

    def prev_high(self, period):
        if period not in self.high_cache:
            self.high_cache[period] = rolling_max_prev(self.c["high"], period)
        return self.high_cache[period]

    def prev_low(self, period):
        if period not in self.low_cache:
            self.low_cache[period] = rolling_min_prev(self.c["low"], period)
        return self.low_cache[period]

    def std(self, period):
        if period not in self.std_cache:
            self.std_cache[period] = rolling_std(self.c["close"], period)
        return self.std_cache[period]

    def hours(self):
        if self.hour_cache is None:
            self.hour_cache = [
                datetime.fromtimestamp(value, tz=timezone.utc).hour
                for value in self.c["time"]
            ]
        return self.hour_cache

    def weekdays(self):
        if self.weekday_cache is None:
            self.weekday_cache = [
                datetime.fromtimestamp(value, tz=timezone.utc).weekday()
                for value in self.c["time"]
            ]
        return self.weekday_cache


def fee_percent(exit_execution, margin_ratio):
    exit_fee = MAKER_FEE if exit_execution == "tp" else TAKER_FEE
    return (TAKER_FEE + exit_fee) * LEVERAGE * margin_ratio * 100.0


def leg_return(side, entry, exit_price, margin_ratio):
    if side == "long":
        gross = (exit_price - entry) / entry * 100.0 * LEVERAGE * margin_ratio
    else:
        gross = (entry - exit_price) / entry * 100.0 * LEVERAGE * margin_ratio
    return gross


def hour_mask(start, length):
    mask = 0
    for offset in range(length):
        mask |= 1 << ((start + offset) % 24)
    return mask


def two_window_hour_mask(first_start, first_length, second_start, second_length):
    return hour_mask(first_start, first_length) | hour_mask(second_start, second_length)


def session_allowed(p, hour, weekday):
    if p.get("hour_mask", (1 << 24) - 1) & (1 << hour) == 0:
        return False
    return p.get("weekday_mask", (1 << 7) - 1) & (1 << weekday) != 0


def side_allowed(p, side):
    mode = p.get("side_mode", 0)
    if side == "long":
        return mode >= 0
    return mode <= 0


def target_prices(side, entry, stop, rr):
    if side == "long":
        risk = entry - stop
        return risk, entry + risk * rr
    risk = stop - entry
    return risk, entry - risk * rr


def simulate(candles, indicators, p):
    o = candles["open"]
    h = candles["high"]
    l = candles["low"]
    c = candles["close"]
    v = candles["volume"]
    t = candles["time"]
    n = len(c)
    fast = indicators.sma(p["fast"])
    slow = indicators.sma(p["slow"])
    atr = indicators.atr(p["atr"])
    av = indicators.avg_volume(p["vol_lookback"])
    ph = indicators.prev_high(p["channel"])
    pl = indicators.prev_low(p["channel"])
    hour_values = indicators.hours()
    weekday_values = indicators.weekdays()
    basis = indicators.sma(p.get("basis", p["slow"]))
    deviation = indicators.std(p.get("basis", p["slow"]))
    balance = INITIAL_BALANCE
    peak = balance
    max_dd = 0.0
    wins = 0
    losses = 0
    tp1 = 0
    tp2 = 0
    tp1_sl = 0
    pure_sl = 0
    i = max(
        p["slow"],
        p["vol_lookback"],
        p["atr"],
        p["channel"],
        p["ret_lookback"],
        p.get("basis", p["slow"]),
    ) + 1
    first_trade_time = None
    last_trade_time = None
    while i < n - 1:
        if not session_allowed(p, hour_values[i], weekday_values[i]):
            i += 1
            continue
        if not fast[i] or not slow[i] or not atr[i] or not av[i] or not ph[i] or not pl[i]:
            i += 1
            continue
        entry = c[i]
        if entry <= 0 or atr[i] <= 0 or av[i] <= 0:
            i += 1
            continue
        atr_pct = atr[i] / entry
        if atr_pct < p["min_atr_pct"] or atr_pct > p["max_atr_pct"]:
            i += 1
            continue
        if v[i] < av[i] * p["vol_mult"]:
            i += 1
            continue
        rng = h[i] - l[i]
        if rng <= 0:
            i += 1
            continue
        loc = (c[i] - l[i]) / rng
        ret = c[i] / c[i - p["ret_lookback"]] - 1.0
        trend_spread = abs(fast[i] - slow[i]) / entry
        if trend_spread < p["min_spread"] or trend_spread > p["max_spread"]:
            i += 1
            continue
        side = None
        setup = p.get("setup", "momentum")
        if setup == "momentum":
            if (
                side_allowed(p, "long")
                and fast[i] > slow[i]
                and ret > p["ret_threshold"]
                and c[i] > o[i]
                and loc >= p["close_loc"]
                and (c[i] > ph[i] + atr[i] * p["breakout_atr"] or c[i] > h[i - 1])
            ):
                side = "long"
                stop = min(l[i], entry - atr[i] * p["stop_atr"])
            elif (
                side_allowed(p, "short")
                and fast[i] < slow[i]
                and ret < -p["ret_threshold"]
                and c[i] < o[i]
                and loc <= 1.0 - p["close_loc"]
                and (c[i] < pl[i] - atr[i] * p["breakout_atr"] or c[i] < l[i - 1])
            ):
                side = "short"
                stop = max(h[i], entry + atr[i] * p["stop_atr"])
        elif setup == "reclaim":
            pullback_long = l[i] <= fast[i] + atr[i] * p["pullback_atr"]
            pullback_short = h[i] >= fast[i] - atr[i] * p["pullback_atr"]
            if (
                side_allowed(p, "long")
                and fast[i] > slow[i]
                and ret >= p["ret_threshold"]
                and pullback_long
                and c[i] > fast[i]
                and c[i] > ph[i] + atr[i] * p["breakout_atr"]
                and c[i] > o[i]
                and loc >= p["close_loc"]
            ):
                side = "long"
                if p["stop_mode"] == "mean":
                    stop = min(l[i], fast[i] - atr[i] * p["stop_atr"])
                elif p["stop_mode"] == "candle":
                    stop = l[i] - atr[i] * p["stop_atr"]
                else:
                    stop = entry - atr[i] * p["stop_atr"]
            elif (
                side_allowed(p, "short")
                and fast[i] < slow[i]
                and ret <= -p["ret_threshold"]
                and pullback_short
                and c[i] < fast[i]
                and c[i] < pl[i] - atr[i] * p["breakout_atr"]
                and c[i] < o[i]
                and loc <= 1.0 - p["close_loc"]
            ):
                side = "short"
                if p["stop_mode"] == "mean":
                    stop = max(h[i], fast[i] + atr[i] * p["stop_atr"])
                elif p["stop_mode"] == "candle":
                    stop = h[i] + atr[i] * p["stop_atr"]
                else:
                    stop = entry + atr[i] * p["stop_atr"]
        elif setup == "band_reclaim" and basis[i] and deviation[i] and deviation[i] > 0:
            z = (c[i] - basis[i]) / deviation[i]
            if (
                side_allowed(p, "long")
                and z <= -p["z_threshold"]
                and loc >= p["close_loc"]
                and c[i] > o[i]
                and c[i] > l[i] + atr[i] * p["reclaim_atr"]
                and (fast[i] >= slow[i] or trend_spread <= p["counter_max_spread"])
            ):
                side = "long"
                stop = l[i] - atr[i] * p["stop_atr"]
            elif (
                side_allowed(p, "short")
                and z >= p["z_threshold"]
                and loc <= 1.0 - p["close_loc"]
                and c[i] < o[i]
                and c[i] < h[i] - atr[i] * p["reclaim_atr"]
                and (fast[i] <= slow[i] or trend_spread <= p["counter_max_spread"])
            ):
                side = "short"
                stop = h[i] + atr[i] * p["stop_atr"]
        if side is None or p["rr"] < 2.0:
            i += 1
            continue
        risk, take = target_prices(side, entry, stop, p["rr"])
        if risk <= 0 or p["rr"] < 2.0:
            i += 1
            continue
        stop_pct = risk / entry
        if stop_pct < p.get("min_stop_pct", 0.0) or stop_pct > p.get("max_stop_pct", 1.0):
            i += 1
            continue
        full_margin_risk = risk / entry * 100.0 * LEVERAGE
        if full_margin_risk <= 0:
            i += 1
            continue
        margin_ratio = min(MAX_MARGIN_RATIO, MAX_RISK_PERCENT / full_margin_risk)
        blended_reward = risk * p["rr"] * 0.75 / entry * 100.0 * LEVERAGE * margin_ratio
        if blended_reward <= fee_percent("tp", margin_ratio):
            i += 1
            continue
        partial = (entry + take) / 2.0
        lock_stop = entry + (take - entry) * 0.25
        did_tp1 = False
        exit_index = None
        ret_pct = None
        for j in range(i + 1, n):
            active_stop = lock_stop if did_tp1 else stop
            if side == "long":
                hit_stop = l[j] <= active_stop
                hit_partial = h[j] >= partial
                hit_final = h[j] >= take
            else:
                hit_stop = h[j] >= active_stop
                hit_partial = l[j] <= partial
                hit_final = l[j] <= take
            if hit_stop:
                if did_tp1:
                    ret_pct = (
                        leg_return(side, entry, partial, margin_ratio * 0.5)
                        - fee_percent("tp", margin_ratio * 0.5)
                        + leg_return(side, entry, lock_stop, margin_ratio * 0.5)
                        - fee_percent("sl", margin_ratio * 0.5)
                    )
                    tp1 += 1
                    tp1_sl += 1
                else:
                    ret_pct = leg_return(side, entry, stop, margin_ratio) - fee_percent("sl", margin_ratio)
                    pure_sl += 1
                exit_index = j
                break
            if hit_final:
                ret_pct = (
                    leg_return(side, entry, partial, margin_ratio * 0.5)
                    - fee_percent("tp", margin_ratio * 0.5)
                    + leg_return(side, entry, take, margin_ratio * 0.5)
                    - fee_percent("tp", margin_ratio * 0.5)
                )
                tp1 += 1
                tp2 += 1
                exit_index = j
                break
            if hit_partial:
                did_tp1 = True
        if exit_index is None:
            break
        balance *= 1.0 + ret_pct / 100.0
        if ret_pct > 0:
            wins += 1
        else:
            losses += 1
        peak = max(peak, balance)
        if peak > 0:
            max_dd = max(max_dd, (peak - balance) / peak * 100.0)
        first_trade_time = first_trade_time or t[i]
        last_trade_time = t[exit_index]
        i = max(exit_index + 1, i + 1)
    total = wins + losses
    years = (t[-1] - t[0]) / (365.25 * 24 * 60 * 60)
    cagr = (balance / INITIAL_BALANCE) ** (1.0 / years) - 1.0 if balance > 0 and years > 0 else -1.0
    return {
        "final": balance,
        "net": balance - INITIAL_BALANCE,
        "net_pct": (balance / INITIAL_BALANCE - 1.0) * 100.0,
        "cagr_pct": cagr * 100.0,
        "mdd": max_dd,
        "wins": wins,
        "losses": losses,
        "trades": total,
        "win_rate": wins / total * 100.0 if total else 0.0,
        "annual_trades": total / years if years else 0.0,
        "tp1": tp1,
        "tp2": tp2,
        "tp1_sl": tp1_sl,
        "pure_sl": pure_sl,
    }


def random_params(symbol, rng):
    if symbol == "BTCUSDT":
        fast_choices = [24, 32, 48, 64, 72, 96]
        slow_choices = [96, 144, 192, 256, 288, 384]
        threshold_choices = [0.0025, 0.0035, 0.005, 0.0075, 0.01, 0.013]
        stop_choices = [0.45, 0.6, 0.8, 1.0, 1.25, 1.5]
    else:
        fast_choices = [16, 24, 32, 48, 64, 96]
        slow_choices = [96, 144, 192, 256, 384]
        threshold_choices = [0.003, 0.0045, 0.006, 0.008, 0.011, 0.015]
        stop_choices = [0.55, 0.75, 1.0, 1.25, 1.5, 1.8]
    fast = rng.choice(fast_choices)
    slow = rng.choice([s for s in slow_choices if s > fast])
    session_choice = rng.choices(
        ["all", "single", "double", "week"],
        weights=[7, 1, 1, 1],
        k=1,
    )[0]
    if session_choice == "single":
        hours = hour_mask(rng.randrange(24), rng.choice([6, 8, 10, 12, 14, 16]))
    elif session_choice == "double":
        hours = two_window_hour_mask(
            rng.randrange(24),
            rng.choice([3, 4, 6, 8]),
            rng.randrange(24),
            rng.choice([3, 4, 6, 8]),
        )
    else:
        hours = (1 << 24) - 1
    if session_choice == "week":
        weekday_mask = rng.choice([0b0011111, 0b1111100, 0b1111111, 0b0111110, 0b1110011])
    else:
        weekday_mask = rng.choice([0b1111111, 0b0011111, 0b1111100])

    setup = rng.choices(
        ["momentum", "reclaim", "band_reclaim"],
        weights=[2, 6, 2],
        k=1,
    )[0]
    params = {
        "setup": setup,
        "fast": fast,
        "slow": slow,
        "atr": rng.choice([10, 14, 20]),
        "vol_lookback": rng.choice([32, 48, 64, 96, 144]),
        "channel": rng.choice([2, 3, 4, 6, 8, 12, 16, 24]),
        "ret_lookback": rng.choice([2, 3, 4, 6, 8, 12, 16]),
        "ret_threshold": rng.choice([0.0, 0.0015, 0.0025] + threshold_choices),
        "min_atr_pct": rng.choice([0.0004, 0.0006, 0.0008, 0.0010, 0.0012]),
        "max_atr_pct": rng.choice([0.006, 0.008, 0.010, 0.012, 0.016, 0.022, 0.030]),
        "vol_mult": rng.choice([0.35, 0.45, 0.55, 0.7, 0.85, 1.0, 1.15, 1.35, 1.6, 2.0]),
        "close_loc": rng.choice([0.52, 0.56, 0.60, 0.64, 0.70, 0.76]),
        "stop_atr": rng.choice([0.25, 0.35] + stop_choices),
        "rr": rng.choice([2.0, 2.25, 2.5, 3.0, 3.5, 4.0, 4.8, 5.5]),
        "breakout_atr": rng.choice([-0.2, -0.1, 0.0, 0.05, 0.1, 0.2]),
        "min_spread": rng.choice([0.0, 0.0005, 0.001, 0.002]),
        "max_spread": rng.choice([0.015, 0.025, 0.04, 0.08, 0.20]),
        "pullback_atr": rng.choice([-0.1, 0.0, 0.1, 0.25, 0.5]),
        "stop_mode": rng.choice(["atr", "candle", "mean"]),
        "min_stop_pct": rng.choice([0.0004, 0.0006, 0.0008, 0.0010, 0.0015]),
        "max_stop_pct": rng.choice([0.0045, 0.006, 0.008, 0.012, 0.018, 0.040]),
        "basis": rng.choice([48, 64, 96, 144, 192, 256]),
        "z_threshold": rng.choice([1.2, 1.5, 1.8, 2.1, 2.4]),
        "reclaim_atr": rng.choice([0.1, 0.2, 0.35, 0.5]),
        "counter_max_spread": rng.choice([0.006, 0.010, 0.016, 0.025]),
        "side_mode": rng.choice([-1, 0, 0, 1]),
        "hour_mask": hours,
        "weekday_mask": weekday_mask,
    }
    return params


def score(result):
    trade_score = -abs(result["annual_trades"] - 100.0) * 2.0
    mdd_penalty = max(result["mdd"] - 40.0, 0.0) * 100.0
    cagr_bonus = min(result["cagr_pct"], 600.0)
    return cagr_bonus + trade_score - mdd_penalty + result["win_rate"] * 0.5


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default="/Users/goods99j/Library/Application Support/BucksCopy/BucksCopy.sqlite")
    parser.add_argument("--symbols", default="BTCUSDT,ETHUSDT")
    parser.add_argument("--iterations", type=int, default=1000)
    parser.add_argument("--limit", type=int, default=140160)
    parser.add_argument("--seed", type=int, default=11)
    args = parser.parse_args()

    for symbol in args.symbols.split(","):
        symbol = symbol.strip()
        candles = load_candles(args.db, symbol, "15m", args.limit)
        indicators = IndicatorCache(candles)
        rng = random.Random(args.seed + sum(ord(ch) for ch in symbol))
        best = []
        started = time.time()
        for index in range(args.iterations):
            params = random_params(symbol, rng)
            result = simulate(candles, indicators, params)
            result["score"] = score(result)
            result["params"] = params
            best.append(result)
            best.sort(key=lambda item: item["score"], reverse=True)
            del best[30:]
            if (index + 1) % 250 == 0:
                top = best[0]
                print(
                    f"{symbol} {index + 1}/{args.iterations} "
                    f"best final={top['final']:.2f} cagr={top['cagr_pct']:.1f}% "
                    f"mdd={top['mdd']:.1f}% trades/y={top['annual_trades']:.1f}"
                )
        print(f"\n== {symbol} top candidates ({time.time() - started:.1f}s) ==")
        for rank, item in enumerate(best[:15], 1):
            p = item["params"]
            print(
                f"#{rank} score={item['score']:.2f} final={item['final']:.6f} "
                f"net={item['net_pct']:.2f}% cagr={item['cagr_pct']:.2f}% "
                f"mdd={item['mdd']:.2f}% win={item['win_rate']:.2f}% "
                f"trades={item['wins']}/{item['losses']}/{item['trades']} "
                f"annual={item['annual_trades']:.2f} tp={item['tp1']}/{item['tp2']}/{item['tp1_sl']}/{item['pure_sl']} "
                f"params={p}"
            )


if __name__ == "__main__":
    main()
