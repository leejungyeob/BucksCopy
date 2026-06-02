#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any

import paper_runner
import paper_runner_backtest as single


@dataclass(frozen=True)
class PortfolioBacktestConfig:
    db_path: Path
    strategy_ids: tuple[str, ...]
    symbol: str
    start: int | None
    end: int | None
    output_prefix: Path


def strategy_params(strategy_ids: tuple[str, ...], symbol: str) -> list[dict[str, Any]]:
    params = [single.strategy_params(strategy_id) for strategy_id in strategy_ids]
    wrong_symbol = [str(item["strategy_id"]) for item in params if item["symbol"] != symbol]
    if wrong_symbol:
        raise ValueError(f"{wrong_symbol[0]} belongs to another symbol")
    return params


def summary_counts(trades: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    counts: dict[str, dict[str, int]] = {}
    for trade in trades:
        strategy_id = str(trade["strategy_id"])
        bucket = counts.setdefault(strategy_id, {"trade_count": 0, "wins": 0, "losses": 0})
        bucket["trade_count"] += 1
        profit_loss = Decimal(str(trade["profit_loss"]))
        if profit_loss > 0:
            bucket["wins"] += 1
        elif profit_loss < 0:
            bucket["losses"] += 1
    return counts


def run_portfolio_backtest(config: PortfolioBacktestConfig) -> dict[str, Any]:
    params_list = strategy_params(config.strategy_ids, config.symbol)
    load_config = single.BacktestConfig(
        db_path=config.db_path,
        strategy_id=config.strategy_ids[0],
        symbol=config.symbol,
        start=config.start,
        end=config.end,
        output_prefix=config.output_prefix,
    )
    candles = single.load_candles(load_config)
    balance = single.INITIAL_CAPITAL
    peak = single.INITIAL_CAPITAL
    max_drawdown = Decimal("0")
    trades: list[dict[str, Any]] = []
    history: list[paper_runner.Candle] = []
    evaluation_context = paper_runner.StrategyEvaluationContext(candles)
    equity_curve = [{
        "time": single.iso_text(candles[0].open_time),
        "strategy_id": ",".join(config.strategy_ids),
        "symbol": config.symbol,
        "equity": str(balance),
        "drawdown_percent": "0",
    }]

    index = 0
    while index < len(candles):
        history.append(candles[index])
        evaluated_at = datetime.fromtimestamp(candles[index].open_time + paper_runner.TIMEFRAME_SECONDS, timezone.utc)
        candidates: list[tuple[paper_runner.Signal, dict[str, Any]]] = []
        for params in params_list:
            signal = paper_runner.evaluate_strategy(history, params, evaluated_at, context=evaluation_context)
            if signal is not None:
                candidates.append((signal, params))
        if not candidates:
            index += 1
            continue

        candidates.sort(key=lambda item: item[0].reward_risk_ratio or Decimal("0"), reverse=True)
        signal, params = candidates[0]
        exit_result = single.simulate_exit(
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
            "strategy_id": ",".join(config.strategy_ids),
            "symbol": config.symbol,
            "equity": str(balance),
            "drawdown_percent": str(drawdown),
        })
        if exit_index > index:
            history.extend(candles[index + 1 : exit_index + 1])
        index = max(exit_index + 1, index + 1)

    if equity_curve[-1]["time"] != single.iso_text(candles[-1].open_time):
        equity_curve.append({
            "time": single.iso_text(candles[-1].open_time),
            "strategy_id": ",".join(config.strategy_ids),
            "symbol": config.symbol,
            "equity": str(balance),
            "drawdown_percent": str(max_drawdown),
        })

    gross_profit = sum(Decimal(str(trade["profit_loss"])) for trade in trades if Decimal(str(trade["profit_loss"])) > 0)
    gross_loss = sum(Decimal(str(trade["profit_loss"])) for trade in trades if Decimal(str(trade["profit_loss"])) < 0)
    wins = sum(1 for trade in trades if Decimal(str(trade["profit_loss"])) > 0)
    summary = {
        "strategy_id": ",".join(config.strategy_ids),
        "strategy_name": " + ".join(str(params.get("name") or params["strategy_id"]) for params in params_list),
        "symbol": config.symbol,
        "first_candle": single.iso_text(candles[0].open_time),
        "last_candle": single.iso_text(candles[-1].open_time),
        "initial_capital": str(single.INITIAL_CAPITAL),
        "final_balance": str(balance),
        "net_return_percent": str((balance / single.INITIAL_CAPITAL - Decimal("1")) * Decimal("100")),
        "max_drawdown_percent": str(max_drawdown),
        "profit_factor": str(gross_profit / abs(gross_loss)) if gross_loss < 0 else None,
        "win_rate_percent": str(Decimal(wins) / Decimal(len(trades)) * Decimal("100")) if trades else "0",
        "trade_count": len(trades),
        "tp1_count": sum(1 for trade in trades if Decimal(str(trade["partial_fill_ratio"])) > 0),
        "tp2_count": sum(1 for trade in trades if Decimal(str(trade["final_fill_ratio"])) > 0),
        "profit_lock_stop_count": sum(1 for trade in trades if trade["exit_reason"] == "profit_lock_stop"),
        "pure_stop_count": sum(1 for trade in trades if trade["exit_reason"] == "pure_stop"),
        "time_exit_count": sum(1 for trade in trades if "time_exit" in str(trade["exit_reason"])),
        "component_counts": summary_counts(trades),
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
    fieldnames: list[str] = []
    for row in rows:
        for key in row:
            if key not in fieldnames:
                fieldnames.append(key)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=str(Path.home() / "Library/Application Support/BucksCopy/BucksCopy.sqlite"))
    parser.add_argument("--strategies", required=True, help="Comma-separated strategy IDs")
    parser.add_argument("--symbol", default="ETHUSDT")
    parser.add_argument("--start")
    parser.add_argument("--end")
    parser.add_argument("--output-prefix", default="Derived/Reports/paper-runner-portfolio-backtest")
    args = parser.parse_args()

    strategy_ids = tuple(strategy_id.strip() for strategy_id in args.strategies.split(",") if strategy_id.strip())
    if not strategy_ids:
        raise ValueError("at least one strategy is required")
    config = PortfolioBacktestConfig(
        db_path=Path(args.db).expanduser(),
        strategy_ids=strategy_ids,
        symbol=args.symbol.upper(),
        start=single.parse_timestamp(args.start),
        end=single.parse_timestamp(args.end),
        output_prefix=Path(args.output_prefix),
    )
    result = run_portfolio_backtest(config)
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
