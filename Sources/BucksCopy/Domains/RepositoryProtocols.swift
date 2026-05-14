import Foundation

protocol CredentialStore {
    func save(_ credential: APIKeyCredential) throws
    func load() throws -> APIKeyCredential?
    func delete() throws
}

protocol PositionRepository {
    func fetchPositions() async throws -> [PositionSnapshot]
}

protocol PositionStreamService {
    func streamPositions() -> AsyncStream<[PositionSnapshot]>
}

protocol SymbolCatalogRepository {
    func fetchUSDTFuturesSymbols() async throws -> [ContractSpec]
}

protocol CandleRepository {
    func loadCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) throws -> [Candle]

    func loadAllCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) throws -> [Candle]

    func loadOldestCandleOpenTime(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) throws -> Date?

    func upsertCandles(_ candles: [Candle]) throws
}

protocol CandleBackfillRepository {
    func fetchCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) async throws -> [Candle]

    func fetchHistoricalCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        endingBefore endTime: Date,
        limit: Int
    ) async throws -> [Candle]
}

protocol CandleHistoryStateStore {
    func loadHistorySyncState(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) throws -> CandleHistorySyncState?

    func saveHistorySyncState(_ state: CandleHistorySyncState) throws
}

protocol CandleStreamService {
    func streamCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) -> AsyncStream<Candle>
}

protocol TradeEventLogStore {
    func append(_ log: TradeEventLog) throws
    func loadRecent(limit: Int) throws -> [TradeEventLog]
}

protocol LiveOrderPlacing {
    func placeLiveOrder(_ intent: OrderIntent) async throws
}

protocol PositionProtectionInstalling {
    func installProtection(_ plan: ExchangeProtectionPlan) async throws -> [ExchangeProtectionReceipt]
}

protocol Clock {
    var now: Date { get }
}

struct SystemClock: Clock {
    var now: Date { Date() }
}
