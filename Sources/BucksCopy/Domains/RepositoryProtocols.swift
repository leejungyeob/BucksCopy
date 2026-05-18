import Foundation

protocol CredentialStore {
    func save(_ credential: APIKeyCredential) throws
    func load() throws -> APIKeyCredential?
    func delete() throws
}

protocol PositionRepository {
    func fetchPositions() async throws -> [PositionSnapshot]
}

protocol PositionProtectionRepository {
    func fetchPendingPositionProtectionOrders() async throws -> [PositionProtectionOrderSnapshot]
}

struct PositionProtectionOrderSnapshot: Equatable {
    let symbol: FuturesSymbol
    let side: PositionSide
    let kind: ExchangeProtectionOrderKind
    let triggerPrice: Decimal
    let executePrice: Decimal?
    let size: Decimal
    let orderID: String
    let updatedAt: Date?

    init(
        symbol: FuturesSymbol,
        side: PositionSide,
        kind: ExchangeProtectionOrderKind,
        triggerPrice: Decimal,
        executePrice: Decimal?,
        size: Decimal,
        orderID: String,
        updatedAt: Date?
    ) {
        self.symbol = symbol
        self.side = side
        self.kind = kind
        self.triggerPrice = triggerPrice
        self.executePrice = executePrice
        self.size = size
        self.orderID = orderID
        self.updatedAt = updatedAt
    }
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
    func placeMarketOrder(_ request: LiveOrderRequest) async throws -> LiveOrderReceipt
    func closePosition(symbol: FuturesSymbol, holdSide: PositionSide?) async throws -> LiveClosePositionReceipt
}

protocol LiveLeverageSetting {
    func setLeverage(symbol: FuturesSymbol, leverage: Int, marginCoin: String) async throws
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
