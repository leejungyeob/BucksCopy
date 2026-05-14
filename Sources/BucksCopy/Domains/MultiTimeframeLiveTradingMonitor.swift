import Foundation

struct LiveMonitorFailure: Equatable {
    let symbol: FuturesSymbol
    let timeframe: CandleTimeframe
    let strategyID: String?
    let message: String
}

struct LiveMonitorEvaluation: Equatable {
    let symbol: FuturesSymbol
    let timeframe: CandleTimeframe
    let strategyID: String
    let candleOpenTime: Date
    let evaluation: StrategyEvaluation
}

struct LiveMonitorRunResult: Equatable {
    let evaluations: [LiveMonitorEvaluation]
    let failures: [LiveMonitorFailure]
    let executionResult: LiveTradeExecutionResult?

    var signalCount: Int {
        evaluations.filter {
            if case .signal = $0.evaluation {
                return true
            }
            return false
        }.count
    }
}

struct LiveMonitorPrimingResult: Equatable {
    let primedCount: Int
    let failures: [LiveMonitorFailure]
}

actor MultiTimeframeLiveTradingMonitor {
    private let candleRepository: CandleRepository
    private let candleBackfillRepository: CandleBackfillRepository?
    private let signalEvaluator: TradingSignalEvaluator
    private let liveExecutor: LiveTradeExecutor
    private let strategyRegistry: StrategyRegistry
    private let candleLimit: Int
    private var evaluatedCandleKeys: Set<String> = []

    init(
        candleRepository: CandleRepository,
        candleBackfillRepository: CandleBackfillRepository?,
        signalEvaluator: TradingSignalEvaluator,
        liveExecutor: LiveTradeExecutor,
        strategyRegistry: StrategyRegistry,
        candleLimit: Int = 500
    ) {
        self.candleRepository = candleRepository
        self.candleBackfillRepository = candleBackfillRepository
        self.signalEvaluator = signalEvaluator
        self.liveExecutor = liveExecutor
        self.strategyRegistry = strategyRegistry
        self.candleLimit = candleLimit
    }

    func primeLatestClosedCandles(watchlist: [FuturesSymbol]) async -> LiveMonitorPrimingResult {
        var primedCount = 0
        var failures: [LiveMonitorFailure] = []

        for symbol in watchlist {
            for timeframe in CandleTimeframe.allCases {
                do {
                    try Task.checkCancellation()
                    let candles = try await latestCandles(symbol: symbol, timeframe: timeframe)
                    guard let latestCandle = candles.last else { continue }

                    for definition in strategyRegistry.definitions(recommendedFor: timeframe) {
                        let key = evaluatedKey(
                            symbol: symbol,
                            timeframe: timeframe,
                            strategyID: definition.id,
                            candleOpenTime: latestCandle.openTime
                        )
                        if evaluatedCandleKeys.insert(key).inserted {
                            primedCount += 1
                        }
                    }
                } catch is CancellationError {
                    return LiveMonitorPrimingResult(primedCount: primedCount, failures: failures)
                } catch {
                    failures.append(LiveMonitorFailure(
                        symbol: symbol,
                        timeframe: timeframe,
                        strategyID: nil,
                        message: String(describing: error)
                    ))
                }
            }
        }

        return LiveMonitorPrimingResult(primedCount: primedCount, failures: failures)
    }

    func evaluateOnce(
        watchlist: [FuturesSymbol],
        leverageBySymbol: [FuturesSymbol: Int],
        maximumRiskPerTradePercentBySymbol: [FuturesSymbol: Decimal] = [:],
        maximumPositionMarginPercentBySymbol: [FuturesSymbol: Decimal] = [:],
        openPositions: [PositionSnapshot] = [],
        accountEquity: Decimal? = nil,
        contractSpecs: [ContractSpec] = []
    ) async -> LiveMonitorRunResult {
        var evaluations: [LiveMonitorEvaluation] = []
        var failures: [LiveMonitorFailure] = []
        var candidates: [TradeCandidate] = []

        for symbol in watchlist {
            for timeframe in CandleTimeframe.allCases {
                do {
                    try Task.checkCancellation()
                    let candles = try await latestCandles(symbol: symbol, timeframe: timeframe)
                    guard let latestCandle = candles.last else { continue }

                    for definition in strategyRegistry.definitions(recommendedFor: timeframe) {
                        let key = evaluatedKey(
                            symbol: symbol,
                            timeframe: timeframe,
                            strategyID: definition.id,
                            candleOpenTime: latestCandle.openTime
                        )
                        guard evaluatedCandleKeys.contains(key) == false else { continue }

                        var config = definition.defaultConfig
                        config.leverage = leverageBySymbol[symbol] ?? config.leverage
                        config.maximumRiskPerTradePercent = maximumRiskPerTradePercentBySymbol[symbol]
                            ?? config.maximumRiskPerTradePercent
                        config.maximumPositionMarginPercent = maximumPositionMarginPercentBySymbol[symbol]
                            ?? config.maximumPositionMarginPercent

                        do {
                            let candidate = try signalEvaluator.makeCandidate(
                                symbol: symbol,
                                watchlist: watchlist,
                                timeframe: timeframe,
                                candleOpenTime: latestCandle.openTime,
                                candles: candles,
                                config: config
                            )
                            evaluatedCandleKeys.insert(key)
                            if let candidate {
                                candidates.append(candidate)
                            }
                            evaluations.append(LiveMonitorEvaluation(
                                symbol: symbol,
                                timeframe: timeframe,
                                strategyID: definition.id,
                                candleOpenTime: latestCandle.openTime,
                                evaluation: candidate.map { .signal($0.signal) } ?? .noSignal
                            ))
                        } catch {
                            failures.append(LiveMonitorFailure(
                                symbol: symbol,
                                timeframe: timeframe,
                                strategyID: definition.id,
                                message: String(describing: error)
                            ))
                        }
                    }
                } catch is CancellationError {
                    return LiveMonitorRunResult(
                        evaluations: evaluations,
                        failures: failures,
                        executionResult: nil
                    )
                } catch {
                    failures.append(LiveMonitorFailure(
                        symbol: symbol,
                        timeframe: timeframe,
                        strategyID: nil,
                        message: String(describing: error)
                    ))
                }
            }
        }

        var executionResult: LiveTradeExecutionResult?
        do {
            executionResult = try await executePortfolioDecision(
                candidates: candidates,
                openPositions: openPositions,
                accountEquity: accountEquity,
                contractSpecs: contractSpecs
            )
        } catch {
            failures.append(LiveMonitorFailure(
                symbol: candidates.first?.signal.symbol ?? openPositions.first?.symbol ?? watchlist.first ?? FuturesSymbol("UNKNOWN"),
                timeframe: candidates.first?.timeframe ?? .fifteenMinutes,
                strategyID: candidates.first?.signal.strategyID,
                message: String(describing: error)
            ))
        }

        return LiveMonitorRunResult(
            evaluations: evaluations,
            failures: failures,
            executionResult: executionResult
        )
    }

    private func executePortfolioDecision(
        candidates: [TradeCandidate],
        openPositions: [PositionSnapshot],
        accountEquity: Decimal?,
        contractSpecs: [ContractSpec]
    ) async throws -> LiveTradeExecutionResult {
        let decision = PortfolioSignalSelectionPolicy.decision(
            candidates: candidates,
            openPositions: openPositions,
            accountEquity: accountEquity
        )
        return try await liveExecutor.execute(
            decision: decision,
            accountEquity: accountEquity,
            contractSpecs: contractSpecs,
            signalEvaluator: signalEvaluator
        )
    }

    private func latestCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) async throws -> [Candle] {
        if let candleBackfillRepository {
            let remoteCandles = try await candleBackfillRepository.fetchCandles(
                symbol: symbol,
                timeframe: timeframe,
                limit: candleLimit
            )
            if remoteCandles.isEmpty == false {
                try candleRepository.upsertCandles(remoteCandles)
            }
        }

        return try candleRepository.loadCandles(
            symbol: symbol,
            timeframe: timeframe,
            limit: candleLimit
        )
        .filter(\.isClosed)
        .sorted { $0.openTime < $1.openTime }
    }

    private func evaluatedKey(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        strategyID: String,
        candleOpenTime: Date
    ) -> String {
        "\(symbol.rawValue):\(timeframe.rawValue):\(strategyID):\(Int(candleOpenTime.timeIntervalSince1970))"
    }
}
