import XCTest
@testable import BucksCopy

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testTimeframeChangeReloadsCandlesForSelectedSymbol() throws {
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
            paperRunner: PaperTradingRunner(strategyRegistry: registry, logStore: logStore),
            strategyRegistry: registry
        )

        try candleRepository.upsertCandles(DemoDataSeeder.makeCandles(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .oneHour,
            count: 12
        ))

        viewModel.selectTimeframe(.oneHour)

        XCTAssertEqual(viewModel.state.selectedTimeframe, .oneHour)
        XCTAssertEqual(viewModel.state.candles.count, 12)
        XCTAssertTrue(viewModel.state.candles.allSatisfy { $0.timeframe == .oneHour })
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
            paperRunner: PaperTradingRunner(strategyRegistry: registry, logStore: logStore),
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
            paperRunner: PaperTradingRunner(strategyRegistry: registry, logStore: logStore),
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
            paperRunner: PaperTradingRunner(strategyRegistry: registry, logStore: logStore),
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
            strategyConfig: TrendPullbackStrategy().definition.defaultConfig
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
            paperRunner: PaperTradingRunner(strategyRegistry: registry, logStore: logStore),
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
            paperRunner: PaperTradingRunner(strategyRegistry: registry, logStore: logStore),
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
            paperRunner: PaperTradingRunner(strategyRegistry: registry, logStore: logStore),
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

private struct StubSymbolCatalogRepository: SymbolCatalogRepository {
    let specs: [ContractSpec]

    func fetchUSDTFuturesSymbols() async throws -> [ContractSpec] {
        specs
    }
}
