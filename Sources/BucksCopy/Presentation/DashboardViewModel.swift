import Combine
import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var state: DashboardState

    let strategyRegistry: StrategyRegistry

    private let credentialStore: CredentialStore
    private let accountRepository: BitgetAccountRepository?
    private let positionRepository: PositionRepository?
    private let positionStreamService: PositionStreamService?
    private let symbolCatalogRepository: SymbolCatalogRepository?
    private let candleRepository: CandleRepository
    private let candleHistoryStore: CandleHistoryStateStore?
    private let candleBackfillRepository: CandleBackfillRepository?
    private let candleStreamService: CandleStreamService?
    private let logStore: TradeEventLogStore
    private let paperRunner: PaperTradingRunner
    private let clock: Clock
    private let historyBackfillPolicy: CandleHistoryBackfillPolicy
    private var candleRefreshTask: Task<Void, Never>?
    private var candleHistoryBackfillTask: Task<Void, Never>?
    private var candleStreamTask: Task<Void, Never>?
    private var positionStreamTask: Task<Void, Never>?
    private var positionPollingTask: Task<Void, Never>?
    private let initialCandleDisplayLimit = 2_500
    private var candleDisplayLimit = 2_500
    private let maxCandleDisplayLimit = 50_000
    private var sessionLogs: [TradeEventLog] = []
    private var emittedSessionLogKeys: Set<String> = []

    init(
        state: DashboardState = DashboardState(),
        credentialStore: CredentialStore,
        accountRepository: BitgetAccountRepository?,
        positionRepository: PositionRepository?,
        positionStreamService: PositionStreamService? = nil,
        symbolCatalogRepository: SymbolCatalogRepository? = nil,
        candleRepository: CandleRepository,
        candleHistoryStore: CandleHistoryStateStore? = nil,
        candleBackfillRepository: CandleBackfillRepository?,
        candleStreamService: CandleStreamService? = nil,
        logStore: TradeEventLogStore,
        paperRunner: PaperTradingRunner,
        strategyRegistry: StrategyRegistry,
        clock: Clock = SystemClock(),
        historyBackfillPolicy: CandleHistoryBackfillPolicy = .live
    ) {
        self.state = state
        self.credentialStore = credentialStore
        self.accountRepository = accountRepository
        self.positionRepository = positionRepository
        self.positionStreamService = positionStreamService
        self.symbolCatalogRepository = symbolCatalogRepository
        self.candleRepository = candleRepository
        self.candleHistoryStore = candleHistoryStore
        self.candleBackfillRepository = candleBackfillRepository
        self.candleStreamService = candleStreamService
        self.logStore = logStore
        self.paperRunner = paperRunner
        self.strategyRegistry = strategyRegistry
        self.clock = clock
        self.historyBackfillPolicy = historyBackfillPolicy
    }

    deinit {
        candleRefreshTask?.cancel()
        candleHistoryBackfillTask?.cancel()
        candleStreamTask?.cancel()
        positionStreamTask?.cancel()
        positionPollingTask?.cancel()
    }

    var strategyDefinitions: [StrategyDefinition] {
        strategyRegistry.definitions
    }

    func bootstrap() {
        do {
            if let credential = try credentialStore.load() {
                state.credentialStatus = .validating(redactedIdentifier: credential.redactedIdentifier)
                connectSavedCredential()
            }
            refreshSymbolCatalog()
            loadCandles()
            loadRecentLogs()
            startCandleBackfill()
        } catch {
            state.credentialStatus = .failed(message: sanitizedError(error))
        }
    }

    func connectCredential(apiKey: String, secretKey: String, passphrase: String) {
        let credential = APIKeyCredential(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            secretKey: secretKey.trimmingCharacters(in: .whitespacesAndNewlines),
            passphrase: passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        guard credential.isComplete else {
            state.credentialStatus = .failed(message: "Missing credential field.")
            return
        }

        do {
            try credentialStore.save(credential)
            state.credentialStatus = .validating(redactedIdentifier: credential.redactedIdentifier)
            Task {
                await validateCredential(credential)
            }
        } catch {
            state.credentialStatus = .failed(message: sanitizedError(error))
        }
    }

    func deleteCredential() {
        do {
            try credentialStore.delete()
            state.accounts = []
            state.positions = []
            state.credentialStatus = .disconnected
            stopPositionUpdates()
            appendSessionLog(.init(
                timestamp: clock.now,
                category: .credential,
                message: "Credential deleted."
            ))
        } catch {
            state.credentialStatus = .failed(message: sanitizedError(error))
        }
    }

    func connectSavedCredential() {
        Task {
            do {
                guard let credential = try credentialStore.load() else {
                    state.credentialStatus = .failed(message: "No saved credential.")
                    return
                }
                await validateCredential(credential)
            } catch {
                state.credentialStatus = .failed(message: sanitizedError(error))
            }
        }
    }

    private func validateCredential(_ credential: APIKeyCredential) async {
        do {
            state.credentialStatus = .validating(redactedIdentifier: credential.redactedIdentifier)
            try await refreshAccountSnapshot()
            state.credentialStatus = .connected(
                redactedIdentifier: credential.redactedIdentifier,
                checkedAt: clock.now
            )
            appendSessionLogOnce(key: "credential.connected", .init(
                timestamp: clock.now,
                category: .credential,
                message: "Bitget connected and credential stored in Keychain."
            ))
            await refreshPositions(logSuccess: true)
            startPositionUpdates()
        } catch {
            stopPositionUpdates()
            state.credentialStatus = .failed(message: sanitizedError(error))
        }
    }

    func refreshPositions(logSuccess: Bool = true) async {
        do {
            guard let positionRepository else { return }
            state.positions = try await positionRepository.fetchPositions()
            if logSuccess {
                appendSessionLogOnce(key: "positions.loaded", .init(
                    timestamp: clock.now,
                    category: .position,
                    message: "Loaded \(state.positions.count) read-only position(s)."
                ))
            }
        } catch {
            appendSessionLog(.init(
                timestamp: clock.now,
                category: .position,
                severity: .warning,
                message: sanitizedError(error)
            ))
        }
    }

    private func refreshAccountSnapshot() async throws {
        guard let accountRepository else { return }
        state.accounts = try await accountRepository.fetchAccounts()
    }

    func refreshSymbolCatalog() {
        Task {
            await loadSymbolCatalog()
        }
    }

    func loadSymbolCatalog() async {
        guard let symbolCatalogRepository else { return }
        do {
            let specs = try await symbolCatalogRepository.fetchUSDTFuturesSymbols()
            guard !specs.isEmpty else { return }
            state.symbolCatalog = specs
            state.watchlist = specs.map(\.symbol)

            if !state.watchlist.contains(state.selectedSymbol),
               let firstSymbol = state.watchlist.first {
                state.selectedSymbol = firstSymbol
                candleDisplayLimit = initialCandleDisplayLimit
                state.candleHistoryStatus = .idle
                stopLiveCandleStream()
                stopHistoricalCandleBackfill()
                loadCandles()
                startCandleBackfill()
            }

            state.strategyConfig.leverage = clampedLeverage(
                state.strategyConfig.leverage,
                for: state.selectedSymbol
            )
        } catch {
            appendSessionLogOnce(key: "symbols.failed", .init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                message: sanitizedError(error)
            ))
        }
    }

    func selectSymbol(_ symbol: FuturesSymbol) {
        guard state.watchlist.contains(symbol) else { return }
        state.selectedSymbol = symbol
        state.strategyConfig.leverage = clampedLeverage(state.strategyConfig.leverage, for: symbol)
        candleDisplayLimit = initialCandleDisplayLimit
        state.candleHistoryStatus = .idle
        stopLiveCandleStream()
        stopHistoricalCandleBackfill()
        loadCandles()
        startCandleBackfill()
    }

    func selectTimeframe(_ timeframe: CandleTimeframe) {
        state.selectedTimeframe = timeframe
        candleDisplayLimit = initialCandleDisplayLimit
        state.candleHistoryStatus = .idle
        stopLiveCandleStream()
        stopHistoricalCandleBackfill()
        loadCandles()
        startCandleBackfill()
    }

    func updateStrategy(_ strategyID: String) {
        state.strategyConfig.strategyID = strategyID
    }

    func updateLeverage(_ leverage: Int) {
        state.strategyConfig.leverage = clampedLeverage(leverage, for: state.selectedSymbol)
    }

    func updateLogLanguage(_ language: TradeLogLanguage) {
        state.logLanguage = language
    }

    func startPaperBot() {
        do {
            state.runState = .runningPaper(startedAt: clock.now)
            _ = try paperRunner.start(
                symbol: state.selectedSymbol,
                watchlist: state.watchlist,
                timeframe: state.selectedTimeframe,
                candles: state.candles.filter(\.isClosed),
                config: state.strategyConfig
            )
            loadRecentLogs()
        } catch {
            appendSessionLog(.init(
                timestamp: clock.now,
                category: .bot,
                severity: .error,
                symbol: state.selectedSymbol,
                message: sanitizedError(error)
            ))
        }
    }

    func stopPaperBot() {
        state.runState = .stopped
        appendSessionLog(.init(
            timestamp: clock.now,
            category: .bot,
            symbol: state.selectedSymbol,
            message: "Paper bot stopped."
        ))
    }

    func loadCandles() {
        do {
            state.candles = try candleRepository.loadCandles(
                symbol: state.selectedSymbol,
                timeframe: state.selectedTimeframe,
                limit: candleDisplayLimit
            )
            state.candleStatus = .loaded(count: state.candles.count, source: "Local DB")
        } catch {
            state.candleStatus = .failed(message: sanitizedError(error))
            appendSessionLog(.init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                message: sanitizedError(error)
            ))
        }
    }

    func loadMoreLocalCandles() {
        guard candleDisplayLimit < maxCandleDisplayLimit else { return }
        candleDisplayLimit = min(candleDisplayLimit * 2, maxCandleDisplayLimit)
        loadCandles()
    }

    func startCandleBackfill() {
        candleRefreshTask?.cancel()
        candleRefreshTask = Task {
            await refreshCandlesFromBitget()
        }
    }

    func refreshCandlesFromBitget() async {
        guard let candleBackfillRepository else { return }
        let symbol = state.selectedSymbol
        let timeframe = state.selectedTimeframe
        state.candleStatus = .loading

        do {
            let remoteCandles = try await candleBackfillRepository.fetchCandles(
                symbol: symbol,
                timeframe: timeframe,
                limit: 200
            )
            try candleRepository.upsertCandles(remoteCandles)

            guard state.selectedSymbol == symbol, state.selectedTimeframe == timeframe else {
                return
            }

            state.candles = try candleRepository.loadCandles(
                symbol: symbol,
                timeframe: timeframe,
                limit: candleDisplayLimit
            )
            state.candleStatus = .loaded(count: state.candles.count, source: "Bitget REST")
            startLiveCandleStream(symbol: symbol, timeframe: timeframe)
            startHistoricalCandleBackfill(symbol: symbol, timeframe: timeframe)
        } catch {
            state.candleStatus = .failed(message: sanitizedError(error))
            appendSessionLog(.init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                symbol: symbol,
                message: sanitizedError(error)
            ))
        }
    }

    private func startHistoricalCandleBackfill(symbol: FuturesSymbol, timeframe: CandleTimeframe) {
        guard candleHistoryStore != nil else { return }
        stopHistoricalCandleBackfill()
        candleHistoryBackfillTask = Task { [weak self] in
            await self?.syncHistoricalCandles(symbol: symbol, timeframe: timeframe)
        }
    }

    private func stopHistoricalCandleBackfill() {
        candleHistoryBackfillTask?.cancel()
        candleHistoryBackfillTask = nil
    }

    private func syncHistoricalCandles(symbol: FuturesSymbol, timeframe: CandleTimeframe) async {
        guard let candleBackfillRepository, let candleHistoryStore else { return }

        do {
            if try candleHistoryStore.loadHistorySyncState(
                symbol: symbol,
                timeframe: timeframe
            )?.isComplete == true {
                guard state.selectedSymbol == symbol, state.selectedTimeframe == timeframe else {
                    return
                }
                state.candleHistoryStatus = .complete(savedCount: 0)
                return
            }

            var endTime = try candleRepository.loadOldestCandleOpenTime(
                symbol: symbol,
                timeframe: timeframe
            ) ?? clock.now
            var savedCount = 0
            var pageCount = 0
            state.candleHistoryStatus = .syncing(savedCount: savedCount, pageCount: pageCount)

            while pageCount < historyBackfillPolicy.maxPagesPerRun {
                try Task.checkCancellation()
                let historicalCandles = try await candleBackfillRepository.fetchHistoricalCandles(
                    symbol: symbol,
                    timeframe: timeframe,
                    endingBefore: endTime,
                    limit: historyBackfillPolicy.pageLimit
                )
                let olderCandles = historicalCandles
                    .filter { $0.openTime < endTime }
                    .sorted { $0.openTime < $1.openTime }

                guard !olderCandles.isEmpty else {
                    try candleHistoryStore.saveHistorySyncState(.init(
                        productType: .usdtFutures,
                        symbol: symbol,
                        timeframe: timeframe,
                        isComplete: true,
                        oldestOpenTime: try candleRepository.loadOldestCandleOpenTime(
                            symbol: symbol,
                            timeframe: timeframe
                        ),
                        updatedAt: clock.now
                    ))
                    if state.selectedSymbol == symbol, state.selectedTimeframe == timeframe {
                        state.candleHistoryStatus = .complete(savedCount: savedCount)
                    }
                    return
                }

                try candleRepository.upsertCandles(olderCandles)
                endTime = olderCandles.first?.openTime ?? endTime
                savedCount += olderCandles.count
                pageCount += 1

                try candleHistoryStore.saveHistorySyncState(.init(
                    productType: .usdtFutures,
                    symbol: symbol,
                    timeframe: timeframe,
                    isComplete: false,
                    oldestOpenTime: endTime,
                    updatedAt: clock.now
                ))

                if state.selectedSymbol == symbol, state.selectedTimeframe == timeframe {
                    state.candleHistoryStatus = .syncing(savedCount: savedCount, pageCount: pageCount)
                    loadCandles()
                }

                guard historyBackfillPolicy.pageDelayNanoseconds > 0 else { continue }
                try await Task.sleep(nanoseconds: historyBackfillPolicy.pageDelayNanoseconds)
            }

            try candleHistoryStore.saveHistorySyncState(.init(
                productType: .usdtFutures,
                symbol: symbol,
                timeframe: timeframe,
                isComplete: false,
                oldestOpenTime: endTime,
                updatedAt: clock.now
            ))
            appendSessionLog(.init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                symbol: symbol,
                message: "Historical candle sync paused after \(pageCount) page(s) and \(savedCount) saved candle(s)."
            ))
        } catch is CancellationError {
            return
        } catch {
            if state.selectedSymbol == symbol, state.selectedTimeframe == timeframe {
                state.candleHistoryStatus = .failed(message: sanitizedError(error))
            }
            appendSessionLog(.init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                symbol: symbol,
                message: sanitizedError(error)
            ))
        }
    }

    private func startLiveCandleStream(symbol: FuturesSymbol, timeframe: CandleTimeframe) {
        guard let candleStreamService else { return }
        stopLiveCandleStream()
        candleStreamTask = Task { [weak self] in
            let stream = candleStreamService.streamCandles(symbol: symbol, timeframe: timeframe)
            for await candle in stream {
                await self?.handleLiveCandle(candle, symbol: symbol, timeframe: timeframe)
            }
        }
    }

    private func stopLiveCandleStream() {
        candleStreamTask?.cancel()
        candleStreamTask = nil
    }

    private func startPositionUpdates() {
        stopPositionUpdates()

        if let positionStreamService {
            positionStreamTask = Task { [weak self] in
                let stream = positionStreamService.streamPositions()
                for await positions in stream {
                    await self?.handleLivePositions(positions)
                }
            }
        }

        positionPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                do {
                    try await self?.refreshAccountSnapshot()
                    await self?.refreshPositions(logSuccess: false)
                } catch {
                    self?.appendPositionWarning(error)
                }
            }
        }
    }

    private func stopPositionUpdates() {
        positionStreamTask?.cancel()
        positionStreamTask = nil
        positionPollingTask?.cancel()
        positionPollingTask = nil
    }

    private func handleLivePositions(_ positions: [PositionSnapshot]) async {
        state.positions = positions.map { incoming in
            guard let previous = state.positions.first(where: { $0.id == incoming.id }) else {
                return incoming
            }
            return incoming.fillingMissingDetail(from: previous)
        }
    }

    private func appendPositionWarning(_ error: Error) {
        appendSessionLog(.init(
            timestamp: clock.now,
            category: .position,
            severity: .warning,
            message: sanitizedError(error)
        ))
    }

    private func handleLiveCandle(
        _ candle: Candle,
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) async {
        guard state.selectedSymbol == symbol, state.selectedTimeframe == timeframe else {
            return
        }

        do {
            var candlesToUpsert: [Candle] = []
            if let previous = state.candles.last,
               previous.symbol == symbol,
               previous.timeframe == timeframe,
               previous.openTime < candle.openTime,
               !previous.isClosed {
                candlesToUpsert.append(previous.withClosedState(true))
            }
            candlesToUpsert.append(candle)
            try candleRepository.upsertCandles(candlesToUpsert)
            state.candles = try candleRepository.loadCandles(
                symbol: symbol,
                timeframe: timeframe,
                limit: candleDisplayLimit
            )
            state.candleStatus = .loaded(count: state.candles.count, source: "Bitget WebSocket")
        } catch {
            appendSessionLog(.init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                symbol: symbol,
                message: sanitizedError(error)
            ))
        }
    }

    func loadRecentLogs() {
        refreshVisibleLogs()
    }

    private func appendSessionLog(_ log: TradeEventLog) {
        sessionLogs.append(log)
        sessionLogs = Array(sessionLogs.suffix(80))
        refreshVisibleLogs()
    }

    private func appendSessionLogOnce(key: String, _ log: TradeEventLog) {
        guard !emittedSessionLogKeys.contains(key) else { return }
        emittedSessionLogKeys.insert(key)
        appendSessionLog(log)
    }

    private func refreshVisibleLogs() {
        let persistentLogs = (try? logStore.loadRecent(limit: 200))?
            .filter(\.isPersistentTradingRecord) ?? []
        state.recentLogs = (persistentLogs + sessionLogs)
            .sorted { $0.timestamp < $1.timestamp }
    }

    var selectedLeverageRange: ClosedRange<Int> {
        let minLeverage = selectedContractSpec?.minLeverage ?? 1
        let maxLeverage = selectedContractSpec?.maxLeverage ?? 150
        return minLeverage...max(maxLeverage, minLeverage)
    }

    private var selectedContractSpec: ContractSpec? {
        state.symbolCatalog.first { $0.symbol == state.selectedSymbol }
    }

    private func clampedLeverage(_ leverage: Int, for symbol: FuturesSymbol) -> Int {
        let spec = state.symbolCatalog.first { $0.symbol == symbol }
        let minimum = spec?.minLeverage ?? 1
        let maximum = max(spec?.maxLeverage ?? 150, minimum)
        return min(max(leverage, minimum), maximum)
    }

    private func sanitizedError(_ error: Error) -> String {
        switch error {
        case BitgetClientError.missingCredential:
            return "Missing saved credential."
        case BitgetClientError.httpStatus(let status):
            return "Bitget request failed with HTTP \(status)."
        case BitgetClientError.apiError(let code, let message):
            return "Bitget API error \(code): \(message)"
        case TradingDomainError.liveTradingDisabled:
            return "Live trading is disabled."
        case TradingDomainError.strategyNotFound(let id):
            return "Strategy not found: \(id)"
        case TradingDomainError.selectedSymbolNotInWatchlist(let symbol):
            return "\(symbol.rawValue) is not in Watchlist."
        default:
            return "Operation failed: \(String(describing: type(of: error)))."
        }
    }
}

private extension Candle {
    func withClosedState(_ isClosed: Bool) -> Candle {
        Candle(
            productType: productType,
            symbol: symbol,
            timeframe: timeframe,
            openTime: openTime,
            open: open,
            high: high,
            low: low,
            close: close,
            volume: volume,
            isClosed: isClosed
        )
    }
}

private extension PositionSnapshot {
    func fillingMissingDetail(from previous: PositionSnapshot) -> PositionSnapshot {
        PositionSnapshot(
            symbol: symbol,
            side: side,
            total: total,
            available: available,
            openPriceAverage: openPriceAverage == 0 ? previous.openPriceAverage : openPriceAverage,
            markPrice: markPrice == 0 ? previous.markPrice : markPrice,
            unrealizedProfitLoss: unrealizedProfitLoss,
            leverage: leverage == 0 ? previous.leverage : leverage,
            marginMode: marginMode.isEmpty ? previous.marginMode : marginMode,
            liquidationPrice: liquidationPrice ?? previous.liquidationPrice,
            takeProfit: takeProfit ?? previous.takeProfit,
            stopLoss: stopLoss ?? previous.stopLoss,
            createdAt: createdAt ?? previous.createdAt,
            updatedAt: updatedAt ?? previous.updatedAt
        )
    }
}

struct CandleHistoryBackfillPolicy: Equatable {
    let pageLimit: Int
    let maxPagesPerRun: Int
    let pageDelayNanoseconds: UInt64

    static let live = CandleHistoryBackfillPolicy(
        pageLimit: 200,
        maxPagesPerRun: 1_000,
        pageDelayNanoseconds: 80_000_000
    )

    static let test = CandleHistoryBackfillPolicy(
        pageLimit: 200,
        maxPagesPerRun: 10,
        pageDelayNanoseconds: 0
    )
}
