import Foundation

struct AppEnvironment {
    static let live = AppEnvironment()

    @MainActor
    func makeDashboardViewModel() -> DashboardViewModel {
        let credentialStore = KeychainCredentialStore()
        let strategyRegistry = StrategyRegistry()

        do {
            let databasePath = try Self.databasePath()
            let candleRepository = try SQLiteCandleRepository(path: databasePath)
            let logStore = try SQLiteTradeEventLogStore(path: databasePath)

            let restClient = BitgetRESTClient(credentialStore: credentialStore)
            let accountRepository = BitgetAccountRepository(client: restClient)
            let positionRepository = BitgetPositionRepository(client: restClient)
            let symbolCatalogRepository = BitgetSymbolCatalogRepository(client: restClient)
            let positionStreamService = Self.isRunningTests
                ? nil
                : BitgetPositionWebSocketClient(credentialStore: credentialStore)
            let candleBackfillRepository = Self.isRunningTests
                ? nil
                : BitgetCandleBackfillRepository(client: restClient)
            let candleStreamService = Self.isRunningTests
                ? nil
                : BitgetCandleWebSocketClient()
            let paperRunner = PaperTradingRunner(
                strategyRegistry: strategyRegistry,
                logStore: logStore
            )

            return DashboardViewModel(
                credentialStore: credentialStore,
                accountRepository: accountRepository,
                positionRepository: positionRepository,
                positionStreamService: positionStreamService,
                symbolCatalogRepository: symbolCatalogRepository,
                candleRepository: candleRepository,
                candleHistoryStore: candleRepository,
                candleBackfillRepository: candleBackfillRepository,
                candleStreamService: candleStreamService,
                logStore: logStore,
                paperRunner: paperRunner,
                strategyRegistry: strategyRegistry
            )
        } catch {
            let fallbackCredentialStore = InMemoryCredentialStore()
            let fallbackCandleRepository = InMemoryCandleRepository()
            let fallbackLogStore = InMemoryTradeEventLogStore()
            let paperRunner = PaperTradingRunner(
                strategyRegistry: strategyRegistry,
                logStore: fallbackLogStore
            )
            return DashboardViewModel(
                credentialStore: fallbackCredentialStore,
                accountRepository: nil,
                positionRepository: nil,
                candleRepository: fallbackCandleRepository,
                candleBackfillRepository: nil,
                logStore: fallbackLogStore,
                paperRunner: paperRunner,
                strategyRegistry: strategyRegistry
            )
        }
    }

    private static func databasePath() throws -> String {
        let supportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appURL = supportURL.appendingPathComponent("BucksCopy", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        return appURL.appendingPathComponent("BucksCopy.sqlite").path
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

final class InMemoryTradeEventLogStore: TradeEventLogStore {
    private var logs: [TradeEventLog] = []

    func append(_ log: TradeEventLog) throws {
        logs.append(log)
    }

    func loadRecent(limit: Int) throws -> [TradeEventLog] {
        Array(logs.suffix(limit))
    }
}

final class InMemoryCandleRepository: CandleRepository, CandleHistoryStateStore {
    private var candles: [Candle] = []
    private var historyStates: [String: CandleHistorySyncState] = [:]

    init() {
        candles = DemoDataSeeder.makeCandles(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            count: 120
        )
    }

    func loadCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) throws -> [Candle] {
        Array(candles
            .filter { $0.symbol == symbol && $0.timeframe == timeframe }
            .suffix(limit))
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

    func upsertCandles(_ candles: [Candle]) throws {
        for candle in candles {
            if let index = self.candles.firstIndex(where: { $0.id == candle.id }) {
                self.candles[index] = candle
            } else {
                self.candles.append(candle)
            }
        }
        self.candles.sort { $0.openTime < $1.openTime }
    }

    func loadHistorySyncState(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) throws -> CandleHistorySyncState? {
        historyStates[historyKey(symbol: symbol, timeframe: timeframe)]
    }

    func saveHistorySyncState(_ state: CandleHistorySyncState) throws {
        historyStates[historyKey(symbol: state.symbol, timeframe: state.timeframe)] = state
    }

    private func historyKey(symbol: FuturesSymbol, timeframe: CandleTimeframe) -> String {
        "\(ProductType.usdtFutures.rawValue):\(symbol.rawValue):\(timeframe.rawValue)"
    }
}
