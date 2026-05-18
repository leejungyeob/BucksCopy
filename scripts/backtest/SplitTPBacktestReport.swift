import Foundation

struct BacktestReportOptions {
    var symbol = FuturesSymbol("BTCUSDT")
    var databasePath = "\(NSHomeDirectory())/Library/Application Support/BucksCopy/BucksCopy.sqlite"
    var outputPath = "Derived/Reports/split-tp-backtest-BTCUSDT-all.md"
    var cachePath = "Derived/Reports/split-tp-backtest-BTCUSDT-cache.json"
    var includeAllStrategyTimeframes = true
    var usesCache = true
    var refreshesCache = false
    var fifteenMinuteCandleLimit = 20_000
    var oneHourCandleLimit = 20_000
    var timeframeFilter: CandleTimeframe?
    var strategyIDFilter: String?
    var parameterOverrides: [String: Decimal] = [:]
    var leverage = 2
    var maximumRiskPerTradePercent: Decimal = 5
    var maximumPositionMarginPercent: Decimal = 100

    static func parse(arguments: [String]) throws -> BacktestReportOptions {
        var options = BacktestReportOptions()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--symbol":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingValue(argument) }
                options.symbol = FuturesSymbol(arguments[index])
                if options.outputPath == BacktestReportOptions().outputPath {
                    options.outputPath = "Derived/Reports/split-tp-backtest-\(options.symbol.rawValue)-all.md"
                }
                if options.cachePath == BacktestReportOptions().cachePath {
                    options.cachePath = "Derived/Reports/split-tp-backtest-\(options.symbol.rawValue)-cache.json"
                }
            case "--db":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingValue(argument) }
                options.databasePath = arguments[index]
            case "--output":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingValue(argument) }
                options.outputPath = arguments[index]
            case "--cache":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingValue(argument) }
                options.cachePath = arguments[index]
            case "--no-cache":
                options.usesCache = false
            case "--refresh-cache":
                options.refreshesCache = true
            case "--15m-limit":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingValue(argument) }
                guard let limit = Int(arguments[index]), limit >= 0 else {
                    throw RunnerError.invalidValue(argument, arguments[index])
                }
                options.fifteenMinuteCandleLimit = limit
            case "--1h-limit":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingValue(argument) }
                guard let limit = Int(arguments[index]), limit >= 0 else {
                    throw RunnerError.invalidValue(argument, arguments[index])
                }
                options.oneHourCandleLimit = limit
            case "--timeframe":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingValue(argument) }
                guard let timeframe = CandleTimeframe(rawValue: arguments[index]) else {
                    throw RunnerError.invalidValue(argument, arguments[index])
                }
                options.timeframeFilter = timeframe
            case "--strategy":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingValue(argument) }
                options.strategyIDFilter = arguments[index]
            case "--param":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingValue(argument) }
                let pair = arguments[index].split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2,
                      let value = parseDecimal(pair[1]) else {
                    throw RunnerError.invalidValue(argument, arguments[index])
                }
                options.parameterOverrides[pair[0]] = value
            case "--leverage":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingValue(argument) }
                guard let leverage = Int(arguments[index]), leverage > 0 else {
                    throw RunnerError.invalidValue(argument, arguments[index])
                }
                options.leverage = leverage
            case "--risk":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingValue(argument) }
                guard let risk = parseDecimal(arguments[index]), risk >= 0 else {
                    throw RunnerError.invalidValue(argument, arguments[index])
                }
                options.maximumRiskPerTradePercent = risk
            case "--margin":
                index += 1
                guard index < arguments.count else { throw RunnerError.missingValue(argument) }
                guard let margin = parseDecimal(arguments[index]), margin >= 0 else {
                    throw RunnerError.invalidValue(argument, arguments[index])
                }
                options.maximumPositionMarginPercent = margin
            case "--recommended-only":
                options.includeAllStrategyTimeframes = false
            case "--all":
                options.includeAllStrategyTimeframes = true
            case "--help", "-h":
                throw RunnerError.helpRequested
            default:
                throw RunnerError.unknownArgument(argument)
            }
            index += 1
        }
        return options
    }

    private static func parseDecimal(_ value: String) -> Decimal? {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }
}

enum RunnerError: Error, CustomStringConvertible {
    case helpRequested
    case missingValue(String)
    case invalidValue(String, String)
    case unknownArgument(String)

    var description: String {
        switch self {
        case .helpRequested:
            return Self.usage
        case .missingValue(let argument):
            return "\(argument)에 필요한 값이 없습니다.\n\n\(Self.usage)"
        case .invalidValue(let argument, let value):
            return "\(argument)에 올바르지 않은 값입니다: \(value)\n\n\(Self.usage)"
        case .unknownArgument(let argument):
            return "알 수 없는 인자입니다: \(argument)\n\n\(Self.usage)"
        }
    }

    static let usage = """
    사용법:
      scripts/backtest/run_split_tp_backtest_report.sh [--symbol BTCUSDT] [--db PATH] [--output PATH] [--cache PATH] [--timeframe 15m] [--strategy ID] [--param key=value] [--leverage 2] [--risk 5] [--margin 100] [--15m-limit 20000] [--1h-limit 20000] [--all|--recommended-only] [--no-cache|--refresh-cache]

    기본값:
      symbol: BTCUSDT
      db: ~/Library/Application Support/BucksCopy/BucksCopy.sqlite
      output: Derived/Reports/split-tp-backtest-BTCUSDT-all.md
      cache: Derived/Reports/split-tp-backtest-BTCUSDT-cache.json
      leverage: 2
      risk: 5
      margin: 100
      15m-limit: 20000 (0이면 15분봉도 전체 캔들)
      1h-limit: 20000 (0이면 1시간봉도 전체 캔들)
    """
}

struct BacktestRow {
    let timeframe: CandleTimeframe
    let strategyID: String
    let strategyName: String
    let isRecommended: Bool
    let candleCount: Int
    let firstOpenTime: Date?
    let lastOpenTime: Date?
    let result: BacktestResult
    let source: BacktestRowSource
}

enum BacktestRowSource: String, Codable {
    case cache = "캐시"
    case computed = "신규"
}

struct BacktestCacheEntry: Codable {
    let timeframe: CandleTimeframe
    let strategyID: String
    let strategyName: String
    let isRecommended: Bool
    let candleCount: Int
    let firstOpenTime: Date?
    let lastOpenTime: Date?
    let result: BacktestResult
}

@main
struct SplitTPBacktestReport {
    private static let cacheVersion = "split-tp-v3-main-strategy-candidates-2026-05-14"

    static func main() throws {
        let options: BacktestReportOptions
        do {
            options = try BacktestReportOptions.parse(arguments: CommandLine.arguments)
        } catch let error as RunnerError {
            print(error.description)
            if case .helpRequested = error {
                return
            }
            throw error
        }

        let outputURL = URL(fileURLWithPath: options.outputPath)
        let cacheURL = URL(fileURLWithPath: options.cachePath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let repository = try SQLiteCandleRepository(path: options.databasePath)
        let registry = StrategyRegistry()
        let engine = BacktestEngine(strategyRegistry: registry)
        let timeframes = options.timeframeFilter.map { [$0] } ?? CandleTimeframe.allCases
        let strategies = registry.definitions.filter { definition in
            options.strategyIDFilter.map { $0 == definition.id } ?? true
        }
        if let strategyIDFilter = options.strategyIDFilter, strategies.isEmpty {
            throw RunnerError.invalidValue("--strategy", strategyIDFilter)
        }
        let formatter = utcFormatter()
        var cache = loadCache(from: cacheURL)
        var didUpdateCache = false

        var rows: [BacktestRow] = []
        for timeframe in timeframes {
            var loadedCandles: [Candle]?
            for definition in strategies {
                if options.includeAllStrategyTimeframes == false,
                   StrategyTimeframeRouting.isRecommended(
                    strategyID: definition.id,
                    for: timeframe,
                    symbol: options.symbol
                   ) == false {
                    continue
                }

                var config = definition.defaultConfig
                for (key, value) in options.parameterOverrides {
                    config.parameters[key] = value
                }
                config.leverage = options.leverage
                config.maximumRiskPerTradePercent = options.maximumRiskPerTradePercent
                config.maximumPositionMarginPercent = options.maximumPositionMarginPercent
                config.signalConfirmation = .disabled

                let key = cacheKey(
                    symbol: options.symbol,
                    timeframe: timeframe,
                    config: config,
                    fifteenMinuteCandleLimit: options.fifteenMinuteCandleLimit,
                    oneHourCandleLimit: options.oneHourCandleLimit,
                    initialCapital: 100
                )
                if options.usesCache,
                   options.refreshesCache == false,
                   let cached = cache[key] {
                    rows.append(BacktestRow(
                        timeframe: cached.timeframe,
                        strategyID: cached.strategyID,
                        strategyName: cached.strategyName,
                        isRecommended: cached.isRecommended,
                        candleCount: cached.candleCount,
                        firstOpenTime: cached.firstOpenTime,
                        lastOpenTime: cached.lastOpenTime,
                        result: cached.result,
                        source: .cache
                    ))
                    continue
                }

                let candles: [Candle]
                if let existingCandles = loadedCandles {
                    candles = existingCandles
                } else {
                    let fetchedCandles = try loadCandles(
                        repository: repository,
                        symbol: options.symbol,
                        timeframe: timeframe,
                        fifteenMinuteLimit: options.fifteenMinuteCandleLimit,
                        oneHourLimit: options.oneHourCandleLimit
                    )
                    loadedCandles = fetchedCandles
                    candles = fetchedCandles
                }

                let result = try engine.run(
                    symbol: options.symbol,
                    timeframe: timeframe,
                    candles: candles,
                    config: config,
                    initialCapital: 100,
                    completedAt: Date()
                )
                let row = BacktestRow(
                    timeframe: timeframe,
                    strategyID: definition.id,
                    strategyName: definition.name,
                    isRecommended: StrategyTimeframeRouting.isRecommended(
                        strategyID: definition.id,
                        for: timeframe,
                        symbol: options.symbol
                    ),
                    candleCount: candles.count,
                    firstOpenTime: candles.first?.openTime,
                    lastOpenTime: candles.last?.openTime,
                    result: result,
                    source: .computed
                )
                rows.append(row)
                cache[key] = BacktestCacheEntry(
                    timeframe: row.timeframe,
                    strategyID: row.strategyID,
                    strategyName: row.strategyName,
                    isRecommended: row.isRecommended,
                    candleCount: row.candleCount,
                    firstOpenTime: row.firstOpenTime,
                    lastOpenTime: row.lastOpenTime,
                    result: row.result
                )
                didUpdateCache = true
            }
        }

        if options.usesCache, didUpdateCache {
            try saveCache(cache, to: cacheURL)
        }

        let report = markdownReport(
            symbol: options.symbol,
            databasePath: options.databasePath,
            cachePath: options.cachePath,
            fifteenMinuteCandleLimit: options.fifteenMinuteCandleLimit,
            oneHourCandleLimit: options.oneHourCandleLimit,
            timeframeFilter: options.timeframeFilter,
            leverage: options.leverage,
            maximumRiskPerTradePercent: options.maximumRiskPerTradePercent,
            maximumPositionMarginPercent: options.maximumPositionMarginPercent,
            rows: rows,
            includeAllStrategyTimeframes: options.includeAllStrategyTimeframes,
            formatter: formatter
        )
        try report.write(to: outputURL, atomically: true, encoding: .utf8)
        print(report)
        print("\n리포트 저장: \(outputURL.path)")
        if options.usesCache {
            print("캐시 저장/사용: \(cacheURL.path)")
        }
    }

    private static func markdownReport(
        symbol: FuturesSymbol,
        databasePath: String,
        cachePath: String,
        fifteenMinuteCandleLimit: Int,
        oneHourCandleLimit: Int,
        timeframeFilter: CandleTimeframe?,
        leverage: Int,
        maximumRiskPerTradePercent: Decimal,
        maximumPositionMarginPercent: Decimal,
        rows: [BacktestRow],
        includeAllStrategyTimeframes: Bool,
        formatter: DateFormatter
    ) -> String {
        let recommendedRows = rows.filter(\.isRecommended)
        let allSorted = rows.sorted(by: rowSort)
        let recommendedSorted = recommendedRows.sorted(by: rowSort)

        var markdown: [String] = []
        markdown.append("# Split TP Backtest - \(symbol.rawValue)")
        markdown.append("")
        markdown.append("- 실행 기준: 로컬 SQLite 캔들, 초기금액 $100, 레버리지 \(leverage)x, 1회 최대 손실 \(number(maximumRiskPerTradePercent))%, 1회 최대 투입 \(number(maximumPositionMarginPercent))%")
        markdown.append("- 대상 시간봉: \(timeframeFilter?.rawValue ?? "전체")")
        markdown.append("- 캔들 범위: \(limitedScopeDescription(timeframe: .fifteenMinutes, limit: fifteenMinuteCandleLimit)), \(limitedScopeDescription(timeframe: .oneHour, limit: oneHourCandleLimit)), 4H/12H/1D 전체 캔들")
        markdown.append("- 청산 기준: TP1 50% midpoint, TP2 50% final target, TP1 이후 SL은 진입가-목표가 거리의 25% profit-lock")
        markdown.append("- 수수료 모델: 진입 시장가 taker, TP limit maker, SL market taker")
        markdown.append("- 보조지표: OFF")
        markdown.append("- DB: `\(databasePath)`")
        markdown.append("- 캐시: `\(cachePath)`")
        markdown.append("")
        markdown.append("## 용어 설명")
        markdown.append("")
        markdown.append("| 용어 | 뜻 | 해석 기준 |")
        markdown.append("| --- | --- | --- |")
        markdown.append("| 최종잔고 | 백테스트 종료 시 계좌 잔고 | $100에서 시작해 복리 반영 후 남은 금액 |")
        markdown.append("| 순손익률 | 최종잔고 기준 전체 수익률 | +100%면 원금 2배, -50%면 원금 절반 |")
        markdown.append("| 승률 | 종료된 거래 중 순수익이 난 거래 비율 | TP1 후 profit-lock SL로 끝난 거래도 최종 수익이면 승리 |")
        markdown.append("| 거래 승/패/전체 | 이긴 거래 수 / 진 거래 수 / 전체 거래 수 | 거래 수가 너무 적으면 과신 금지 |")
        markdown.append("| MDD | Maximum Drawdown, 최고 잔고 이후 최저 잔고까지의 최대 하락률 | 낮을수록 실전에서 버티기 쉬움 |")
        markdown.append("| PF | Profit Factor, 총 이익 / 총 손실 | 1보다 크면 총 이익이 총 손실보다 큼 |")
        markdown.append("| TP1 | 진입가와 최종 목표가의 중간값에서 50% 익절 | 목표가 근처까지 못 가도 일부 수익 확보 |")
        markdown.append("| TP2 | 기존 최종 목표가에서 남은 50% 익절 | 추세가 끝까지 가면 추가 수익 확보 |")
        markdown.append("| TP1후 SL | TP1 체결 후 profit-lock SL로 남은 물량이 익절 종료된 횟수 | 목표가 실패 후 되돌림 방어 횟수 |")
        markdown.append("| 순수 SL | TP1도 못 찍고 기존 SL로 손절된 횟수 | 낮을수록 초반 실패가 적음 |")
        markdown.append("| 추천 | 앱 라우팅상 해당 시간봉에 우선 배정된 전략 여부 | Y만 자동매매 후보로 우선 검토 |")
        markdown.append("| 소스 | 이번 실행에서 계산했는지, 이전 캐시에서 가져왔는지 | 신규는 이번 계산, 캐시는 이전 기록 재사용 |")
        markdown.append("")
        markdown.append("## 추천 조합")
        markdown.append("")
        markdown.append(table(for: recommendedSorted))
        if includeAllStrategyTimeframes {
            markdown.append("")
            markdown.append("## 전체 조합")
            markdown.append("")
            markdown.append(table(for: allSorted))
        }
        markdown.append("")
        markdown.append("## 백테스트 시간봉 범위")
        markdown.append("")
        markdown.append("| 시간봉 | 캔들 수 | 시작 UTC | 종료 UTC |")
        markdown.append("| --- | ---: | --- | --- |")
        for timeframe in CandleTimeframe.allCases {
            if let row = rows.first(where: { $0.timeframe == timeframe }) {
                markdown.append("| \(timeframe.rawValue) | \(row.candleCount) | \(dateText(row.firstOpenTime, formatter: formatter)) | \(dateText(row.lastOpenTime, formatter: formatter)) |")
            }
        }
        markdown.append("")
        return markdown.joined(separator: "\n")
    }

    private static func table(for rows: [BacktestRow]) -> String {
        var lines = [
            "| 추천 | 시간봉 | 전략 | 소스 | 캔들 | 최종잔고 | 순손익률 | 승률 | 거래 승/패/전체 | MDD | PF | TP1 | TP2 | TP1후 SL | 순수 SL |",
            "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
        ]
        for row in rows {
            let result = row.result
            let partialHits = result.trades.filter { $0.partialTakeProfitFillRatio > 0 }.count
            let finalHits = result.trades.filter { $0.finalTakeProfitFillRatio > 0 }.count
            let profitLockStops = result.trades.filter {
                $0.partialTakeProfitFillRatio > 0 && $0.stopLossFillRatio > 0
            }.count
            let pureStops = result.trades.filter {
                $0.partialTakeProfitFillRatio == 0 && $0.stopLossFillRatio > 0
            }.count
            let tradeText = "\(result.winningTrades)/\(result.losingTrades)/\(result.totalTrades)"
            lines.append("| \(row.isRecommended ? "Y" : "-") | \(row.timeframe.rawValue) | \(row.strategyName) | \(row.source.rawValue) | \(row.candleCount) | \(currency(result.finalBalance)) | \(signedPercent(result.netReturnPercent)) | \(percent(result.winRatePercent)) | \(tradeText) | \(percent(result.maxDrawdownPercent)) | \(number(result.profitFactor)) | \(partialHits) | \(finalHits) | \(profitLockStops) | \(pureStops) |")
        }
        return lines.joined(separator: "\n")
    }

    private static func rowSort(_ left: BacktestRow, _ right: BacktestRow) -> Bool {
        if left.result.finalBalance == right.result.finalBalance {
            if left.timeframe.rawValue == right.timeframe.rawValue {
                return left.strategyName < right.strategyName
            }
            return left.timeframe.rawValue < right.timeframe.rawValue
        }
        return left.result.finalBalance > right.result.finalBalance
    }

    private static func cacheKey(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        config: StrategyConfig,
        fifteenMinuteCandleLimit: Int,
        oneHourCandleLimit: Int,
        initialCapital: Decimal
    ) -> String {
        let parameters = config.parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return [
            cacheVersion,
            symbol.rawValue,
            timeframe.rawValue,
            config.strategyID,
            "initial=\(initialCapital)",
            "lev=\(config.leverage)",
            "risk=\(config.maximumRiskPerTradePercent)",
            "margin=\(config.maximumPositionMarginPercent)",
            "confirmation=\(config.signalConfirmation.mode.rawValue)",
            "candleScope=\(candleScopeText(for: timeframe, fifteenMinuteLimit: fifteenMinuteCandleLimit, oneHourLimit: oneHourCandleLimit))",
            "params=\(parameters)"
        ].joined(separator: "|")
    }

    private static func loadCandles(
        repository: SQLiteCandleRepository,
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        fifteenMinuteLimit: Int,
        oneHourLimit: Int
    ) throws -> [Candle] {
        if timeframe == .fifteenMinutes, fifteenMinuteLimit > 0 {
            return try repository.loadCandles(
                symbol: symbol,
                timeframe: timeframe,
                limit: fifteenMinuteLimit
            )
        }
        if timeframe == .oneHour, oneHourLimit > 0 {
            return try repository.loadCandles(
                symbol: symbol,
                timeframe: timeframe,
                limit: oneHourLimit
            )
        }
        return try repository.loadAllCandles(symbol: symbol, timeframe: timeframe)
    }

    private static func candleScopeText(
        for timeframe: CandleTimeframe,
        fifteenMinuteLimit: Int,
        oneHourLimit: Int
    ) -> String {
        if timeframe == .fifteenMinutes, fifteenMinuteLimit > 0 {
            return "latest-\(fifteenMinuteLimit)"
        }
        if timeframe == .oneHour, oneHourLimit > 0 {
            return "latest-\(oneHourLimit)"
        }
        return "all"
    }

    private static func limitedScopeDescription(timeframe: CandleTimeframe, limit: Int) -> String {
        if limit > 0 {
            return "\(timeframe.rawValue) 최신 \(number(Decimal(limit), maxFractionDigits: 0))개"
        }
        return "\(timeframe.rawValue) 전체 캔들"
    }

    private static func loadCache(from url: URL) -> [String: BacktestCacheEntry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: BacktestCacheEntry].self, from: data)) ?? [:]
    }

    private static func saveCache(_ cache: [String: BacktestCacheEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)
        try data.write(to: url, options: .atomic)
    }

    private static func utcFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    private static func dateText(_ date: Date?, formatter: DateFormatter) -> String {
        guard let date else { return "-" }
        return formatter.string(from: date)
    }

    private static func currency(_ value: Decimal) -> String {
        "$" + number(value, maxFractionDigits: 6)
    }

    private static func signedPercent(_ value: Decimal) -> String {
        let sign = value > 0 ? "+" : ""
        return sign + number(value, maxFractionDigits: 2) + "%"
    }

    private static func percent(_ value: Decimal) -> String {
        number(value, maxFractionDigits: 2) + "%"
    }

    private static func number(_ value: Decimal, maxFractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maxFractionDigits
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }
}
