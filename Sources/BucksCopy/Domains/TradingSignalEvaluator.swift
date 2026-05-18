import Foundation

final class TradingSignalEvaluator {
    private let strategyRegistry: StrategyRegistry
    private let logStore: TradeEventLogStore
    private let confirmationEngine: SignalConfirmationEngine
    private let clock: Clock

    init(
        strategyRegistry: StrategyRegistry,
        logStore: TradeEventLogStore,
        confirmationEngine: SignalConfirmationEngine = SignalConfirmationEngine(),
        clock: Clock = SystemClock()
    ) {
        self.strategyRegistry = strategyRegistry
        self.logStore = logStore
        self.confirmationEngine = confirmationEngine
        self.clock = clock
    }

    func makeCandidate(
        symbol: FuturesSymbol,
        watchlist: [FuturesSymbol],
        timeframe: CandleTimeframe,
        candleOpenTime: Date,
        candles: [Candle],
        config: StrategyConfig
    ) throws -> TradeCandidate? {
        try makeCandidate(
            symbol: symbol,
            watchlist: watchlist,
            timeframe: timeframe,
            candleOpenTime: candleOpenTime,
            candles: candles,
            config: config,
            includesLiveFormingCandle: false
        )
    }

    func makeCandidate(
        symbol: FuturesSymbol,
        watchlist: [FuturesSymbol],
        timeframe: CandleTimeframe,
        candleOpenTime: Date,
        candles: [Candle],
        config: StrategyConfig,
        includesLiveFormingCandle: Bool = false
    ) throws -> TradeCandidate? {
        guard watchlist.contains(symbol) else {
            throw TradingDomainError.selectedSymbolNotInWatchlist(symbol)
        }
        guard let strategy = strategyRegistry.strategy(id: config.strategyID) else {
            throw TradingDomainError.strategyNotFound(config.strategyID)
        }

        let context = StrategyContext(
            symbol: symbol,
            timeframe: timeframe,
            closedCandles: includesLiveFormingCandle ? candles : candles.filter(\.isClosed),
            generatedAt: clock.now
        )
        let evaluation = try strategy.evaluate(context, config: config)

        switch evaluation {
        case .noSignal:
            break
        case .signal(let signal):
            let confirmationDecision: SignalConfirmationDecision
            if let profile = SignalConfirmationProfile.researchDefault(
                strategyID: config.strategyID,
                timeframe: timeframe
            ) {
                confirmationDecision = confirmationEngine.decision(
                    for: signal,
                    context: context,
                    config: config.signalConfirmation,
                    profile: profile
                )
            } else {
                confirmationDecision = confirmationEngine.decision(
                    for: signal,
                    context: context,
                    config: config.signalConfirmation
                )
            }
            guard confirmationDecision.isAllowed else {
                try logStore.append(TradeEventLog(
                    timestamp: clock.now,
                    category: .signal,
                    severity: .warning,
                    symbol: signal.symbol,
                    message: confirmationDecision.reason
                ))
                return nil
            }

            let confirmedSignal = signal.addingConfirmation(confirmationDecision.score)
            let riskDecision = StrategyRiskPolicy.decision(
                for: confirmedSignal,
                leverage: config.leverage,
                maximumRiskPerTradePercent: config.maximumRiskPerTradePercent *
                    confirmationDecision.maximumRiskPerTradeMultiplier,
                maximumPositionMarginPercent: config.maximumPositionMarginPercent,
                decidedAt: clock.now
            )
            guard riskDecision.isAllowed else {
                try logStore.append(TradeEventLog(
                    timestamp: clock.now,
                    category: .risk,
                    severity: .warning,
                    symbol: confirmedSignal.symbol,
                    message: riskDecision.reason
                ))
                return nil
            }

            return TradeCandidate(
                signal: confirmedSignal,
                timeframe: timeframe,
                candleOpenTime: candleOpenTime,
                leverage: config.leverage,
                riskDecision: riskDecision
            )
        }

        return nil
    }

    func recordLiveOrder(
        _ candidate: TradeCandidate,
        receipt: LiveOrderReceipt,
        protectionReceipts: [ExchangeProtectionReceipt],
        portfolioDecisionReason: String? = nil
    ) throws {
        let confirmedSignal = candidate.signal
        let riskDecision = candidate.riskDecision
        let decisionText = portfolioDecisionReason.map { " Portfolio decision: \($0)." } ?? ""
        let entryOrderText = TradeLogRedaction.identifier(receipt.orderID)
        let protectionText = protectionReceipts
            .map { "\($0.kind.rawValue)#\(TradeLogRedaction.identifier($0.orderID))" }
            .joined(separator: ", ")
        let entryPrice = receipt.averagePrice ?? confirmedSignal.entryPrice
        let sideText = confirmedSignal.side == .buy ? "매수" : "매도"
        let sizeText = receipt.filledSize.map(DecimalText.string) ?? "-"
        let rewardRiskText = "\(confirmedSignal.plannedRewardRiskRatio?.riskText ?? "-"):1"
        let marginText = "\((riskDecision.positionMarginRatio * 100).riskText)%"
        let accountRiskText = "\(riskDecision.accountRiskPercent.riskText)%"

        try logStore.append(TradeEventLog(
            timestamp: clock.now,
            category: .liveOrder,
            symbol: confirmedSignal.symbol,
            message: "Live \(confirmedSignal.side.rawValue) order submitted by \(confirmedSignal.strategyID) on \(candidate.timeframe.rawValue). Order \(entryOrderText), size \(sizeText), entry \(DecimalText.string(entryPrice)), stop loss \(DecimalText.string(confirmedSignal.stopLoss)), TP1 \(DecimalText.string(confirmedSignal.partialTakeProfit)) 50%, TP2 \(DecimalText.string(confirmedSignal.takeProfit)) 50%, TP1 이후 SL \(DecimalText.string(confirmedSignal.profitLockStopLossAfterPartialTakeProfit)), leverage \(candidate.leverage)x, margin \(marginText), account risk \(accountRiskText), reward/risk \(rewardRiskText), protection \(protectionText). Reason: \(confirmedSignal.reason).\(decisionText)",
            metadata: TradeLogMetadata(
                title: "\(confirmedSignal.symbol.rawValue) \(candidate.timeframe.rawValue) \(sideText) 진입",
                subtitle: "\(confirmedSignal.strategyID) 시그널로 \(DecimalText.string(entryPrice))에 실거래 진입했습니다.",
                tags: [
                    TradeLogTag(label: "LIVE", tone: .success),
                    TradeLogTag(label: candidate.timeframe.rawValue, tone: .accent),
                    TradeLogTag(label: sideText, tone: confirmedSignal.side == .buy ? .success : .warning),
                    TradeLogTag(label: "\(candidate.leverage)x", tone: .accent),
                    TradeLogTag(label: confirmedSignal.strategyID, tone: .neutral)
                ],
                details: [
                    TradeLogDetail(label: "진입가", value: DecimalText.string(entryPrice), tone: .accent),
                    TradeLogDetail(label: "주문수량", value: sizeText),
                    TradeLogDetail(label: "손절가", value: DecimalText.string(confirmedSignal.stopLoss), tone: .danger),
                    TradeLogDetail(label: "TP1", value: "\(DecimalText.string(confirmedSignal.partialTakeProfit)) / 50%", tone: .success),
                    TradeLogDetail(label: "TP2", value: "\(DecimalText.string(confirmedSignal.takeProfit)) / 50%", tone: .success),
                    TradeLogDetail(label: "TP1 이후 SL", value: DecimalText.string(confirmedSignal.profitLockStopLossAfterPartialTakeProfit), tone: .success),
                    TradeLogDetail(label: "손익비", value: rewardRiskText, tone: .success),
                    TradeLogDetail(label: "레버리지", value: "\(candidate.leverage)x", tone: .accent),
                    TradeLogDetail(label: "투입 증거금", value: marginText),
                    TradeLogDetail(label: "계좌 최대손실", value: accountRiskText, tone: .warning),
                    TradeLogDetail(label: "주문 ID", value: entryOrderText),
                    TradeLogDetail(label: "보호주문", value: protectionText.isEmpty ? "-" : protectionText),
                    TradeLogDetail(label: "시그널 근거", value: confirmedSignal.reason),
                    TradeLogDetail(label: "선정 로직", value: portfolioDecisionReason ?? "신규 진입 후보 선택")
                ]
            )
        ))
    }

    func recordPortfolioDecision(
        symbol: FuturesSymbol?,
        message: String
    ) throws {
        try logStore.append(TradeEventLog(
            timestamp: clock.now,
            category: .signal,
            symbol: symbol,
            message: message
        ))
    }
}
