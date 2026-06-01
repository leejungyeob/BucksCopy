#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


INITIAL = 10000.0
FEE = 0.0005
SLIPPAGE = 0.0002
LOOKBACK = 5760
REBALANCE_BARS = 624
DD_PENALTY = 1.0
HOLD_BARS = 96
ATR_LEN = 384
STOP_ATR = 6.0
TAKE_R = 2.0
MAX_LEV = 20.0
COOLDOWN_BARS = 8
FAST_EMA = 192
SLOW_EMA = 1536
EXTERNAL_LEVERAGE = 1.05


@dataclass(frozen=True)
class Candle:
    open_time: int
    open: float
    high: float
    low: float
    close: float
    volume: float


@dataclass(frozen=True)
class Candidate:
    name: str
    risk_pct: float
    mdd_budget: float
    dd_buffer: float


@dataclass
class Position:
    side: str
    entry_index: int
    entry_time: int
    entry: float
    stop: float
    take: float
    leverage: float
    cash_at_entry: float
    candidate: str


@dataclass
class AccountState:
    cash: float = INITIAL
    peak: float = INITIAL
    position: Position | None = None
    cooldown_until: int = -1


CANDIDATES = [
    Candidate("raw", 0.20, -0.45, 1.5),
    Candidate("lowdd", 0.04, -0.30, 5.0),
    Candidate("mid", 0.12, -0.35, 2.0),
]


def parse_time(value: str | None) -> int | None:
    if value is None:
        return None
    return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())


def utc_text(timestamp: int | float) -> str:
    return datetime.fromtimestamp(float(timestamp), tz=timezone.utc).strftime("%Y-%m-%d %H:%M")


def load_candles(db: Path, start: int | None, end: int | None) -> list[Candle]:
    clauses = [
        "product_type = 'USDT-FUTURES'",
        "symbol = 'BTCUSDT'",
        "timeframe = '15m'",
        "is_closed = 1",
    ]
    args: list[Any] = []
    if start is not None:
        clauses.append("open_time >= ?")
        args.append(start)
    if end is not None:
        clauses.append("open_time <= ?")
        args.append(end)
    query = f"""
        SELECT open_time, open, high, low, close, volume
        FROM candles
        WHERE {" AND ".join(clauses)}
        ORDER BY open_time ASC
    """
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=30)
    conn.execute("PRAGMA busy_timeout = 30000")
    try:
        rows = conn.execute(query, args).fetchall()
    finally:
        conn.close()
    if not rows:
        raise RuntimeError("no BTCUSDT 15m candles found")
    return [Candle(int(t), float(o), float(h), float(l), float(c), float(v)) for t, o, h, l, c, v in rows]


def ema(values: list[float], period: int) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    if period <= 0 or len(values) < period:
        return out
    current = sum(values[:period]) / period
    out[period - 1] = current
    alpha = 2.0 / (period + 1.0)
    for i in range(period, len(values)):
        current = values[i] * alpha + current * (1.0 - alpha)
        out[i] = current
    return out


def atr_wilder(candles: list[Candle], period: int) -> list[float | None]:
    out: list[float | None] = [None] * len(candles)
    if period <= 0 or len(candles) <= period:
        return out
    true_ranges = [0.0] * len(candles)
    for i in range(1, len(candles)):
        c = candles[i]
        prev = candles[i - 1].close
        true_ranges[i] = max(c.high - c.low, abs(c.high - prev), abs(c.low - prev))
    current = sum(true_ranges[1 : period + 1]) / period
    out[period] = current
    for i in range(period + 1, len(candles)):
        current = ((period - 1.0) * current + true_ranges[i]) / period
        out[i] = current
    return out


def is_thursday_utc(open_time: int) -> bool:
    return datetime.fromtimestamp(open_time, tz=timezone.utc).weekday() == 3


def downtrend(index: int, candles: list[Candle], fast: list[float | None], slow: list[float | None]) -> bool:
    fast_value = fast[index]
    slow_value = slow[index]
    return fast_value is not None and slow_value is not None and fast_value < slow_value and candles[index].close < slow_value


def exit_position(position: Position, candle: Candle, index: int) -> tuple[str, float] | None:
    if candle.high >= position.stop:
        return "stop_loss", position.stop
    if candle.low <= position.take:
        return "take_profit", position.take
    if index - position.entry_index + 1 >= HOLD_BARS:
        return "time_exit", candle.close * (1.0 + SLIPPAGE)
    return None


def apply_exit(state: AccountState, exit_price: float, reason: str, exit_time: int) -> dict[str, Any]:
    assert state.position is not None
    position = state.position
    gross = (position.entry - exit_price) / position.entry
    net = gross - FEE * 2.0
    pnl = position.cash_at_entry * position.leverage * net
    before = state.cash
    state.cash += pnl
    state.peak = max(state.peak, state.cash)
    state.position = None
    state.cooldown_until = position.entry_index + HOLD_BARS if reason == "time_exit" else position.entry_index + COOLDOWN_BARS
    return {
        "candidate": position.candidate,
        "entry_time": utc_text(position.entry_time),
        "exit_time": utc_text(exit_time),
        "entry": position.entry,
        "exit": exit_price,
        "stop": position.stop,
        "take": position.take,
        "leverage": position.leverage,
        "exit_reason": reason,
        "return_percent": (state.cash / before - 1.0) * 100.0 if before > 0 else 0.0,
        "profit_loss": state.cash - before,
        "starting_balance": before,
        "ending_balance": state.cash,
    }


def maybe_enter(
    state: AccountState,
    candidate: Candidate,
    candles: list[Candle],
    atr: list[float | None],
    index: int,
    signal_index: int,
) -> None:
    if state.position is not None or index < state.cooldown_until:
        return
    atr_value = atr[signal_index]
    if atr_value is None or atr_value <= 0:
        return
    entry = candles[index].open * (1.0 - SLIPPAGE)
    stop_dist = atr_value * STOP_ATR
    if entry <= 0 or stop_dist <= 0:
        return
    stop = entry + stop_dist
    take = entry - stop_dist * TAKE_R
    stop_rate = stop_dist / entry + FEE * 2.0 + SLIPPAGE
    if stop_rate <= 0:
        return

    drawdown = state.cash / state.peak - 1.0 if state.peak > 0 else 0.0
    risk = candidate.risk_pct
    if drawdown < -0.20:
        risk *= 0.25
    elif drawdown < -0.12:
        risk *= 0.50

    leverage = min(MAX_LEV, risk / stop_rate)
    floor = state.peak * (1.0 + candidate.mdd_budget)
    buffer = max(0.0, state.cash - floor) * candidate.dd_buffer
    leverage_by_budget = buffer / (state.cash * stop_rate) if state.cash > 0 else 0.0
    leverage = min(leverage, leverage_by_budget) * EXTERNAL_LEVERAGE
    if leverage < 0.05:
        return
    state.position = Position(
        side="short",
        entry_index=index,
        entry_time=candles[index].open_time,
        entry=entry,
        stop=stop,
        take=take,
        leverage=leverage,
        cash_at_entry=state.cash,
        candidate=candidate.name,
    )


def recent_score(equity: list[float], index: int) -> float:
    start = index - LOOKBACK
    if start < 0 or equity[start] <= 0:
        return -1e9
    recent_return = equity[index] / equity[start] - 1.0
    peak = equity[start]
    recent_dd = 0.0
    for value in equity[start : index + 1]:
        peak = max(peak, value)
        if peak > 0:
            recent_dd = min(recent_dd, value / peak - 1.0)
    return recent_return + recent_dd * DD_PENALTY


def summarize(
    candles: list[Candle],
    equity: list[dict[str, Any]],
    trades: list[dict[str, Any]],
    switches: int,
    selected_counts: dict[str, int],
) -> dict[str, Any]:
    final_balance = float(equity[-1]["equity"])
    peak = INITIAL
    max_dd = 0.0
    for point in equity:
        value = float(point["equity"])
        peak = max(peak, value)
        max_dd = max(max_dd, (peak - value) / peak * 100.0 if peak > 0 else 0.0)
    gross_profit = sum(float(t["profit_loss"]) for t in trades if float(t["profit_loss"]) > 0)
    gross_loss = sum(float(t["profit_loss"]) for t in trades if float(t["profit_loss"]) < 0)
    wins = sum(1 for trade in trades if float(trade["profit_loss"]) > 0)
    years = (candles[-1].open_time - candles[0].open_time) / (365.25 * 86400)
    return {
        "strategy_id": "calendar-timing-thursday-short",
        "strategy_name": "Calendar Timing Thursday Short",
        "symbol": "BTCUSDT",
        "data_source": "local USDT-FUTURES BTCUSDT 15m candles",
        "first_candle": utc_text(candles[0].open_time),
        "last_candle": utc_text(candles[-1].open_time),
        "initial_capital": INITIAL,
        "final_balance": final_balance,
        "net_return_percent": (final_balance / INITIAL - 1.0) * 100.0,
        "cagr_percent": ((final_balance / INITIAL) ** (1 / years) - 1.0) * 100.0 if years > 0 else 0.0,
        "max_drawdown_percent": max_dd,
        "profit_factor": gross_profit / abs(gross_loss) if gross_loss < 0 else None,
        "win_rate_percent": wins / len(trades) * 100.0 if trades else 0.0,
        "trade_count": len(trades),
        "trades_per_year": len(trades) / years if years > 0 else 0.0,
        "strategy_switches": switches,
        "selected_counts": selected_counts,
    }


def run_backtest(candles: list[Candle], trade_start: int | None) -> dict[str, Any]:
    closes = [c.close for c in candles]
    fast = ema(closes, FAST_EMA)
    slow = ema(closes, SLOW_EMA)
    atr = atr_wilder(candles, ATR_LEN)
    warm = LOOKBACK + 2

    shadow_states = {candidate.name: AccountState() for candidate in CANDIDATES}
    shadow_equity = {candidate.name: [INITIAL] * len(candles) for candidate in CANDIDATES}
    actual = AccountState()
    actual_equity: list[dict[str, Any]] = []
    trades: list[dict[str, Any]] = []
    selected: Candidate | None = None
    switches = 0
    selected_counts = {candidate.name: 0 for candidate in CANDIDATES}

    for index in range(1, len(candles)):
        signal_index = index - 1
        if index >= warm and (index - warm) % REBALANCE_BARS == 0:
            scored = [(recent_score(shadow_equity[c.name], signal_index), c) for c in CANDIDATES]
            next_selected = max(scored, key=lambda item: item[0])[1]
            if selected is not None and next_selected.name != selected.name:
                switches += 1
            selected = next_selected

        signal_ok = is_thursday_utc(candles[signal_index].open_time) and downtrend(signal_index, candles, fast, slow)
        for candidate in CANDIDATES:
            state = shadow_states[candidate.name]
            if signal_ok:
                maybe_enter(state, candidate, candles, atr, index, signal_index)
            if state.position is not None:
                result = exit_position(state.position, candles[index], index)
                if result is not None:
                    reason, exit_price = result
                    apply_exit(state, exit_price, reason, candles[index].open_time)
            shadow_equity[candidate.name][index] = state.cash

        can_trade = trade_start is None or candles[index].open_time >= trade_start
        if can_trade and selected is not None:
            selected_counts[selected.name] += 1
            if signal_ok:
                maybe_enter(actual, selected, candles, atr, index, signal_index)
        if actual.position is not None:
            result = exit_position(actual.position, candles[index], index)
            if result is not None:
                reason, exit_price = result
                trades.append(apply_exit(actual, exit_price, reason, candles[index].open_time))
        if can_trade:
            actual_equity.append({
                "time": utc_text(candles[index].open_time),
                "equity": actual.cash,
                "selected": selected.name if selected else None,
            })

    if not actual_equity:
        raise RuntimeError("no equity points in requested trade period")
    summary = summarize(
        [c for c in candles if trade_start is None or c.open_time >= trade_start],
        actual_equity,
        trades,
        switches,
        selected_counts,
    )
    return {"summary": summary, "trades": trades, "equity_curve": actual_equity}


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    keys: list[str] = []
    for row in rows:
        for key in row:
            if key not in keys:
                keys.append(key)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=keys)
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=str(Path.home() / "Library/Application Support/BucksCopy/BucksCopy.sqlite"))
    parser.add_argument("--data-start", default="2019-07-10T00:00:00Z")
    parser.add_argument("--start", default="2022-01-01T00:00:00Z")
    parser.add_argument("--end", default="2026-05-24T03:00:00Z")
    parser.add_argument("--output-prefix", default="Derived/Reports/calendar-timing-backtest")
    args = parser.parse_args()

    data_start = parse_time(args.data_start)
    trade_start = parse_time(args.start)
    end = parse_time(args.end)
    candles = load_candles(Path(args.db).expanduser(), data_start, end)
    result = run_backtest(candles, trade_start)

    prefix = Path(args.output_prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    summary_path = prefix.with_name(prefix.name + "-summary.json")
    trades_path = prefix.with_name(prefix.name + "-trades.csv")
    equity_path = prefix.with_name(prefix.name + "-equity.csv")
    summary_path.write_text(json.dumps(result["summary"], ensure_ascii=False, indent=2), encoding="utf-8")
    write_csv(trades_path, result["trades"])
    write_csv(equity_path, result["equity_curve"])
    print(json.dumps(result["summary"], ensure_ascii=False, indent=2))
    print(f"summary={summary_path}")
    print(f"trades={trades_path}")
    print(f"equity={equity_path}")


if __name__ == "__main__":
    main()
