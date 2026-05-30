#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import math
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean
from typing import Iterable


TIMEFRAME_SECONDS = 15 * 60
DEFAULT_DB = str(Path.home() / "Library/Application Support/BucksCopy/BucksCopy.sqlite")


@dataclass(frozen=True)
class Candle:
    open_time: int
    open: float
    high: float
    low: float
    close: float
    volume: float


@dataclass(frozen=True)
class Trade:
    side: str
    entry_time: int
    exit_time: int
    entry: float
    exit: float
    stop: float
    take_profit: float
    margin_fraction: float
    leverage: float
    gross_move: float
    net_return_pct: float
    starting_equity: float
    ending_equity: float
    reason: str


PARAMS = {
    "target_natr": 0.004,
    "margin_min": 0.5,
    "margin_max": 1.0,
    "atr_period": 10,
    "long_donchian_period": 3,
    "short_donchian_period": 3,
    "long_breakout_confirm": 4,
    "short_breakout_confirm": 3,
    "long_vol_lookback": 40,
    "long_vol_min_quantile": 0.05,
    "long_sl_pct": 0.01,
    "long_tp_pct": 0.035,
    "short_sl_pct": 0.015,
    "short_tp_pct": 0.02,
    "long_lev_min": 1.5,
    "long_lev_max": 5.0,
    "short_lev_min": 1.0,
    "short_lev_max": 4.5,
    "long_natr_ref": 0.005,
    "short_natr_ref": 0.005,
    "long_natr_power": 0.75,
    "short_natr_power": 1.25,
    "long_strength_boost": 0.25,
    "short_strength_boost": 0.75,
    "fee_rate": 0.0005,
    "slippage_rate": 0.0003,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Backtest Dynamic Top1 BTC 15m strategy.")
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--symbol", default="BTCUSDT")
    parser.add_argument("--years", type=float, default=4.0, help="Use most recent N years. 0 means all rows.")
    parser.add_argument("--initial-equity", type=float, default=10_000.0)
    parser.add_argument("--fee-rate", type=float, default=PARAMS["fee_rate"])
    parser.add_argument("--slippage-rate", type=float, default=PARAMS["slippage_rate"])
    parser.add_argument("--output", default="Derived/Reports/dynamic-top1-BTCUSDT-4y.md")
    parser.add_argument("--trades-csv", default="Derived/Reports/dynamic-top1-BTCUSDT-4y-trades.csv")
    return parser.parse_args()


def load_candles(db_path: str, symbol: str, years: float) -> list[Candle]:
    connection = sqlite3.connect(db_path)
    try:
        rows = connection.execute(
            """
            SELECT open_time, open, high, low, close, volume
            FROM candles
            WHERE product_type = 'USDT-FUTURES'
              AND symbol = ?
              AND timeframe = '15m'
              AND is_closed = 1
            ORDER BY open_time ASC
            """,
            (symbol,),
        ).fetchall()
    finally:
        connection.close()

    candles = [
        Candle(
            open_time=int(float(row[0])),
            open=float(row[1]),
            high=float(row[2]),
            low=float(row[3]),
            close=float(row[4]),
            volume=float(row[5]),
        )
        for row in rows
    ]
    if years > 0 and candles:
        cutoff = candles[-1].open_time - int(years * 365.25 * 24 * 60 * 60)
        candles = [candle for candle in candles if candle.open_time >= cutoff]
    return candles


def aggregate_hourly(candles: list[Candle]) -> list[Candle]:
    hourly: list[Candle] = []
    bucket: list[Candle] = []
    current_hour: int | None = None
    for candle in candles:
        hour = candle.open_time - candle.open_time % 3600
        if current_hour is None:
            current_hour = hour
        if hour != current_hour:
            if len(bucket) == 4:
                hourly.append(join_bucket(current_hour, bucket))
            bucket = []
            current_hour = hour
        bucket.append(candle)
    if current_hour is not None and len(bucket) == 4:
        hourly.append(join_bucket(current_hour, bucket))
    return hourly


def join_bucket(open_time: int, bucket: list[Candle]) -> Candle:
    return Candle(
        open_time=open_time,
        open=bucket[0].open,
        high=max(c.high for c in bucket),
        low=min(c.low for c in bucket),
        close=bucket[-1].close,
        volume=sum(c.volume for c in bucket),
    )


def ema_by_hour(hourly: list[Candle], period: int) -> dict[int, float]:
    output: dict[int, float] = {}
    if len(hourly) < period:
        return output
    alpha = 2.0 / (period + 1)
    current = sum(c.close for c in hourly[:period]) / period
    output[hourly[period - 1].open_time] = current
    for candle in hourly[period:]:
        current = candle.close * alpha + current * (1 - alpha)
        output[candle.open_time] = current
    return output


def true_ranges(candles: list[Candle]) -> list[float]:
    values = [math.nan]
    for index in range(1, len(candles)):
        candle = candles[index]
        previous_close = candles[index - 1].close
        values.append(max(
            candle.high - candle.low,
            abs(candle.high - previous_close),
            abs(candle.low - previous_close),
        ))
    return values


def rolling_average(values: list[float], period: int) -> list[float]:
    output = [math.nan] * len(values)
    total = 0.0
    valid = 0
    for index, value in enumerate(values):
        if not math.isnan(value):
            total += value
            valid += 1
        if index >= period:
            old = values[index - period]
            if not math.isnan(old):
                total -= old
                valid -= 1
        if valid == period:
            output[index] = total / period
    return output


def rolling_std(values: list[float], period: int) -> list[float]:
    output = [math.nan] * len(values)
    for index in range(period - 1, len(values)):
        window = values[index - period + 1:index + 1]
        if any(math.isnan(value) for value in window):
            continue
        avg = sum(window) / period
        variance = sum((value - avg) ** 2 for value in window) / period
        output[index] = math.sqrt(variance)
    return output


def quantile(values: Iterable[float], q: float) -> float | None:
    clean = sorted(value for value in values if not math.isnan(value))
    if not clean:
        return None
    if len(clean) == 1:
        return clean[0]
    position = (len(clean) - 1) * q
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return clean[lower]
    weight = position - lower
    return clean[lower] * (1 - weight) + clean[upper] * weight


def clip(value: float, minimum: float, maximum: float) -> float:
    return min(max(value, minimum), maximum)


def dynamic_margin(natr: float) -> float:
    if natr <= 0 or math.isnan(natr):
        return 0.0
    return clip(PARAMS["target_natr"] / natr, PARAMS["margin_min"], PARAMS["margin_max"])


def dynamic_leverage(side: str, natr: float, strength_up: float, strength_dn: float) -> float:
    if natr <= 0 or math.isnan(natr):
        return 0.0
    if side == "long":
        lev_min = PARAMS["long_lev_min"]
        lev_max = PARAMS["long_lev_max"]
        ref = PARAMS["long_natr_ref"]
        power = PARAMS["long_natr_power"]
        boost = 1 + strength_up * PARAMS["long_strength_boost"] * 0.25
    else:
        lev_min = PARAMS["short_lev_min"]
        lev_max = PARAMS["short_lev_max"]
        ref = PARAMS["short_natr_ref"]
        power = PARAMS["short_natr_power"]
        boost = 1 + strength_dn * PARAMS["short_strength_boost"] * 0.25
    base_ratio = clip(ref / natr, 0.1, 10.0) ** power
    scaled = (clip(base_ratio, 0.25, 2.5) - 0.25) / (2.5 - 0.25)
    leverage = lev_min + (lev_max - lev_min) * scaled
    return clip(leverage * boost, lev_min, lev_max)


def has_confirmed(raw: list[bool], index: int, confirm: int) -> bool:
    start = index - confirm
    if start < 0:
        return False
    return all(raw[start:index + 1])


def run_backtest(candles: list[Candle], initial_equity: float, fee_rate: float, slippage_rate: float) -> list[Trade]:
    hourly = aggregate_hourly(candles)
    ema20 = ema_by_hour(hourly, 20)
    ema100 = ema_by_hour(hourly, 100)
    returns = [math.nan] + [
        candles[index].close / candles[index - 1].close - 1
        for index in range(1, len(candles))
    ]
    vol = rolling_std(returns, PARAMS["long_vol_lookback"])
    atr = rolling_average(true_ranges(candles), PARAMS["atr_period"])

    raw_long = [False] * len(candles)
    raw_short = [False] * len(candles)
    long_signal = [False] * len(candles)
    short_signal = [False] * len(candles)

    for index, candle in enumerate(candles):
        if index >= PARAMS["long_donchian_period"]:
            upper_prev = max(c.high for c in candles[index - PARAMS["long_donchian_period"]:index])
            raw_long[index] = candle.close > upper_prev
        if index >= PARAMS["short_donchian_period"]:
            lower_prev = min(c.low for c in candles[index - PARAMS["short_donchian_period"]:index])
            raw_short[index] = candle.close < lower_prev

        if has_confirmed(raw_long, index, PARAMS["long_breakout_confirm"]):
            threshold = quantile(
                vol[max(0, index - PARAMS["long_vol_lookback"] + 1):index + 1],
                PARAMS["long_vol_min_quantile"],
            )
            long_signal[index] = threshold is not None and not math.isnan(vol[index]) and vol[index] > threshold

        if has_confirmed(raw_short, index, PARAMS["short_breakout_confirm"]):
            previous_hour = candle.open_time - candle.open_time % 3600 - 3600
            short_signal[index] = (
                previous_hour in ema20
                and previous_hour in ema100
                and ema20[previous_hour] < ema100[previous_hour]
            )

    equity = initial_equity
    trades: list[Trade] = []
    index = 0
    while index < len(candles) - 1:
        if not long_signal[index] and not short_signal[index]:
            index += 1
            continue
        if long_signal[index] and short_signal[index]:
            index += 1
            continue
        if math.isnan(atr[index]) or candles[index].close <= 0:
            index += 1
            continue

        entry_candle = candles[index]
        entry = entry_candle.close
        natr = atr[index] / entry
        margin_fraction = dynamic_margin(natr)
        previous_hour = entry_candle.open_time - entry_candle.open_time % 3600 - 3600
        hour_ema20 = ema20.get(previous_hour, math.nan)
        hour_ema100 = ema100.get(previous_hour, math.nan)
        if not math.isnan(hour_ema20) and not math.isnan(hour_ema100) and hour_ema100 > 0:
            strength_up = clip(((hour_ema20 - hour_ema100) / hour_ema100) * 100.0 / 5.0, 0.0, 1.0)
            strength_dn = clip(((hour_ema100 - hour_ema20) / hour_ema100) * 100.0 / 5.0, 0.0, 1.0)
        else:
            strength_up = 0.0
            strength_dn = 0.0

        if long_signal[index]:
            side = "long"
            stop = entry * (1 - PARAMS["long_sl_pct"])
            take_profit = entry * (1 + PARAMS["long_tp_pct"])
            leverage = dynamic_leverage(side, natr, strength_up, strength_dn)
        else:
            side = "short"
            stop = entry * (1 + PARAMS["short_sl_pct"])
            take_profit = entry * (1 - PARAMS["short_tp_pct"])
            leverage = dynamic_leverage(side, natr, strength_up, strength_dn)

        exit_index = None
        exit_price = None
        reason = ""
        for cursor in range(index + 1, len(candles)):
            candle = candles[cursor]
            if side == "long":
                hit_stop = candle.low <= stop
                hit_take = candle.high >= take_profit
            else:
                hit_stop = candle.high >= stop
                hit_take = candle.low <= take_profit
            if hit_stop:
                exit_index = cursor
                exit_price = stop
                reason = "SL"
                break
            if hit_take:
                exit_index = cursor
                exit_price = take_profit
                reason = "TP"
                break

        if exit_index is None or exit_price is None:
            break

        if side == "long":
            gross_move = exit_price / entry - 1
        else:
            gross_move = entry / exit_price - 1
        round_trip_cost = 2 * (fee_rate + slippage_rate)
        net_return_pct = margin_fraction * leverage * (gross_move - round_trip_cost) * 100
        starting_equity = equity
        equity = equity * (1 + net_return_pct / 100)
        trades.append(Trade(
            side=side,
            entry_time=entry_candle.open_time,
            exit_time=candles[exit_index].open_time,
            entry=entry,
            exit=exit_price,
            stop=stop,
            take_profit=take_profit,
            margin_fraction=margin_fraction,
            leverage=leverage,
            gross_move=gross_move,
            net_return_pct=net_return_pct,
            starting_equity=starting_equity,
            ending_equity=equity,
            reason=reason,
        ))
        index = exit_index + 1

    return trades


def max_drawdown(trades: list[Trade], initial_equity: float) -> float:
    peak = initial_equity
    mdd = 0.0
    for trade in trades:
        peak = max(peak, trade.ending_equity)
        if peak > 0:
            mdd = max(mdd, (peak - trade.ending_equity) / peak * 100)
    return mdd


def profit_factor(trades: list[Trade]) -> float:
    wins = sum(max(trade.ending_equity - trade.starting_equity, 0.0) for trade in trades)
    losses = sum(abs(min(trade.ending_equity - trade.starting_equity, 0.0)) for trade in trades)
    if losses == 0:
        return 999.0 if wins > 0 else 0.0
    return wins / losses


def fmt_ts(timestamp: int) -> str:
    return datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y-%m-%d %H:%M")


def write_trades_csv(path: Path, trades: list[Trade]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow([
            "side", "entry_time_utc", "exit_time_utc", "entry", "exit", "stop", "take_profit",
            "margin_fraction", "leverage", "gross_move_pct", "net_return_pct",
            "starting_equity", "ending_equity", "reason",
        ])
        for trade in trades:
            writer.writerow([
                trade.side,
                fmt_ts(trade.entry_time),
                fmt_ts(trade.exit_time),
                f"{trade.entry:.8f}",
                f"{trade.exit:.8f}",
                f"{trade.stop:.8f}",
                f"{trade.take_profit:.8f}",
                f"{trade.margin_fraction:.6f}",
                f"{trade.leverage:.6f}",
                f"{trade.gross_move * 100:.6f}",
                f"{trade.net_return_pct:.6f}",
                f"{trade.starting_equity:.6f}",
                f"{trade.ending_equity:.6f}",
                trade.reason,
            ])


def write_report(path: Path, symbol: str, candles: list[Candle], trades: list[Trade], initial_equity: float, fee_rate: float, slippage_rate: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    final_equity = trades[-1].ending_equity if trades else initial_equity
    net_return = (final_equity / initial_equity - 1) * 100
    wins = [trade for trade in trades if trade.ending_equity > trade.starting_equity]
    longs = [trade for trade in trades if trade.side == "long"]
    shorts = [trade for trade in trades if trade.side == "short"]
    years = (candles[-1].open_time - candles[0].open_time) / (365.25 * 24 * 60 * 60) if len(candles) >= 2 else 0
    lines = [
        "# Dynamic Top1 Backtest",
        "",
        f"- Symbol: `{symbol}`",
        f"- Candle range: `{fmt_ts(candles[0].open_time)}` -> `{fmt_ts(candles[-1].open_time)}`",
        f"- Candles: `{len(candles)}`",
        f"- Initial equity: `{initial_equity:,.2f}`",
        f"- Fee/slippage: `{fee_rate:.4%}` / `{slippage_rate:.4%}` per side",
        "",
        "## Result",
        "",
        f"- Final equity: `{final_equity:,.2f}`",
        f"- Net return: `{net_return:+.2f}%`",
        f"- Trades: `{len(trades)}`",
        f"- Annual trades: `{(len(trades) / years) if years > 0 else 0:.2f}`",
        f"- Win rate: `{(len(wins) / len(trades) * 100) if trades else 0:.2f}%`",
        f"- MDD: `{max_drawdown(trades, initial_equity):.2f}%`",
        f"- PF: `{profit_factor(trades):.4f}`",
        "",
        "## Direction Split",
        "",
        f"- Long trades: `{len(longs)}`",
        f"- Short trades: `{len(shorts)}`",
        f"- Avg long leverage: `{mean([t.leverage for t in longs]) if longs else 0:.4f}`",
        f"- Avg short leverage: `{mean([t.leverage for t in shorts]) if shorts else 0:.4f}`",
        f"- Avg long margin fraction: `{mean([t.margin_fraction for t in longs]) if longs else 0:.4f}`",
        f"- Avg short margin fraction: `{mean([t.margin_fraction for t in shorts]) if shorts else 0:.4f}`",
        "",
        "## Notes",
        "",
        "- Entry uses closed 15m candle close.",
        "- 1H EMA filter uses only the previous completed 1H candle.",
        "- If TP and SL touch in the same candle, SL wins.",
        "- This reproduces the friend spec exit model: full-size TP/SL, no TP1/TP2 split.",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    candles = load_candles(args.db, args.symbol, args.years)
    if len(candles) < 500:
        raise SystemExit(f"not enough candles: {len(candles)}")
    trades = run_backtest(candles, args.initial_equity, args.fee_rate, args.slippage_rate)
    write_report(Path(args.output), args.symbol, candles, trades, args.initial_equity, args.fee_rate, args.slippage_rate)
    write_trades_csv(Path(args.trades_csv), trades)
    final_equity = trades[-1].ending_equity if trades else args.initial_equity
    print(f"trades={len(trades)} final={final_equity:.2f} return={(final_equity / args.initial_equity - 1) * 100:+.2f}%")


if __name__ == "__main__":
    main()
