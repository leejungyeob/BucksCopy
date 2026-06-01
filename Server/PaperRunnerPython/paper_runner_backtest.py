#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import gzip
import json
import sqlite3
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any

import paper_runner


INITIAL_CAPITAL = Decimal("100")
MAXIMUM_RISK_PER_TRADE_PERCENT = Decimal("5")
MAXIMUM_POSITION_MARGIN_RATIO = Decimal("1")
MAKER_FEE_RATE = Decimal("0.0002") * Decimal("0.8")
TAKER_FEE_RATE = Decimal("0.0006") * Decimal("0.8")
PARTIAL_TAKE_PROFIT_RATIO = Decimal("0.5")
FINAL_TAKE_PROFIT_RATIO = Decimal("0.5")


@dataclass(frozen=True)
class BacktestConfig:
    db_path: Path
    strategy_id: str
    symbol: str
    start: int | None
    end: int | None
    output_prefix: Path


def parse_timestamp(value: str | None) -> int | None:
    if value is None:
        return None
    return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())


def iso_text(timestamp: int) -> str:
    return datetime.fromtimestamp(timestamp, tz=timezone.utc).strftime("%Y-%m-%d %H:%M")


def connect_readonly(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)
    conn.execute("PRAGMA busy_timeout = 30000")
    return conn


def materialized_db_path(path: Path) -> tuple[Path, tempfile.TemporaryDirectory[str] | None]:
    if path.suffix != ".gz":
        return path, None
    temp_dir = tempfile.TemporaryDirectory()
    db_path = Path(temp_dir.name) / path.with_suffix("").name
    with gzip.open(path, "rb") as source, db_path.open("wb") as target:
        target.write(source.read())
    return db_path, temp_dir


def load_candles(config: BacktestConfig) -> list[paper_runner.Candle]:
    clauses = [
        "product_type = 'USDT-FUTURES'",
        "symbol = ?",
        "timeframe = '15m'",
        "is_closed = 1",
    ]
    args: list[Any] = [config.symbol]
    if config.start is not None:
        clauses.append("open_time >= ?")
        args.append(config.start)
    if config.end is not None:
        clauses.append("open_time <= ?")
        args.append(config.end)
    query = f"""
        SELECT open_time, open, high, low, close, volume
        FROM candles
        WHERE {" AND ".join(clauses)}
        ORDER BY open_time ASC
    """
    db_path, temp_dir = materialized_db_path(config.db_path)
    try:
        conn = connect_readonly(db_path)
        try:
            rows = conn.execute(query, args).fetchall()
        finally:
            conn.close()
    finally:
        if temp_dir is not None:
            temp_dir.cleanup()
    if not rows:
        raise RuntimeError(f"no {config.symbol} closed 15m candles found")
    return [
        paper_runner.Candle(
            symbol=config.symbol,
            open_time=int(row[0]),
            open=paper_runner.dec(row[1]),
            high=paper_runner.dec(row[2]),
            low=paper_runner.dec(row[3]),
            close=paper_runner.dec(row[4]),
            volume=paper_runner.dec(row[5]),
            is_closed=True,
        )
        for row in rows
    ]


def strategy_params(strategy_id: str) -> dict[str, Any]:
    for params in paper_runner.ACTIVE_STRATEGIES_BY_SYMBOL.get("BTCUSDT", []):
        if params["strategy_id"] == strategy_id:
            return dict(params)
    for params in paper_runner.ACTIVE_STRATEGIES_BY_SYMBOL.get("ETHUSDT", []):
        if params["strategy_id"] == strategy_id:
            return dict(params)
    raise ValueError(f"unknown active strategy: {strategy_id}")


def sized_position_margin_ratio(signal: paper_runner.Signal) -> tuple[Decimal, Decimal]:
    if signal.entry <= 0:
        return Decimal("0"), Decimal("0")
    full_margin_risk_percent = abs(signal.entry - signal.stop) / signal.entry * Decimal(signal.leverage) * Decimal("100")
    if full_margin_risk_percent <= 0:
        return Decimal("0"), Decimal("0")
    margin_ratio = min(
        MAXIMUM_POSITION_MARGIN_RATIO,
        MAXIMUM_RISK_PER_TRADE_PERCENT / full_margin_risk_percent,
    )
    return margin_ratio, full_margin_risk_percent * margin_ratio


def take_profit_fee_percent(leverage: int, position_margin_ratio: Decimal) -> Decimal:
    return (TAKER_FEE_RATE + MAKER_FEE_RATE) * Decimal(leverage) * position_margin_ratio * Decimal("100")


def stop_loss_fee_percent(leverage: int, position_margin_ratio: Decimal) -> Decimal:
    return (TAKER_FEE_RATE + TAKER_FEE_RATE) * Decimal(leverage) * position_margin_ratio * Decimal("100")


def leveraged_return_percent(
    side: str,
    entry: Decimal,
    exit_price: Decimal,
    leverage: int,
    position_margin_ratio: Decimal,
) -> Decimal:
    if entry <= 0:
        return Decimal("0")
    if side == "buy":
        move = (exit_price - entry) / entry
    else:
        move = (entry - exit_price) / entry
    return move * Decimal("100") * Decimal(leverage) * position_margin_ratio


def leg_return_percent(
    signal: paper_runner.Signal,
    exit_price: Decimal,
    ratio: Decimal,
    exit_execution: str,
    position_margin_ratio: Decimal,
) -> Decimal:
    leg_margin_ratio = position_margin_ratio * ratio
    gross = leveraged_return_percent(
        signal.side,
        signal.entry,
        exit_price,
        signal.leverage,
        leg_margin_ratio,
    )
    fee = (
        take_profit_fee_percent(signal.leverage, leg_margin_ratio)
        if exit_execution == "take_profit_limit"
        else stop_loss_fee_percent(signal.leverage, leg_margin_ratio)
    )
    return gross - fee


def simulate_exit(
    signal: paper_runner.Signal,
    candles: list[paper_runner.Candle],
    starting_at: int,
    starting_balance: Decimal,
    maximum_holding_candles: int | None,
) -> tuple[dict[str, Any], int] | None:
    position_margin_ratio, account_risk_percent = sized_position_margin_ratio(signal)
    if position_margin_ratio <= 0:
        return None

    did_hit_partial = False
    maximum_holding = maximum_holding_candles if maximum_holding_candles and maximum_holding_candles > 0 else None

    for index in range(starting_at, len(candles)):
        candle = candles[index]
        active_stop = signal.profit_lock_stop if did_hit_partial else signal.stop
        if signal.side == "buy":
            hit_stop = candle.low <= active_stop
            hit_partial = candle.high >= signal.partial_take_profit
            hit_final = candle.high >= signal.take_profit
        else:
            hit_stop = candle.high >= active_stop
            hit_partial = candle.low <= signal.partial_take_profit
            hit_final = candle.low <= signal.take_profit

        legs: list[tuple[str, Decimal, Decimal, str]] | None = None
        exit_reason = ""
        if hit_stop:
            if did_hit_partial:
                legs = [
                    ("tp1", signal.partial_take_profit, PARTIAL_TAKE_PROFIT_RATIO, "take_profit_limit"),
                    ("profit_lock_stop", signal.profit_lock_stop, FINAL_TAKE_PROFIT_RATIO, "stop_loss_market"),
                ]
                exit_reason = "profit_lock_stop"
            else:
                legs = [("pure_stop", signal.stop, Decimal("1"), "stop_loss_market")]
                exit_reason = "pure_stop"
        elif hit_final:
            legs = [
                ("tp1", signal.partial_take_profit, PARTIAL_TAKE_PROFIT_RATIO, "take_profit_limit"),
                ("tp2", signal.take_profit, FINAL_TAKE_PROFIT_RATIO, "take_profit_limit"),
            ]
            exit_reason = "tp2"
        elif hit_partial:
            did_hit_partial = True

        if legs is None and maximum_holding is not None and index - starting_at + 1 >= maximum_holding:
            legs = []
            if did_hit_partial:
                legs.append(("tp1", signal.partial_take_profit, PARTIAL_TAKE_PROFIT_RATIO, "take_profit_limit"))
            legs.append((
                "time_exit",
                candle.close,
                FINAL_TAKE_PROFIT_RATIO if did_hit_partial else Decimal("1"),
                "stop_loss_market",
            ))
            exit_reason = "time_exit_after_tp1" if did_hit_partial else "time_exit"

        if legs is None:
            continue

        return_percent = sum(
            leg_return_percent(signal, price, ratio, execution, position_margin_ratio)
            for _, price, ratio, execution in legs
        )
        ending_balance = starting_balance + starting_balance * return_percent / Decimal("100")
        return (
            {
                "strategy_id": signal.strategy_id,
                "symbol": signal.symbol,
                "side": signal.side,
                "entry_time": iso_text(candles[starting_at - 1].open_time),
                "exit_time": iso_text(candle.open_time),
                "entry": str(signal.entry),
                "stop": str(signal.stop),
                "tp1": str(signal.partial_take_profit),
                "tp2": str(signal.take_profit),
                "exit_reason": exit_reason,
                "return_percent": str(return_percent),
                "starting_balance": str(starting_balance),
                "ending_balance": str(ending_balance),
                "profit_loss": str(ending_balance - starting_balance),
                "position_margin_ratio": str(position_margin_ratio),
                "account_risk_percent": str(account_risk_percent),
                "partial_fill_ratio": str(sum(ratio for kind, _, ratio, _ in legs if kind == "tp1")),
                "final_fill_ratio": str(sum(ratio for kind, _, ratio, _ in legs if kind == "tp2")),
                "stop_fill_ratio": str(sum(ratio for kind, _, ratio, _ in legs if kind in {"pure_stop", "profit_lock_stop"})),
                "time_fill_ratio": str(sum(ratio for kind, _, ratio, _ in legs if kind == "time_exit")),
            },
            index,
        )
    return None


def run_backtest(config: BacktestConfig) -> dict[str, Any]:
    params = strategy_params(config.strategy_id)
    if params["symbol"] != config.symbol:
        raise ValueError(f"{config.strategy_id} belongs to {params['symbol']}, not {config.symbol}")
    candles = load_candles(config)
    balance = INITIAL_CAPITAL
    peak = INITIAL_CAPITAL
    max_drawdown = Decimal("0")
    trades: list[dict[str, Any]] = []
    history: list[paper_runner.Candle] = []
    equity_curve = [{
        "time": iso_text(candles[0].open_time),
        "strategy_id": config.strategy_id,
        "symbol": config.symbol,
        "equity": str(balance),
        "drawdown_percent": "0",
    }]

    index = 0
    while index < len(candles):
        history.append(candles[index])
        evaluated_at = datetime.fromtimestamp(candles[index].open_time + paper_runner.TIMEFRAME_SECONDS, timezone.utc)
        signal = paper_runner.evaluate_strategy(history, params, evaluated_at)
        if signal is None:
            index += 1
            continue

        exit_result = simulate_exit(
            signal,
            candles,
            index + 1,
            balance,
            params.get("maximum_holding_candles"),
        )
        if exit_result is None:
            index += 1
            continue
        trade, exit_index = exit_result
        trades.append(trade)
        balance = Decimal(str(trade["ending_balance"]))
        peak = max(peak, balance)
        drawdown = (peak - balance) / peak * Decimal("100") if peak > 0 else Decimal("0")
        max_drawdown = max(max_drawdown, drawdown)
        equity_curve.append({
            "time": trade["exit_time"],
            "strategy_id": config.strategy_id,
            "symbol": config.symbol,
            "equity": str(balance),
            "drawdown_percent": str(drawdown),
        })
        if exit_index > index:
            history.extend(candles[index + 1 : exit_index + 1])
        index = max(exit_index + 1, index + 1)

    if equity_curve[-1]["time"] != iso_text(candles[-1].open_time):
        equity_curve.append({
            "time": iso_text(candles[-1].open_time),
            "strategy_id": config.strategy_id,
            "symbol": config.symbol,
            "equity": str(balance),
            "drawdown_percent": str(max_drawdown),
        })

    gross_profit = sum(Decimal(str(trade["profit_loss"])) for trade in trades if Decimal(str(trade["profit_loss"])) > 0)
    gross_loss = sum(Decimal(str(trade["profit_loss"])) for trade in trades if Decimal(str(trade["profit_loss"])) < 0)
    wins = sum(1 for trade in trades if Decimal(str(trade["profit_loss"])) > 0)
    summary = {
        "strategy_id": config.strategy_id,
        "strategy_name": params.get("name", config.strategy_id),
        "symbol": config.symbol,
        "first_candle": iso_text(candles[0].open_time),
        "last_candle": iso_text(candles[-1].open_time),
        "initial_capital": str(INITIAL_CAPITAL),
        "final_balance": str(balance),
        "net_return_percent": str((balance / INITIAL_CAPITAL - Decimal("1")) * Decimal("100")),
        "max_drawdown_percent": str(max_drawdown),
        "profit_factor": str(gross_profit / abs(gross_loss)) if gross_loss < 0 else None,
        "win_rate_percent": str(Decimal(wins) / Decimal(len(trades)) * Decimal("100")) if trades else "0",
        "trade_count": len(trades),
        "tp1_count": sum(1 for trade in trades if Decimal(str(trade["partial_fill_ratio"])) > 0),
        "tp2_count": sum(1 for trade in trades if Decimal(str(trade["final_fill_ratio"])) > 0),
        "profit_lock_stop_count": sum(1 for trade in trades if trade["exit_reason"] == "profit_lock_stop"),
        "pure_stop_count": sum(1 for trade in trades if trade["exit_reason"] == "pure_stop"),
        "time_exit_count": sum(1 for trade in trades if "time_exit" in str(trade["exit_reason"])),
    }
    return {
        "summary": summary,
        "trades": trades,
        "equity_curve": equity_curve,
    }


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=str(Path.home() / "Library/Application Support/BucksCopy/BucksCopy.sqlite"))
    parser.add_argument("--strategy", required=True)
    parser.add_argument("--symbol")
    parser.add_argument("--start")
    parser.add_argument("--end")
    parser.add_argument("--output-prefix", default="Derived/Reports/paper-runner-backtest")
    args = parser.parse_args()

    params = strategy_params(args.strategy)
    config = BacktestConfig(
        db_path=Path(args.db).expanduser(),
        strategy_id=args.strategy,
        symbol=args.symbol or str(params["symbol"]),
        start=parse_timestamp(args.start),
        end=parse_timestamp(args.end),
        output_prefix=Path(args.output_prefix),
    )
    result = run_backtest(config)
    prefix = config.output_prefix
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
