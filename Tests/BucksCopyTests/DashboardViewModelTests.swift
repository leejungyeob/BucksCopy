import XCTest
@testable import BucksCopy

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testTimeframeChangeReloadsCandlesForSelectedSymbol() async throws {
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry()
        let viewModel = DashboardViewModel(
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: nil,
            candleRepository: candleRepository,
            candleBackfillRepository: nil,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry
        )

        try candleRepository.upsertCandles(DemoDataSeeder.makeCandles(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .oneHour,
            count: 12
        ))

        viewModel.selectTimeframe(.oneHour)

        XCTAssertEqual(viewModel.state.selectedTimeframe, .oneHour)
        try await waitUntil { viewModel.state.candles.count == 12 }
        XCTAssertEqual(viewModel.state.candles.count, 12)
        XCTAssertTrue(viewModel.state.candles.allSatisfy { $0.timeframe == .oneHour })
    }

    func testTimeframeChangeRoutesLiveStrategyToRecommendedDefault() {
        let viewModel = makeViewModel(credentialStore: InMemoryCredentialStore())

        viewModel.selectTimeframe(.twelveHours)

        XCTAssertEqual(viewModel.state.selectedTimeframe, .twelveHours)
        XCTAssertEqual(viewModel.state.strategyConfig.strategyID, VWMATouchTrendStrategy.identifier)

        viewModel.selectTimeframe(.fourHours)

        XCTAssertEqual(viewModel.state.selectedTimeframe, .fourHours)
        XCTAssertEqual(viewModel.state.strategyConfig.strategyID, VWMATouchTrendStrategy.identifier)
    }

    func testBacktestTimeframeChangeRoutesStrategyToRecommendedDefault() {
        let viewModel = makeViewModel(credentialStore: InMemoryCredentialStore())

        viewModel.selectBacktestTimeframe(.oneDay)

        XCTAssertEqual(viewModel.state.backtestConfiguration.timeframe, .oneDay)
        XCTAssertEqual(
            viewModel.state.backtestConfiguration.strategyConfig.strategyID,
            VWMATouchTrendStrategy.identifier
        )
    }

    func testStrategySelectionIgnoresStrategiesOutsideCurrentTimeframe() {
        let viewModel = makeViewModel(credentialStore: InMemoryCredentialStore())
        viewModel.selectTimeframe(.twelveHours)

        viewModel.updateStrategy("removed-strategy")

        XCTAssertEqual(viewModel.state.strategyConfig.strategyID, VWMATouchTrendStrategy.identifier)
    }

    func testLiveBotMonitorsRecommendedStrategiesAcrossAllTimeframes() async throws {
        let symbol = FuturesSymbol("SOLUSDT")
        var state = DashboardState()
        state.credentialStatus = .connected(
            redactedIdentifier: "test...test",
            checkedAt: Date(timeIntervalSince1970: 1)
        )
        state.watchlist = [symbol]
        state.selectedSymbol = symbol
        state.selectedTimeframe = .fifteenMinutes
        state.strategyConfig = VWMATouchTrendStrategy().definition.defaultConfig
        state.accounts = [
            AccountSnapshot(
                marginCoin: "USDT",
                available: 10_000,
                accountEquity: 10_000,
                unrealizedProfitLoss: 0,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ]
        state.symbolCatalog = [makeContractSpec(symbol: symbol, maxLeverage: 10)]

        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry()
        let liveOrderClient = TestLiveOrderClient()
        let viewModel = DashboardViewModel(
            state: state,
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: nil,
            candleRepository: candleRepository,
            candleBackfillRepository: nil,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(
                strategyRegistry: registry,
                logStore: logStore,
                confirmationEngine: dashboardPassingConfirmationEngine()
            ),
            liveExecutor: LiveTradeExecutor(
                orderPlacer: liveOrderClient,
                leverageSetter: liveOrderClient,
                protectionInstaller: ExchangeProtectionInstaller(
                    orderPlacer: liveOrderClient,
                    retryPolicy: ExchangeProtectionRetryPolicy(retryDelayNanoseconds: 0)
                ),
                logStore: logStore
            ),
            strategyRegistry: registry,
            liveMonitorIntervalNanoseconds: 20_000_000
        )

        try candleRepository.upsertCandles(dashboardDonchianBreakoutCandles(
            symbol: symbol,
            timeframe: .fourHours,
            startOffset: 100
        ))

        viewModel.startLiveBot()
        defer {
            if case .runningLive = viewModel.state.runState {
                viewModel.stopLiveBot()
            }
        }
        XCTAssertEqual(viewModel.state.liveAutomationSession?.seedEquity, 10_000)
        XCTAssertEqual(viewModel.state.liveAutomationSession?.latestEquity, 10_000)
        XCTAssertNil(viewModel.state.liveAutomationSession?.stoppedAt)
        XCTAssertEqual(viewModel.state.automationLogs.filter { $0.category == .automation }.count, 1)

        try await waitUntil(timeout: 2) {
            viewModel.state.recentLogs.contains {
                $0.message.contains("Live monitor armed")
            }
        }

        XCTAssertFalse(viewModel.state.recentLogs.contains {
            $0.message.contains(DonchianChannelBreakoutStrategy.identifier) &&
                $0.message.contains("4H")
        })

        try candleRepository.upsertCandles(dashboardDonchianBreakoutCandles(
            symbol: symbol,
            timeframe: .fourHours,
            startOffset: 200
        ))

        try await waitUntil(timeout: 2) {
            viewModel.state.recentLogs.contains {
                $0.message.contains(DonchianChannelBreakoutStrategy.identifier) &&
                    $0.message.contains("4H")
            }
        }

        XCTAssertEqual(viewModel.state.selectedTimeframe, .fifteenMinutes)

        viewModel.stopLiveBot()
        XCTAssertNotNil(viewModel.state.liveAutomationSession?.stoppedAt)
        let automationRecords = try logStore.loadRecent(limit: 10)
            .filter { $0.category == .automation }
        XCTAssertEqual(automationRecords.map(\.message), [
            "Live automation session started.",
            "Live automation session stopped."
        ])
        XCTAssertEqual(viewModel.state.automationLogs.filter { $0.category == .automation }.count, 2)
    }

    func testConnectCredentialStoresKeyAndConnects() async throws {
        let credentialStore = InMemoryCredentialStore()
        let viewModel = makeViewModel(credentialStore: credentialStore)

        viewModel.connectCredential(
            apiKey: "  abcdefgh12345678  ",
            secretKey: " secret ",
            passphrase: " passphrase "
        )

        let savedCredential = try XCTUnwrap(credentialStore.load())
        XCTAssertEqual(savedCredential.apiKey, "abcdefgh12345678")
        XCTAssertEqual(savedCredential.secretKey, "secret")
        XCTAssertEqual(savedCredential.passphrase, "passphrase")

        try await waitUntil { viewModel.state.isConnected }
    }

    func testBootstrapAutoConnectsSavedCredential() async throws {
        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save(APIKeyCredential(
            apiKey: "abcdefgh12345678",
            secretKey: "secret",
            passphrase: "passphrase"
        ))
        let viewModel = makeViewModel(credentialStore: credentialStore)

        viewModel.bootstrap()

        try await waitUntil { viewModel.state.isConnected }
    }

    func testBootstrapSeedsDefaultWatchlistAcrossAllTimeframes() async throws {
        let symbols = [FuturesSymbol("BTCUSDT"), FuturesSymbol("ETHUSDT")]
        var state = DashboardState()
        state.watchlist = symbols
        state.selectedSymbol = symbols[0]
        state.selectedTimeframe = .twelveHours

        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry()
        let backfillRepository = RecordingBootstrapCandleBackfillRepository()
        let viewModel = DashboardViewModel(
            state: state,
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: nil,
            candleRepository: candleRepository,
            candleHistoryStore: candleRepository,
            candleBackfillRepository: backfillRepository,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry,
            historyBackfillPolicy: .test
        )

        viewModel.bootstrap()

        try await waitUntil(timeout: 3) {
            if case .complete(let totalRoutes, _, _) = viewModel.state.marketDataBootstrapStatus {
                return totalRoutes == symbols.count * CandleTimeframe.allCases.count
            }
            return false
        }

        let expectedRoutes = bootstrapRouteKeys(symbols: symbols)
        XCTAssertEqual(Set(backfillRepository.latestRequestKeys), expectedRoutes)
        XCTAssertEqual(Set(backfillRepository.historicalRequestKeys), expectedRoutes)

        for symbol in symbols {
            for timeframe in CandleTimeframe.allCases {
                let candles = try candleRepository.loadCandles(
                    symbol: symbol,
                    timeframe: timeframe,
                    limit: 1
                )
                XCTAssertFalse(candles.isEmpty)
                XCTAssertEqual(
                    try candleRepository.loadHistorySyncState(
                        symbol: symbol,
                        timeframe: timeframe
                    )?.isComplete,
                    true
                )
            }
        }
    }

    func testBootstrapSkipsRoutesWithCompleteSavedHistory() async throws {
        let symbols = [FuturesSymbol("BTCUSDT"), FuturesSymbol("ETHUSDT")]
        var state = DashboardState()
        state.watchlist = symbols

        let candleRepository = InMemoryCandleRepository()
        for symbol in symbols {
            for timeframe in CandleTimeframe.allCases {
                try candleRepository.saveHistorySyncState(.init(
                    productType: .usdtFutures,
                    symbol: symbol,
                    timeframe: timeframe,
                    isComplete: true,
                    oldestOpenTime: Date(timeIntervalSince1970: 0),
                    updatedAt: Date(timeIntervalSince1970: 1)
                ))
            }
        }

        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry()
        let backfillRepository = RecordingBootstrapCandleBackfillRepository()
        let viewModel = DashboardViewModel(
            state: state,
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: nil,
            candleRepository: candleRepository,
            candleHistoryStore: candleRepository,
            candleBackfillRepository: backfillRepository,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry,
            historyBackfillPolicy: .test
        )

        viewModel.bootstrap()

        try await waitUntil(timeout: 2) {
            if case .complete(let totalRoutes, let skippedRoutes, _) = viewModel.state.marketDataBootstrapStatus {
                return totalRoutes == symbols.count * CandleTimeframe.allCases.count &&
                    skippedRoutes == totalRoutes
            }
            return false
        }

        XCTAssertTrue(backfillRepository.latestRequestKeys.isEmpty)
        XCTAssertTrue(backfillRepository.historicalRequestKeys.isEmpty)
    }

    func testRefreshStartsWebSocketStreamAndAppliesLiveCandle() async throws {
        let symbol = FuturesSymbol("BTCUSDT")
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry()
        let backfillCandle = makeCandle(
            symbol: symbol,
            openTime: Date(timeIntervalSince1970: 4_102_444_800),
            close: 100,
            isClosed: true
        )
        let liveCandle = makeCandle(
            symbol: symbol,
            openTime: Date(timeIntervalSince1970: 4_102_445_700),
            close: 105,
            isClosed: false
        )
        let streamService = TestCandleStreamService()
        let viewModel = DashboardViewModel(
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: nil,
            candleRepository: candleRepository,
            candleBackfillRepository: StubCandleBackfillRepository(candles: [backfillCandle]),
            candleStreamService: streamService,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry
        )

        await viewModel.refreshCandlesFromBitget()
        try await waitUntil { streamService.hasSubscriber }
        streamService.emit(liveCandle)

        try await waitUntil {
            viewModel.state.candles.last?.close == 105 &&
                viewModel.state.candles.last?.isClosed == false
        }
    }

    func testHistoricalBackfillStoresOlderPagesAndMarksComplete() async throws {
        var state = DashboardState()
        let symbol = FuturesSymbol("LTCUSDT")
        state.watchlist = [symbol]
        state.selectedSymbol = symbol
        state.selectedTimeframe = .fifteenMinutes

        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry()
        let latestCandle = makeCandle(
            symbol: symbol,
            openTime: Date(timeIntervalSince1970: 3_600),
            close: 100,
            isClosed: true
        )
        let olderPage = [
            makeCandle(
                symbol: symbol,
                openTime: Date(timeIntervalSince1970: 2_700),
                close: 95,
                isClosed: true
            ),
            makeCandle(
                symbol: symbol,
                openTime: Date(timeIntervalSince1970: 1_800),
                close: 90,
                isClosed: true
            )
        ]
        let backfillRepository = StubCandleBackfillRepository(
            candles: [latestCandle],
            historicalPages: [olderPage, []]
        )
        let viewModel = DashboardViewModel(
            state: state,
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: nil,
            candleRepository: candleRepository,
            candleHistoryStore: candleRepository,
            candleBackfillRepository: backfillRepository,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry,
            historyBackfillPolicy: .test
        )

        await viewModel.refreshCandlesFromBitget()

        try await waitUntil {
            if case .complete = viewModel.state.candleHistoryStatus {
                return true
            }
            return false
        }

        let candles = try candleRepository.loadCandles(
            symbol: symbol,
            timeframe: .fifteenMinutes,
            limit: 10
        )
        let syncState = try candleRepository.loadHistorySyncState(
            symbol: symbol,
            timeframe: .fifteenMinutes
        )

        XCTAssertEqual(candles.map(\.openTime.timeIntervalSince1970), [1_800, 2_700, 3_600])
        XCTAssertEqual(syncState?.isComplete, true)
    }

    func testSymbolCatalogKeepsOnlyBitcoinAndEthereumInWatchlist() async throws {
        var state = DashboardState()
        state.strategyConfig.leverage = 120
        let specs = [
            makeContractSpec(symbol: FuturesSymbol("BTCUSDT"), maxLeverage: 150),
            makeContractSpec(symbol: FuturesSymbol("ETHUSDT"), maxLeverage: 8),
            makeContractSpec(symbol: FuturesSymbol("SUIUSDT"), maxLeverage: 50),
            makeContractSpec(symbol: FuturesSymbol("PEPEUSDT"), maxLeverage: 25)
        ]
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry()
        let viewModel = DashboardViewModel(
            state: state,
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: nil,
            symbolCatalogRepository: StubSymbolCatalogRepository(specs: specs),
            candleRepository: InMemoryCandleRepository(),
            candleBackfillRepository: nil,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry
        )

        await viewModel.loadSymbolCatalog()

        XCTAssertEqual(viewModel.state.symbolCatalog, Array(specs.prefix(2)))
        XCTAssertEqual(viewModel.state.watchlist, [FuturesSymbol("BTCUSDT"), FuturesSymbol("ETHUSDT")])
        XCTAssertEqual(viewModel.state.selectedSymbol, FuturesSymbol("BTCUSDT"))
        XCTAssertEqual(viewModel.state.strategyConfig.leverage, 10)

        viewModel.selectSymbol(FuturesSymbol("SUIUSDT"))
        XCTAssertEqual(viewModel.state.selectedSymbol, FuturesSymbol("BTCUSDT"))

        viewModel.selectSymbol(FuturesSymbol("ETHUSDT"))
        XCTAssertEqual(viewModel.state.selectedSymbol, FuturesSymbol("ETHUSDT"))
        XCTAssertEqual(viewModel.state.strategyConfig.leverage, 8)
        XCTAssertEqual(viewModel.selectedLeverageRange, 1...8)
    }

    func testBacktestRunsManuallyForConfiguredSymbolAndTimeframe() async throws {
        var state = DashboardState()
        state.watchlist = [FuturesSymbol("BTCUSDT"), FuturesSymbol("ETHUSDT")]
        state.selectedSymbol = FuturesSymbol("ETHUSDT")
        state.selectedTimeframe = .oneHour
        state.backtestConfiguration = BacktestConfiguration(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            strategyConfig: DonchianChannelBreakoutStrategy().definition.defaultConfig
        )

        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry()
        let viewModel = DashboardViewModel(
            state: state,
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: nil,
            candleRepository: candleRepository,
            candleBackfillRepository: nil,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry
        )

        XCTAssertEqual(viewModel.state.backtestStatus, .idle)

        viewModel.runBacktest()

        try await waitUntil {
            if case .complete = viewModel.state.backtestStatus {
                return true
            }
            return false
        }

        XCTAssertEqual(viewModel.state.selectedSymbol, FuturesSymbol("ETHUSDT"))
        XCTAssertEqual(viewModel.state.selectedTimeframe, .oneHour)
        XCTAssertEqual(viewModel.state.backtestResult?.symbol, FuturesSymbol("BTCUSDT"))
        XCTAssertEqual(viewModel.state.backtestResult?.timeframe, .fifteenMinutes)
        XCTAssertLessThanOrEqual(viewModel.backtestLeverageRange.upperBound, 10)
    }

    func testBacktestComparisonDoesNotReplacePrimaryResultWithGateResult() async throws {
        let symbol = FuturesSymbol("BTCUSDT")
        let timeframe = CandleTimeframe.fourHours
        var config = DonchianChannelBreakoutStrategy().definition.defaultConfig
        config.signalConfirmation = SignalConfirmationConfig(
            mode: .gate,
            requiredScore: 10,
            groupScoreCaps: SignalConfirmationConfig.optimizedDefault.groupScoreCaps
        )

        var state = DashboardState()
        state.watchlist = [symbol]
        state.backtestConfiguration = BacktestConfiguration(
            symbol: symbol,
            timeframe: timeframe,
            strategyConfig: config,
            initialCapital: 100,
            comparesSignalConfirmation: true
        )

        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let viewModel = DashboardViewModel(
            state: state,
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: nil,
            candleRepository: candleRepository,
            candleBackfillRepository: nil,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            backtestEngine: BacktestEngine(
                strategyRegistry: registry,
                confirmationEngine: SignalConfirmationEngine(rules: [])
            ),
            strategyRegistry: registry
        )

        let exit = dashboardCandle(
            symbol: symbol,
            timeframe: timeframe,
            offset: 141,
            open: 105,
            high: 130,
            low: 104,
            close: 128
        )
        try candleRepository.upsertCandles(
            dashboardDonchianBreakoutCandles(symbol: symbol, timeframe: timeframe, startOffset: 100) + [exit]
        )

        viewModel.runBacktest()

        try await waitUntil {
            if case .complete = viewModel.state.backtestStatus {
                return true
            }
            return false
        }

        XCTAssertGreaterThan(viewModel.state.backtestResult?.totalTrades ?? 0, 0)
        XCTAssertEqual(
            viewModel.state.backtestResult?.totalTrades,
            viewModel.state.backtestComparisonResult?.withoutSignalConfirmation.totalTrades
        )
        XCTAssertEqual(viewModel.state.backtestComparisonResult?.withSignalConfirmation.totalTrades, 0)
    }

    func testBacktestUsesAllStoredCandlesInsteadOfDisplayLimit() async throws {
        let symbol = FuturesSymbol("BTCUSDT")
        let timeframe = CandleTimeframe.fourHours
        let repository = BacktestAllHistoryCandleRepository(
            candles: dashboardDonchianBreakoutCandles(
                symbol: symbol,
                timeframe: timeframe,
                startOffset: 100
            ) + [
                dashboardCandle(
                    symbol: symbol,
                    timeframe: timeframe,
                    offset: 141,
                    open: 105,
                    high: 130,
                    low: 104,
                    close: 128
                )
            ]
        )
        var state = DashboardState()
        state.watchlist = [symbol]
        state.backtestConfiguration = BacktestConfiguration(
            symbol: symbol,
            timeframe: timeframe,
            strategyConfig: DonchianChannelBreakoutStrategy().definition.defaultConfig
        )
        let registry = StrategyRegistry(strategies: [DonchianChannelBreakoutStrategy()])
        let logStore = InMemoryTradeEventLogStore()
        let viewModel = DashboardViewModel(
            state: state,
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: nil,
            candleRepository: repository,
            candleBackfillRepository: nil,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry
        )

        viewModel.runBacktest()

        try await waitUntil {
            if case .complete = viewModel.state.backtestStatus {
                return true
            }
            return false
        }

        XCTAssertTrue(repository.didLoadAllCandles)
        XCTAssertEqual(repository.limitedLoadCount, 0)
        XCTAssertEqual(viewModel.state.backtestResult?.totalTrades, 1)
    }

    func testConnectStartsPositionStreamAndAppliesLivePositions() async throws {
        let positionStreamService = TestPositionStreamService()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry()
        let viewModel = DashboardViewModel(
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: nil,
            positionStreamService: positionStreamService,
            candleRepository: InMemoryCandleRepository(),
            candleBackfillRepository: nil,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry
        )

        viewModel.connectCredential(
            apiKey: "abcdefgh12345678",
            secretKey: "secret",
            passphrase: "passphrase"
        )

        try await waitUntil {
            viewModel.state.isConnected && positionStreamService.hasSubscriber
        }

        positionStreamService.emit([
            makePosition(
                symbol: FuturesSymbol("ETHUSDT"),
                unrealizedProfitLoss: 12.5,
                markPrice: 2562.5
            )
        ])

        try await waitUntil {
            viewModel.state.positions.first?.symbol == FuturesSymbol("ETHUSDT") &&
                viewModel.state.positions.first?.unrealizedProfitLoss == 12.5
        }
    }

    func testPositionProtectionLevelsAreRecoveredFromLiveEntryLog() throws {
        let symbol = FuturesSymbol("ETHUSDT")
        let entryLog = TradeEventLog(
            timestamp: Date(timeIntervalSince1970: 10),
            category: .liveOrder,
            symbol: symbol,
            message: "Live sell order submitted by donchian-channel-breakout on 1D.",
            metadata: TradeLogMetadata(
                title: "ETHUSDT 1D 매도 진입",
                details: [
                    TradeLogDetail(label: "손절가", value: "2347.645714285714"),
                    TradeLogDetail(label: "TP1", value: "2008.656428571429 / 50%"),
                    TradeLogDetail(label: "TP2", value: "1805.262857142858 / 50%")
                ]
            )
        )
        let position = PositionSnapshot(
            symbol: symbol,
            side: .short,
            total: 0.1,
            available: 0.1,
            openPriceAverage: 2212.01,
            markPrice: 2211.23,
            unrealizedProfitLoss: 0.078,
            leverage: 10,
            marginMode: "isolated",
            liquidationPrice: nil,
            takeProfit: nil,
            stopLoss: nil,
            createdAt: Date(timeIntervalSince1970: 11),
            updatedAt: Date(timeIntervalSince1970: 11)
        )

        let enriched = position.withChartProtectionLevels(from: [entryLog])

        XCTAssertEqual(enriched.takeProfit, Decimal(string: "1805.262857142858"))
        XCTAssertEqual(enriched.stopLoss, Decimal(string: "2347.645714285714"))
        XCTAssertEqual(
            enriched.chartProtectionLevels(from: [entryLog])?.partialTakeProfit,
            Decimal(string: "2008.656428571429")
        )
    }

    func testRefreshPositionsUsesExchangeProtectionOrdersBeforeEntryLogFallback() async throws {
        let symbol = FuturesSymbol("ETHUSDT")
        let positionRepository = StaticPositionRepository(positions: [
            PositionSnapshot(
                symbol: symbol,
                side: .short,
                total: 0.1,
                available: 0.1,
                openPriceAverage: 2200,
                markPrice: 2190,
                unrealizedProfitLoss: 1,
                leverage: 10,
                marginMode: "isolated",
                liquidationPrice: nil,
                takeProfit: nil,
                stopLoss: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 20)
            )
        ])
        let protectionRepository = StaticPositionProtectionRepository(orders: [
            PositionProtectionOrderSnapshot(
                symbol: symbol,
                side: .short,
                kind: .takeProfit,
                triggerPrice: 2100,
                executePrice: 2100,
                size: 0.05,
                orderID: "tp1",
                updatedAt: Date(timeIntervalSince1970: 21)
            ),
            PositionProtectionOrderSnapshot(
                symbol: symbol,
                side: .short,
                kind: .takeProfit,
                triggerPrice: 2000,
                executePrice: 2000,
                size: 0.05,
                orderID: "tp2",
                updatedAt: Date(timeIntervalSince1970: 22)
            ),
            PositionProtectionOrderSnapshot(
                symbol: symbol,
                side: .short,
                kind: .stopLoss,
                triggerPrice: 2300,
                executePrice: nil,
                size: 0.1,
                orderID: "sl",
                updatedAt: Date(timeIntervalSince1970: 23)
            )
        ])
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry()
        let viewModel = DashboardViewModel(
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: positionRepository,
            positionProtectionRepository: protectionRepository,
            candleRepository: InMemoryCandleRepository(),
            candleBackfillRepository: nil,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry
        )

        await viewModel.refreshPositions(logSuccess: false)

        let position = try XCTUnwrap(viewModel.state.positions.first)
        XCTAssertEqual(position.partialTakeProfit, 2100)
        XCTAssertEqual(position.takeProfit, 2000)
        XCTAssertEqual(position.stopLoss, 2300)
    }

    func testRefreshPositionsRecordsManualCloseOutcomeWhenPositionDisappears() async throws {
        let symbol = FuturesSymbol("BTCUSDT")
        let position = PositionSnapshot(
            symbol: symbol,
            side: .long,
            total: 0.2,
            available: 0.2,
            openPriceAverage: 100,
            markPrice: 104,
            unrealizedProfitLoss: 8,
            leverage: 10,
            marginMode: "isolated",
            positionMode: .hedge,
            liquidationPrice: nil,
            takeProfit: nil,
            stopLoss: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let positionRepository = MutablePositionRepository(positions: [position])
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry()
        let viewModel = DashboardViewModel(
            credentialStore: InMemoryCredentialStore(),
            accountRepository: nil,
            positionRepository: positionRepository,
            candleRepository: InMemoryCandleRepository(),
            candleBackfillRepository: nil,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry,
            clock: FixedClock(now: Date(timeIntervalSince1970: 100))
        )

        await viewModel.refreshPositions(logSuccess: false)
        positionRepository.positions = []
        await viewModel.refreshPositions(logSuccess: false)

        let logs = try logStore.loadRecent(limit: 10)
        let closeLog = try XCTUnwrap(logs.first { $0.metadata?.title == "BTCUSDT 수동 청산 감지" })
        XCTAssertEqual(closeLog.category, .liveOrder)
        XCTAssertEqual(closeLog.symbol, symbol)
        XCTAssertEqual(
            closeLog.metadata?.details.first { $0.label == "청산 직전 PnL" }?.value,
            "8"
        )
        XCTAssertEqual(
            closeLog.metadata?.details.first { $0.label == "청산 판정" }?.value,
            "승"
        )
    }

    private func makeViewModel(credentialStore: CredentialStore) -> DashboardViewModel {
        let candleRepository = InMemoryCandleRepository()
        let logStore = InMemoryTradeEventLogStore()
        let registry = StrategyRegistry()
        return DashboardViewModel(
            credentialStore: credentialStore,
            accountRepository: nil,
            positionRepository: nil,
            candleRepository: candleRepository,
            candleBackfillRepository: nil,
            logStore: logStore,
            signalEvaluator: TradingSignalEvaluator(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition.")
    }

    private func bootstrapRouteKeys(symbols: [FuturesSymbol]) -> Set<String> {
        Set(symbols.flatMap { symbol in
            CandleTimeframe.allCases.map { timeframe in
                bootstrapRouteKey(symbol: symbol, timeframe: timeframe)
            }
        })
    }

    private func bootstrapRouteKey(symbol: FuturesSymbol, timeframe: CandleTimeframe) -> String {
        "\(symbol.rawValue):\(timeframe.rawValue)"
    }

    private func dashboardPassingConfirmationEngine() -> SignalConfirmationEngine {
        SignalConfirmationEngine(rules: [
            DashboardEvidenceRule(id: "trend", group: .trend, score: 20),
            DashboardEvidenceRule(id: "momentum", group: .momentum, score: 5)
        ])
    }

    private func makeCandle(
        symbol: FuturesSymbol,
        openTime: Date,
        close: Decimal,
        isClosed: Bool
    ) -> Candle {
        Candle(
            productType: .usdtFutures,
            symbol: symbol,
            timeframe: .fifteenMinutes,
            openTime: openTime,
            open: close - 1,
            high: close + 2,
            low: close - 2,
            close: close,
            volume: 10,
            isClosed: isClosed
        )
    }

    private func makePosition(
        symbol: FuturesSymbol,
        unrealizedProfitLoss: Decimal,
        markPrice: Decimal
    ) -> PositionSnapshot {
        PositionSnapshot(
            symbol: symbol,
            side: .long,
            total: 0.2,
            available: 0.2,
            openPriceAverage: 2500,
            markPrice: markPrice,
            unrealizedProfitLoss: unrealizedProfitLoss,
            leverage: 20,
            marginMode: "crossed",
            liquidationPrice: nil,
            takeProfit: nil,
            stopLoss: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    private func makeContractSpec(symbol: FuturesSymbol, maxLeverage: Int) -> ContractSpec {
        ContractSpec(
            symbol: symbol,
            baseCoin: symbol.rawValue.replacingOccurrences(of: "USDT", with: ""),
            quoteCoin: "USDT",
            symbolStatus: "normal",
            supportMarginCoins: ["USDT"],
            minTradeNum: 1,
            minTradeUSDT: 5,
            sizeMultiplier: 1,
            pricePlace: 4,
            volumePlace: 0,
            minLeverage: 1,
            maxLeverage: maxLeverage
        )
    }

    private func dashboardDonchianBreakoutCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        startOffset: Int
    ) -> [Candle] {
        (0..<40).map { offset in
            dashboardCandle(
                symbol: symbol,
                timeframe: timeframe,
                offset: startOffset + offset,
                open: 100,
                high: 101,
                low: 99,
                close: 100
            )
        } + [
            dashboardCandle(
                symbol: symbol,
                timeframe: timeframe,
                offset: startOffset + 40,
                open: 100,
                high: 106,
                low: 99,
                close: 105
            )
        ]
    }

    private func dashboardCandle(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        offset: Int,
        open: Decimal,
        high: Decimal,
        low: Decimal,
        close: Decimal
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
            volume: 1_000,
            isClosed: true
        )
    }
}

private struct DashboardEvidenceRule: SignalConfirmationRule {
    let id: String
    let group: SignalEvidenceGroup
    let score: Decimal

    func evaluate(baseSignal: StrategySignal, context: StrategyContext) -> SignalEvidence? {
        SignalEvidence(id: id, group: group, score: score, reason: id)
    }
}

private final class BacktestAllHistoryCandleRepository: CandleRepository {
    private let candles: [Candle]
    private(set) var didLoadAllCandles = false
    private(set) var limitedLoadCount = 0

    init(candles: [Candle]) {
        self.candles = candles.sorted { $0.openTime < $1.openTime }
    }

    func loadCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) throws -> [Candle] {
        limitedLoadCount += 1
        return []
    }

    func loadAllCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) throws -> [Candle] {
        didLoadAllCandles = true
        return candles.filter { $0.symbol == symbol && $0.timeframe == timeframe }
    }

    func loadOldestCandleOpenTime(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) throws -> Date? {
        candles
            .filter { $0.symbol == symbol && $0.timeframe == timeframe }
            .map(\.openTime)
            .min()
    }

    func upsertCandles(_ candles: [Candle]) throws {}
}

private final class StubCandleBackfillRepository: CandleBackfillRepository {
    let candles: [Candle]
    private var historicalPages: [[Candle]]

    init(candles: [Candle], historicalPages: [[Candle]] = []) {
        self.candles = candles
        self.historicalPages = historicalPages
    }

    func fetchCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) async throws -> [Candle] {
        candles
    }

    func fetchHistoricalCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        endingBefore endTime: Date,
        limit: Int
    ) async throws -> [Candle] {
        guard !historicalPages.isEmpty else { return [] }
        return historicalPages.removeFirst()
    }
}

private final class RecordingBootstrapCandleBackfillRepository: CandleBackfillRepository {
    private let lock = NSLock()
    private var latestRequests: [String] = []
    private var historicalRequests: [String] = []

    var latestRequestKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return latestRequests
    }

    var historicalRequestKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return historicalRequests
    }

    func fetchCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) async throws -> [Candle] {
        let requestIndex = recordLatest(symbol: symbol, timeframe: timeframe)
        let close = Decimal(100 + requestIndex)
        return [
            Candle(
                productType: .usdtFutures,
                symbol: symbol,
                timeframe: timeframe,
                openTime: Date(timeIntervalSince1970: TimeInterval(requestIndex) * timeframe.duration),
                open: close - 1,
                high: close + 2,
                low: close - 2,
                close: close,
                volume: 10,
                isClosed: true
            )
        ]
    }

    func fetchHistoricalCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        endingBefore endTime: Date,
        limit: Int
    ) async throws -> [Candle] {
        recordHistorical(symbol: symbol, timeframe: timeframe)
        return []
    }

    private func recordLatest(symbol: FuturesSymbol, timeframe: CandleTimeframe) -> Int {
        lock.lock()
        defer { lock.unlock() }
        latestRequests.append(routeKey(symbol: symbol, timeframe: timeframe))
        return latestRequests.count
    }

    private func recordHistorical(symbol: FuturesSymbol, timeframe: CandleTimeframe) {
        lock.lock()
        defer { lock.unlock() }
        historicalRequests.append(routeKey(symbol: symbol, timeframe: timeframe))
    }

    private func routeKey(symbol: FuturesSymbol, timeframe: CandleTimeframe) -> String {
        "\(symbol.rawValue):\(timeframe.rawValue)"
    }
}

private final class TestCandleStreamService: CandleStreamService {
    private var continuation: AsyncStream<Candle>.Continuation?

    var hasSubscriber: Bool {
        continuation != nil
    }

    func streamCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) -> AsyncStream<Candle> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func emit(_ candle: Candle) {
        continuation?.yield(candle)
    }
}

private final class TestPositionStreamService: PositionStreamService {
    private var continuation: AsyncStream<[PositionSnapshot]>.Continuation?

    var hasSubscriber: Bool {
        continuation != nil
    }

    func streamPositions() -> AsyncStream<[PositionSnapshot]> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func emit(_ positions: [PositionSnapshot]) {
        continuation?.yield(positions)
    }
}

private struct StaticPositionRepository: PositionRepository {
    let positions: [PositionSnapshot]

    func fetchPositions() async throws -> [PositionSnapshot] {
        positions
    }
}

private final class MutablePositionRepository: PositionRepository {
    var positions: [PositionSnapshot]

    init(positions: [PositionSnapshot]) {
        self.positions = positions
    }

    func fetchPositions() async throws -> [PositionSnapshot] {
        positions
    }
}

private struct StaticPositionProtectionRepository: PositionProtectionRepository {
    let orders: [PositionProtectionOrderSnapshot]

    func fetchPendingPositionProtectionOrders() async throws -> [PositionProtectionOrderSnapshot] {
        orders
    }
}

private struct StubSymbolCatalogRepository: SymbolCatalogRepository {
    let specs: [ContractSpec]

    func fetchUSDTFuturesSymbols() async throws -> [ContractSpec] {
        specs
    }
}
