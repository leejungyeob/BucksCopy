import XCTest
@testable import BucksCopy

final class StrategyTests: XCTestCase {
    func testDefaultRegistryIncludesBuiltInStrategies() {
        let ids = Set(StrategyRegistry().definitions.map(\.id))

        XCTAssertEqual(ids, Set([
            DonchianChannelBreakoutStrategy.identifier,
            ETHOneHourMomentumBurstStrategy.identifier,
            ETHFifteenMinuteVacuumPulseStrategy.identifier,
            TimeSeriesMomentumStrategy.identifier,
            VWMATouchTrendStrategy.identifier,
            BTCFifteenMinutePhaseVacuumReclaimStrategy.identifier,
            BTCFifteenMinuteVacuumPulseStrategy.identifier,
            XOneHourLongStrategy.identifier,
            XOneHourShortStrategy.identifier,
            XFrequencyStrategy.identifier,
            XStrategy.identifier
        ]))
    }

    func testTimeframeRoutingUsesRecommendedStrategies() {
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(for: .fifteenMinutes),
            [
                XStrategy.identifier,
                XFrequencyStrategy.identifier,
                BTCFifteenMinutePhaseVacuumReclaimStrategy.identifier,
                BTCFifteenMinuteVacuumPulseStrategy.identifier,
                ETHFifteenMinuteVacuumPulseStrategy.identifier
            ]
        )
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(for: .oneHour),
            [ETHOneHourMomentumBurstStrategy.identifier]
        )
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(for: .fourHours),
            [DonchianChannelBreakoutStrategy.identifier]
        )
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(for: .twelveHours),
            [
                VWMATouchTrendStrategy.identifier,
                DonchianChannelBreakoutStrategy.identifier,
                TimeSeriesMomentumStrategy.identifier
            ]
        )
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(for: .oneDay),
            [
                VWMATouchTrendStrategy.identifier,
                DonchianChannelBreakoutStrategy.identifier
            ]
        )
    }

    func testTimeframeRoutingBlocksSymbolSpecificInvalidStrategyRoutes() {
        XCTAssertFalse(StrategyTimeframeRouting.isRecommended(
            strategyID: DonchianChannelBreakoutStrategy.identifier,
            for: .fourHours,
            symbol: FuturesSymbol("BTCUSDT")
        ))
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(
                for: .fourHours,
                symbol: FuturesSymbol("BTCUSDT")
            ),
            []
        )
        XCTAssertTrue(StrategyTimeframeRouting.isRecommended(
            strategyID: BTCFifteenMinuteVacuumPulseStrategy.identifier,
            for: .fifteenMinutes,
            symbol: FuturesSymbol("BTCUSDT")
        ))
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(
                for: .fifteenMinutes,
                symbol: FuturesSymbol("BTCUSDT")
            ),
            [
                BTCFifteenMinutePhaseVacuumReclaimStrategy.identifier,
                BTCFifteenMinuteVacuumPulseStrategy.identifier
            ]
        )
        XCTAssertTrue(StrategyTimeframeRouting.isRecommended(
            strategyID: BTCFifteenMinutePhaseVacuumReclaimStrategy.identifier,
            for: .fifteenMinutes,
            symbol: FuturesSymbol("BTCUSDT")
        ))
        XCTAssertFalse(StrategyTimeframeRouting.isRecommended(
            strategyID: XStrategy.identifier,
            for: .fifteenMinutes,
            symbol: FuturesSymbol("BTCUSDT")
        ))
        XCTAssertFalse(StrategyTimeframeRouting.isRecommended(
            strategyID: XFrequencyStrategy.identifier,
            for: .fifteenMinutes,
            symbol: FuturesSymbol("BTCUSDT")
        ))
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(
                for: .twelveHours,
                symbol: FuturesSymbol("BTCUSDT")
            ),
            []
        )
        XCTAssertFalse(StrategyTimeframeRouting.isRecommended(
            strategyID: VWMATouchTrendStrategy.identifier,
            for: .twelveHours,
            symbol: FuturesSymbol("BTCUSDT")
        ))
        XCTAssertFalse(StrategyTimeframeRouting.isRecommended(
            strategyID: DonchianChannelBreakoutStrategy.identifier,
            for: .twelveHours,
            symbol: FuturesSymbol("BTCUSDT")
        ))
        XCTAssertFalse(StrategyTimeframeRouting.isRecommended(
            strategyID: TimeSeriesMomentumStrategy.identifier,
            for: .twelveHours,
            symbol: FuturesSymbol("BTCUSDT")
        ))
        XCTAssertFalse(StrategyTimeframeRouting.isRecommended(
            strategyID: VWMATouchTrendStrategy.identifier,
            for: .oneDay,
            symbol: FuturesSymbol("BTCUSDT")
        ))
        XCTAssertFalse(StrategyTimeframeRouting.isRecommended(
            strategyID: DonchianChannelBreakoutStrategy.identifier,
            for: .oneDay,
            symbol: FuturesSymbol("BTCUSDT")
        ))
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(
                for: .oneDay,
                symbol: FuturesSymbol("BTCUSDT")
            ),
            []
        )
        XCTAssertTrue(StrategyTimeframeRouting.isRecommended(
            strategyID: ETHOneHourMomentumBurstStrategy.identifier,
            for: .oneHour,
            symbol: FuturesSymbol("ETHUSDT")
        ))
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(
                for: .oneHour,
                symbol: FuturesSymbol("ETHUSDT")
            ),
            [ETHOneHourMomentumBurstStrategy.identifier]
        )
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(
                for: .oneHour,
                symbol: FuturesSymbol("BTCUSDT")
            ),
            []
        )
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(
                for: .fifteenMinutes,
                symbol: FuturesSymbol("ETHUSDT")
            ),
            [ETHFifteenMinuteVacuumPulseStrategy.identifier]
        )
        XCTAssertTrue(StrategyTimeframeRouting.isRecommended(
            strategyID: ETHFifteenMinuteVacuumPulseStrategy.identifier,
            for: .fifteenMinutes,
            symbol: FuturesSymbol("ETHUSDT")
        ))
        XCTAssertFalse(StrategyTimeframeRouting.isRecommended(
            strategyID: BTCFifteenMinuteVacuumPulseStrategy.identifier,
            for: .fifteenMinutes,
            symbol: FuturesSymbol("ETHUSDT")
        ))
        XCTAssertFalse(StrategyTimeframeRouting.isRecommended(
            strategyID: BTCFifteenMinutePhaseVacuumReclaimStrategy.identifier,
            for: .fifteenMinutes,
            symbol: FuturesSymbol("ETHUSDT")
        ))
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(
                for: .fourHours,
                symbol: FuturesSymbol("ETHUSDT")
            ),
            []
        )
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(
                for: .twelveHours,
                symbol: FuturesSymbol("ETHUSDT")
            ),
            []
        )
        XCTAssertFalse(StrategyTimeframeRouting.isRecommended(
            strategyID: TimeSeriesMomentumStrategy.identifier,
            for: .twelveHours,
            symbol: FuturesSymbol("ETHUSDT")
        ))
        XCTAssertFalse(StrategyTimeframeRouting.isRecommended(
            strategyID: VWMATouchTrendStrategy.identifier,
            for: .oneDay,
            symbol: FuturesSymbol("ETHUSDT")
        ))
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(
                for: .oneDay,
                symbol: FuturesSymbol("ETHUSDT")
            ),
            []
        )
    }

    func testSignalDraftRequiresStopLossAndTakeProfit() throws {
        let missingStop = StrategySignalDraft(
            strategyID: "fixture",
            symbol: FuturesSymbol("BTCUSDT"),
            side: .buy,
            entryPrice: 100,
            stopLoss: nil,
            takeProfit: 120,
            reason: "fixture",
            generatedAt: Date()
        )

        XCTAssertThrowsError(try missingStop.validated()) { error in
            XCTAssertEqual(error as? TradingDomainError, .missingStopLoss)
        }

        let missingTake = StrategySignalDraft(
            strategyID: "fixture",
            symbol: FuturesSymbol("BTCUSDT"),
            side: .buy,
            entryPrice: 100,
            stopLoss: 90,
            takeProfit: nil,
            reason: "fixture",
            generatedAt: Date()
        )

        XCTAssertThrowsError(try missingTake.validated()) { error in
            XCTAssertEqual(error as? TradingDomainError, .missingTakeProfit)
        }
    }

    func testXStrategyCreatesLongAfterPhaseSpreadReclaim() throws {
        let strategy = XStrategy()
        let candles = xLongCandles()
        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .fifteenMinutes,
                closedCandles: candles,
                generatedAt: candles.last?.openTime ?? Date()
            ),
            config: strategy.definition.defaultConfig
        )

        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected X long signal")
        }

        XCTAssertEqual(signal.strategyID, XStrategy.identifier)
        XCTAssertEqual(signal.side, .buy)
        XCTAssertEqual(signal.entryPrice, Decimal(string: "100.85")!)
        XCTAssertLessThan(signal.stopLoss, signal.entryPrice)
        XCTAssertEqual(signal.plannedRewardRiskRatio, 2)
    }

    func testXStrategyCreatesShortAfterPhaseSpreadReclaim() throws {
        let strategy = XStrategy()
        let candles = xShortCandles()
        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .fifteenMinutes,
                closedCandles: candles,
                generatedAt: candles.last?.openTime ?? Date()
            ),
            config: strategy.definition.defaultConfig
        )

        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected X short signal")
        }

        XCTAssertEqual(signal.strategyID, XStrategy.identifier)
        XCTAssertEqual(signal.side, .sell)
        XCTAssertEqual(signal.entryPrice, Decimal(string: "99.15")!)
        XCTAssertGreaterThan(signal.stopLoss, signal.entryPrice)
        XCTAssertEqual(signal.plannedRewardRiskRatio, 2)
    }

    func testXStrategyRejectsUnsupportedTimeframe() throws {
        let strategy = XStrategy()
        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .oneHour,
                closedCandles: xLongCandles(),
                generatedAt: Date(timeIntervalSince1970: 221 * 900)
            ),
            config: strategy.definition.defaultConfig
        )

        XCTAssertEqual(evaluation, .noSignal)
    }

    func testXFrequencyStrategyCreatesLongAfterThreeBarReclaim() throws {
        let strategy = XFrequencyStrategy()
        let candles = xLongCandles()
        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .fifteenMinutes,
                closedCandles: candles,
                generatedAt: candles.last?.openTime ?? Date()
            ),
            config: strategy.definition.defaultConfig
        )

        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected X-Frequency long signal")
        }

        XCTAssertEqual(signal.strategyID, XFrequencyStrategy.identifier)
        XCTAssertEqual(signal.side, .buy)
        XCTAssertEqual(signal.entryPrice, Decimal(string: "100.85")!)
        XCTAssertLessThan(signal.stopLoss, signal.entryPrice)
        XCTAssertEqual(signal.plannedRewardRiskRatio, 2)
    }

    func testBTCPhaseVacuumReclaimCreatesLongOnlyForBTCFifteenMinutes() throws {
        let strategy = BTCFifteenMinutePhaseVacuumReclaimStrategy()
        var candles = xLongCandles()
        let latest = candles.removeLast()
        candles.append(Candle(
            productType: latest.productType,
            symbol: latest.symbol,
            timeframe: latest.timeframe,
            openTime: latest.openTime,
            open: latest.open,
            high: latest.high,
            low: latest.low,
            close: latest.close,
            volume: 3_000,
            isClosed: latest.isClosed
        ))

        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .fifteenMinutes,
                closedCandles: candles,
                generatedAt: candles.last?.openTime ?? Date()
            ),
            config: strategy.definition.defaultConfig
        )

        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected BTC phase-vacuum long signal")
        }

        XCTAssertEqual(signal.strategyID, BTCFifteenMinutePhaseVacuumReclaimStrategy.identifier)
        XCTAssertEqual(signal.symbol, FuturesSymbol("BTCUSDT"))
        XCTAssertEqual(signal.side, .buy)
        XCTAssertEqual(signal.entryPrice, Decimal(string: "100.85")!)
        XCTAssertLessThan(signal.stopLoss, signal.entryPrice)
        XCTAssertEqual(
            NSDecimalNumber(decimal: signal.plannedRewardRiskRatio ?? 0).doubleValue,
            3.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(strategy.definition.defaultConfig.leverage, 10)
        XCTAssertEqual(strategy.definition.defaultConfig.maximumRiskPerTradePercent, 5)

        let ethEvaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("ETHUSDT"),
                timeframe: .fifteenMinutes,
                closedCandles: candles,
                generatedAt: candles.last?.openTime ?? Date()
            ),
            config: strategy.definition.defaultConfig
        )
        XCTAssertEqual(ethEvaluation, .noSignal)

        let oneHourEvaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .oneHour,
                closedCandles: candles,
                generatedAt: candles.last?.openTime ?? Date()
            ),
            config: strategy.definition.defaultConfig
        )
        XCTAssertEqual(oneHourEvaluation, .noSignal)
    }

    func testXFrequencyStrategyCreatesShortAfterThreeBarReclaim() throws {
        let strategy = XFrequencyStrategy()
        let candles = xShortCandles()
        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .fifteenMinutes,
                closedCandles: candles,
                generatedAt: candles.last?.openTime ?? Date()
            ),
            config: strategy.definition.defaultConfig
        )

        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected X-Frequency short signal")
        }

        XCTAssertEqual(signal.strategyID, XFrequencyStrategy.identifier)
        XCTAssertEqual(signal.side, .sell)
        XCTAssertEqual(signal.entryPrice, Decimal(string: "99.15")!)
        XCTAssertGreaterThan(signal.stopLoss, signal.entryPrice)
        XCTAssertEqual(signal.plannedRewardRiskRatio, 2)
    }

    func testXOneHourLongStrategyCreatesLongAfterHourlyReclaim() throws {
        let strategy = XOneHourLongStrategy()
        let candles = xOneHourLongCandles()
        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .oneHour,
                closedCandles: candles,
                generatedAt: candles.last?.openTime ?? Date()
            ),
            config: strategy.definition.defaultConfig
        )

        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected X 1H long signal")
        }

        XCTAssertEqual(signal.strategyID, XOneHourLongStrategy.identifier)
        XCTAssertEqual(signal.side, .buy)
        XCTAssertEqual(signal.entryPrice, Decimal(string: "103.5")!)
        XCTAssertLessThan(signal.stopLoss, signal.entryPrice)
        XCTAssertEqual(signal.plannedRewardRiskRatio, Decimal(string: "2.2")!)
    }

    func testXOneHourShortStrategyCreatesShortAfterHourlyReclaim() throws {
        let strategy = XOneHourShortStrategy()
        let candles = xOneHourShortCandles()
        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .oneHour,
                closedCandles: candles,
                generatedAt: candles.last?.openTime ?? Date()
            ),
            config: strategy.definition.defaultConfig
        )

        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected X 1H short signal")
        }

        XCTAssertEqual(signal.strategyID, XOneHourShortStrategy.identifier)
        XCTAssertEqual(signal.side, .sell)
        XCTAssertEqual(signal.entryPrice, Decimal(string: "96.5")!)
        XCTAssertGreaterThan(signal.stopLoss, signal.entryPrice)
        XCTAssertEqual(signal.plannedRewardRiskRatio, Decimal(string: "2.2")!)
    }

    func testETHOneHourMomentumBurstCreatesSignalAfterDirectionalReturnBreakout() throws {
        let strategy = ETHOneHourMomentumBurstStrategy()
        let candles = ethOneHourMomentumBurstCandles()
        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("ETHUSDT"),
                timeframe: .oneHour,
                closedCandles: candles,
                generatedAt: candles.last?.openTime ?? Date()
            ),
            config: strategy.definition.defaultConfig
        )

        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected ETH 1H momentum burst signal")
        }

        XCTAssertEqual(signal.strategyID, ETHOneHourMomentumBurstStrategy.identifier)
        XCTAssertEqual(signal.symbol, FuturesSymbol("ETHUSDT"))
        XCTAssertEqual(signal.side, .buy)
        XCTAssertEqual(signal.entryPrice, 105)
        XCTAssertLessThan(signal.stopLoss, signal.entryPrice)
        XCTAssertEqual(signal.plannedRewardRiskRatio, Decimal(string: "2.5")!)
    }

    func testSignalEvaluatorRejectsSymbolOutsideWatchlist() throws {
        let logStore = InMemoryTradeEventLogStore()
        let runner = TradingSignalEvaluator(
            strategyRegistry: StrategyRegistry(),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        XCTAssertThrowsError(
            try runner.makeCandidate(
                symbol: FuturesSymbol("SOLUSDT"),
                watchlist: [FuturesSymbol("BTCUSDT")],
                timeframe: .fifteenMinutes,
                candleOpenTime: Date(timeIntervalSince1970: 1),
                candles: [],
                config: .default
            )
        ) { error in
            XCTAssertEqual(error as? TradingDomainError, .selectedSymbolNotInWatchlist(FuturesSymbol("SOLUSDT")))
        }
    }

    func testSignalEvaluatorDoesNotPersistNoSignalEvaluation() throws {
        let logStore = InMemoryTradeEventLogStore()
        let runner = TradingSignalEvaluator(
            strategyRegistry: StrategyRegistry(),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        _ = try runner.makeCandidate(
            symbol: FuturesSymbol("BTCUSDT"),
            watchlist: [FuturesSymbol("BTCUSDT")],
            timeframe: .fifteenMinutes,
            candleOpenTime: Date(timeIntervalSince1970: 1),
            candles: [],
            config: .default
        )

        let logs = try logStore.loadRecent(limit: 10)
        XCTAssertEqual(logs.count, 0)
    }

    func testSignalEvaluatorPersistsDetailedLiveOrderWhenExecutionSucceeds() throws {
        let logStore = InMemoryTradeEventLogStore()
        let runner = TradingSignalEvaluator(
            strategyRegistry: StrategyRegistry(strategies: [FixtureSignalStrategy()]),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        let candidate = try XCTUnwrap(try runner.makeCandidate(
            symbol: FuturesSymbol("BTCUSDT"),
            watchlist: [FuturesSymbol("BTCUSDT")],
            timeframe: .fifteenMinutes,
            candleOpenTime: Date(timeIntervalSince1970: 1),
            candles: [],
            config: fixtureSignalConfig(leverage: 2)
        ))
        let receipt = LiveOrderReceipt(
            orderID: "entry-1",
            clientOid: "client-1",
            symbol: candidate.signal.symbol,
            status: .filled,
            filledSize: Decimal(string: "0.5"),
            averagePrice: candidate.signal.entryPrice
        )
        let protectionReceipts = [
            ExchangeProtectionReceipt(orderID: "tp1", clientOid: "tp1", kind: .takeProfit, attempts: 1),
            ExchangeProtectionReceipt(orderID: "tp2", clientOid: "tp2", kind: .takeProfit, attempts: 1),
            ExchangeProtectionReceipt(orderID: "sl", clientOid: "sl", kind: .stopLoss, attempts: 1)
        ]

        try runner.recordLiveOrder(
            candidate,
            receipt: receipt,
            protectionReceipts: protectionReceipts,
            portfolioDecisionReason: "fixture decision"
        )

        let log = try XCTUnwrap(try logStore.loadRecent(limit: 10).first)
        XCTAssertEqual(log.category, .liveOrder)
        XCTAssertTrue(log.message.contains("Live buy order submitted"))
        XCTAssertTrue(log.message.contains("leverage 2x"))
        XCTAssertTrue(log.message.contains("margin 25%"))
        XCTAssertTrue(log.message.contains("account risk 5%"))
        XCTAssertTrue(log.message.contains("protection takeProfit#****, takeProfit#****, stopLoss#****"))
        XCTAssertFalse(log.message.contains("entry-1"))
        XCTAssertFalse(log.message.contains("tp1"))
        XCTAssertTrue(log.message.contains("fixture decision"))
        XCTAssertTrue(log.isPersistentTradingRecord)
        XCTAssertEqual(log.metadata?.title, "BTCUSDT 15m 매수 진입")
        XCTAssertEqual(log.metadata?.tags.map(\.label), ["LIVE", "15m", "매수", "2x", FixtureSignalStrategy.identifier])
        XCTAssertTrue(log.metadata?.details.contains {
            $0.label == "손익비" && $0.value == "2:1"
        } ?? false)
        XCTAssertTrue(log.metadata?.details.contains {
            $0.label == "진입가" && $0.value == "100"
        } ?? false)
    }

    func testSignalEvaluatorBlocksLeverageAboveAutomationLimit() throws {
        let logStore = InMemoryTradeEventLogStore()
        let runner = TradingSignalEvaluator(
            strategyRegistry: StrategyRegistry(strategies: [FixtureSignalStrategy()]),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        let candidate = try runner.makeCandidate(
            symbol: FuturesSymbol("BTCUSDT"),
            watchlist: [FuturesSymbol("BTCUSDT")],
            timeframe: .fifteenMinutes,
            candleOpenTime: Date(timeIntervalSince1970: 1),
            candles: [],
            config: fixtureSignalConfig(leverage: 11)
        )

        let log = try XCTUnwrap(try logStore.loadRecent(limit: 10).first)
        XCTAssertNil(candidate)
        XCTAssertEqual(log.category, .risk)
        XCTAssertTrue(log.message.contains("최대 10x"))
    }

    func testRiskPolicySizesPositionToConfiguredRiskLimit() throws {
        let signal = try StrategySignalDraft(
            strategyID: "fixture",
            symbol: FuturesSymbol("BTCUSDT"),
            side: .buy,
            entryPrice: 100,
            stopLoss: 96,
            takeProfit: 108,
            reason: "fixture",
            generatedAt: Date(timeIntervalSince1970: 1)
        ).validated()

        let decision = StrategyRiskPolicy.decision(for: signal, leverage: 8)

        XCTAssertTrue(decision.isAllowed)
        XCTAssertEqual(decision.positionMarginRatio, Decimal(string: "0.15625")!)
        XCTAssertEqual(decision.accountRiskPercent, 5)
    }

    func testRiskPolicyCapsPositionByConfiguredMarginLimit() throws {
        let signal = try StrategySignalDraft(
            strategyID: "fixture",
            symbol: FuturesSymbol("BTCUSDT"),
            side: .buy,
            entryPrice: 100,
            stopLoss: 96,
            takeProfit: 108,
            reason: "fixture",
            generatedAt: Date(timeIntervalSince1970: 1)
        ).validated()

        let decision = StrategyRiskPolicy.decision(
            for: signal,
            leverage: 8,
            maximumRiskPerTradePercent: 12,
            maximumPositionMarginPercent: 20
        )

        XCTAssertTrue(decision.isAllowed)
        XCTAssertEqual(decision.positionMarginRatio, Decimal(string: "0.2")!)
        XCTAssertEqual(decision.accountRiskPercent, Decimal(string: "6.4")!)
    }

    func testFeePolicyUsesReferralRegisteredMakerAndTakerFee() {
        XCTAssertEqual(
            TradingFeePolicy.referralRegisteredFuturesMakerFeeRate,
            Decimal(16) / Decimal(100_000)
        )
        XCTAssertEqual(
            TradingFeePolicy.referralRegisteredFuturesTakerFeeRate,
            Decimal(48) / Decimal(100_000)
        )
        XCTAssertEqual(
            TradingFeePolicy.marketEntryTakeProfitLimitFeePercent(leverage: 2),
            Decimal(string: "0.128")!
        )
        XCTAssertEqual(
            TradingFeePolicy.marketEntryStopLossMarketFeePercent(leverage: 2),
            Decimal(string: "0.192")!
        )
        XCTAssertEqual(
            TradingFeePolicy.marketEntryTakeProfitLimitFeePercent(
                leverage: 2,
                positionMarginRatio: Decimal(string: "0.6")!
            ),
            Decimal(string: "0.0768")!
        )
    }

    func testRiskPolicyBlocksTakeProfitThatCannotCoverFees() throws {
        let signal = try StrategySignalDraft(
            strategyID: "fixture",
            symbol: FuturesSymbol("BTCUSDT"),
            side: .buy,
            entryPrice: 100,
            stopLoss: Decimal(string: "99.999")!,
            takeProfit: Decimal(string: "100.002")!,
            reason: "fixture",
            generatedAt: Date(timeIntervalSince1970: 1)
        ).validated()

        let decision = StrategyRiskPolicy.decision(for: signal, leverage: 2)

        XCTAssertFalse(decision.isAllowed)
        XCTAssertTrue(decision.reason.contains("수수료"))
    }

    func testBacktestEngineReportsWinningTrades() throws {
        let registry = StrategyRegistry(strategies: [FixtureSignalStrategy()])
        let engine = BacktestEngine(strategyRegistry: registry)
        let candles = DemoDataSeeder.makeCandles(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            count: 80
        ).map { candle in
            Candle(
                productType: candle.productType,
                symbol: candle.symbol,
                timeframe: candle.timeframe,
                openTime: candle.openTime,
                open: 100,
                high: 121,
                low: 99,
                close: 100,
                volume: candle.volume,
                isClosed: true
            )
        }

        let result = try engine.run(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: candles,
            config: fixtureSignalConfig()
        )

        XCTAssertGreaterThan(result.totalTrades, 0)
        XCTAssertEqual(result.winRatePercent, 100)
        XCTAssertGreaterThanOrEqual(result.averageRewardRiskRatio, 2)
        XCTAssertEqual(result.trades.first?.partialTakeProfit, 110)
        XCTAssertEqual(result.trades.first?.partialTakeProfitFillRatio, Decimal(string: "0.5"))
        XCTAssertEqual(result.trades.first?.finalTakeProfitFillRatio, Decimal(string: "0.5"))
        XCTAssertEqual(result.trades.first?.leveragedReturnPercent, Decimal(string: "7.468"))
    }

    func testBacktestEngineMovesStopToProfitLockAfterPartialTakeProfit() throws {
        let registry = StrategyRegistry(strategies: [FixtureSignalStrategy()])
        let engine = BacktestEngine(strategyRegistry: registry)
        var candles = repeatedCandles(count: 40, close: 100)
        candles.append(makeStrategyCandle(offset: 40, open: 100, high: 111, low: 99, close: 110))
        candles.append(makeStrategyCandle(offset: 41, open: 106, high: 106, low: 104, close: 105))

        let result = try engine.run(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: candles,
            config: fixtureSignalConfig()
        )
        let trade = try XCTUnwrap(result.trades.first)

        XCTAssertEqual(result.totalTrades, 1)
        XCTAssertEqual(trade.outcome, .win)
        XCTAssertEqual(trade.partialTakeProfit, 110)
        XCTAssertEqual(trade.exitPrice, Decimal(string: "107.5")!)
        XCTAssertEqual(trade.partialTakeProfitFillRatio, Decimal(string: "0.5"))
        XCTAssertEqual(trade.finalTakeProfitFillRatio, 0)
        XCTAssertEqual(trade.stopLossFillRatio, Decimal(string: "0.5"))
        XCTAssertEqual(trade.leveragedReturnPercent, Decimal(string: "3.71")!)
    }

    func testBacktestEngineClosesAtMaximumHoldingPeriodWithReason() throws {
        let registry = StrategyRegistry(strategies: [FixtureSignalStrategy()])
        let engine = BacktestEngine(strategyRegistry: registry)
        var config = fixtureSignalConfig()
        config.maximumHoldingCandles = 2
        var candles = repeatedCandles(count: 40, close: 100)
        candles.append(makeStrategyCandle(offset: 40, open: 100, high: 105, low: 95, close: 100))
        candles.append(makeStrategyCandle(offset: 41, open: 100, high: 105, low: 95, close: 101))

        let result = try engine.run(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: candles,
            config: config
        )
        let trade = try XCTUnwrap(result.trades.first)

        XCTAssertEqual(result.totalTrades, 1)
        XCTAssertEqual(trade.exitTime, candles[41].openTime)
        XCTAssertEqual(trade.exitPrice, 101)
        XCTAssertEqual(trade.partialTakeProfitFillRatio, 0)
        XCTAssertEqual(trade.finalTakeProfitFillRatio, 0)
        XCTAssertEqual(trade.stopLossFillRatio, 0)
        XCTAssertTrue(trade.reason.contains("시간 종료"))
        XCTAssertTrue(trade.reason.contains("최대 보유 2봉"))
        XCTAssertTrue(trade.reason.contains("진입 가설"))
    }

    func testBacktestEngineAppliesStopLossMarketFeeToLosingTrades() throws {
        let registry = StrategyRegistry(strategies: [FixtureSignalStrategy()])
        let engine = BacktestEngine(strategyRegistry: registry)
        let candles = DemoDataSeeder.makeCandles(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            count: 80
        ).map { candle in
            Candle(
                productType: candle.productType,
                symbol: candle.symbol,
                timeframe: candle.timeframe,
                openTime: candle.openTime,
                open: 100,
                high: 101,
                low: 89,
                close: 100,
                volume: candle.volume,
                isClosed: true
            )
        }

        let result = try engine.run(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: candles,
            config: fixtureSignalConfig()
        )

        XCTAssertGreaterThan(result.totalTrades, 0)
        XCTAssertEqual(result.losingTrades, result.totalTrades)
        XCTAssertEqual(result.trades.first?.leveragedReturnPercent, Decimal(string: "-5.048"))
    }

    func testBacktestEngineReportsRiskBlockReasons() throws {
        let registry = StrategyRegistry(strategies: [FixtureSignalStrategy()])
        let engine = BacktestEngine(strategyRegistry: registry)
        let candles = DemoDataSeeder.makeCandles(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            count: 45
        )

        let result = try engine.run(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: candles,
            config: fixtureSignalConfig(leverage: 11)
        )

        XCTAssertEqual(result.totalTrades, 0)
        XCTAssertGreaterThan(result.blockedSignals, 0)
        XCTAssertEqual(result.blockedSignalSummaries.first?.reason, "레버리지 10x 초과")
        XCTAssertEqual(result.blockedSignalSummaries.first?.count, result.blockedSignals)
    }

    func testBacktestEngineCompoundsBalanceAndKeepsSkippedTradeCandlesInHistory() throws {
        let registry = StrategyRegistry(strategies: [HistoryCountSignalStrategy()])
        let engine = BacktestEngine(strategyRegistry: registry)
        var candles = repeatedCandles(count: 40, close: 100)
        candles.append(makeStrategyCandle(offset: 40, open: 100, high: 121, low: 99, close: 100))
        candles.append(makeStrategyCandle(offset: 41, open: 100, high: 100, low: 100, close: 100))
        candles.append(makeStrategyCandle(offset: 42, open: 100, high: 101, low: 89, close: 100))

        let result = try engine.run(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: candles,
            config: historyCountSignalConfig(),
            initialCapital: 100
        )

        XCTAssertEqual(result.totalTrades, 2)
        XCTAssertEqual(result.initialCapital, 100)
        XCTAssertEqual(result.trades[0].startingBalance, 100)
        XCTAssertEqual(result.trades[0].endingBalance, Decimal(string: "107.468")!)
        XCTAssertEqual(result.trades[1].startingBalance, Decimal(string: "107.468")!)
        XCTAssertEqual(result.finalBalance, Decimal(string: "102.04301536")!)
        XCTAssertEqual(result.netReturnPercent, Decimal(string: "2.04301536")!)
    }

    func testVWMATouchTrendStrategyCreatesLongNearSupport() throws {
        let strategy = VWMATouchTrendStrategy()
        var candles = repeatedCandles(count: 99, close: 100)
        candles.append(makeStrategyCandle(offset: 99, open: 101, high: 103, low: 100.5, close: 102))

        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .twelveHours,
                closedCandles: candles,
                generatedAt: candles[99].openTime
            ),
            config: strategy.definition.defaultConfig
        )

        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected VWMA long signal")
        }

        XCTAssertEqual(signal.side, .buy)
        XCTAssertEqual(signal.entryPrice, 102)
        XCTAssertLessThan(signal.stopLoss, signal.entryPrice)
        XCTAssertGreaterThan(signal.takeProfit, signal.entryPrice)
        XCTAssertGreaterThanOrEqual(signal.plannedRewardRiskRatio ?? 0, 2)
    }

    func testVWMATouchTrendStrategyCreatesShortNearResistance() throws {
        let strategy = VWMATouchTrendStrategy()
        var candles = repeatedCandles(count: 99, close: 100)
        candles.append(makeStrategyCandle(offset: 99, open: 99, high: 99.5, low: 97, close: 98))

        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .twelveHours,
                closedCandles: candles,
                generatedAt: candles[99].openTime
            ),
            config: strategy.definition.defaultConfig
        )

        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected VWMA short signal")
        }

        XCTAssertEqual(signal.side, .sell)
        XCTAssertEqual(signal.entryPrice, 98)
        XCTAssertGreaterThan(signal.stopLoss, signal.entryPrice)
        XCTAssertLessThan(signal.takeProfit, signal.entryPrice)
        XCTAssertGreaterThanOrEqual(signal.plannedRewardRiskRatio ?? 0, 2)
    }

    func testDonchianChannelBreakoutStrategyCreatesLongOnFourHours() throws {
        let strategy = DonchianChannelBreakoutStrategy()
        let candles = donchianBreakoutCandles()

        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .fourHours,
                closedCandles: candles,
                generatedAt: candles.last?.openTime ?? Date()
            ),
            config: strategy.definition.defaultConfig
        )

        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected Donchian breakout signal")
        }

        XCTAssertEqual(signal.side, .buy)
        XCTAssertEqual(signal.entryPrice, 105)
        XCTAssertLessThan(signal.stopLoss, signal.entryPrice)
        XCTAssertGreaterThan(signal.takeProfit, signal.entryPrice)
        XCTAssertGreaterThanOrEqual(signal.plannedRewardRiskRatio ?? 0, 2)
    }

    func testTimeSeriesMomentumStrategyCreatesLongOnTwelveHours() throws {
        let strategy = TimeSeriesMomentumStrategy()
        var candles = repeatedCandles(count: 35, close: 100)
        candles.append(makeStrategyCandle(offset: 35, open: 100, high: 111, low: 99, close: 110))

        let evaluation = try strategy.evaluate(
            StrategyContext(
                symbol: FuturesSymbol("BTCUSDT"),
                timeframe: .twelveHours,
                closedCandles: candles,
                generatedAt: candles[35].openTime
            ),
            config: strategy.definition.defaultConfig
        )

        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected time-series momentum signal")
        }

        XCTAssertEqual(signal.side, .buy)
        XCTAssertEqual(signal.entryPrice, 110)
        XCTAssertLessThan(signal.stopLoss, signal.entryPrice)
        XCTAssertGreaterThan(signal.takeProfit, signal.entryPrice)
        XCTAssertGreaterThanOrEqual(signal.plannedRewardRiskRatio ?? 0, 2)
    }

    func testBacktestEngineRunsDonchianChannelBreakoutStrategy() throws {
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let engine = BacktestEngine(strategyRegistry: registry)
        var config = DonchianChannelBreakoutStrategy().definition.defaultConfig
        config.signalConfirmation = .disabled
        let exit = makeStrategyCandle(
            offset: 41,
            open: 105,
            high: 130,
            low: 104,
            close: 128,
            timeframe: .fourHours
        )

        let result = try engine.run(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fourHours,
            candles: donchianBreakoutCandles() + [exit],
            config: config
        )

        XCTAssertEqual(result.totalTrades, 1)
        XCTAssertEqual(result.winningTrades, 1)
        XCTAssertEqual(result.trades.first?.entryPrice, 105)
        XCTAssertEqual(result.trades.first?.outcome, .win)
    }

    func testDefaultBacktestKeepsSignalConfirmationOutOfPrimaryResult() {
        XCTAssertEqual(StrategyConfig.default.signalConfirmation.mode, .off)
        XCTAssertEqual(BacktestConfiguration.default.strategyConfig.signalConfirmation.mode, .off)
        XCTAssertFalse(BacktestConfiguration.default.comparesSignalConfirmation)
    }

    func testSignalConfirmationEngineCapsGroupsAndBlocksBelowThreshold() throws {
        let signal = try fixtureSignal()
        let context = StrategyContext(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            closedCandles: repeatedCandles(count: 45, close: 100),
            generatedAt: Date(timeIntervalSince1970: 1)
        )
        let engine = SignalConfirmationEngine(rules: [
            FixedEvidenceRule(id: "trend-a", group: .trend, score: 15),
            FixedEvidenceRule(id: "trend-b", group: .trend, score: 15),
            FixedEvidenceRule(id: "momentum-a", group: .momentum, score: 8)
        ])
        let config = SignalConfirmationConfig(
            isEnabled: true,
            requiredScore: 29,
            groupScoreCaps: [
                .trend: 20,
                .momentum: 10
            ]
        )

        let score = engine.score(signal: signal, context: context, config: config)
        let decision = engine.decision(for: signal, context: context, config: config)

        XCTAssertEqual(score.rawScore, 38)
        XCTAssertEqual(score.totalScore, 28)
        XCTAssertFalse(decision.isAllowed)
        XCTAssertEqual(decision.blockSummaryReason, "보조 점수 28/29 미달")
    }

    func testBacktestEngineBlocksSignalsWhenConfirmationScoreIsLow() throws {
        let registry = StrategyRegistry(strategies: [FixtureSignalStrategy()])
        let engine = BacktestEngine(
            strategyRegistry: registry,
            confirmationEngine: SignalConfirmationEngine(rules: [])
        )
        let candles = profitableFixtureCandles()
        var config = fixtureSignalConfig(
            signalConfirmation: SignalConfirmationConfig(
                isEnabled: true,
                requiredScore: 10,
                groupScoreCaps: SignalConfirmationConfig.optimizedDefault.groupScoreCaps
            )
        )

        let result = try engine.run(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: candles,
            config: config
        )

        XCTAssertEqual(result.totalTrades, 0)
        XCTAssertGreaterThan(result.confirmationBlockedSignals, 0)
        XCTAssertEqual(result.blockedSignals, 0)
        XCTAssertEqual(result.confirmationBlockedSignalSummaries.first?.reason, "보조 점수 0/10 미달")

        config.signalConfirmation.isEnabled = false
        let disabledResult = try engine.run(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: candles,
            config: config
        )
        XCTAssertGreaterThan(disabledResult.totalTrades, 0)
    }

    func testBacktestEngineObserveModeRecordsScoreBucketsWithoutBlocking() throws {
        let registry = StrategyRegistry(strategies: [FixtureSignalStrategy()])
        let engine = BacktestEngine(
            strategyRegistry: registry,
            confirmationEngine: SignalConfirmationEngine(rules: [])
        )
        let result = try engine.run(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: profitableFixtureCandles(),
            config: fixtureSignalConfig(
                signalConfirmation: SignalConfirmationConfig(
                    mode: .observe,
                    requiredScore: 10,
                    groupScoreCaps: SignalConfirmationConfig.optimizedDefault.groupScoreCaps
                )
            )
        )

        XCTAssertGreaterThan(result.totalTrades, 0)
        XCTAssertEqual(result.confirmationBlockedSignals, 0)
        XCTAssertEqual(result.confirmationScoreBuckets.first?.bucket, .zeroToTen)
        XCTAssertGreaterThan(result.confirmationScoreBuckets.first?.signalCount ?? 0, 0)
        XCTAssertGreaterThan(result.confirmationScoreBuckets.first?.tradeCount ?? 0, 0)
    }

    func testBacktestEngineComparesSignalConfirmationModes() throws {
        let registry = StrategyRegistry(strategies: [FixtureSignalStrategy()])
        let engine = BacktestEngine(
            strategyRegistry: registry,
            confirmationEngine: SignalConfirmationEngine(rules: [])
        )
        let comparison = try engine.runSignalConfirmationComparison(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: profitableFixtureCandles(),
            config: fixtureSignalConfig(
                signalConfirmation: SignalConfirmationConfig(
                    isEnabled: true,
                    requiredScore: 10,
                    groupScoreCaps: SignalConfirmationConfig.optimizedDefault.groupScoreCaps
                )
            )
        )

        XCTAssertGreaterThan(comparison.withoutSignalConfirmation.totalTrades, 0)
        XCTAssertGreaterThan(comparison.observedSignalConfirmation.totalTrades, 0)
        XCTAssertFalse(comparison.observedSignalConfirmation.confirmationScoreBuckets.isEmpty)
        XCTAssertEqual(comparison.withSignalConfirmation.totalTrades, 0)
        XCTAssertLessThan(comparison.tradeCountDelta, 0)
        XCTAssertGreaterThan(comparison.withSignalConfirmation.confirmationBlockedSignals, 0)
        XCTAssertEqual(comparison.optimizationReport.recommendedMode, .off)
        XCTAssertNil(comparison.optimizationReport.recommendedRequiredScore)
    }

    func testBacktestComparisonImpactCountsOnlyNetTradesRemovedByGate() {
        let keptBefore = comparisonFixtureTrade(offset: 1, leveragedReturnPercent: 10)
        let missedWin = comparisonFixtureTrade(offset: 2, leveragedReturnPercent: 5)
        let defendedLoss = comparisonFixtureTrade(offset: 3, leveragedReturnPercent: -4)
        let keptAfterWithDifferentReturn = comparisonFixtureTrade(offset: 1, leveragedReturnPercent: 1)

        let comparison = BacktestComparisonResult(
            withoutSignalConfirmation: comparisonFixtureBacktestResult(
                trades: [keptBefore, missedWin, defendedLoss]
            ),
            observedSignalConfirmation: comparisonFixtureBacktestResult(
                trades: [keptBefore, missedWin, defendedLoss]
            ),
            withSignalConfirmation: comparisonFixtureBacktestResult(
                trades: [keptAfterWithDifferentReturn]
            ),
            optimizationReport: comparisonFixtureOptimizationReport()
        )

        XCTAssertEqual(comparison.netFilteredOutTradeCount, 2)
        XCTAssertEqual(comparison.missedUpsideTradeCount, 1)
        XCTAssertEqual(comparison.missedUpsidePercentPoints, Decimal(5))
        XCTAssertEqual(comparison.defendedDownsideTradeCount, 1)
        XCTAssertEqual(comparison.defendedDownsidePercentPoints, Decimal(-4))
    }

    func testBacktestComparisonOffsetsPathReplacementTradesInNetImpactCount() {
        let comparison = BacktestComparisonResult(
            withoutSignalConfirmation: comparisonFixtureBacktestResult(
                trades: [
                    comparisonFixtureTrade(offset: 1, leveragedReturnPercent: 5),
                    comparisonFixtureTrade(offset: 2, leveragedReturnPercent: -4),
                    comparisonFixtureTrade(offset: 3, leveragedReturnPercent: 6)
                ]
            ),
            observedSignalConfirmation: comparisonFixtureBacktestResult(trades: []),
            withSignalConfirmation: comparisonFixtureBacktestResult(
                trades: [
                    comparisonFixtureTrade(offset: 4, leveragedReturnPercent: 3),
                    comparisonFixtureTrade(offset: 5, leveragedReturnPercent: -1)
                ]
            ),
            optimizationReport: comparisonFixtureOptimizationReport()
        )

        XCTAssertEqual(comparison.netFilteredOutTradeCount, 1)
        XCTAssertEqual(comparison.missedUpsideTradeCount, 1)
        XCTAssertEqual(comparison.defendedDownsideTradeCount, 0)
    }

    func testBacktestEngineRecommendsGateThresholdWhenScoreSeparatesLosingSignal() throws {
        let registry = StrategyRegistry(strategies: [HistoryCountSignalStrategy()])
        let engine = BacktestEngine(
            strategyRegistry: registry,
            confirmationEngine: SignalConfirmationEngine(rules: [
                HistoryCountEvidenceRule()
            ])
        )

        let comparison = try engine.runSignalConfirmationComparison(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: splitOutcomeFixtureCandles(),
            config: historyCountSignalConfig(
                signalConfirmation: SignalConfirmationConfig(
                    mode: .gate,
                    requiredScore: 22,
                    groupScoreCaps: SignalConfirmationConfig.optimizedDefault.groupScoreCaps
                )
            )
        )

        XCTAssertEqual(comparison.withoutSignalConfirmation.totalTrades, 2)
        XCTAssertEqual(comparison.withSignalConfirmation.totalTrades, 0)
        XCTAssertEqual(comparison.optimizationReport.recommendedMode, .gate)
        XCTAssertEqual(comparison.optimizationReport.recommendedRequiredScore, 5)
        XCTAssertGreaterThan(
            comparison.optimizationReport.recommendedCandidate?.netReturnDeltaPercent ?? 0,
            0
        )
        XCTAssertEqual(comparison.optimizationReport.recommendedCandidate?.totalTrades, 1)
    }

}

struct FixedClock: Clock {
    let now: Date
}

private struct FixtureSignalStrategy: TradingStrategy {
    static let identifier = "fixture-signal"

    let definition = StrategyDefinition(
        id: FixtureSignalStrategy.identifier,
        name: "Fixture Signal",
        summary: "Always emits one fixture signal",
        defaultConfig: fixtureSignalConfig()
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        .signal(try StrategySignalDraft(
            strategyID: FixtureSignalStrategy.identifier,
            symbol: context.symbol,
            side: .buy,
            entryPrice: 100,
            stopLoss: 90,
            takeProfit: 120,
            reason: "fixture",
            generatedAt: context.generatedAt
        ).validated())
    }
}

private struct HistoryCountSignalStrategy: TradingStrategy {
    static let identifier = "history-count-signal"

    let definition = StrategyDefinition(
        id: HistoryCountSignalStrategy.identifier,
        name: "History Count Signal",
        summary: "Emits signals at specific history counts",
        defaultConfig: historyCountSignalConfig()
    )

    func evaluate(_ context: StrategyContext, config: StrategyConfig) throws -> StrategyEvaluation {
        guard context.closedCandles.count == 40 || context.closedCandles.count == 42 else {
            return .noSignal
        }

        return .signal(try StrategySignalDraft(
            strategyID: HistoryCountSignalStrategy.identifier,
            symbol: context.symbol,
            side: .buy,
            entryPrice: 100,
            stopLoss: 90,
            takeProfit: 120,
            reason: "fixture",
            generatedAt: context.generatedAt
        ).validated())
    }
}

private struct FixedEvidenceRule: SignalConfirmationRule {
    let id: String
    let group: SignalEvidenceGroup
    let score: Decimal

    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence? {
        SignalEvidence(id: id, group: group, score: score, reason: id)
    }
}

private struct HistoryCountEvidenceRule: SignalConfirmationRule {
    let id = "history-count-evidence"

    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence? {
        let score: Decimal = context.closedCandles.count >= 42 ? 20 : 0
        return SignalEvidence(id: id, group: .trend, score: score, reason: id)
    }
}

private func fixtureSignalConfig(
    leverage: Int = 1,
    signalConfirmation: SignalConfirmationConfig = .disabled
) -> StrategyConfig {
    StrategyConfig(
        strategyID: FixtureSignalStrategy.identifier,
        leverage: leverage,
        parameters: [:],
        signalConfirmation: signalConfirmation
    )
}

private func historyCountSignalConfig(
    leverage: Int = 1,
    signalConfirmation: SignalConfirmationConfig = .disabled
) -> StrategyConfig {
    StrategyConfig(
        strategyID: HistoryCountSignalStrategy.identifier,
        leverage: leverage,
        parameters: [:],
        signalConfirmation: signalConfirmation
    )
}

private func comparisonFixtureTrade(
    offset: Int,
    leveragedReturnPercent: Decimal
) -> BacktestTrade {
    BacktestTrade(
        symbol: FuturesSymbol("BTCUSDT"),
        side: .buy,
        entryTime: Date(timeIntervalSince1970: TimeInterval(offset * 900)),
        exitTime: Date(timeIntervalSince1970: TimeInterval((offset + 1) * 900)),
        entryPrice: 100,
        stopLoss: 90,
        takeProfit: 120,
        exitPrice: leveragedReturnPercent >= 0 ? 120 : 90,
        outcome: leveragedReturnPercent >= 0 ? .win : .loss,
        rewardRiskRatio: 2,
        leveragedReturnPercent: leveragedReturnPercent,
        leveragedStopLossPercent: 1,
        reason: "fixture"
    )
}

private func comparisonFixtureBacktestResult(trades: [BacktestTrade]) -> BacktestResult {
    let netReturnPercent = trades.reduce(Decimal(0)) { $0 + $1.leveragedReturnPercent }

    return BacktestResult(
        symbol: FuturesSymbol("BTCUSDT"),
        timeframe: .fifteenMinutes,
        strategyID: "fixture",
        leverage: 1,
        totalCandles: 100,
        totalTrades: trades.count,
        winningTrades: trades.filter { $0.outcome == .win }.count,
        losingTrades: trades.filter { $0.outcome == .loss }.count,
        skippedSignals: 0,
        blockedSignals: 0,
        openSignals: 0,
        confirmationBlockedSignals: 0,
        initialCapital: 100,
        finalBalance: 100 + netReturnPercent,
        netReturnPercent: netReturnPercent,
        maxDrawdownPercent: 0,
        averageRewardRiskRatio: 0,
        profitFactor: 0,
        blockedSignalSummaries: [],
        confirmationBlockedSignalSummaries: [],
        averageConfirmationScore: 0,
        confirmationScoreBuckets: [],
        trades: trades,
        completedAt: Date(timeIntervalSince1970: 0)
    )
}

private func comparisonFixtureOptimizationReport() -> BacktestSignalConfirmationOptimizationReport {
    BacktestSignalConfirmationOptimizationReport(
        minimumTradeCount: 1,
        recommendedMode: .gate,
        recommendedRequiredScore: nil,
        reason: "fixture",
        candidates: []
    )
}

private func fixtureSignal() throws -> StrategySignal {
    try StrategySignalDraft(
        strategyID: FixtureSignalStrategy.identifier,
        symbol: FuturesSymbol("BTCUSDT"),
        side: .buy,
        entryPrice: 100,
        stopLoss: 90,
        takeProfit: 120,
        reason: "fixture",
        generatedAt: Date(timeIntervalSince1970: 1)
    ).validated()
}

private func profitableFixtureCandles(
    timeframe: CandleTimeframe = .fifteenMinutes
) -> [Candle] {
    DemoDataSeeder.makeCandles(
        symbol: FuturesSymbol("BTCUSDT"),
        timeframe: timeframe,
        count: 80
    ).map { candle in
        Candle(
            productType: candle.productType,
            symbol: candle.symbol,
            timeframe: candle.timeframe,
            openTime: candle.openTime,
            open: 100,
            high: 121,
            low: 99,
            close: 100,
            volume: candle.volume,
            isClosed: true
        )
    }
}

private func splitOutcomeFixtureCandles() -> [Candle] {
    let warmup = (0..<40).map { index in
        makeStrategyCandle(
            offset: index,
            open: 100,
            high: 101,
            low: 99,
            close: 100
        )
    }
    let lossExit = makeStrategyCandle(
        offset: 40,
        open: 100,
        high: 101,
        low: 89,
        close: 91
    )
    let secondSignal = makeStrategyCandle(
        offset: 41,
        open: 100,
        high: 101,
        low: 99,
        close: 100
    )
    let winExit = makeStrategyCandle(
        offset: 42,
        open: 100,
        high: 121,
        low: 99,
        close: 120
    )

    return warmup + [lossExit, secondSignal, winExit]
}

private func repeatedCandles(count: Int, close: Decimal) -> [Candle] {
    (0..<count).map { index in
        makeStrategyCandle(
            offset: index,
            open: close,
            high: close,
            low: close,
            close: close
        )
    }
}

private func donchianBreakoutCandles() -> [Candle] {
    (0..<40).map { index in
        makeStrategyCandle(
            offset: index,
            open: 100,
            high: 101,
            low: 99,
            close: 100,
            timeframe: .fourHours
        )
    } + [
        makeStrategyCandle(
            offset: 40,
            open: 100,
            high: 106,
            low: 99,
            close: 105,
            timeframe: .fourHours
        )
    ]
}

private func xLongCandles() -> [Candle] {
    let slowBase = (0..<288).map { index in
        makeStrategyCandle(offset: index, open: 100, high: Decimal(string: "100.1")!, low: Decimal(string: "99.9")!, close: 100)
    }
    let fastBase = (288..<383).map { index in
        makeStrategyCandle(offset: index, open: Decimal(string: "100.6")!, high: Decimal(string: "100.7")!, low: Decimal(string: "100.5")!, close: Decimal(string: "100.6")!)
    }
    let reclaim = makeStrategyCandle(
        offset: 383,
        open: Decimal(string: "100.6")!,
        high: Decimal(string: "100.9")!,
        low: Decimal(string: "100.55")!,
        close: Decimal(string: "100.85")!,
        volume: 2_000
    )
    return slowBase + fastBase + [reclaim]
}

private func xShortCandles() -> [Candle] {
    let slowBase = (0..<288).map { index in
        makeStrategyCandle(offset: index, open: 100, high: Decimal(string: "100.1")!, low: Decimal(string: "99.9")!, close: 100)
    }
    let fastBase = (288..<383).map { index in
        makeStrategyCandle(offset: index, open: Decimal(string: "99.4")!, high: Decimal(string: "99.5")!, low: Decimal(string: "99.3")!, close: Decimal(string: "99.4")!)
    }
    let reclaim = makeStrategyCandle(
        offset: 383,
        open: Decimal(string: "99.4")!,
        high: Decimal(string: "99.45")!,
        low: Decimal(string: "99.1")!,
        close: Decimal(string: "99.15")!,
        volume: 2_000
    )
    return slowBase + fastBase + [reclaim]
}

private func xOneHourLongCandles() -> [Candle] {
    let slowBase = (0..<72).map { index in
        makeStrategyCandle(
            offset: index,
            open: 100,
            high: Decimal(string: "100.2")!,
            low: Decimal(string: "99.8")!,
            close: 100,
            timeframe: .oneHour
        )
    }
    let fastBase = (72..<95).map { index in
        makeStrategyCandle(
            offset: index,
            open: 103,
            high: Decimal(string: "103.1")!,
            low: Decimal(string: "102.9")!,
            close: 103,
            timeframe: .oneHour
        )
    }
    let reclaim = makeStrategyCandle(
        offset: 95,
        open: 103,
        high: Decimal(string: "103.6")!,
        low: Decimal(string: "102.8")!,
        close: Decimal(string: "103.5")!,
        volume: 2_000,
        timeframe: .oneHour
    )
    return slowBase + fastBase + [reclaim]
}

private func xOneHourShortCandles() -> [Candle] {
    let slowBase = (0..<72).map { index in
        makeStrategyCandle(
            offset: index,
            open: 100,
            high: Decimal(string: "100.2")!,
            low: Decimal(string: "99.8")!,
            close: 100,
            timeframe: .oneHour
        )
    }
    let fastBase = (72..<95).map { index in
        makeStrategyCandle(
            offset: index,
            open: 97,
            high: Decimal(string: "97.1")!,
            low: Decimal(string: "96.9")!,
            close: 97,
            timeframe: .oneHour
        )
    }
    let reclaim = makeStrategyCandle(
        offset: 95,
        open: 97,
        high: Decimal(string: "97.2")!,
        low: Decimal(string: "96.4")!,
        close: Decimal(string: "96.5")!,
        volume: 2_000,
        timeframe: .oneHour
    )
    return slowBase + fastBase + [reclaim]
}

private func ethOneHourMomentumBurstCandles() -> [Candle] {
    let slowBase = (0..<109).map { index in
        makeStrategyCandle(
            offset: index,
            open: 100,
            high: Decimal(string: "100.6")!,
            low: Decimal(string: "99.4")!,
            close: 100,
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .oneHour
        )
    }
    let preBreakout = (109..<120).map { index in
        makeStrategyCandle(
            offset: index,
            open: Decimal(string: "103.4")!,
            high: Decimal(string: "104.1")!,
            low: Decimal(string: "102.9")!,
            close: Decimal(string: "103.5")!,
            symbol: FuturesSymbol("ETHUSDT"),
            timeframe: .oneHour
        )
    }
    let breakout = makeStrategyCandle(
        offset: 120,
        open: 104,
        high: Decimal(string: "105.6")!,
        low: Decimal(string: "103.8")!,
        close: 105,
        volume: 2_000,
        symbol: FuturesSymbol("ETHUSDT"),
        timeframe: .oneHour
    )
    return slowBase + preBreakout + [breakout]
}

private func makeStrategyCandle(
    offset: Int,
    open: Decimal,
    high: Decimal,
    low: Decimal,
    close: Decimal,
    volume: Decimal = 1_000,
    symbol: FuturesSymbol = FuturesSymbol("BTCUSDT"),
    timeframe: CandleTimeframe = .fifteenMinutes
) -> Candle {
    Candle(
        productType: .usdtFutures,
        symbol: symbol,
        timeframe: timeframe,
        openTime: Date(timeIntervalSince1970: TimeInterval(offset) * timeframe.duration),
        open: open,
        high: high,
        low: low,
        close: close,
        volume: volume,
        isClosed: true
    )
}
