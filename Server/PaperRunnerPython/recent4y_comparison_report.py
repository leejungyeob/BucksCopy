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
import paper_runner_backtest


INITIAL = 100.0


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


def run_dynamic_top1(candles: list[Candle], include_trades: bool = False) -> dict[str, Any]:
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
            trades.append({
                "entry_time": position["entry_time"],
                "exit_time": c.open_time,
                "pnl": net,
                "return_pct": net / before * 100.0,
                "reason": reason,
                "side": side,
            })
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
        position = {
            "side": side,
            "entry_time": c.open_time,
            "entry_fill": entry,
            "stop": stop,
            "take": take,
            "notional": notional,
            "entry_fee": notional * 0.0005,
        }
    return summarize(
        "dynamic-top1-conservative-v2",
        "Dynamic Top1 Conservative v2",
        "BTCUSDT",
        candles,
        trades,
        equity,
        balance,
        max_dd,
        initial=10000.0,
        include_trades=include_trades,
    )


def summarize(
    strategy_id: str,
    name: str,
    symbol: str,
    candles: list[Candle],
    trades: list[dict[str, Any]],
    equity: list[dict[str, Any]],
    balance: float,
    max_dd: float,
    initial: float = INITIAL,
    include_trades: bool = False,
) -> dict[str, Any]:
    gross_profit = sum(t["pnl"] for t in trades if t["pnl"] > 0)
    gross_loss = sum(t["pnl"] for t in trades if t["pnl"] < 0)
    wins = sum(1 for t in trades if t["pnl"] > 0)
    summary = {
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
    if include_trades:
        summary["trades"] = trades
    return summary


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    keys = []
    for row in rows:
        for key in row:
            if key != "equity_curve" and key not in keys:
                keys.append(key)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=keys)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key) for key in keys})


def run_runtime_strategy(db: Path, strategy: dict[str, Any], start: float, end: float) -> dict[str, Any]:
    result = paper_runner_backtest.run_backtest(
        paper_runner_backtest.BacktestConfig(
            db_path=db,
            strategy_id=str(strategy["strategy_id"]),
            symbol=str(strategy["symbol"]),
            start=int(start),
            end=int(end),
            output_prefix=Path("Derived/Reports/paper-runner-backtest"),
        )
    )
    summary = dict(result["summary"])
    summary["source"] = "paper_runner.evaluate_strategy"
    summary["tp2_or_take_profit_count"] = summary.get("tp2_count")
    summary["equity_curve"] = result["equity_curve"]
    return summary


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
    strategies = [
        dict(strategy)
        for active_strategies in paper_runner.ACTIVE_STRATEGIES_BY_SYMBOL.values()
        for strategy in active_strategies
    ]
    results = [
        run_dynamic_top1(btc),
        *(run_runtime_strategy(db, strategy, start, end) for strategy in strategies),
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
