import XCTest
@testable import BucksCopy

final class StrategyTests: XCTestCase {
    func testDefaultRegistryIncludesBuiltInStrategies() {
        let ids = Set(StrategyRegistry().definitions.map(\.id))

        XCTAssertEqual(ids, Set([
            DonchianChannelBreakoutStrategy.identifier,
            TimeSeriesMomentumStrategy.identifier,
            VWMATouchTrendStrategy.identifier,
            XFrequencyStrategy.identifier,
            XStrategy.identifier
        ]))
    }

    func testTimeframeRoutingUsesRecommendedStrategies() {
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(for: .fifteenMinutes),
            [
                XStrategy.identifier,
                XFrequencyStrategy.identifier
            ]
        )
        XCTAssertEqual(
            StrategyTimeframeRouting.recommendedStrategyIDs(for: .oneHour),
            []
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

    func testPaperRunnerRejectsSymbolOutsideWatchlist() throws {
        let logStore = InMemoryTradeEventLogStore()
        let runner = PaperTradingRunner(
            strategyRegistry: StrategyRegistry(),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        XCTAssertThrowsError(
            try runner.start(
                symbol: FuturesSymbol("SOLUSDT"),
                watchlist: [FuturesSymbol("BTCUSDT")],
                timeframe: .fifteenMinutes,
                candles: [],
                config: .default
            )
        ) { error in
            XCTAssertEqual(error as? TradingDomainError, .selectedSymbolNotInWatchlist(FuturesSymbol("SOLUSDT")))
        }
    }

    func testPaperRunnerDoesNotPersistNoSignalEvaluation() throws {
        let logStore = InMemoryTradeEventLogStore()
        let runner = PaperTradingRunner(
            strategyRegistry: StrategyRegistry(),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        _ = try runner.start(
            symbol: FuturesSymbol("BTCUSDT"),
            watchlist: [FuturesSymbol("BTCUSDT")],
            timeframe: .fifteenMinutes,
            candles: [],
            config: .default
        )

        let logs = try logStore.loadRecent(limit: 10)
        XCTAssertEqual(logs.count, 0)
    }

    func testPaperRunnerPersistsDetailedPaperOrderWhenSignalExists() throws {
        let logStore = InMemoryTradeEventLogStore()
        let runner = PaperTradingRunner(
            strategyRegistry: StrategyRegistry(strategies: [FixtureSignalStrategy()]),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        _ = try runner.start(
            symbol: FuturesSymbol("BTCUSDT"),
            watchlist: [FuturesSymbol("BTCUSDT")],
            timeframe: .fifteenMinutes,
            candles: [],
            config: fixtureSignalConfig(leverage: 2)
        )

        let log = try XCTUnwrap(try logStore.loadRecent(limit: 10).first)
        XCTAssertEqual(log.category, .paperOrder)
        XCTAssertTrue(log.message.contains("Paper buy order"))
        XCTAssertTrue(log.message.contains("leverage 2x"))
        XCTAssertTrue(log.message.contains("margin 25%"))
        XCTAssertTrue(log.message.contains("account risk 5%"))
        XCTAssertTrue(log.message.contains("TP fee 0.03%"))
        XCTAssertTrue(log.message.contains("SL fee 0.05%"))
        XCTAssertTrue(log.isPersistentTradingRecord)
    }

    func testPaperRunnerBlocksLeverageAboveAutomationLimit() throws {
        let logStore = InMemoryTradeEventLogStore()
        let runner = PaperTradingRunner(
            strategyRegistry: StrategyRegistry(strategies: [FixtureSignalStrategy()]),
            logStore: logStore,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1))
        )

        let evaluation = try runner.start(
            symbol: FuturesSymbol("BTCUSDT"),
            watchlist: [FuturesSymbol("BTCUSDT")],
            timeframe: .fifteenMinutes,
            candles: [],
            config: fixtureSignalConfig(leverage: 11)
        )

        let log = try XCTUnwrap(try logStore.loadRecent(limit: 10).first)
        XCTAssertEqual(evaluation, .noSignal)
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

private func makeStrategyCandle(
    offset: Int,
    open: Decimal,
    high: Decimal,
    low: Decimal,
    close: Decimal,
    volume: Decimal = 1_000,
    timeframe: CandleTimeframe = .fifteenMinutes
) -> Candle {
    Candle(
        productType: .usdtFutures,
        symbol: FuturesSymbol("BTCUSDT"),
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
