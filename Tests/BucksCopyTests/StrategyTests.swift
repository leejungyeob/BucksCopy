import XCTest
@testable import BucksCopy

final class StrategyTests: XCTestCase {
    func testDefaultRegistryIncludesOnlyBlockedCandleShortStrategy() {
        let ids = Set(StrategyRegistry().definitions.map(\.id))

        XCTAssertEqual(ids, Set([BlockedCandleShortStrategy.identifier]))
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
            config: StrategyConfig(strategyID: FixtureSignalStrategy.identifier, leverage: 2, parameters: [:])
        )

        let log = try XCTUnwrap(try logStore.loadRecent(limit: 10).first)
        XCTAssertEqual(log.category, .paperOrder)
        XCTAssertTrue(log.message.contains("Paper buy order"))
        XCTAssertTrue(log.message.contains("leverage 2x"))
        XCTAssertTrue(log.message.contains("TP fee 0.13%"))
        XCTAssertTrue(log.message.contains("SL fee 0.19%"))
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
            config: StrategyConfig(strategyID: FixtureSignalStrategy.identifier, leverage: 11, parameters: [:])
        )

        let log = try XCTUnwrap(try logStore.loadRecent(limit: 10).first)
        XCTAssertEqual(evaluation, .noSignal)
        XCTAssertEqual(log.category, .risk)
        XCTAssertTrue(log.message.contains("최대 10x"))
    }

    func testRiskPolicyBlocksLeveragedStopLossAtThirtyPercentOrMore() throws {
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

        XCTAssertFalse(decision.isAllowed)
        XCTAssertTrue(decision.reason.contains("30"))
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
            config: StrategyConfig(strategyID: FixtureSignalStrategy.identifier, leverage: 1, parameters: [:])
        )

        XCTAssertGreaterThan(result.totalTrades, 0)
        XCTAssertEqual(result.winRatePercent, 100)
        XCTAssertGreaterThanOrEqual(result.averageRewardRiskRatio, 2)
        XCTAssertEqual(result.trades.first?.leveragedReturnPercent, Decimal(string: "19.936"))
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
            config: StrategyConfig(strategyID: FixtureSignalStrategy.identifier, leverage: 1, parameters: [:])
        )

        XCTAssertGreaterThan(result.totalTrades, 0)
        XCTAssertEqual(result.losingTrades, result.totalTrades)
        XCTAssertEqual(result.trades.first?.leveragedReturnPercent, Decimal(string: "-10.096"))
    }

    func testBlockedCandleShortStrategyCreatesSignalWithDefinedLevels() throws {
        let strategy = BlockedCandleShortStrategy()
        let context = StrategyContext(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            closedCandles: blockedCandlePattern(),
            generatedAt: Date(timeIntervalSince1970: 3_600)
        )

        let evaluation = try strategy.evaluate(context, config: strategy.definition.defaultConfig)
        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected blocked candle short signal")
        }

        XCTAssertEqual(signal.side, .sell)
        XCTAssertEqual(signal.entryPrice, 150)
        XCTAssertEqual(signal.stopLoss, 166)
        XCTAssertEqual(signal.takeProfit, 118)
        XCTAssertEqual(signal.plannedRewardRiskRatio, 2)
    }

    func testBlockedCandleShortStrategyKeepsStructuralTargetOnOneHour() throws {
        let strategy = BlockedCandleShortStrategy()
        let context = StrategyContext(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .oneHour,
            closedCandles: blockedCandlePattern(),
            generatedAt: Date(timeIntervalSince1970: 3_600)
        )

        let evaluation = try strategy.evaluate(context, config: strategy.definition.defaultConfig)
        guard case .signal(let signal) = evaluation else {
            return XCTFail("Expected blocked candle short signal")
        }

        XCTAssertEqual(signal.takeProfit, 100)
        XCTAssertEqual(signal.plannedRewardRiskRatio, Decimal(50) / Decimal(16))
    }

    func testBlockedCandleShortStrategyRejectsWeakBearishReversalClose() throws {
        let strategy = BlockedCandleShortStrategy()
        var candles = blockedCandlePattern()
        candles[3] = makeStrategyCandle(
            offset: 3,
            open: 166,
            high: 166,
            low: 148,
            close: 160
        )
        let context = StrategyContext(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            closedCandles: candles,
            generatedAt: Date(timeIntervalSince1970: 3_600)
        )

        let evaluation = try strategy.evaluate(context, config: strategy.definition.defaultConfig)

        XCTAssertEqual(evaluation, .noSignal)
    }

    func testBlockedCandleShortStrategySkipsTwelveHourUntilDataShowsEdge() throws {
        let strategy = BlockedCandleShortStrategy()
        let context = StrategyContext(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .twelveHours,
            closedCandles: blockedCandlePattern(),
            generatedAt: Date(timeIntervalSince1970: 3_600)
        )

        let evaluation = try strategy.evaluate(context, config: strategy.definition.defaultConfig)

        XCTAssertEqual(evaluation, .noSignal)
    }

    func testBlockedCandleShortStrategyRejectsHigherThirdHigh() throws {
        let strategy = BlockedCandleShortStrategy()
        var candles = blockedCandlePattern()
        candles[2] = makeStrategyCandle(
            offset: 2,
            open: 151,
            high: 171,
            low: 150,
            close: 160
        )
        let context = StrategyContext(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            closedCandles: candles,
            generatedAt: Date(timeIntervalSince1970: 3_600)
        )

        let evaluation = try strategy.evaluate(context, config: strategy.definition.defaultConfig)

        XCTAssertEqual(evaluation, .noSignal)
    }

    func testBacktestEngineRunsBlockedCandleShortStrategy() throws {
        let registry = StrategyRegistry(strategies: [BlockedCandleShortStrategy()])
        let engine = BacktestEngine(strategyRegistry: registry)
        let warmup = (0..<36).map { offset in
            makeStrategyCandle(
                offset: offset,
                open: 120,
                high: 122,
                low: 118,
                close: 120
            )
        }
        let pattern = blockedCandlePattern(startOffset: 36)
        let exit = makeStrategyCandle(
            offset: 40,
            open: 149,
            high: 151,
            low: 99,
            close: 105
        )

        let result = try engine.run(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            candles: warmup + pattern + [exit],
            config: BlockedCandleShortStrategy().definition.defaultConfig
        )

        XCTAssertEqual(result.totalTrades, 1)
        XCTAssertEqual(result.winningTrades, 1)
        XCTAssertEqual(result.trades.first?.entryPrice, 150)
        XCTAssertEqual(result.trades.first?.stopLoss, 166)
        XCTAssertEqual(result.trades.first?.takeProfit, 118)
        XCTAssertEqual(result.trades.first?.exitPrice, 118)
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
        defaultConfig: StrategyConfig(strategyID: FixtureSignalStrategy.identifier, leverage: 1, parameters: [:])
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

private func blockedCandlePattern(startOffset: Int = 0) -> [Candle] {
    [
        makeStrategyCandle(offset: startOffset, open: 100, high: 135, low: 99, close: 130),
        makeStrategyCandle(offset: startOffset + 1, open: 132, high: 170, low: 131, close: 150),
        makeStrategyCandle(offset: startOffset + 2, open: 151, high: 165, low: 150, close: 160),
        makeStrategyCandle(offset: startOffset + 3, open: 166, high: 166, low: 148, close: 150)
    ]
}

private func makeStrategyCandle(
    offset: Int,
    open: Decimal,
    high: Decimal,
    low: Decimal,
    close: Decimal
) -> Candle {
    Candle(
        productType: .usdtFutures,
        symbol: FuturesSymbol("BTCUSDT"),
        timeframe: .fifteenMinutes,
        openTime: Date(timeIntervalSince1970: TimeInterval(offset * 900)),
        open: open,
        high: high,
        low: low,
        close: close,
        volume: 1_000,
        isClosed: true
    )
}
