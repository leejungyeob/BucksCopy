#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any

import paper_runner
import paper_runner_backtest
import recent4y_comparison_report


ACTIVE_STRATEGIES = [
    dict(paper_runner.BTC_PULSE_PARAMS),
    dict(paper_runner.BTC_REGIME_SESSION_FADE_PARAMS),
    dict(paper_runner.BTC_BULL_PULLBACK_LONG_PARAMS),
    dict(paper_runner.ETH_PULSE_PARAMS),
]


def parse_time(value: str) -> int:
    return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())


def utc_text(timestamp: int | float) -> str:
    return datetime.fromtimestamp(float(timestamp), tz=timezone.utc).strftime("%Y-%m-%d %H:%M")


def trade_entry_timestamp(trade: dict[str, Any]) -> int:
    value = trade.get("entry_time")
    if isinstance(value, (int, float)):
        return int(value)
    return int(datetime.strptime(str(value), "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc).timestamp())


def trade_return_percent(trade: dict[str, Any]) -> Decimal:
    if "return_percent" in trade:
        return Decimal(str(trade["return_percent"]))
    return Decimal(str(trade["return_pct"]))


def window_summary(
    strategy_id: str,
    strategy_name: str,
    symbol: str,
    window_kind: str,
    window_label: str,
    start: int,
    end: int,
    trades: list[dict[str, Any]],
) -> dict[str, Any]:
    selected = [trade for trade in trades if start <= trade_entry_timestamp(trade) < end]
    balance = Decimal("100")
    peak = balance
    max_drawdown = Decimal("0")
    gross_profit = Decimal("0")
    gross_loss = Decimal("0")
    wins = 0
    for trade in selected:
        before = balance
        ret = trade_return_percent(trade)
        balance *= Decimal("1") + ret / Decimal("100")
        profit_loss = balance - before
        if profit_loss > 0:
            wins += 1
            gross_profit += profit_loss
        elif profit_loss < 0:
            gross_loss += profit_loss
        peak = max(peak, balance)
        drawdown = (peak - balance) / peak * Decimal("100") if peak > 0 else Decimal("0")
        max_drawdown = max(max_drawdown, drawdown)
    return {
        "strategy_id": strategy_id,
        "strategy_name": strategy_name,
        "symbol": symbol,
        "window_kind": window_kind,
        "window_label": window_label,
        "start": utc_text(start),
        "end": utc_text(end),
        "final_balance": str(balance),
        "net_return_percent": str((balance / Decimal("100") - Decimal("1")) * Decimal("100")),
        "max_drawdown_percent": str(max_drawdown),
        "profit_factor": str(gross_profit / abs(gross_loss)) if gross_loss < 0 else None,
        "win_rate_percent": str(Decimal(wins) / Decimal(len(selected)) * Decimal("100")) if selected else "0",
        "trade_count": len(selected),
    }


def yearly_windows(start: int, end: int) -> list[tuple[str, int, int]]:
    starts = [
        "2022-05-24T03:00:00Z",
        "2023-05-24T03:00:00Z",
        "2024-05-24T03:00:00Z",
        "2025-05-24T03:00:00Z",
        "2026-05-24T03:00:00Z",
    ]
    timestamps = [parse_time(value) for value in starts]
    return [
        (f"Y{index + 1}", max(timestamps[index], start), min(timestamps[index + 1], end))
        for index in range(len(timestamps) - 1)
        if timestamps[index] < end and timestamps[index + 1] > start
    ]


def half_year_windows(start: int, end: int) -> list[tuple[str, int, int]]:
    starts = [
        "2022-05-24T03:00:00Z",
        "2022-11-24T03:00:00Z",
        "2023-05-24T03:00:00Z",
        "2023-11-24T03:00:00Z",
        "2024-05-24T03:00:00Z",
        "2024-11-24T03:00:00Z",
        "2025-05-24T03:00:00Z",
        "2025-11-24T03:00:00Z",
        "2026-05-24T03:00:00Z",
    ]
    timestamps = [parse_time(value) for value in starts]
    return [
        (f"H{index + 1}", max(timestamps[index], start), min(timestamps[index + 1], end))
        for index in range(len(timestamps) - 1)
        if timestamps[index] < end and timestamps[index + 1] > start
    ]


def concentration(returns: list[Decimal]) -> Decimal:
    positive_logs = []
    for value in returns:
        multiplier = Decimal("1") + value / Decimal("100")
        if multiplier > 1:
            positive_logs.append(Decimal(str(math.log(float(multiplier)))))
    if not positive_logs:
        return Decimal("1")
    return max(positive_logs) / sum(positive_logs)


def risk_assessment(full: dict[str, Any], yearly: list[dict[str, Any]], half_year: list[dict[str, Any]]) -> dict[str, Any]:
    yearly_returns = [Decimal(str(row["net_return_percent"])) for row in yearly]
    half_returns = [Decimal(str(row["net_return_percent"])) for row in half_year]
    positive_years = sum(1 for value in yearly_returns if value > 0)
    positive_halves = sum(1 for value in half_returns if value > 0)
    worst_year = min(yearly_returns) if yearly_returns else Decimal("0")
    worst_half = min(half_returns) if half_returns else Decimal("0")
    best_year = max(yearly_returns) if yearly_returns else Decimal("0")
    full_return = Decimal(str(full["net_return_percent"]))
    full_mdd = Decimal(str(full["max_drawdown_percent"]))
    trade_count = int(full["trade_count"])
    yearly_concentration = concentration(yearly_returns)
    half_positive_ratio = Decimal(positive_halves) / Decimal(len(half_returns)) if half_returns else Decimal("0")

    flags: list[str] = []
    if trade_count < 80:
        flags.append("trade_sample_small")
    if positive_years <= 2:
        flags.append("weak_yearly_persistence")
    if half_positive_ratio < Decimal("0.625"):
        flags.append("weak_half_year_persistence")
    if worst_year <= Decimal("-30"):
        flags.append("deep_negative_year")
    if worst_half <= Decimal("-25"):
        flags.append("deep_negative_half")
    if yearly_concentration >= Decimal("0.70"):
        flags.append("return_concentrated")
    if full_mdd >= Decimal("35"):
        flags.append("large_drawdown")
    if full_return >= Decimal("10000"):
        flags.append("extreme_compounding_requires_forward_validation")

    if (
        "weak_yearly_persistence" in flags
        or "weak_half_year_persistence" in flags
        or "deep_negative_year" in flags
        or "deep_negative_half" in flags
        or ("return_concentrated" in flags and full_return > Decimal("1000"))
    ):
        risk = "HIGH"
    elif flags:
        risk = "MEDIUM"
    else:
        risk = "LOWER"

    return {
        "strategy_id": full["strategy_id"],
        "strategy_name": full["strategy_name"],
        "full_return_percent": str(full_return),
        "full_mdd_percent": str(full_mdd),
        "full_trade_count": trade_count,
        "positive_years": positive_years,
        "year_count": len(yearly_returns),
        "positive_half_years": positive_halves,
        "half_year_count": len(half_returns),
        "worst_year_return_percent": str(worst_year),
        "best_year_return_percent": str(best_year),
        "worst_half_return_percent": str(worst_half),
        "yearly_return_concentration": str(yearly_concentration),
        "overfit_risk": risk,
        "flags": flags,
    }


def run_dynamic(db: Path, start: int, end: int) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    candles = recent4y_comparison_report.load_candles(db, "BTCUSDT", start, end)
    result = recent4y_comparison_report.run_dynamic_top1(candles, include_trades=True)
    trades = list(result.pop("trades"))
    return result, trades


def run_active(db: Path, strategy: dict[str, Any], start: int, end: int) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    result = paper_runner_backtest.run_backtest(
        paper_runner_backtest.BacktestConfig(
            db_path=db,
            strategy_id=str(strategy["strategy_id"]),
            symbol=str(strategy["symbol"]),
            start=start,
            end=end,
            output_prefix=Path("Derived/Reports/paper-runner-backtest"),
        )
    )
    summary = dict(result["summary"])
    summary["source"] = "paper_runner.evaluate_strategy"
    return summary, result["trades"]


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
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
    parser.add_argument("--start", default="2022-05-24T03:00:00Z")
    parser.add_argument("--end", default="2026-05-24T03:00:00Z")
    parser.add_argument("--output-prefix", default="Derived/Reports/strategy-robustness-report")
    args = parser.parse_args()

    db = Path(args.db).expanduser()
    start = parse_time(args.start)
    end = parse_time(args.end)
    yearly = yearly_windows(start, end)
    half_year = half_year_windows(start, end)

    strategies: list[tuple[dict[str, Any], list[dict[str, Any]]]] = [run_dynamic(db, start, end)]
    strategies.extend(run_active(db, strategy, start, end) for strategy in ACTIVE_STRATEGIES)

    window_rows: list[dict[str, Any]] = []
    assessments: list[dict[str, Any]] = []
    full_rows: list[dict[str, Any]] = []
    for full, trades in strategies:
        full_rows.append(full)
        year_rows = [
            window_summary(
                str(full["strategy_id"]),
                str(full["strategy_name"]),
                str(full["symbol"]),
                "year",
                label,
                window_start,
                window_end,
                trades,
            )
            for label, window_start, window_end in yearly
        ]
        half_rows = [
            window_summary(
                str(full["strategy_id"]),
                str(full["strategy_name"]),
                str(full["symbol"]),
                "half_year",
                label,
                window_start,
                window_end,
                trades,
            )
            for label, window_start, window_end in half_year
        ]
        window_rows.extend(year_rows)
        window_rows.extend(half_rows)
        assessments.append(risk_assessment(full, year_rows, half_rows))

    prefix = Path(args.output_prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    full_path = prefix.with_name(prefix.name + "-full-summary.json")
    window_path = prefix.with_name(prefix.name + "-windows.csv")
    assessment_path = prefix.with_name(prefix.name + "-assessment.json")
    full_path.write_text(json.dumps(full_rows, ensure_ascii=False, indent=2), encoding="utf-8")
    write_csv(window_path, window_rows)
    assessment_path.write_text(json.dumps(assessments, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(assessments, ensure_ascii=False, indent=2))
    print(f"full={full_path}")
    print(f"windows={window_path}")
    print(f"assessment={assessment_path}")


if __name__ == "__main__":
    main()
