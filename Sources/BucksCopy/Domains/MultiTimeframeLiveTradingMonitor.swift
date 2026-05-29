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
    private let clock: Clock
    private let candleLimit: Int
    private let remoteRefreshAttempts: Int
    private let remoteRefreshRetryDelayNanoseconds: UInt64
    private var evaluatedCandleKeys: Set<String> = []

    init(
        candleRepository: CandleRepository,
        candleBackfillRepository: CandleBackfillRepository?,
        signalEvaluator: TradingSignalEvaluator,
        liveExecutor: LiveTradeExecutor,
        strategyRegistry: StrategyRegistry,
        clock: Clock = SystemClock(),
        candleLimit: Int = 500,
        remoteRefreshAttempts: Int = 3,
        remoteRefreshRetryDelayNanoseconds: UInt64 = 500_000_000
    ) {
        self.candleRepository = candleRepository
        self.candleBackfillRepository = candleBackfillRepository
        self.signalEvaluator = signalEvaluator
        self.liveExecutor = liveExecutor
        self.strategyRegistry = strategyRegistry
        self.clock = clock
        self.candleLimit = candleLimit
        self.remoteRefreshAttempts = max(remoteRefreshAttempts, 1)
        self.remoteRefreshRetryDelayNanoseconds = remoteRefreshRetryDelayNanoseconds
    }

    func primeLatestClosedCandles(watchlist: [FuturesSymbol]) async -> LiveMonitorPrimingResult {
        var primedCount = 0
        var failures: [LiveMonitorFailure] = []

        for symbol in watchlist {
            for timeframe in CandleTimeframe.allCases {
                do {
                    try Task.checkCancellation()
                    let definitions = strategyRegistry.definitions(
                        recommendedFor: timeframe,
                        symbol: symbol
                    )
                    guard definitions.isEmpty == false else { continue }

                    let candles = try await latestCandles(
                        symbol: symbol,
                        timeframe: timeframe,
                        includesFormingCandle: false
                    )
                    guard let latestCandle = candles.last else { continue }

                    for definition in definitions {
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
                        message: publicFailureMessage(error)
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
        accountAvailable: Decimal? = nil,
        contractSpecs: [ContractSpec] = []
    ) async -> LiveMonitorRunResult {
        var evaluations: [LiveMonitorEvaluation] = []
        var failures: [LiveMonitorFailure] = []
        var candidates: [TradeCandidate] = []

        do {
            let recentLogs = try signalEvaluator.recentLogs(limit: 1_000)
            let holdingPeriodExits = PositionHoldingPeriodExitPolicy.expiredPositions(
                openPositions: openPositions,
                recentLogs: recentLogs,
                strategyRegistry: strategyRegistry,
                now: clock.now
            )
            if holdingPeriodExits.isEmpty == false {
                let executionResult = try await liveExecutor.closeHoldingPeriodExits(holdingPeriodExits)
                return LiveMonitorRunResult(
                    evaluations: evaluations,
                    failures: failures,
                    executionResult: executionResult
                )
            }
        } catch {
            failures.append(LiveMonitorFailure(
                symbol: openPositions.first?.symbol ?? watchlist.first ?? FuturesSymbol("UNKNOWN"),
                timeframe: .fifteenMinutes,
                strategyID: nil,
                message: publicFailureMessage(error)
            ))
            return LiveMonitorRunResult(
                evaluations: evaluations,
                failures: failures,
                executionResult: nil
            )
        }

        for symbol in watchlist {
            for timeframe in CandleTimeframe.allCases {
                do {
                    try Task.checkCancellation()
                    let definitions = strategyRegistry.definitions(
                        recommendedFor: timeframe,
                        symbol: symbol
                    )
                    guard definitions.isEmpty == false else { continue }

                    let candles = try await latestCandles(
                        symbol: symbol,
                        timeframe: timeframe,
                        includesFormingCandle: true
                    )
                    guard let latestCandle = candles.last else { continue }
                    let latestCandleIsForming = isFormingForLive(latestCandle, timeframe: timeframe)

                    for definition in definitions {
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
                                config: config,
                                includesLiveFormingCandle: true
                            )
                            if let candidate {
                                evaluatedCandleKeys.insert(key)
                                candidates.append(candidate)
                            } else if latestCandleIsForming == false {
                                evaluatedCandleKeys.insert(key)
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
                                message: publicFailureMessage(error)
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
                        message: publicFailureMessage(error)
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
                accountAvailable: accountAvailable,
                contractSpecs: contractSpecs
            )
        } catch {
            failures.append(LiveMonitorFailure(
                symbol: candidates.first?.signal.symbol ?? openPositions.first?.symbol ?? watchlist.first ?? FuturesSymbol("UNKNOWN"),
                timeframe: candidates.first?.timeframe ?? .fifteenMinutes,
                strategyID: candidates.first?.signal.strategyID,
                message: publicFailureMessage(error)
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
        accountAvailable: Decimal?,
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
            accountAvailable: accountAvailable,
            contractSpecs: contractSpecs,
            signalEvaluator: signalEvaluator
        )
    }

    private func latestCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        includesFormingCandle: Bool
    ) async throws -> [Candle] {
        var backfillError: Error?
        if let candleBackfillRepository {
            do {
                let remoteCandles = try await fetchRemoteCandlesWithRetry(
                    from: candleBackfillRepository,
                    symbol: symbol,
                    timeframe: timeframe
                )
                if remoteCandles.isEmpty == false {
                    try candleRepository.upsertCandles(remoteCandles)
                }
            } catch {
                backfillError = error
            }
        }

        let storedCandles = try candleRepository.loadCandles(
            symbol: symbol,
            timeframe: timeframe,
            limit: candleLimit
        )
        .filter {
            isUsableForLive($0, timeframe: timeframe, includesFormingCandle: includesFormingCandle)
        }
        .sorted { $0.openTime < $1.openTime }
        let localCandles = try candlesIncludingSynthesizedFormingCandle(
            storedCandles,
            symbol: symbol,
            timeframe: timeframe,
            includesFormingCandle: includesFormingCandle
        )

        if let backfillError,
           isLocalFallbackFresh(localCandles, timeframe: timeframe) == false {
            throw backfillError
        }

        return localCandles
    }

    private func candlesIncludingSynthesizedFormingCandle(
        _ candles: [Candle],
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        includesFormingCandle: Bool
    ) throws -> [Candle] {
        guard includesFormingCandle,
              timeframe != .fifteenMinutes,
              let synthesized = try synthesizeFormingCandleFromFifteenMinutes(
                symbol: symbol,
                timeframe: timeframe
              ) else {
            return candles
        }

        let merged = candles
            .filter { $0.openTime != synthesized.openTime }
            + [synthesized]
        return Array(merged.sorted { $0.openTime < $1.openTime }.suffix(candleLimit))
    }

    private func synthesizeFormingCandleFromFifteenMinutes(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) throws -> Candle? {
        let openTime = bucketOpenTime(containing: clock.now, timeframe: timeframe)
        guard openTime.addingTimeInterval(timeframe.duration) > clock.now else {
            return nil
        }

        let requiredSubCandles = Int(ceil(timeframe.duration / CandleTimeframe.fifteenMinutes.duration))
        let fifteenMinuteCandles = try candleRepository.loadCandles(
            symbol: symbol,
            timeframe: .fifteenMinutes,
            limit: max(requiredSubCandles + 4, 8)
        )
        .filter {
            $0.openTime >= openTime &&
                $0.openTime < openTime.addingTimeInterval(timeframe.duration) &&
                isUsableForLive($0, timeframe: .fifteenMinutes, includesFormingCandle: true)
        }
        .sorted { $0.openTime < $1.openTime }

        guard let first = fifteenMinuteCandles.first,
              let latest = fifteenMinuteCandles.last,
              isLocalFallbackFresh(fifteenMinuteCandles, timeframe: .fifteenMinutes) else {
            return nil
        }

        return Candle(
            productType: .usdtFutures,
            symbol: symbol,
            timeframe: timeframe,
            openTime: openTime,
            open: first.open,
            high: fifteenMinuteCandles.map(\.high).max() ?? first.high,
            low: fifteenMinuteCandles.map(\.low).min() ?? first.low,
            close: latest.close,
            volume: fifteenMinuteCandles.reduce(Decimal(0)) { $0 + $1.volume },
            isClosed: false
        )
    }

    private func fetchRemoteCandlesWithRetry(
        from repository: CandleBackfillRepository,
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) async throws -> [Candle] {
        var latestError: Error?
        for attempt in 0..<remoteRefreshAttempts {
            do {
                try Task.checkCancellation()
                return try await repository.fetchCandles(
                    symbol: symbol,
                    timeframe: timeframe,
                    limit: candleLimit
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                latestError = error
                guard attempt < remoteRefreshAttempts - 1 else {
                    break
                }
                if remoteRefreshRetryDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: remoteRefreshRetryDelayNanoseconds)
                }
            }
        }

        throw latestError ?? URLError(.timedOut)
    }

    private func evaluatedKey(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        strategyID: String,
        candleOpenTime: Date
    ) -> String {
        "\(symbol.rawValue):\(timeframe.rawValue):\(strategyID):\(Int(candleOpenTime.timeIntervalSince1970))"
    }

    private func isLocalFallbackFresh(
        _ candles: [Candle],
        timeframe: CandleTimeframe
    ) -> Bool {
        guard let latest = candles.last else { return false }
        let age = clock.now.timeIntervalSince(latest.openTime)
        let maximumAge = timeframe.duration * 2.2
        return age >= 0 && age <= maximumAge
    }

    private func bucketOpenTime(containing date: Date, timeframe: CandleTimeframe) -> Date {
        let offset = exchangeOpenOffset(for: timeframe)
        let duration = timeframe.duration
        let seconds = date.timeIntervalSince1970
        let bucket = floor((seconds - offset) / duration) * duration + offset
        return Date(timeIntervalSince1970: bucket)
    }

    private func exchangeOpenOffset(for timeframe: CandleTimeframe) -> TimeInterval {
        switch timeframe {
        case .fifteenMinutes, .oneHour, .fourHours:
            return 0
        case .twelveHours:
            return 4 * 60 * 60
        case .oneDay:
            return 16 * 60 * 60
        }
    }

    private func isUsableForLive(
        _ candle: Candle,
        timeframe: CandleTimeframe,
        includesFormingCandle: Bool
    ) -> Bool {
        if candle.isClosed,
           candle.openTime.addingTimeInterval(timeframe.duration) <= clock.now {
            return true
        }

        return includesFormingCandle &&
            isFormingForLive(candle, timeframe: timeframe)
    }

    private func isFormingForLive(_ candle: Candle, timeframe: CandleTimeframe) -> Bool {
        candle.openTime <= clock.now &&
            candle.openTime.addingTimeInterval(timeframe.duration) > clock.now
    }

    private func publicFailureMessage(_ error: Error) -> String {
        if let publicError = error as? PublicTradingErrorDescribing {
            return publicError.tradingLogDescription
        }
        if let domainError = error as? TradingDomainError {
            return domainError.description
        }
        if let urlError = error as? URLError {
            return "Network request failed: \(urlError.localizedDescription)"
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Network request failed: \(nsError.localizedDescription)"
        }

        return String(describing: error)
    }
}

enum PositionHoldingPeriodExitPolicy {
    static func expiredPositions(
        openPositions: [PositionSnapshot],
        recentLogs: [TradeEventLog],
        strategyRegistry: StrategyRegistry,
        now: Date
    ) -> [PositionHoldingPeriodExit] {
        let entries = recentLogs
            .compactMap(ManagedPositionEntry.init(log:))
            .sorted { $0.enteredAt > $1.enteredAt }

        return openPositions.compactMap { position in
            guard position.total > 0,
                  position.side != .unknown || position.positionMode == .oneWay,
                  let entry = entries.first(where: { $0.matches(position) }),
                  let definition = strategyRegistry.definition(id: entry.strategyID),
                  let maximumHoldingCandles = definition.defaultConfig.maximumHoldingCandles,
                  maximumHoldingCandles > 0 else {
                return nil
            }

            let elapsed = now.timeIntervalSince(entry.enteredAt)
            guard elapsed >= 0 else { return nil }
            let maximumHoldingDuration = entry.timeframe.duration * Double(maximumHoldingCandles)
            guard elapsed >= maximumHoldingDuration else { return nil }

            let elapsedCandles = max(Int(floor(elapsed / entry.timeframe.duration)), maximumHoldingCandles)
            let reason = [
                "최대 보유 기간 \(maximumHoldingCandles)봉(\(durationText(maximumHoldingDuration))) 경과",
                "진입 후 \(durationText(elapsed)) 동안 TP2/SL 종료가 확정되지 않아 \(entry.strategyID) \(entry.timeframe.rawValue) 진입 가설을 만료 처리",
                "시장가 청산으로 포지션 시간을 리셋"
            ].joined(separator: ": ")

            return PositionHoldingPeriodExit(
                position: position,
                strategyID: entry.strategyID,
                timeframe: entry.timeframe,
                enteredAt: entry.enteredAt,
                maximumHoldingCandles: maximumHoldingCandles,
                elapsedCandles: elapsedCandles,
                reason: reason
            )
        }
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(Int(seconds / 60), 0)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0, hours > 0 {
            return "\(days)일 \(hours)시간"
        }
        if days > 0 {
            return "\(days)일"
        }
        if hours > 0, minutes > 0 {
            return "\(hours)시간 \(minutes)분"
        }
        if hours > 0 {
            return "\(hours)시간"
        }
        return "\(minutes)분"
    }
}

private struct ManagedPositionEntry {
    let symbol: FuturesSymbol
    let side: PositionSide
    let strategyID: String
    let timeframe: CandleTimeframe
    let enteredAt: Date

    init?(log: TradeEventLog) {
        guard log.category == .liveOrder,
              log.message.contains("order submitted") || log.metadata?.title.contains("진입") == true,
              let symbol = log.symbol,
              let side = Self.side(from: log),
              let strategyID = Self.strategyID(from: log),
              let timeframe = Self.timeframe(from: log) else {
            return nil
        }

        self.symbol = symbol
        self.side = side
        self.strategyID = strategyID
        self.timeframe = timeframe
        self.enteredAt = log.timestamp
    }

    func matches(_ position: PositionSnapshot) -> Bool {
        guard position.symbol == symbol else { return false }
        if position.positionMode == .oneWay {
            return true
        }
        return position.side == side
    }

    private static func side(from log: TradeEventLog) -> PositionSide? {
        let tagLabels = log.metadata?.tags.map(\.label) ?? []
        if tagLabels.contains("매수") || log.message.contains("Live buy order") {
            return .long
        }
        if tagLabels.contains("매도") || log.message.contains("Live sell order") {
            return .short
        }
        return nil
    }

    private static func timeframe(from log: TradeEventLog) -> CandleTimeframe? {
        if let value = detailValue(in: log.metadata, for: "시간봉"),
           let timeframe = CandleTimeframe(rawValue: value) {
            return timeframe
        }
        return log.metadata?.tags.compactMap { CandleTimeframe(rawValue: $0.label) }.first
    }

    private static func strategyID(from log: TradeEventLog) -> String? {
        if let value = detailValue(in: log.metadata, for: "매매전략"),
           value.isEmpty == false {
            return value
        }

        let excludedTags = Set(
            ["LIVE", "START", "STOP", "매수", "매도", "LONG", "SHORT", "청산"] +
                CandleTimeframe.allCases.map(\.rawValue)
        )
        return log.metadata?.tags.map(\.label).first { label in
            !excludedTags.contains(label) && !label.hasSuffix("x")
        }
    }

    private static func detailValue(
        in metadata: TradeLogMetadata?,
        for label: String
    ) -> String? {
        metadata?.details.first { $0.label == label }?.value
    }
}
