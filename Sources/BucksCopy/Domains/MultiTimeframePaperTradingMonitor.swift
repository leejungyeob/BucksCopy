import Foundation

struct PaperMonitorFailure: Equatable {
    let symbol: FuturesSymbol
    let timeframe: CandleTimeframe
    let strategyID: String?
    let message: String
}

struct PaperMonitorEvaluation: Equatable {
    let symbol: FuturesSymbol
    let timeframe: CandleTimeframe
    let strategyID: String
    let candleOpenTime: Date
    let evaluation: StrategyEvaluation
}

struct PaperMonitorRunResult: Equatable {
    let evaluations: [PaperMonitorEvaluation]
    let failures: [PaperMonitorFailure]

    var signalCount: Int {
        evaluations.filter {
            if case .signal = $0.evaluation {
                return true
            }
            return false
        }.count
    }
}

actor MultiTimeframePaperTradingMonitor {
    private let candleRepository: CandleRepository
    private let candleBackfillRepository: CandleBackfillRepository?
    private let paperRunner: PaperTradingRunner
    private let strategyRegistry: StrategyRegistry
    private let candleLimit: Int
    private var evaluatedCandleKeys: Set<String> = []

    init(
        candleRepository: CandleRepository,
        candleBackfillRepository: CandleBackfillRepository?,
        paperRunner: PaperTradingRunner,
        strategyRegistry: StrategyRegistry,
        candleLimit: Int = 500
    ) {
        self.candleRepository = candleRepository
        self.candleBackfillRepository = candleBackfillRepository
        self.paperRunner = paperRunner
        self.strategyRegistry = strategyRegistry
        self.candleLimit = candleLimit
    }

    func evaluateOnce(
        watchlist: [FuturesSymbol],
        leverageBySymbol: [FuturesSymbol: Int],
        maximumRiskPerTradePercentBySymbol: [FuturesSymbol: Decimal] = [:],
        maximumPositionMarginPercentBySymbol: [FuturesSymbol: Decimal] = [:],
        openPositions: [PositionSnapshot] = [],
        accountEquity: Decimal? = nil
    ) async -> PaperMonitorRunResult {
        var evaluations: [PaperMonitorEvaluation] = []
        var failures: [PaperMonitorFailure] = []
        var candidates: [PaperTradeCandidate] = []

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
                            let candidate = try paperRunner.makeCandidate(
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
                            evaluations.append(PaperMonitorEvaluation(
                                symbol: symbol,
                                timeframe: timeframe,
                                strategyID: definition.id,
                                candleOpenTime: latestCandle.openTime,
                                evaluation: candidate.map { .signal($0.signal) } ?? .noSignal
                            ))
                        } catch {
                            failures.append(PaperMonitorFailure(
                                symbol: symbol,
                                timeframe: timeframe,
                                strategyID: definition.id,
                                message: String(describing: error)
                            ))
                        }
                    }
                } catch is CancellationError {
                    return PaperMonitorRunResult(evaluations: evaluations, failures: failures)
                } catch {
                    failures.append(PaperMonitorFailure(
                        symbol: symbol,
                        timeframe: timeframe,
                        strategyID: nil,
                        message: String(describing: error)
                    ))
                }
            }
        }

        do {
            try recordPortfolioDecision(
                candidates: candidates,
                openPositions: openPositions,
                accountEquity: accountEquity
            )
        } catch {
            failures.append(PaperMonitorFailure(
                symbol: candidates.first?.signal.symbol ?? openPositions.first?.symbol ?? watchlist.first ?? FuturesSymbol("UNKNOWN"),
                timeframe: candidates.first?.timeframe ?? .fifteenMinutes,
                strategyID: candidates.first?.signal.strategyID,
                message: String(describing: error)
            ))
        }

        return PaperMonitorRunResult(evaluations: evaluations, failures: failures)
    }

    private func recordPortfolioDecision(
        candidates: [PaperTradeCandidate],
        openPositions: [PositionSnapshot],
        accountEquity: Decimal?
    ) throws {
        let decision = PortfolioSignalSelectionPolicy.decision(
            candidates: candidates,
            openPositions: openPositions,
            accountEquity: accountEquity
        )

        switch decision {
        case .noAction:
            break
        case .enter(let candidate, let reason):
            try paperRunner.recordPaperOrder(candidate, portfolioDecisionReason: reason)
        case .replace(_, let candidate, let reason):
            try paperRunner.recordPaperOrder(candidate, portfolioDecisionReason: "Paper replacement policy. \(reason)")
        case .holdExisting(_, let bestCandidate, let reason):
            try paperRunner.recordPortfolioDecision(
                symbol: bestCandidate.signal.symbol,
                message: "Portfolio signal held: \(reason)"
            )
        }
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
