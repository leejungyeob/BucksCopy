#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/Derived/Tools"
RUNNER="$BUILD_DIR/split-tp-backtest-report"

mkdir -p "$BUILD_DIR" "$ROOT_DIR/Derived/Reports"

swiftc \
  "$ROOT_DIR/Sources/BucksCopy/Domains/TradingModels.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Domains/StrategyModels.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Domains/ServerPaperRunnerModels.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Domains/TradeEventLog.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Domains/TradingFeePolicy.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Domains/StrategyRiskPolicy.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Domains/SignalConfirmation.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Domains/BuiltInStrategies.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Domains/BacktestEngine.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Domains/ExchangeProtection.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Domains/RepositoryProtocols.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Data/SQLiteDatabase.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Data/SQLiteCandleRepository.swift" \
  "$ROOT_DIR/Sources/BucksCopy/Presentation/DecimalFormatting.swift" \
  "$ROOT_DIR/scripts/backtest/SplitTPBacktestReport.swift" \
  -o "$RUNNER"

"$RUNNER" "$@"
