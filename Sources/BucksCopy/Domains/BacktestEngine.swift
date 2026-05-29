import Foundation

enum BacktestEngineError: Error, Equatable {
    case insufficientCandles(required: Int, actual: Int)
    case invalidInitialCapital(Decimal)
}

struct BacktestEngine {
    private let strategyRegistry: StrategyRegistry
    private let confirmationEngine: SignalConfirmationEngine
    private let minimumWarmupCandles = 40
    private static let confirmationOptimizationThresholds: [Decimal] = [
        -5, 0, 5, 10, 15, 20, 22, 25, 30, 35, 40, 45, 50
    ]

    init(
        strategyRegistry: StrategyRegistry,
        confirmationEngine: SignalConfirmationEngine = SignalConfirmationEngine()
    ) {
        self.strategyRegistry = strategyRegistry
        self.confirmationEngine = confirmationEngine
    }

    func run(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        candles: [Candle],
        config: StrategyConfig,
        initialCapital: Decimal = 100,
        completedAt: Date = Date()
    ) throws -> BacktestResult {
        try run(
            symbol: symbol,
            timeframe: timeframe,
            candles: candles,
            config: config,
            initialCapital: initialCapital,
            completedAt: completedAt,
            confirmationProfile: nil
        )
    }

    private func run(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        candles: [Candle],
        config: StrategyConfig,
        initialCapital: Decimal,
        completedAt: Date,
        confirmationProfile: SignalConfirmationProfile?
    ) throws -> BacktestResult {
        guard let strategy = strategyRegistry.strategy(id: config.strategyID) else {
            throw TradingDomainError.strategyNotFound(config.strategyID)
        }

        guard initialCapital > 0 else {
            throw BacktestEngineError.invalidInitialCapital(initialCapital)
        }

        let closedCandles = candles
            .filter { $0.symbol == symbol && $0.timeframe == timeframe && $0.isClosed }
            .sorted { $0.openTime < $1.openTime }

        guard closedCandles.count >= minimumWarmupCandles else {
            throw BacktestEngineError.insufficientCandles(
                required: minimumWarmupCandles,
                actual: closedCandles.count
            )
        }

        var trades: [BacktestTrade] = []
        var skippedSignals = 0
        var blockedSignals = 0
        var openSignals = 0
        var confirmationBlockedSignals = 0
        var history: [Candle] = []
        var currentBalance = initialCapital
        var peakBalance = initialCapital
        var maxDrawdownPercent: Decimal = 0
        var blockedSignalReasonCounts: [String: Int] = [:]
        var confirmationBlockReasonCounts: [String: Int] = [:]
        var confirmationScoreTotal: Decimal = 0
        var confirmationScoreCount = 0
        var scoreBucketAccumulators: [SignalConfirmationScoreBucket: ScoreBucketAccumulator] = [:]
        history.reserveCapacity(closedCandles.count)

        var index = 0
        while index < closedCandles.count {
            try Task.checkCancellation()
            history.append(closedCandles[index])

            guard history.count >= minimumWarmupCandles else {
                index += 1
                continue
            }

            let context = StrategyContext(
                symbol: symbol,
                timeframe: timeframe,
                closedCandles: history,
                generatedAt: closedCandles[index].openTime
            )

            let evaluation = try strategy.evaluate(context, config: config)
            guard case .signal(let signal) = evaluation else {
                index += 1
                continue
            }

            let confirmationDecision = confirmationDecision(
                for: signal,
                context: context,
                config: config.signalConfirmation,
                profile: confirmationProfile
            )
            if let score = confirmationDecision.score {
                confirmationScoreTotal += score.totalScore
                confirmationScoreCount += 1
                let bucket = SignalConfirmationScoreBucket.bucket(for: score.totalScore)
                scoreBucketAccumulators[bucket, default: ScoreBucketAccumulator()]
                    .recordSignal(score: score.totalScore)
            }

            guard confirmationDecision.isAllowed else {
                confirmationBlockedSignals += 1
                confirmationBlockReasonCounts[confirmationDecision.blockSummaryReason, default: 0] += 1
                if let score = confirmationDecision.score {
                    let bucket = SignalConfirmationScoreBucket.bucket(for: score.totalScore)
                    scoreBucketAccumulators[bucket, default: ScoreBucketAccumulator()]
                        .recordConfirmationBlocked()
                }
                index += 1
                continue
            }

            let confirmedSignal = signal.addingConfirmation(confirmationDecision.score)

            let riskDecision = StrategyRiskPolicy.decision(
                for: confirmedSignal,
                leverage: config.leverage,
                maximumRiskPerTradePercent: config.maximumRiskPerTradePercent *
                    confirmationDecision.maximumRiskPerTradeMultiplier,
                maximumPositionMarginPercent: config.maximumPositionMarginPercent,
                decidedAt: closedCandles[index].openTime
            )

            guard riskDecision.isAllowed else {
                blockedSignals += 1
                blockedSignalReasonCounts[blockSummaryReason(from: riskDecision.reason), default: 0] += 1
                if let score = confirmationDecision.score {
                    let bucket = SignalConfirmationScoreBucket.bucket(for: score.totalScore)
                    scoreBucketAccumulators[bucket, default: ScoreBucketAccumulator()]
                        .recordRiskBlocked()
                }
                index += 1
                continue
            }

            guard let exit = simulatedExit(
                signal: confirmedSignal,
                timeframe: timeframe,
                candles: closedCandles,
                startingAt: index + 1,
                leverage: config.leverage,
                positionMarginRatio: riskDecision.positionMarginRatio,
                accountRiskPercent: riskDecision.accountRiskPercent,
                startingBalance: currentBalance,
                maximumHoldingCandles: config.maximumHoldingCandles
            ) else {
                openSignals += 1
                if let score = confirmationDecision.score {
                    let bucket = SignalConfirmationScoreBucket.bucket(for: score.totalScore)
                    scoreBucketAccumulators[bucket, default: ScoreBucketAccumulator()]
                        .recordOpen()
                }
                index += 1
                continue
            }

            trades.append(exit.trade)
            if let score = confirmationDecision.score {
                let bucket = SignalConfirmationScoreBucket.bucket(for: score.totalScore)
                scoreBucketAccumulators[bucket, default: ScoreBucketAccumulator()]
                    .recordTrade(exit.trade)
            }
            currentBalance = exit.trade.endingBalance
            peakBalance = Swift.max(peakBalance, currentBalance)
            if peakBalance > 0 {
                let drawdownPercent = (peakBalance - currentBalance) / peakBalance * 100
                maxDrawdownPercent = Swift.max(maxDrawdownPercent, drawdownPercent)
            }

            if exit.exitIndex > index {
                history.append(contentsOf: closedCandles[(index + 1)...exit.exitIndex])
            }
            index = max(exit.exitIndex + 1, index + 1)
        }

        let winningTrades = trades.filter { $0.outcome == .win }.count
        let losingTrades = trades.filter { $0.outcome == .loss }.count
        skippedSignals += openSignals

        return BacktestResult(
            symbol: symbol,
            timeframe: timeframe,
            strategyID: config.strategyID,
            leverage: config.leverage,
            totalCandles: closedCandles.count,
            totalTrades: trades.count,
            winningTrades: winningTrades,
            losingTrades: losingTrades,
            skippedSignals: skippedSignals,
            blockedSignals: blockedSignals,
            openSignals: openSignals,
            confirmationBlockedSignals: confirmationBlockedSignals,
            initialCapital: initialCapital,
            finalBalance: currentBalance,
            netReturnPercent: compoundReturnPercent(initialCapital: initialCapital, finalBalance: currentBalance),
            maxDrawdownPercent: maxDrawdownPercent,
            averageRewardRiskRatio: trades.averageRewardRiskRatio,
            profitFactor: trades.profitFactor,
            blockedSignalSummaries: blockedSignalReasonCounts
                .map { BacktestBlockedSignalSummary(reason: $0.key, count: $0.value) }
                .sorted {
                    if $0.count == $1.count {
                        return $0.reason < $1.reason
                    }
                    return $0.count > $1.count
                },
            confirmationBlockedSignalSummaries: confirmationBlockReasonCounts
                .map { BacktestBlockedSignalSummary(reason: $0.key, count: $0.value) }
                .sorted {
                    if $0.count == $1.count {
                        return $0.reason < $1.reason
                    }
                    return $0.count > $1.count
                },
            averageConfirmationScore: confirmationScoreCount > 0
                ? confirmationScoreTotal / Decimal(confirmationScoreCount)
                : 0,
            confirmationScoreBuckets: SignalConfirmationScoreBucket.allCases.compactMap { bucket in
                scoreBucketAccumulators[bucket]?.result(
                    bucket: bucket,
                    initialCapital: initialCapital
                )
            },
            trades: trades,
            completedAt: completedAt
        )
    }

    func runSignalConfirmationComparison(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        candles: [Candle],
        config: StrategyConfig,
        initialCapital: Decimal = 100,
        completedAt: Date = Date()
    ) throws -> BacktestComparisonResult {
        if let profile = SignalConfirmationProfile.researchDefault(
            strategyID: config.strategyID,
            timeframe: timeframe
        ) {
            return try runResearchProfileComparison(
                symbol: symbol,
                timeframe: timeframe,
                candles: candles,
                config: config,
                profile: profile,
                initialCapital: initialCapital,
                completedAt: completedAt
            )
        }

        var disabledConfig = config
        disabledConfig.signalConfirmation.mode = .off

        var observedConfig = config
        observedConfig.signalConfirmation.mode = .observe
        if observedConfig.signalConfirmation.requiredScore <= 0 {
            observedConfig.signalConfirmation.requiredScore = SignalConfirmationConfig.optimizedDefault.requiredScore
        }

        var gateConfig = config
        gateConfig.signalConfirmation.mode = .gate
        if gateConfig.signalConfirmation.requiredScore <= 0 {
            gateConfig.signalConfirmation.requiredScore = SignalConfirmationConfig.optimizedDefault.requiredScore
        }

        let withoutSignalConfirmation = try run(
            symbol: symbol,
            timeframe: timeframe,
            candles: candles,
            config: disabledConfig,
            initialCapital: initialCapital,
            completedAt: completedAt
        )
        let withSignalConfirmation = try run(
            symbol: symbol,
            timeframe: timeframe,
            candles: candles,
            config: gateConfig,
            initialCapital: initialCapital,
            completedAt: completedAt
        )
        let observedSignalConfirmation = try run(
            symbol: symbol,
            timeframe: timeframe,
            candles: candles,
            config: observedConfig,
            initialCapital: initialCapital,
            completedAt: completedAt
        )
        let optimizationReport = try signalConfirmationOptimizationReport(
            symbol: symbol,
            timeframe: timeframe,
            candles: candles,
            config: gateConfig,
            baseline: withoutSignalConfirmation,
            initialCapital: initialCapital,
            completedAt: completedAt
        )
        return BacktestComparisonResult(
            withoutSignalConfirmation: withoutSignalConfirmation,
            observedSignalConfirmation: observedSignalConfirmation,
            withSignalConfirmation: withSignalConfirmation,
            optimizationReport: optimizationReport
        )
    }

    private func runResearchProfileComparison(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        candles: [Candle],
        config: StrategyConfig,
        profile: SignalConfirmationProfile,
        initialCapital: Decimal,
        completedAt: Date
    ) throws -> BacktestComparisonResult {
        var disabledConfig = config
        disabledConfig.signalConfirmation.mode = .off

        var observedConfig = config
        observedConfig.signalConfirmation.mode = .observe
        observedConfig.signalConfirmation.requiredScore = 0

        var appliedConfig = config
        appliedConfig.signalConfirmation.mode = .gate
        appliedConfig.signalConfirmation.requiredScore = 0

        let withoutSignalConfirmation = try run(
            symbol: symbol,
            timeframe: timeframe,
            candles: candles,
            config: disabledConfig,
            initialCapital: initialCapital,
            completedAt: completedAt
        )
        let observedSignalConfirmation = try run(
            symbol: symbol,
            timeframe: timeframe,
            candles: candles,
            config: observedConfig,
            initialCapital: initialCapital,
            completedAt: completedAt,
            confirmationProfile: profile
        )
        let withSignalConfirmation = try run(
            symbol: symbol,
            timeframe: timeframe,
            candles: candles,
            config: appliedConfig,
            initialCapital: initialCapital,
            completedAt: completedAt,
            confirmationProfile: profile
        )

        return BacktestComparisonResult(
            withoutSignalConfirmation: withoutSignalConfirmation,
            observedSignalConfirmation: observedSignalConfirmation,
            withSignalConfirmation: withSignalConfirmation,
            optimizationReport: BacktestSignalConfirmationOptimizationReport(
                minimumTradeCount: Swift.max(1, withoutSignalConfirmation.totalTrades / 3),
                recommendedMode: profile.isActive ? .gate : .off,
                recommendedRequiredScore: nil,
                reason: profile.inactiveReason ?? "전용 보조지표 프로파일 적용: \(profile.name)",
                candidates: []
            )
        )
    }

    private func signalConfirmationOptimizationReport(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        candles: [Candle],
        config: StrategyConfig,
        baseline: BacktestResult,
        initialCapital: Decimal,
        completedAt: Date
    ) throws -> BacktestSignalConfirmationOptimizationReport {
        guard baseline.totalTrades > 0 else {
            return BacktestSignalConfirmationOptimizationReport(
                minimumTradeCount: 0,
                recommendedMode: .off,
                recommendedRequiredScore: nil,
                reason: "OFF 기준 거래가 없어 Gate 최적화 불가",
                candidates: []
            )
        }

        let minimumTradeCount = Swift.max(1, baseline.totalTrades / 3)
        let thresholds = uniqueThresholds(
            Self.confirmationOptimizationThresholds + [config.signalConfirmation.requiredScore]
        )

        let candidates = try thresholds.map { threshold in
            var candidateConfig = config
            candidateConfig.signalConfirmation.mode = .gate
            candidateConfig.signalConfirmation.requiredScore = threshold
            let result = try run(
                symbol: symbol,
                timeframe: timeframe,
                candles: candles,
                config: candidateConfig,
                initialCapital: initialCapital,
                completedAt: completedAt
            )

            return BacktestSignalConfirmationOptimizationCandidate(
                requiredScore: threshold,
                totalTrades: result.totalTrades,
                confirmationBlockedSignals: result.confirmationBlockedSignals,
                netReturnPercent: result.netReturnPercent,
                netReturnDeltaPercent: result.netReturnPercent - baseline.netReturnPercent,
                winRatePercent: result.winRatePercent,
                winRateDeltaPercent: result.winRatePercent - baseline.winRatePercent,
                maxDrawdownPercent: result.maxDrawdownPercent,
                maxDrawdownDeltaPercent: result.maxDrawdownPercent - baseline.maxDrawdownPercent
            )
        }

        let rankedCandidates = candidates.sorted { lhs, rhs in
            if lhs.netReturnDeltaPercent == rhs.netReturnDeltaPercent {
                if lhs.maxDrawdownDeltaPercent == rhs.maxDrawdownDeltaPercent {
                    if lhs.totalTrades == rhs.totalTrades {
                        return lhs.requiredScore < rhs.requiredScore
                    }
                    return lhs.totalTrades > rhs.totalTrades
                }
                return lhs.maxDrawdownDeltaPercent < rhs.maxDrawdownDeltaPercent
            }
            return lhs.netReturnDeltaPercent > rhs.netReturnDeltaPercent
        }

        guard let bestCandidate = rankedCandidates.first(where: {
            $0.totalTrades >= minimumTradeCount && $0.netReturnDeltaPercent > 0
        }) else {
            return BacktestSignalConfirmationOptimizationReport(
                minimumTradeCount: minimumTradeCount,
                recommendedMode: .off,
                recommendedRequiredScore: nil,
                reason: "OFF보다 나은 Gate 기준점 후보 없음",
                candidates: rankedCandidates
            )
        }

        return BacktestSignalConfirmationOptimizationReport(
            minimumTradeCount: minimumTradeCount,
            recommendedMode: .gate,
            recommendedRequiredScore: bestCandidate.requiredScore,
            reason: "OFF 대비 \(bestCandidate.netReturnDeltaPercent.percentText) 개선 후보",
            candidates: rankedCandidates
        )
    }

    private func uniqueThresholds(_ thresholds: [Decimal]) -> [Decimal] {
        thresholds.reduce(into: [Decimal]()) { result, threshold in
            guard !result.contains(threshold) else { return }
            result.append(threshold)
        }
        .sorted()
    }

    private func confirmationDecision(
        for signal: StrategySignal,
        context: StrategyContext,
        config: SignalConfirmationConfig,
        profile: SignalConfirmationProfile?
    ) -> SignalConfirmationDecision {
        guard let profile else {
            return confirmationEngine.decision(
                for: signal,
                context: context,
                config: config
            )
        }

        return confirmationEngine.decision(
            for: signal,
            context: context,
            config: config,
            profile: profile
        )
    }

    private func simulatedExit(
        signal: StrategySignal,
        timeframe: CandleTimeframe,
        candles: [Candle],
        startingAt startIndex: Int,
        leverage: Int,
        positionMarginRatio: Decimal,
        accountRiskPercent: Decimal,
        startingBalance: Decimal,
        maximumHoldingCandles: Int?
    ) -> (trade: BacktestTrade, exitIndex: Int)? {
        guard startIndex < candles.count else { return nil }

        let partialTakeProfit = signal.partialTakeProfit
        let profitLockStopLoss = signal.profitLockStopLossAfterPartialTakeProfit
        let maximumHoldingCandles = maximumHoldingCandles.flatMap { $0 > 0 ? $0 : nil }
        var didHitPartialTakeProfit = false

        for index in startIndex..<candles.count {
            let candle = candles[index]
            let heldCandles = index - startIndex + 1
            let activeStopLoss = didHitPartialTakeProfit ? profitLockStopLoss : signal.stopLoss
            let hitStop: Bool
            let hitPartialTakeProfit: Bool
            let hitFinalTakeProfit: Bool

            switch signal.side {
            case .buy:
                hitStop = candle.low <= activeStopLoss
                hitPartialTakeProfit = candle.high >= partialTakeProfit
                hitFinalTakeProfit = candle.high >= signal.takeProfit
            case .sell:
                hitStop = candle.high >= activeStopLoss
                hitPartialTakeProfit = candle.low <= partialTakeProfit
                hitFinalTakeProfit = candle.low <= signal.takeProfit
            }

            if hitStop {
                let legs: [SimulatedExitLeg]
                if didHitPartialTakeProfit {
                    legs = [
                        SimulatedExitLeg(
                            kind: .partialTakeProfit,
                            price: partialTakeProfit,
                            ratio: SplitTakeProfitPlan.partialTakeProfitRatio,
                            exitExecution: .takeProfitLimit
                        ),
                        SimulatedExitLeg(
                            kind: .stopLoss,
                            price: profitLockStopLoss,
                            ratio: SplitTakeProfitPlan.finalTakeProfitRatio,
                            exitExecution: .stopLossMarket
                        )
                    ]
                } else {
                    legs = [
                        SimulatedExitLeg(
                            kind: .stopLoss,
                            price: signal.stopLoss,
                            ratio: 1,
                            exitExecution: .stopLossMarket
                        )
                    ]
                }
                return makeTrade(
                    signal: signal,
                    exitTime: candle.openTime,
                    legs: legs,
                    leverage: leverage,
                    positionMarginRatio: positionMarginRatio,
                    accountRiskPercent: accountRiskPercent,
                    startingBalance: startingBalance,
                    exitIndex: index
                )
            }

            if hitFinalTakeProfit {
                let legs = [
                    SimulatedExitLeg(
                        kind: .partialTakeProfit,
                        price: partialTakeProfit,
                        ratio: SplitTakeProfitPlan.partialTakeProfitRatio,
                        exitExecution: .takeProfitLimit
                    ),
                    SimulatedExitLeg(
                        kind: .finalTakeProfit,
                        price: signal.takeProfit,
                        ratio: SplitTakeProfitPlan.finalTakeProfitRatio,
                        exitExecution: .takeProfitLimit
                    )
                ]
                return makeTrade(
                    signal: signal,
                    exitTime: candle.openTime,
                    legs: legs,
                    leverage: leverage,
                    positionMarginRatio: positionMarginRatio,
                    accountRiskPercent: accountRiskPercent,
                    startingBalance: startingBalance,
                    exitIndex: index
                )
            }

            if hitPartialTakeProfit {
                didHitPartialTakeProfit = true
            }

            if let maximumHoldingCandles,
               heldCandles >= maximumHoldingCandles {
                var legs: [SimulatedExitLeg] = []
                if didHitPartialTakeProfit {
                    legs.append(SimulatedExitLeg(
                        kind: .partialTakeProfit,
                        price: partialTakeProfit,
                        ratio: SplitTakeProfitPlan.partialTakeProfitRatio,
                        exitExecution: .takeProfitLimit
                    ))
                }
                legs.append(SimulatedExitLeg(
                    kind: .timeExit,
                    price: candle.close,
                    ratio: didHitPartialTakeProfit ? SplitTakeProfitPlan.finalTakeProfitRatio : 1,
                    exitExecution: .stopLossMarket
                ))
                return makeTrade(
                    signal: signal,
                    exitTime: candle.openTime,
                    legs: legs,
                    leverage: leverage,
                    positionMarginRatio: positionMarginRatio,
                    accountRiskPercent: accountRiskPercent,
                    startingBalance: startingBalance,
                    exitIndex: index,
                    exitReasonOverride: holdingPeriodExitReason(
                        signal: signal,
                        timeframe: timeframe,
                        maximumHoldingCandles: maximumHoldingCandles,
                        didHitPartialTakeProfit: didHitPartialTakeProfit
                    )
                )
            }
        }

        return nil
    }

    private func makeTrade(
        signal: StrategySignal,
        exitTime: Date,
        legs: [SimulatedExitLeg],
        leverage: Int,
        positionMarginRatio: Decimal,
        accountRiskPercent: Decimal,
        startingBalance: Decimal,
        exitIndex: Int,
        exitReasonOverride: String? = nil
    ) -> (trade: BacktestTrade, exitIndex: Int) {
        let returnPercent = legs.reduce(Decimal(0)) { partial, leg in
            let legPositionMarginRatio = positionMarginRatio * leg.ratio
            let grossReturnPercent = leveragedReturnPercent(
                side: signal.side,
                entryPrice: signal.entryPrice,
                exitPrice: leg.price,
                leverage: leverage,
                positionMarginRatio: legPositionMarginRatio
            )
            return partial + TradingFeePolicy.netLeveragedReturnPercent(
                grossLeveragedReturnPercent: grossReturnPercent,
                exitExecution: leg.exitExecution,
                leverage: leverage,
                positionMarginRatio: legPositionMarginRatio
            )
        }
        let endingBalance = balance(
            startingBalance: startingBalance,
            returnPercent: returnPercent
        )
        let exitPrice = weightedExitPrice(legs)
        let outcome: BacktestTradeOutcome = returnPercent > 0 ? .win : .loss
        let partialFillRatio = fillRatio(legs, kind: .partialTakeProfit)
        let finalFillRatio = fillRatio(legs, kind: .finalTakeProfit)
        let stopFillRatio = fillRatio(legs, kind: .stopLoss)
        let exitReason = exitReasonOverride ?? (partialFillRatio > 0
            ? "\(signal.reason) | TP1 \(signal.partialTakeProfit) 50%, SL 보호 \(signal.profitLockStopLossAfterPartialTakeProfit)"
            : signal.reason)

        let trade = BacktestTrade(
            symbol: signal.symbol,
            side: signal.side,
            entryTime: signal.generatedAt,
            exitTime: exitTime,
            entryPrice: signal.entryPrice,
            stopLoss: signal.stopLoss,
            takeProfit: signal.takeProfit,
            partialTakeProfit: partialFillRatio > 0 ? signal.partialTakeProfit : nil,
            exitPrice: exitPrice,
            outcome: outcome,
            rewardRiskRatio: signal.plannedRewardRiskRatio ?? 0,
            leveragedReturnPercent: returnPercent,
            leveragedStopLossPercent: accountRiskPercent,
            positionMarginRatio: positionMarginRatio,
            accountRiskPercent: accountRiskPercent,
            partialTakeProfitFillRatio: partialFillRatio,
            finalTakeProfitFillRatio: finalFillRatio,
            stopLossFillRatio: stopFillRatio,
            startingBalance: startingBalance,
            endingBalance: endingBalance,
            reason: exitReason
        )
        return (trade, exitIndex)
    }

    private func holdingPeriodExitReason(
        signal: StrategySignal,
        timeframe: CandleTimeframe,
        maximumHoldingCandles: Int,
        didHitPartialTakeProfit: Bool
    ) -> String {
        let partialText = didHitPartialTakeProfit
            ? "TP1 체결 후 잔여 50%가 TP2/SL에 도달하지 않음"
            : "TP1/TP2/SL에 도달하지 않음"
        return "\(signal.reason) | 시간 종료: 최대 보유 \(maximumHoldingCandles)봉(\(timeframe.rawValue)) 경과, \(partialText). 진입 가설이 지연되어 종가 기준 시장가 종료."
    }

    private func weightedExitPrice(_ legs: [SimulatedExitLeg]) -> Decimal {
        let totalRatio = legs.reduce(Decimal(0)) { $0 + $1.ratio }
        guard totalRatio > 0 else { return 0 }
        return legs.reduce(Decimal(0)) { $0 + $1.price * $1.ratio } / totalRatio
    }

    private func fillRatio(
        _ legs: [SimulatedExitLeg],
        kind: SimulatedExitLeg.Kind
    ) -> Decimal {
        legs.filter { $0.kind == kind }.reduce(Decimal(0)) { $0 + $1.ratio }
    }

    private func leveragedReturnPercent(
        side: TradeSide,
        entryPrice: Decimal,
        exitPrice: Decimal,
        leverage: Int,
        positionMarginRatio: Decimal
    ) -> Decimal {
        guard entryPrice > 0 else { return 0 }
        let move: Decimal
        switch side {
        case .buy:
            move = (exitPrice - entryPrice) / entryPrice
        case .sell:
            move = (entryPrice - exitPrice) / entryPrice
        }
        return move * 100 * Decimal(leverage) * positionMarginRatio
    }

    private func balance(
        startingBalance: Decimal,
        returnPercent: Decimal
    ) -> Decimal {
        startingBalance + startingBalance * returnPercent / 100
    }

    private func compoundReturnPercent(
        initialCapital: Decimal,
        finalBalance: Decimal
    ) -> Decimal {
        guard initialCapital > 0 else { return 0 }
        return (finalBalance - initialCapital) / initialCapital * 100
    }

    private func blockSummaryReason(from reason: String) -> String {
        if reason.contains("손익비") {
            return "손익비 2:1 미만"
        }
        if reason.contains("수수료") {
            return "익절폭이 수수료 이하"
        }
        if reason.contains("최대") && reason.contains("10x") {
            return "레버리지 10x 초과"
        }
        if reason.contains("방향") {
            return "가격 방향 오류"
        }
        return reason
    }
}

private extension Array where Element == BacktestTrade {
    var averageRewardRiskRatio: Decimal {
        guard isEmpty == false else { return 0 }
        return reduce(Decimal(0)) { $0 + $1.rewardRiskRatio } / Decimal(count)
    }

    var profitFactor: Decimal {
        let wins = filter { $0.profitLossAmount > 0 }
            .reduce(Decimal(0)) { $0 + $1.profitLossAmount }
        let losses = filter { $0.profitLossAmount < 0 }
            .reduce(Decimal(0)) { $0 + absoluteDecimal($1.profitLossAmount) }
        guard losses > 0 else { return wins > 0 ? 999 : 0 }
        return wins / losses
    }
}

private struct SimulatedExitLeg {
    enum Kind: Equatable {
        case partialTakeProfit
        case finalTakeProfit
        case stopLoss
        case timeExit
    }

    let kind: Kind
    let price: Decimal
    let ratio: Decimal
    let exitExecution: TradingFeePolicy.ExitExecution
}

private struct ScoreBucketAccumulator {
    private(set) var signalCount = 0
    private(set) var tradeCount = 0
    private(set) var winningTrades = 0
    private(set) var losingTrades = 0
    private(set) var confirmationBlockedSignals = 0
    private(set) var riskBlockedSignals = 0
    private(set) var openSignals = 0
    private var scoreTotal: Decimal = 0
    private var netProfitAmount: Decimal = 0

    mutating func recordSignal(score: Decimal) {
        signalCount += 1
        scoreTotal += score
    }

    mutating func recordConfirmationBlocked() {
        confirmationBlockedSignals += 1
    }

    mutating func recordRiskBlocked() {
        riskBlockedSignals += 1
    }

    mutating func recordOpen() {
        openSignals += 1
    }

    mutating func recordTrade(_ trade: BacktestTrade) {
        tradeCount += 1
        switch trade.outcome {
        case .win:
            winningTrades += 1
        case .loss:
            losingTrades += 1
        }
        netProfitAmount += trade.profitLossAmount
    }

    func result(
        bucket: SignalConfirmationScoreBucket,
        initialCapital: Decimal
    ) -> BacktestConfirmationScoreBucket {
        BacktestConfirmationScoreBucket(
            bucket: bucket,
            signalCount: signalCount,
            tradeCount: tradeCount,
            winningTrades: winningTrades,
            losingTrades: losingTrades,
            confirmationBlockedSignals: confirmationBlockedSignals,
            riskBlockedSignals: riskBlockedSignals,
            openSignals: openSignals,
            netProfitAmount: netProfitAmount,
            netReturnPercent: initialCapital > 0 ? netProfitAmount / initialCapital * 100 : 0,
            averageScore: signalCount > 0 ? scoreTotal / Decimal(signalCount) : 0
        )
    }
}
