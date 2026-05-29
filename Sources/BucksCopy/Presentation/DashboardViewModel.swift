import Combine
import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    private static let defaultServerRunnerEndpoint = "https://api.buckscopy.com"

    @Published private(set) var state: DashboardState

    let strategyRegistry: StrategyRegistry

    private let credentialStore: CredentialStore
    private let accountRepository: BitgetAccountRepository?
    private let positionRepository: PositionRepository?
    private let positionProtectionRepository: PositionProtectionRepository?
    private let positionStreamService: PositionStreamService?
    private let symbolCatalogRepository: SymbolCatalogRepository?
    private let candleRepository: CandleRepository
    private let candleHistoryStore: CandleHistoryStateStore?
    private let candleBackfillRepository: CandleBackfillRepository?
    private let candleStreamService: CandleStreamService?
    private let logStore: TradeEventLogStore
    private let signalEvaluator: TradingSignalEvaluator
    private let serverRunnerConfigurationStore: ServerRunnerConfigurationStore
    private let serverPaperRunnerServiceFactory: (ServerRunnerConfiguration) -> ServerPaperRunnerService?
    private var serverPaperRunnerService: ServerPaperRunnerService?
    private var serverRunnerConfiguration: ServerRunnerConfiguration?
    private let liveMonitor: MultiTimeframeLiveTradingMonitor
    private let liveMonitorIntervalNanoseconds: UInt64
    private let backtestEngine: BacktestEngine
    private let clock: Clock
    private let historyBackfillPolicy: CandleHistoryBackfillPolicy
    private var localCandleLoadTask: Task<Void, Never>?
    private var activeLocalCandleLoadID: UUID?
    private var candleRefreshTask: Task<Void, Never>?
    private var candleHistoryBackfillTask: Task<Void, Never>?
    private var marketDataBootstrapTask: Task<Void, Never>?
    private var candleStreamTask: Task<Void, Never>?
    private var positionStreamTask: Task<Void, Never>?
    private var positionPollingTask: Task<Void, Never>?
    private var serverRunnerPollingTask: Task<Void, Never>?
    private var backtestTask: Task<Void, Never>?
    private var liveMonitorTask: Task<Void, Never>?
    private let initialCandleDisplayLimit = 1_200
    private var candleDisplayLimit = 1_200
    private let maxCandleDisplayLimit = 50_000
    private var sessionLogs: [TradeEventLog] = []
    private var emittedSessionLogKeys: Set<String> = []
    private var latestExchangeProtectionLevelsByPositionID: [String: ChartProtectionLevels]?

    init(
        state: DashboardState = DashboardState(),
        credentialStore: CredentialStore,
        accountRepository: BitgetAccountRepository?,
        positionRepository: PositionRepository?,
        positionProtectionRepository: PositionProtectionRepository? = nil,
        positionStreamService: PositionStreamService? = nil,
        symbolCatalogRepository: SymbolCatalogRepository? = nil,
        candleRepository: CandleRepository,
        candleHistoryStore: CandleHistoryStateStore? = nil,
        candleBackfillRepository: CandleBackfillRepository?,
        candleStreamService: CandleStreamService? = nil,
        logStore: TradeEventLogStore,
        signalEvaluator: TradingSignalEvaluator,
        liveExecutor: LiveTradeExecutor? = nil,
        serverPaperRunnerService: ServerPaperRunnerService? = nil,
        serverPaperRunnerConfiguration: ServerRunnerConfiguration? = nil,
        serverRunnerConfigurationStore: ServerRunnerConfigurationStore = InMemoryServerRunnerConfigurationStore(),
        serverPaperRunnerServiceFactory: @escaping (ServerRunnerConfiguration) -> ServerPaperRunnerService? = { configuration in
            guard let url = URL(string: configuration.endpoint) else { return nil }
            return ServerPaperRunnerHTTPClient(baseURL: url, authToken: configuration.authToken)
        },
        serverPaperRunnerEndpoint: String = "",
        backtestEngine: BacktestEngine? = nil,
        strategyRegistry: StrategyRegistry,
        clock: Clock = SystemClock(),
        historyBackfillPolicy: CandleHistoryBackfillPolicy = .live,
        liveMonitorIntervalNanoseconds: UInt64 = 3_000_000_000
    ) {
        var initialState = state
        if CandleTimeframe.dashboardCases.contains(initialState.selectedTimeframe) == false {
            initialState.selectedTimeframe = .fifteenMinutes
        }
        self.state = initialState
        self.credentialStore = credentialStore
        self.accountRepository = accountRepository
        self.positionRepository = positionRepository
        self.positionProtectionRepository = positionProtectionRepository
        self.positionStreamService = positionStreamService
        self.symbolCatalogRepository = symbolCatalogRepository
        self.candleRepository = candleRepository
        self.candleHistoryStore = candleHistoryStore
        self.candleBackfillRepository = candleBackfillRepository
        self.candleStreamService = candleStreamService
        self.logStore = logStore
        let resolvedLiveExecutor: LiveTradeExecutor
        if let liveExecutor {
            resolvedLiveExecutor = liveExecutor
        } else {
            let unavailableLiveOrderClient = UnavailableLiveOrderClient()
            resolvedLiveExecutor = LiveTradeExecutor(
                orderPlacer: unavailableLiveOrderClient,
                leverageSetter: unavailableLiveOrderClient,
                protectionInstaller: ExchangeProtectionInstaller(orderPlacer: unavailableLiveOrderClient),
                logStore: logStore,
                clock: clock
            )
        }
        self.signalEvaluator = signalEvaluator
        self.serverPaperRunnerService = serverPaperRunnerService
        self.serverRunnerConfiguration = serverPaperRunnerConfiguration
        self.serverRunnerConfigurationStore = serverRunnerConfigurationStore
        self.serverPaperRunnerServiceFactory = serverPaperRunnerServiceFactory
        self.liveMonitor = MultiTimeframeLiveTradingMonitor(
            candleRepository: candleRepository,
            candleBackfillRepository: candleBackfillRepository,
            signalEvaluator: signalEvaluator,
            liveExecutor: resolvedLiveExecutor,
            strategyRegistry: strategyRegistry
        )
        self.liveMonitorIntervalNanoseconds = liveMonitorIntervalNanoseconds
        self.backtestEngine = backtestEngine ?? BacktestEngine(strategyRegistry: strategyRegistry)
        self.strategyRegistry = strategyRegistry
        self.clock = clock
        self.historyBackfillPolicy = historyBackfillPolicy
        self.applyServerRunnerConfigurationToState(
            serverPaperRunnerConfiguration,
            fallbackEndpoint: serverPaperRunnerEndpoint
        )
        self.state.strategyConfig = routedStrategyConfig(
            self.state.strategyConfig,
            for: self.state.selectedTimeframe,
            symbol: self.state.selectedSymbol
        )
        if CandleTimeframe.dashboardCases.contains(self.state.backtestConfiguration.timeframe) {
            self.state.backtestConfiguration.strategyConfig = routedStrategyConfig(
                self.state.backtestConfiguration.strategyConfig,
                for: self.state.backtestConfiguration.timeframe,
                symbol: self.state.backtestConfiguration.symbol
            )
        }
    }

    deinit {
        localCandleLoadTask?.cancel()
        candleRefreshTask?.cancel()
        candleHistoryBackfillTask?.cancel()
        marketDataBootstrapTask?.cancel()
        candleStreamTask?.cancel()
        positionStreamTask?.cancel()
        positionPollingTask?.cancel()
        serverRunnerPollingTask?.cancel()
        backtestTask?.cancel()
        liveMonitorTask?.cancel()
    }

    var strategyDefinitions: [StrategyDefinition] {
        strategyRegistry.definitions
    }

    private var usdtAccount: AccountSnapshot? {
        state.accounts.first { $0.marginCoin.uppercased() == "USDT" }
    }

    private var usesServerBitgetSession: Bool {
        serverRunnerConfiguration?.redactedCredentialIdentifier != nil && serverPaperRunnerService != nil
    }

    func strategyDefinitions(for timeframe: CandleTimeframe) -> [StrategyDefinition] {
        strategyRegistry.definitions(recommendedFor: timeframe, symbol: state.selectedSymbol)
    }

    func strategyDefinitions(for timeframe: CandleTimeframe, symbol: FuturesSymbol) -> [StrategyDefinition] {
        strategyRegistry.definitions(recommendedFor: timeframe, symbol: symbol)
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
            loadSavedServerRunnerConnection()
            startSelectedLiveCandleStream()
            startInitialMarketDataSync()
            startServerRunnerPolling()
        } catch {
            state.credentialStatus = .failed(message: sanitizedError(error))
        }
    }

    func saveServerRunnerConnection(endpoint: String, authToken: String) {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = validatedServerEndpoint(trimmedEndpoint) else {
            state.serverRunnerConnectionState = .failed(message: "Invalid server endpoint.")
            return
        }

        let storedConfiguration = try? serverRunnerConfigurationStore.load()
        let existingToken = serverRunnerConfiguration?.authToken ?? storedConfiguration?.authToken
        let existingUserID = serverRunnerConfiguration?.authenticatedUserID ?? storedConfiguration?.authenticatedUserID
        let existingIdentifier = serverRunnerConfiguration?.redactedCredentialIdentifier ??
            storedConfiguration?.redactedCredentialIdentifier
        let configuration = ServerRunnerConfiguration(
            endpoint: url.absoluteString,
            authToken: trimmedToken.isEmpty ? existingToken : trimmedToken,
            authenticatedUserID: existingUserID,
            redactedCredentialIdentifier: existingIdentifier
        )
        guard let service = serverPaperRunnerServiceFactory(configuration) else {
            state.serverRunnerConnectionState = .failed(message: "Invalid server endpoint.")
            return
        }

        do {
            try serverRunnerConfigurationStore.save(configuration)
            serverRunnerConfiguration = configuration
            serverPaperRunnerService = service
            applyServerRunnerConfigurationToState(configuration)
            startServerRunnerPolling()
            refreshServerRunnerStatus()
        } catch {
            state.serverRunnerConnectionState = .failed(message: sanitizedError(error))
        }
    }

    func deleteServerRunnerConnection() {
        do {
            try serverRunnerConfigurationStore.delete()
            serverRunnerPollingTask?.cancel()
            serverRunnerConfiguration = nil
            serverPaperRunnerService = nil
            state.serverRunnerEndpoint = ""
            state.serverRunnerHasAuthToken = false
            state.serverRunnerRedactedAuthToken = nil
            state.serverRunnerConnectionState = .idle
            state.serverRunnerStatus = nil
            state.serverRunnerLogs = []
            refreshVisibleLogs()
        } catch {
            state.serverRunnerConnectionState = .failed(message: sanitizedError(error))
        }
    }

    func refreshServerRunnerStatus() {
        guard serverRunnerConfiguration?.hasAuthToken == true,
              serverPaperRunnerService != nil else { return }
        Task { [weak self] in
            await self?.loadServerRunnerSnapshot()
        }
    }

    func setServerPaperRunnerEnabled(_ enabled: Bool) {
        guard serverRunnerConfiguration?.hasAuthToken == true,
              let serverPaperRunnerService else { return }
        state.serverRunnerConnectionState = .refreshing
        Task { [weak self] in
            guard let self else { return }
            do {
                let control: ServerPaperRunnerControl
                let live: ServerLiveStatus
                if enabled {
                    control = try await serverPaperRunnerService.updateControl(enabled: true)
                    live = try await serverPaperRunnerService.updateLiveControl(
                        enabled: true,
                        acknowledgedRisk: true
                    )
                } else {
                    live = try await serverPaperRunnerService.updateLiveControl(
                        enabled: false,
                        acknowledgedRisk: false
                    )
                    control = try await serverPaperRunnerService.updateControl(enabled: false)
                }
                if let status = self.state.serverRunnerStatus {
                    self.state.serverRunnerStatus = ServerPaperRunnerStatus(
                        updatedAt: status.updatedAt,
                        mode: status.mode,
                        symbols: status.symbols,
                        latestClosedCandleOpenTime: status.latestClosedCandleOpenTime,
                        latestClosedCandleOpenTimeDate: status.latestClosedCandleOpenTimeDate,
                        savedCandles: status.savedCandles,
                        evaluations: status.evaluations,
                        skippedEvaluations: status.skippedEvaluations,
                        signals: status.signals,
                        failures: status.failures,
                        storagePath: status.storagePath,
                        control: control,
                        live: live
                    )
                }
                await self.loadServerRunnerSnapshot()
            } catch {
                self.state.serverRunnerConnectionState = .failed(message: self.sanitizedError(error))
            }
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

        let endpoint = state.serverRunnerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasConfiguredServer = endpoint.isEmpty == false ||
            serverRunnerConfiguration != nil ||
            serverPaperRunnerService != nil
        guard hasConfiguredServer else {
            connectLocalCredential(credential)
            return
        }
        let resolvedEndpoint = endpoint.isEmpty ? Self.defaultServerRunnerEndpoint : endpoint
        guard let url = validatedServerEndpoint(resolvedEndpoint) else {
            state.credentialStatus = .failed(message: "Server runner URL is invalid.")
            return
        }
        let loginConfiguration = ServerRunnerConfiguration(endpoint: url.absoluteString, authToken: nil)
        guard let loginService = serverPaperRunnerServiceFactory(loginConfiguration) else {
            connectLocalCredential(credential)
            return
        }

        state.credentialStatus = .validating(redactedIdentifier: credential.redactedIdentifier)
        state.serverRunnerConnectionState = .refreshing
        serverRunnerConfiguration = loginConfiguration
        serverPaperRunnerService = loginService
        applyServerRunnerConfigurationToState(loginConfiguration)
        try? serverRunnerConfigurationStore.save(loginConfiguration)
        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await loginService.loginWithBitgetCredential(credential)
                let configuration = ServerRunnerConfiguration(
                    endpoint: url.absoluteString,
                    authToken: session.authToken,
                    authenticatedUserID: session.userID,
                    redactedCredentialIdentifier: session.redactedIdentifier
                )
                guard let authenticatedService = self.serverPaperRunnerServiceFactory(configuration) else {
                    self.state.credentialStatus = .failed(message: "Server runner URL is invalid.")
                    return
                }
                try self.serverRunnerConfigurationStore.save(configuration)
                try? self.credentialStore.delete()
                self.serverRunnerConfiguration = configuration
                self.serverPaperRunnerService = authenticatedService
                self.state.accounts = session.accounts
                self.applyServerRunnerConfigurationToState(configuration)
                self.appendSessionLogOnce(key: "server-login.connected", .init(
                    timestamp: self.clock.now,
                    category: .credential,
                    message: "Bitget credential validated by server and app session token stored in Keychain."
                ))
                await self.loadServerRunnerSnapshot()
                self.startServerRunnerPolling()
                if self.state.isConnected == false {
                    self.state.credentialStatus = .connected(
                        redactedIdentifier: session.redactedIdentifier,
                        checkedAt: self.clock.now
                    )
                }
            } catch {
                self.state.credentialStatus = .failed(message: self.sanitizedError(error))
                self.state.serverRunnerConnectionState = .failed(message: self.sanitizedError(error))
            }
        }
    }

    private func connectLocalCredential(_ credential: APIKeyCredential) {
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
        let serverLogoutService = usesServerBitgetSession ? serverPaperRunnerService : nil
        let preservedEndpoint = serverRunnerConfiguration?.endpoint ??
            (state.serverRunnerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultServerRunnerEndpoint
                : state.serverRunnerEndpoint)
        let unauthenticatedConfiguration = ServerRunnerConfiguration(
            endpoint: preservedEndpoint,
            authToken: nil
        )
        do {
            try credentialStore.delete()
            try? serverRunnerConfigurationStore.save(unauthenticatedConfiguration)
            stopLiveBot()
            state.accounts = []
            state.positions = []
            state.liveAutomationSession = nil
            state.credentialStatus = .disconnected
            serverRunnerPollingTask?.cancel()
            serverRunnerConfiguration = unauthenticatedConfiguration
            serverPaperRunnerService = serverPaperRunnerServiceFactory(unauthenticatedConfiguration)
            applyServerRunnerConfigurationToState(unauthenticatedConfiguration)
            state.serverRunnerConnectionState = .idle
            state.serverRunnerStatus = nil
            state.serverRunnerLogs = []
            stopPositionUpdates()
            appendSessionLog(.init(
                timestamp: clock.now,
                category: .credential,
                message: "Credential deleted."
            ))
            if let serverLogoutService {
                Task { @MainActor [weak self] in
                    do {
                        try await serverLogoutService.logoutSession()
                    } catch {
                        self?.appendServerLogoutWarning(error)
                    }
                }
            }
        } catch {
            state.credentialStatus = .failed(message: sanitizedError(error))
        }
    }

    private func appendServerLogoutWarning(_ error: Error) {
        appendSessionLog(.init(
            timestamp: clock.now,
            category: .credential,
            severity: .warning,
            message: "Server session revoke failed: \(sanitizedError(error))"
        ))
    }

    func connectSavedCredential() {
        Task {
            do {
                let savedConfiguration = serverRunnerConfiguration ?? (try? serverRunnerConfigurationStore.load())
                if let configuration = savedConfiguration, configuration.hasAuthToken {
                    guard let service = serverPaperRunnerServiceFactory(configuration) else {
                        state.credentialStatus = .failed(message: "Server runner URL is invalid.")
                        return
                    }
                    serverRunnerConfiguration = configuration
                    serverPaperRunnerService = service
                    applyServerRunnerConfigurationToState(configuration)
                    if let redactedIdentifier = configuration.redactedCredentialIdentifier {
                        state.credentialStatus = .validating(redactedIdentifier: redactedIdentifier)
                    }
                    await loadServerRunnerSnapshot()
                    return
                }
                if let credential = try credentialStore.load() {
                    await validateCredential(credential)
                    return
                }
                if let configuration = savedConfiguration {
                    serverRunnerConfiguration = configuration
                    serverPaperRunnerService = serverPaperRunnerServiceFactory(configuration)
                    applyServerRunnerConfigurationToState(configuration)
                    state.credentialStatus = .disconnected
                    state.serverRunnerConnectionState = .idle
                    return
                }
                state.credentialStatus = .disconnected
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
            if usesServerBitgetSession, let serverPaperRunnerService {
                let previousOpenPositions = state.positions.filter(\.isOpenForManualCloseDetection)
                let positions = try await serverPaperRunnerService.fetchPositions()
                state.positions = positionsWithChartProtectionLevels(positions)
                recordExternallyClosedPositions(
                    previousOpenPositions: previousOpenPositions,
                    currentOpenPositions: state.positions.filter(\.isOpenForManualCloseDetection)
                )
                if logSuccess {
                    appendSessionLogOnce(key: "server.positions.loaded", .init(
                        timestamp: clock.now,
                        category: .position,
                        message: "Loaded \(state.positions.count) server read-only position(s)."
                    ))
                }
                return
            }

            guard let positionRepository else { return }
            let previousOpenPositions = state.positions.filter(\.isOpenForManualCloseDetection)
            let positions = try await positionRepository.fetchPositions()
            let exchangeProtectionLevels = await fetchExchangeProtectionLevelsByPositionID(
                positions: positions
            )
            state.positions = positionsWithChartProtectionLevels(
                positions,
                exchangeProtectionLevelsByPositionID: exchangeProtectionLevels
            )
            recordExternallyClosedPositions(
                previousOpenPositions: previousOpenPositions,
                currentOpenPositions: state.positions.filter(\.isOpenForManualCloseDetection)
            )
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

    private func recordExternallyClosedPositions(
        previousOpenPositions: [PositionSnapshot],
        currentOpenPositions: [PositionSnapshot]
    ) {
        guard previousOpenPositions.isEmpty == false else { return }

        let currentIDs = Set(currentOpenPositions.map(\.id))
        let closedPositions = previousOpenPositions.filter { currentIDs.contains($0.id) == false }
        for position in closedPositions where !hasRecentAppCloseLog(for: position) {
            appendAutomationLog(externallyClosedPositionLog(for: position))
        }
    }

    private func hasRecentAppCloseLog(for position: PositionSnapshot) -> Bool {
        let recentWindow = clock.now.addingTimeInterval(-120)
        let logs = state.automationLogs.filter {
            $0.timestamp >= recentWindow &&
                $0.category == .liveOrder &&
                $0.symbol == position.symbol
        }
        return logs.contains { log in
            let text = "\(log.metadata?.title ?? "") \(log.metadata?.subtitle ?? "") \(log.message)"
            return text.contains("Live position close submitted") ||
                text.contains("Fail-closed live position close submitted") ||
                text.contains("기존 포지션 정리") ||
                text.contains("시장가 정리")
        }
    }

    private func externallyClosedPositionLog(for position: PositionSnapshot) -> TradeEventLog {
        let sideText = position.side == .unknown ? position.positionMode.rawValue : position.side.rawValue
        let outcomeText = closeOutcomeText(for: position.unrealizedProfitLoss)
        let outcomeTone = closeOutcomeTone(for: position.unrealizedProfitLoss)

        return TradeEventLog(
            timestamp: clock.now,
            category: .liveOrder,
            symbol: position.symbol,
            message: "External/manual close detected for \(position.symbol.rawValue) \(sideText).",
            metadata: TradeLogMetadata(
                title: "\(position.symbol.rawValue) 수동 청산 감지",
                subtitle: "Refresh 결과 이전에 열려 있던 \(sideText) 포지션이 거래소에서 사라져 마지막 확인 PnL 기준으로 확정 승패에 반영했습니다.",
                tags: [
                    TradeLogTag(label: "LIVE", tone: .success),
                    TradeLogTag(label: "수동청산", tone: .warning),
                    TradeLogTag(label: sideText.uppercased(), tone: .neutral),
                    TradeLogTag(label: outcomeText, tone: outcomeTone)
                ],
                details: [
                    TradeLogDetail(label: "심볼", value: position.symbol.rawValue),
                    TradeLogDetail(label: "포지션 방향", value: sideText),
                    TradeLogDetail(label: "마지막 수량", value: DecimalText.string(position.total)),
                    TradeLogDetail(label: "마지막 마크가", value: DecimalText.string(position.markPrice)),
                    TradeLogDetail(
                        label: "청산 직전 PnL",
                        value: DecimalText.string(position.unrealizedProfitLoss),
                        tone: outcomeTone
                    ),
                    TradeLogDetail(label: "청산 판정", value: outcomeText, tone: outcomeTone),
                    TradeLogDetail(label: "처리", value: "Refresh 감지")
                ]
            )
        )
    }

    private func closeOutcomeText(for profitLoss: Decimal) -> String {
        if profitLoss > 0 { return "승" }
        if profitLoss < 0 { return "패" }
        return "본전"
    }

    private func closeOutcomeTone(for profitLoss: Decimal) -> TradeLogTone {
        if profitLoss > 0 { return .success }
        if profitLoss < 0 { return .danger }
        return .neutral
    }

    private func refreshAccountSnapshot() async throws {
        if usesServerBitgetSession, let serverPaperRunnerService {
            state.accounts = try await serverPaperRunnerService.fetchAccounts()
            updateLiveAutomationSessionFromAccount()
            return
        }

        guard let accountRepository else { return }
        state.accounts = try await accountRepository.fetchAccounts()
        updateLiveAutomationSessionFromAccount()
    }

    private func updateLiveAutomationSessionFromAccount() {
        guard var session = state.liveAutomationSession,
              let account = usdtAccount else { return }
        session.latestEquity = account.accountEquity
        session.latestAvailable = account.available
        session.latestUnrealizedProfitLoss = account.unrealizedProfitLoss
        session.lastUpdatedAt = account.updatedAt
        state.liveAutomationSession = session
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
            let dashboardSpecs = dashboardContractSpecs(from: specs)
            guard !dashboardSpecs.isEmpty else { return }
            state.symbolCatalog = dashboardSpecs
            state.watchlist = dashboardSpecs.map(\.symbol)

            if !state.watchlist.contains(state.backtestConfiguration.symbol),
               let firstSymbol = state.watchlist.first {
                state.backtestConfiguration.symbol = firstSymbol
                resetBacktest()
            }

            if !state.watchlist.contains(state.selectedSymbol),
               let firstSymbol = state.watchlist.first {
                state.selectedSymbol = firstSymbol
                candleDisplayLimit = initialCandleDisplayLimit
                state.candleHistoryStatus = .idle
                stopLiveCandleStream()
                stopHistoricalCandleBackfill()
                loadCandles()
                startSelectedLiveCandleStream()
            }

            state.strategyConfig.leverage = clampedLeverage(
                state.strategyConfig.leverage,
                for: state.selectedSymbol
            )
            state.backtestConfiguration.strategyConfig.leverage = clampedLeverage(
                state.backtestConfiguration.strategyConfig.leverage,
                for: state.backtestConfiguration.symbol
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
        state.strategyConfig = routedStrategyConfig(
            state.strategyConfig,
            for: state.selectedTimeframe,
            symbol: symbol
        )
        candleDisplayLimit = initialCandleDisplayLimit
        state.candleHistoryStatus = .idle
        stopLiveCandleStream()
        loadCandles()
        startSelectedLiveCandleStream()
    }

    func selectTimeframe(_ timeframe: CandleTimeframe) {
        guard CandleTimeframe.dashboardCases.contains(timeframe) else { return }
        state.selectedTimeframe = timeframe
        state.strategyConfig = routedStrategyConfig(
            state.strategyConfig,
            for: timeframe,
            symbol: state.selectedSymbol
        )
        candleDisplayLimit = initialCandleDisplayLimit
        state.candleHistoryStatus = .idle
        stopLiveCandleStream()
        loadCandles()
        startSelectedLiveCandleStream()
    }

    func updateStrategy(_ strategyID: String) {
        guard StrategyTimeframeRouting.isRecommended(
            strategyID: strategyID,
            for: state.selectedTimeframe,
            symbol: state.selectedSymbol
        ),
              let definition = strategyRegistry.definition(id: strategyID) else { return }
        var nextConfig = state.strategyConfig
        nextConfig.strategyID = definition.id
        nextConfig.parameters = definition.defaultConfig.parameters
        nextConfig.leverage = clampedLeverage(nextConfig.leverage, for: state.selectedSymbol)
        state.strategyConfig = nextConfig
    }

    func updateLeverage(_ leverage: Int) {
        state.strategyConfig.leverage = clampedLeverage(leverage, for: state.selectedSymbol)
    }

    func updateMaximumRiskPerTrade(_ maximumRiskPerTradePercent: Decimal) {
        state.strategyConfig.maximumRiskPerTradePercent = clampedMaximumRiskPerTradePercent(
            maximumRiskPerTradePercent
        )
    }

    func updateMaximumPositionMargin(_ maximumPositionMarginPercent: Decimal) {
        state.strategyConfig.maximumPositionMarginPercent = clampedMaximumPositionMarginPercent(
            maximumPositionMarginPercent
        )
    }

    func updateSignalConfirmationMode(_ mode: SignalConfirmationMode) {
        state.strategyConfig.signalConfirmation.mode = mode
    }

    func selectBacktestSymbol(_ symbol: FuturesSymbol) {
        guard state.watchlist.contains(symbol) else { return }
        state.backtestConfiguration.symbol = symbol
        state.backtestConfiguration.strategyConfig = routedStrategyConfig(
            state.backtestConfiguration.strategyConfig,
            for: state.backtestConfiguration.timeframe,
            symbol: symbol
        )
        resetBacktest()
    }

    func selectBacktestTimeframe(_ timeframe: CandleTimeframe) {
        guard CandleTimeframe.dashboardCases.contains(timeframe) else { return }
        state.backtestConfiguration.timeframe = timeframe
        state.backtestConfiguration.strategyConfig = routedStrategyConfig(
            state.backtestConfiguration.strategyConfig,
            for: timeframe,
            symbol: state.backtestConfiguration.symbol
        )
        resetBacktest()
    }

    func updateBacktestStrategy(_ strategyID: String) {
        guard StrategyTimeframeRouting.isRecommended(
            strategyID: strategyID,
            for: state.backtestConfiguration.timeframe,
            symbol: state.backtestConfiguration.symbol
        ), let definition = strategyRegistry.definition(id: strategyID) else { return }
        var nextConfiguration = state.backtestConfiguration
        nextConfiguration.strategyConfig.strategyID = definition.id
        nextConfiguration.strategyConfig.parameters = definition.defaultConfig.parameters
        nextConfiguration.strategyConfig.leverage = clampedLeverage(
            nextConfiguration.strategyConfig.leverage,
            for: nextConfiguration.symbol
        )
        state.backtestConfiguration = nextConfiguration
        resetBacktest()
    }

    func updateBacktestLeverage(_ leverage: Int) {
        state.backtestConfiguration.strategyConfig.leverage = clampedLeverage(
            leverage,
            for: state.backtestConfiguration.symbol
        )
        resetBacktest()
    }

    func updateBacktestMaximumRiskPerTrade(_ maximumRiskPerTradePercent: Decimal) {
        state.backtestConfiguration.strategyConfig.maximumRiskPerTradePercent = clampedMaximumRiskPerTradePercent(
            maximumRiskPerTradePercent
        )
        resetBacktest()
    }

    func updateBacktestMaximumPositionMargin(_ maximumPositionMarginPercent: Decimal) {
        state.backtestConfiguration.strategyConfig.maximumPositionMarginPercent = clampedMaximumPositionMarginPercent(
            maximumPositionMarginPercent
        )
        resetBacktest()
    }

    func updateBacktestInitialCapital(_ initialCapital: Decimal) {
        state.backtestConfiguration.initialCapital = clampedBacktestInitialCapital(initialCapital)
        resetBacktest()
    }

    func updateBacktestSignalConfirmationMode(_ mode: SignalConfirmationMode) {
        state.backtestConfiguration.strategyConfig.signalConfirmation.mode = mode
        resetBacktest()
    }

    func updateBacktestConfirmationComparisonEnabled(_ isEnabled: Bool) {
        state.backtestConfiguration.comparesSignalConfirmation = isEnabled
        resetBacktest()
    }

    func updateLogLanguage(_ language: TradeLogLanguage) {
        state.logLanguage = language
    }

    func startLiveBot() {
        let hasLocalCredential = ((try? credentialStore.load())?.isComplete ?? false)
        guard hasLocalCredential || serverRunnerConfiguration?.redactedCredentialIdentifier == nil else {
            appendSessionLogOnce(key: "live.start.server-session-only", .init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                message: "Live trading requires a local live credential; server login currently enables paper runner access only."
            ))
            return
        }
        liveMonitorTask?.cancel()

        let startedAt = clock.now
        let account = usdtAccount
        state.liveAutomationSession = LiveAutomationSession(
            startedAt: startedAt,
            stoppedAt: nil,
            seedEquity: account?.accountEquity,
            seedAvailable: account?.available,
            latestEquity: account?.accountEquity,
            latestAvailable: account?.available,
            latestUnrealizedProfitLoss: account?.unrealizedProfitLoss,
            lastUpdatedAt: account?.updatedAt ?? startedAt
        )
        state.runState = .runningLive(startedAt: startedAt)
        appendAutomationLog(automationSessionLog(
            title: "자동매매 세션 시작",
            subtitle: "이번 세션의 시작 시드를 저장했고, 하단 기록 패널은 이전 세션까지 포함한 전체 자동매매 장부를 누적 표시합니다.",
            timestamp: startedAt,
            message: "Live automation session started.",
            account: account,
            tags: [
                TradeLogTag(label: "LIVE", tone: .success),
                TradeLogTag(label: "START", tone: .accent),
                TradeLogTag(label: "누적 장부", tone: .neutral)
            ]
        ))
        appendSessionLog(.init(
            timestamp: startedAt,
            category: .bot,
            message: "Live auto trading started for Watchlist on 15m closed candles."
        ))

        liveMonitorTask = Task { [weak self] in
            guard let self else { return }
            await self.primeLiveMonitorAtStart()
            while !Task.isCancelled {
                await self.runLiveMonitorOnce()

                do {
                    try await Task.sleep(nanoseconds: self.liveMonitorIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    private func primeLiveMonitorAtStart() async {
        let watchlist = state.watchlist
        guard !watchlist.isEmpty, state.isConnected else { return }

        let result = await liveMonitor.primeLatestClosedCandles(watchlist: watchlist)
        appendSessionLogOnce(key: "live-monitor.primed", .init(
            timestamp: clock.now,
            category: .bot,
            message: "Live monitor armed after marking \(result.primedCount) latest completed 15m candle route(s) as already seen. New entries can start from the next completed candle."
        ))

        for failure in result.failures.prefix(3) {
            appendSessionLogOnce(key: "live-monitor.prime.failure.\(failure.symbol.rawValue).\(failure.timeframe.rawValue)", .init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                symbol: failure.symbol,
                message: "Live monitor warmup skipped \(failure.timeframe.rawValue): \(failure.message)"
            ))
        }
    }

    func runBacktest() {
        backtestTask?.cancel()

        let configuration = state.backtestConfiguration
        let candleRepository = self.candleRepository
        let backtestEngine = self.backtestEngine
        let startedAt = clock.now

        state.backtestStatus = .running(startedAt: startedAt)
        state.backtestResult = nil
        state.backtestComparisonResult = nil

        backtestTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try Task.checkCancellation()
                let candles = try candleRepository.loadAllCandles(
                    symbol: configuration.symbol,
                    timeframe: configuration.timeframe
                )
                try Task.checkCancellation()
                if configuration.comparesSignalConfirmation {
                    let comparison = try backtestEngine.runSignalConfirmationComparison(
                        symbol: configuration.symbol,
                        timeframe: configuration.timeframe,
                        candles: candles,
                        config: configuration.strategyConfig,
                        initialCapital: configuration.initialCapital
                    )
                    try Task.checkCancellation()
                    await self?.completeBacktest(
                        comparison.withoutSignalConfirmation,
                        comparison: comparison,
                        configuration: configuration
                    )
                } else {
                    let result = try backtestEngine.run(
                        symbol: configuration.symbol,
                        timeframe: configuration.timeframe,
                        candles: candles,
                        config: configuration.strategyConfig,
                        initialCapital: configuration.initialCapital
                    )
                    try Task.checkCancellation()
                    await self?.completeBacktest(result, comparison: nil, configuration: configuration)
                }
            } catch is CancellationError {
                await self?.cancelBacktestIfCurrent(configuration)
            } catch {
                await self?.failBacktest(error, configuration: configuration)
            }
        }
    }

    func stopLiveBot() {
        let stoppedAt = clock.now
        let wasRunning: Bool
        if case .runningLive = state.runState {
            wasRunning = true
        } else {
            wasRunning = false
        }
        liveMonitorTask?.cancel()
        liveMonitorTask = nil
        markLiveAutomationSessionStopped(at: stoppedAt)
        state.runState = .stopped
        if wasRunning {
            appendAutomationLog(automationSessionLog(
                title: "자동매매 세션 정지",
                subtitle: "자동매매 루프를 정지했습니다. 누적 기록은 삭제하지 않고 다음 시작 후에도 계속 합산합니다.",
                timestamp: stoppedAt,
                message: "Live automation session stopped.",
                account: usdtAccount,
                tags: [
                    TradeLogTag(label: "LIVE", tone: .success),
                    TradeLogTag(label: "STOP", tone: .warning),
                    TradeLogTag(label: "누적 유지", tone: .neutral)
                ]
            ))
        }
        appendSessionLog(.init(
            timestamp: stoppedAt,
            category: .bot,
            symbol: state.selectedSymbol,
            message: "Live auto trading stopped."
        ))
    }

    private func markLiveAutomationSessionStopped(at stoppedAt: Date) {
        guard var session = state.liveAutomationSession else { return }
        if let account = usdtAccount {
            session.latestEquity = account.accountEquity
            session.latestAvailable = account.available
            session.latestUnrealizedProfitLoss = account.unrealizedProfitLoss
            session.lastUpdatedAt = account.updatedAt
        }
        if session.stoppedAt == nil {
            session.stoppedAt = stoppedAt
        }
        state.liveAutomationSession = session
    }

    private func automationSessionLog(
        title: String,
        subtitle: String,
        timestamp: Date,
        message: String,
        account: AccountSnapshot?,
        tags: [TradeLogTag]
    ) -> TradeEventLog {
        var details = [
            TradeLogDetail(label: "기록 범위", value: "전체 자동매매 누적", tone: .accent),
            TradeLogDetail(label: "시각", value: timestamp.dashboardDateTime)
        ]
        if let account {
            details.append(TradeLogDetail(
                label: "시드 Equity",
                value: DecimalText.string(account.accountEquity),
                tone: .accent
            ))
            details.append(TradeLogDetail(
                label: "시드 가용잔고",
                value: DecimalText.string(account.available)
            ))
            details.append(TradeLogDetail(
                label: "미실현 PnL",
                value: DecimalText.string(account.unrealizedProfitLoss),
                tone: account.unrealizedProfitLoss < 0 ? .danger : .success
            ))
        }
        return TradeEventLog(
            timestamp: timestamp,
            category: .automation,
            message: message,
            metadata: TradeLogMetadata(
                title: title,
                subtitle: subtitle,
                tags: tags,
                details: details
            )
        )
    }

    func loadCandles() {
        localCandleLoadTask?.cancel()

        let requestID = UUID()
        let symbol = state.selectedSymbol
        let timeframe = state.selectedTimeframe
        let limit = candleDisplayLimit
        activeLocalCandleLoadID = requestID

        localCandleLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candles = try await loadCandles(
                    symbol: symbol,
                    timeframe: timeframe,
                    limit: limit
                )
                try Task.checkCancellation()
                guard activeLocalCandleLoadID == requestID,
                      state.selectedSymbol == symbol,
                      state.selectedTimeframe == timeframe else {
                    return
                }
                state.candles = candles
                state.candleStatus = .loaded(count: candles.count, source: "Local DB")
                finishLocalCandleLoad(id: requestID)
            } catch is CancellationError {
                finishLocalCandleLoad(id: requestID)
            } catch {
                guard activeLocalCandleLoadID == requestID else { return }
                let message = sanitizedError(error)
                state.candleStatus = .failed(message: message)
                appendSessionLogOnce(key: "candles.load.failed.\(symbol.rawValue).\(timeframe.rawValue).\(message)", .init(
                    timestamp: clock.now,
                    category: .bot,
                    severity: .warning,
                    message: message
                ))
                finishLocalCandleLoad(id: requestID)
            }
        }
    }

    func loadMoreLocalCandles() {
        guard candleDisplayLimit < maxCandleDisplayLimit,
              activeLocalCandleLoadID == nil else {
            return
        }
        candleDisplayLimit = min(candleDisplayLimit * 2, maxCandleDisplayLimit)
        loadCandles()
    }

    func startCandleBackfill() {
        candleRefreshTask?.cancel()
        candleRefreshTask = Task {
            await refreshCandlesFromBitget()
        }
    }

    private func startInitialMarketDataSync() {
        let routes = state.watchlist.flatMap { symbol in
            CandleTimeframe.marketDataSyncCases.map { timeframe in
                (symbol: symbol, timeframe: timeframe)
            }
        }
        guard !routes.isEmpty else {
            state.marketDataBootstrapStatus = .complete(totalRoutes: 0, skippedRoutes: 0, savedCandles: 0)
            return
        }

        guard candleBackfillRepository != nil else {
            state.marketDataBootstrapStatus = .complete(totalRoutes: 0, skippedRoutes: 0, savedCandles: 0)
            return
        }

        marketDataBootstrapTask?.cancel()
        marketDataBootstrapTask = Task { [weak self] in
            await self?.syncInitialMarketData(routes: routes)
        }
    }

    private func syncInitialMarketData(
        routes: [(symbol: FuturesSymbol, timeframe: CandleTimeframe)]
    ) async {
        guard let candleBackfillRepository else { return }

        var completedRoutes = 0
        var skippedRoutes = 0
        var savedCandles = 0
        let totalRoutes = routes.count

        do {
            for route in routes {
                try Task.checkCancellation()

                state.marketDataBootstrapStatus = .syncing(
                    completedRoutes: completedRoutes,
                    totalRoutes: totalRoutes,
                    currentSymbol: route.symbol,
                    currentTimeframe: route.timeframe,
                    savedCandles: savedCandles,
                    currentRouteProgress: 0
                )

                if try await isHistoryComplete(symbol: route.symbol, timeframe: route.timeframe) {
                    skippedRoutes += 1
                    completedRoutes += 1
                    state.marketDataBootstrapStatus = .syncing(
                        completedRoutes: completedRoutes,
                        totalRoutes: totalRoutes,
                        currentSymbol: route.symbol,
                        currentTimeframe: route.timeframe,
                        savedCandles: savedCandles,
                        currentRouteProgress: 0
                    )
                    continue
                }

                let latestCandles = try await candleBackfillRepository.fetchCandles(
                    symbol: route.symbol,
                    timeframe: route.timeframe,
                    limit: 200
                )
                try await upsertCandles(latestCandles)
                savedCandles += latestCandles.count
                try await reloadVisibleCandlesIfCurrent(
                    symbol: route.symbol,
                    timeframe: route.timeframe,
                    source: "Local cache"
                )

                let historicalSavedCandles = try await syncHistoricalCandlesForInitialMarketData(
                    symbol: route.symbol,
                    timeframe: route.timeframe
                ) { routeSavedCandles, routeProgress in
                    self.state.marketDataBootstrapStatus = .syncing(
                        completedRoutes: completedRoutes,
                        totalRoutes: totalRoutes,
                        currentSymbol: route.symbol,
                        currentTimeframe: route.timeframe,
                        savedCandles: savedCandles + routeSavedCandles,
                        currentRouteProgress: routeProgress
                    )
                }
                savedCandles += historicalSavedCandles
                completedRoutes += 1

                state.marketDataBootstrapStatus = .syncing(
                    completedRoutes: completedRoutes,
                    totalRoutes: totalRoutes,
                    currentSymbol: route.symbol,
                    currentTimeframe: route.timeframe,
                    savedCandles: savedCandles,
                    currentRouteProgress: 0
                )
            }

            try await reloadVisibleCandlesIfCurrent(
                symbol: state.selectedSymbol,
                timeframe: state.selectedTimeframe,
                source: "Local cache"
            )
            startSelectedLiveCandleStream()
            state.marketDataBootstrapStatus = .complete(
                totalRoutes: totalRoutes,
                skippedRoutes: skippedRoutes,
                savedCandles: savedCandles
            )
            state.candleHistoryStatus = .complete(savedCount: savedCandles)
        } catch is CancellationError {
            return
        } catch {
            state.marketDataBootstrapStatus = .failed(message: sanitizedError(error))
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
            try await upsertCandles(remoteCandles)

            guard state.selectedSymbol == symbol, state.selectedTimeframe == timeframe else {
                return
            }

            cancelLocalCandleLoad()
            state.candles = try await loadCandles(
                symbol: symbol,
                timeframe: timeframe,
                limit: candleDisplayLimit
            )
            state.candleStatus = .loaded(count: state.candles.count, source: "Bitget REST")
            startLiveCandleStream(symbol: symbol, timeframe: timeframe)
            startHistoricalCandleBackfill(symbol: symbol, timeframe: timeframe)
        } catch {
            let message = sanitizedError(error)
            state.candleStatus = .failed(message: message)
            appendSessionLogOnce(key: "candles.refresh.failed.\(symbol.rawValue).\(timeframe.rawValue).\(message)", .init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                symbol: symbol,
                message: message
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

    private func isHistoryComplete(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) async throws -> Bool {
        guard let candleHistoryStore else { return false }
        return try await loadHistorySyncState(
            store: candleHistoryStore,
            symbol: symbol,
            timeframe: timeframe
        )?.isComplete == true
    }

    private func syncHistoricalCandlesForInitialMarketData(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        onProgress: @MainActor (_ savedCandles: Int, _ routeProgress: Double) -> Void
    ) async throws -> Int {
        guard let candleBackfillRepository, let candleHistoryStore else { return 0 }

        var endTime = try await loadOldestCandleOpenTime(
            symbol: symbol,
            timeframe: timeframe
        ) ?? clock.now
        var savedCount = 0
        var pageCount = 0
        let estimatedPages = estimatedFourYearHistoryPages(for: timeframe)

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
                onProgress(savedCount, 0.99)
                try await saveHistorySyncState(.init(
                    productType: .usdtFutures,
                    symbol: symbol,
                    timeframe: timeframe,
                    isComplete: true,
                    oldestOpenTime: try await loadOldestCandleOpenTime(
                        symbol: symbol,
                        timeframe: timeframe
                    ),
                    updatedAt: clock.now
                ), store: candleHistoryStore)
                return savedCount
            }

            try await upsertCandles(olderCandles)
            endTime = olderCandles.first?.openTime ?? endTime
            savedCount += olderCandles.count
            pageCount += 1
            onProgress(
                savedCount,
                min(Double(pageCount) / Double(max(estimatedPages, 1)), 0.98)
            )

            try await saveHistorySyncState(.init(
                productType: .usdtFutures,
                symbol: symbol,
                timeframe: timeframe,
                isComplete: false,
                oldestOpenTime: endTime,
                updatedAt: clock.now
            ), store: candleHistoryStore)

            guard historyBackfillPolicy.pageDelayNanoseconds > 0 else { continue }
            try await Task.sleep(nanoseconds: historyBackfillPolicy.pageDelayNanoseconds)
        }

        try await saveHistorySyncState(.init(
            productType: .usdtFutures,
            symbol: symbol,
            timeframe: timeframe,
            isComplete: false,
            oldestOpenTime: endTime,
            updatedAt: clock.now
        ), store: candleHistoryStore)
        return savedCount
    }

    private func estimatedFourYearHistoryPages(for timeframe: CandleTimeframe) -> Int {
        let fourYears: TimeInterval = 4 * 365 * 24 * 60 * 60
        let estimatedCandles = Int(ceil(fourYears / timeframe.duration))
        return Int(ceil(Double(estimatedCandles) / Double(max(historyBackfillPolicy.pageLimit, 1))))
    }

    private func stopHistoricalCandleBackfill() {
        candleHistoryBackfillTask?.cancel()
        candleHistoryBackfillTask = nil
    }

    private func syncHistoricalCandles(symbol: FuturesSymbol, timeframe: CandleTimeframe) async {
        guard let candleBackfillRepository, let candleHistoryStore else { return }

        do {
            if try await loadHistorySyncState(
                store: candleHistoryStore,
                symbol: symbol,
                timeframe: timeframe
            )?.isComplete == true {
                guard state.selectedSymbol == symbol, state.selectedTimeframe == timeframe else {
                    return
                }
                state.candleHistoryStatus = .complete(savedCount: 0)
                return
            }

            var endTime = try await loadOldestCandleOpenTime(
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
                    try await saveHistorySyncState(.init(
                        productType: .usdtFutures,
                        symbol: symbol,
                        timeframe: timeframe,
                        isComplete: true,
                        oldestOpenTime: try await loadOldestCandleOpenTime(
                            symbol: symbol,
                            timeframe: timeframe
                        ),
                        updatedAt: clock.now
                    ), store: candleHistoryStore)
                    if state.selectedSymbol == symbol, state.selectedTimeframe == timeframe {
                        state.candleHistoryStatus = .complete(savedCount: savedCount)
                    }
                    return
                }

                try await upsertCandles(olderCandles)
                endTime = olderCandles.first?.openTime ?? endTime
                savedCount += olderCandles.count
                pageCount += 1

                try await saveHistorySyncState(.init(
                    productType: .usdtFutures,
                    symbol: symbol,
                    timeframe: timeframe,
                    isComplete: false,
                    oldestOpenTime: endTime,
                    updatedAt: clock.now
                ), store: candleHistoryStore)

                if shouldPublishHistoryProgress(pageCount: pageCount),
                   state.selectedSymbol == symbol,
                   state.selectedTimeframe == timeframe {
                    state.candleHistoryStatus = .syncing(savedCount: savedCount, pageCount: pageCount)
                }

                guard historyBackfillPolicy.pageDelayNanoseconds > 0 else { continue }
                try await Task.sleep(nanoseconds: historyBackfillPolicy.pageDelayNanoseconds)
            }

            try await saveHistorySyncState(.init(
                productType: .usdtFutures,
                symbol: symbol,
                timeframe: timeframe,
                isComplete: false,
                oldestOpenTime: endTime,
                updatedAt: clock.now
            ), store: candleHistoryStore)
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
            let message = sanitizedError(error)
            appendSessionLogOnce(key: "candles.history.failed.\(symbol.rawValue).\(timeframe.rawValue).\(message)", .init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                symbol: symbol,
                message: message
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

    private func startSelectedLiveCandleStream() {
        startLiveCandleStream(symbol: state.selectedSymbol, timeframe: state.selectedTimeframe)
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
        let previousOpenPositions = state.positions.filter(\.isOpenForManualCloseDetection)
        let mergedPositions = positions.map { incoming in
            guard let previous = state.positions.first(where: { $0.id == incoming.id }) else {
                return incoming
            }
            return incoming.fillingMissingDetail(from: previous)
        }
        state.positions = positionsWithChartProtectionLevels(mergedPositions)
        recordExternallyClosedPositions(
            previousOpenPositions: previousOpenPositions,
            currentOpenPositions: state.positions.filter(\.isOpenForManualCloseDetection)
        )
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
            try await upsertCandles(candlesToUpsert)
            mergeLiveCandle(candle, symbol: symbol, timeframe: timeframe)
            state.candleStatus = .loaded(count: state.candles.count, source: "Bitget WebSocket")
        } catch {
            let message = sanitizedError(error)
            appendSessionLogOnce(key: "candles.live.failed.\(symbol.rawValue).\(timeframe.rawValue).\(message)", .init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                symbol: symbol,
                message: message
            ))
        }
    }

    private func mergeLiveCandle(
        _ candle: Candle,
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) {
        guard state.selectedSymbol == symbol, state.selectedTimeframe == timeframe else {
            return
        }

        var visibleCandles = state.candles
        if let matchingIndex = visibleCandles.lastIndex(where: {
            $0.symbol == symbol &&
                $0.timeframe == timeframe &&
                $0.openTime == candle.openTime
        }) {
            visibleCandles[matchingIndex] = candle
        } else {
            if let last = visibleCandles.last,
               last.symbol == symbol,
               last.timeframe == timeframe,
               last.openTime < candle.openTime,
               !last.isClosed {
                visibleCandles[visibleCandles.count - 1] = last.withClosedState(true)
            }
            visibleCandles.append(candle)
        }

        if visibleCandles.count > candleDisplayLimit {
            visibleCandles.removeFirst(visibleCandles.count - candleDisplayLimit)
        }
        state.candles = visibleCandles
    }

    private func runLiveMonitorOnce() async {
        let watchlist = state.watchlist
        guard !watchlist.isEmpty else { return }
        guard state.isConnected else {
            appendSessionLogOnce(key: "live-monitor.not-connected", .init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                message: "Live auto trading requires a connected Bitget credential."
            ))
            stopLiveBot()
            return
        }

        do {
            try await refreshAccountSnapshot()
        } catch {
            appendPositionWarning(error)
        }

        var leverageBySymbol: [FuturesSymbol: Int] = [:]
        var maximumRiskPerTradePercentBySymbol: [FuturesSymbol: Decimal] = [:]
        var maximumPositionMarginPercentBySymbol: [FuturesSymbol: Decimal] = [:]
        for symbol in watchlist {
            leverageBySymbol[symbol] = clampedLeverage(state.strategyConfig.leverage, for: symbol)
            maximumRiskPerTradePercentBySymbol[symbol] = clampedMaximumRiskPerTradePercent(
                state.strategyConfig.maximumRiskPerTradePercent
            )
            maximumPositionMarginPercentBySymbol[symbol] = clampedMaximumPositionMarginPercent(
                state.strategyConfig.maximumPositionMarginPercent
            )
        }

        let result = await liveMonitor.evaluateOnce(
            watchlist: watchlist,
            leverageBySymbol: leverageBySymbol,
            maximumRiskPerTradePercentBySymbol: maximumRiskPerTradePercentBySymbol,
            maximumPositionMarginPercentBySymbol: maximumPositionMarginPercentBySymbol,
            openPositions: positionsWithChartProtectionLevels(state.positions)
                .filter { watchlist.contains($0.symbol) },
            accountEquity: usdtAccount?.accountEquity,
            accountAvailable: usdtAccount?.available,
            contractSpecs: state.symbolCatalog
        )

        if !result.evaluations.isEmpty || result.executionResult?.didSubmitOrder == true {
            loadRecentLogs()
            try? await refreshAccountSnapshot()
            await refreshPositions(logSuccess: false)
        }

        for failure in result.failures.prefix(3) {
            let strategyPart = failure.strategyID ?? "candles"
            appendSessionLogOnce(key: "live-monitor.failure.\(failure.symbol.rawValue).\(failure.timeframe.rawValue).\(strategyPart)", .init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                symbol: failure.symbol,
                message: "Live monitor skipped \(failure.timeframe.rawValue) \(strategyPart): \(failure.message)"
            ))
        }
    }

    func loadRecentLogs() {
        refreshVisibleLogs()
    }

    private func loadSavedServerRunnerConnection() {
        do {
            guard let configuration = try serverRunnerConfigurationStore.load() else { return }
            guard let service = serverPaperRunnerServiceFactory(configuration) else {
                state.serverRunnerConnectionState = .failed(message: "Invalid server endpoint.")
                return
            }
            serverRunnerConfiguration = configuration
            serverPaperRunnerService = service
            applyServerRunnerConfigurationToState(configuration)
        } catch {
            state.serverRunnerConnectionState = .failed(message: sanitizedError(error))
        }
    }

    private func applyServerRunnerConfigurationToState(
        _ configuration: ServerRunnerConfiguration?,
        fallbackEndpoint: String = ""
    ) {
        state.serverRunnerEndpoint = configuration?.endpoint ?? fallbackEndpoint
        state.serverRunnerHasAuthToken = configuration?.hasAuthToken ?? false
        state.serverRunnerRedactedAuthToken = configuration?.redactedAuthToken
    }

    private func validatedServerEndpoint(_ endpoint: String) -> URL? {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedEndpoint),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private func startServerRunnerPolling() {
        guard serverRunnerConfiguration?.hasAuthToken == true,
              serverPaperRunnerService != nil else { return }
        serverRunnerPollingTask?.cancel()
        serverRunnerPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.loadServerRunnerSnapshot()
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func loadServerRunnerSnapshot() async {
        guard serverRunnerConfiguration?.hasAuthToken == true,
              let serverPaperRunnerService else {
            state.serverRunnerConnectionState = .idle
            return
        }
        state.serverRunnerConnectionState = .refreshing
        do {
            async let status = serverPaperRunnerService.fetchStatus()
            async let logs = serverPaperRunnerService.fetchLogs(limit: 50)
            let snapshot = try await status
            let serverLogs = try await logs
            state.serverRunnerStatus = snapshot
            state.serverRunnerLogs = serverLogs
            state.serverRunnerConnectionState = .connected(checkedAt: clock.now)
            if let redactedIdentifier = serverRunnerConfiguration?.redactedCredentialIdentifier {
                state.credentialStatus = .connected(
                    redactedIdentifier: redactedIdentifier,
                    checkedAt: clock.now
                )
                await refreshServerPrivateSnapshots()
            }
            refreshVisibleLogs()
        } catch {
            if let serverError = error as? ServerPaperRunnerClientError,
               case .httpStatus(401, _) = serverError {
                clearServerAuthenticatedSession()
                return
            }
            state.serverRunnerConnectionState = .failed(message: sanitizedError(error))
        }
    }

    private func refreshServerPrivateSnapshots() async {
        do {
            try await refreshAccountSnapshot()
            await refreshPositions(logSuccess: false)
        } catch {
            if let serverError = error as? ServerPaperRunnerClientError,
               case .httpStatus(409, _) = serverError {
                state.credentialStatus = .failed(message: "Bitget login is required again.")
                return
            }
            appendPositionWarning(error)
        }
    }

    private func clearServerAuthenticatedSession() {
        let endpoint = serverRunnerConfiguration?.endpoint ??
            (state.serverRunnerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultServerRunnerEndpoint
                : state.serverRunnerEndpoint)
        let unauthenticatedConfiguration = ServerRunnerConfiguration(endpoint: endpoint, authToken: nil)
        try? serverRunnerConfigurationStore.save(unauthenticatedConfiguration)
        serverRunnerPollingTask?.cancel()
        serverRunnerConfiguration = unauthenticatedConfiguration
        serverPaperRunnerService = serverPaperRunnerServiceFactory(unauthenticatedConfiguration)
        applyServerRunnerConfigurationToState(unauthenticatedConfiguration)
        state.serverRunnerConnectionState = .idle
        state.serverRunnerStatus = nil
        state.serverRunnerLogs = []
        if state.credentialStatus != .disconnected {
            state.credentialStatus = .disconnected
        }
    }

    private func appendAutomationLog(_ log: TradeEventLog) {
        do {
            try logStore.append(log)
            refreshVisibleLogs()
        } catch {
            appendSessionLog(.init(
                timestamp: clock.now,
                category: .bot,
                severity: .warning,
                message: sanitizedError(error)
            ))
        }
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
        state.automationLogs = (try? logStore.loadRecent(limit: 10_000))?
            .filter(\.isAutomationTradingRecord) ?? []
        if state.positions.isEmpty == false {
            state.positions = positionsWithChartProtectionLevels(state.positions)
        }
        state.recentLogs = (persistentLogs + state.serverRunnerLogs + sessionLogs)
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func positionsWithChartProtectionLevels(
        _ positions: [PositionSnapshot],
        exchangeProtectionLevelsByPositionID: [String: ChartProtectionLevels]? = nil
    ) -> [PositionSnapshot] {
        let authoritativeLevels = exchangeProtectionLevelsByPositionID ??
            latestExchangeProtectionLevelsByPositionID
        if let authoritativeLevels {
            return positions.map {
                $0.withChartProtectionLevels(from: authoritativeLevels[$0.id])
            }
        }
        return positions.map { $0.withChartProtectionLevels(from: state.automationLogs) }
    }

    private func fetchExchangeProtectionLevelsByPositionID(
        positions: [PositionSnapshot]
    ) async -> [String: ChartProtectionLevels]? {
        guard let positionProtectionRepository else {
            return latestExchangeProtectionLevelsByPositionID
        }

        do {
            let protectionOrders = try await positionProtectionRepository.fetchPendingPositionProtectionOrders()
            let levelPairs: [(String, ChartProtectionLevels)] = positions.compactMap { position in
                guard let levels = ChartProtectionLevels(
                    position: position,
                    protectionOrders: protectionOrders,
                    createdAt: clock.now
                ) else {
                    return nil
                }
                return (position.id, levels)
            }
            let levelsByPositionID = Dictionary(uniqueKeysWithValues: levelPairs)
            latestExchangeProtectionLevelsByPositionID = levelsByPositionID
            return levelsByPositionID
        } catch {
            appendSessionLogOnce(key: "positions.protection.refresh.failed.\(sanitizedError(error))", .init(
                timestamp: clock.now,
                category: .position,
                severity: .warning,
                message: "Position protection refresh skipped: \(sanitizedError(error))"
            ))
            return latestExchangeProtectionLevelsByPositionID
        }
    }

    var selectedLeverageRange: ClosedRange<Int> {
        leverageRange(for: state.selectedSymbol)
    }

    var backtestLeverageRange: ClosedRange<Int> {
        leverageRange(for: state.backtestConfiguration.symbol)
    }

    private func leverageRange(for symbol: FuturesSymbol) -> ClosedRange<Int> {
        let spec = state.symbolCatalog.first { $0.symbol == symbol }
        let rawMinLeverage = spec?.minLeverage ?? 1
        let rawMaxLeverage = spec?.maxLeverage ?? StrategyRiskPolicy.maximumAutoTradingLeverage
        let minLeverage = min(
            max(rawMinLeverage, 1),
            StrategyRiskPolicy.maximumAutoTradingLeverage
        )
        let maxLeverage = max(
            min(rawMaxLeverage, StrategyRiskPolicy.maximumAutoTradingLeverage),
            minLeverage
        )
        return minLeverage...maxLeverage
    }

    private func dashboardContractSpecs(from specs: [ContractSpec]) -> [ContractSpec] {
        let allowedSymbols = DashboardState.defaultWatchlist
        return allowedSymbols.compactMap { symbol in
            specs.first { $0.symbol == symbol }
        }
    }

    private func clampedLeverage(_ leverage: Int, for symbol: FuturesSymbol) -> Int {
        let range = leverageRange(for: symbol)
        return min(max(leverage, range.lowerBound), range.upperBound)
    }

    private func clampedMaximumRiskPerTradePercent(_ value: Decimal) -> Decimal {
        StrategyRiskPolicy.clampedMaximumRiskPerTradePercent(value)
    }

    private func clampedMaximumPositionMarginPercent(_ value: Decimal) -> Decimal {
        StrategyRiskPolicy.clampedMaximumPositionMarginPercent(value)
    }

    private func routedStrategyConfig(
        _ config: StrategyConfig,
        for timeframe: CandleTimeframe,
        symbol: FuturesSymbol
    ) -> StrategyConfig {
        if StrategyTimeframeRouting.isRecommended(
            strategyID: config.strategyID,
            for: timeframe,
            symbol: symbol
        ) {
            var nextConfig = config
            nextConfig.leverage = clampedLeverage(nextConfig.leverage, for: symbol)
            nextConfig.maximumRiskPerTradePercent = clampedMaximumRiskPerTradePercent(
                nextConfig.maximumRiskPerTradePercent
            )
            nextConfig.maximumPositionMarginPercent = clampedMaximumPositionMarginPercent(
                nextConfig.maximumPositionMarginPercent
            )
            return nextConfig
        }

        guard let defaultID = StrategyTimeframeRouting.recommendedStrategyIDs(
            for: timeframe,
            symbol: symbol
        ).first,
              let definition = strategyRegistry.definition(id: defaultID) else {
            var nextConfig = config
            nextConfig.leverage = clampedLeverage(nextConfig.leverage, for: symbol)
            nextConfig.maximumRiskPerTradePercent = clampedMaximumRiskPerTradePercent(
                nextConfig.maximumRiskPerTradePercent
            )
            nextConfig.maximumPositionMarginPercent = clampedMaximumPositionMarginPercent(
                nextConfig.maximumPositionMarginPercent
            )
            return nextConfig
        }

        var nextConfig = definition.defaultConfig
        nextConfig.leverage = clampedLeverage(config.leverage, for: symbol)
        nextConfig.maximumRiskPerTradePercent = clampedMaximumRiskPerTradePercent(
            config.maximumRiskPerTradePercent
        )
        nextConfig.maximumPositionMarginPercent = clampedMaximumPositionMarginPercent(
            config.maximumPositionMarginPercent
        )
        nextConfig.signalConfirmation = config.signalConfirmation
        return nextConfig
    }

    private func completeBacktest(
        _ result: BacktestResult,
        comparison: BacktestComparisonResult?,
        configuration: BacktestConfiguration
    ) {
        guard state.backtestConfiguration == configuration else { return }
        state.backtestResult = result
        state.backtestComparisonResult = comparison
        state.backtestStatus = .complete
        appendSessionLog(.init(
            timestamp: clock.now,
            category: .bot,
            symbol: configuration.symbol,
            message: "Backtest complete: \(result.totalTrades) trade(s), win rate \(result.winRatePercent.riskText)%, final balance \(result.finalBalance.riskText), net \(result.netReturnPercent.riskText)%."
        ))
    }

    private func failBacktest(
        _ error: Error,
        configuration: BacktestConfiguration
    ) {
        guard state.backtestConfiguration == configuration else { return }
        state.backtestResult = nil
        state.backtestComparisonResult = nil
        state.backtestStatus = .failed(message: sanitizedError(error))
        appendSessionLog(.init(
            timestamp: clock.now,
            category: .bot,
            severity: .warning,
            symbol: configuration.symbol,
            message: sanitizedError(error)
        ))
    }

    private func cancelBacktestIfCurrent(_ configuration: BacktestConfiguration) {
        guard state.backtestConfiguration == configuration else { return }
        state.backtestStatus = .idle
        state.backtestComparisonResult = nil
    }

    private func loadCandles(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        limit: Int
    ) async throws -> [Candle] {
        let repository = candleRepository
        return try await Task.detached(priority: .userInitiated) {
            try repository.loadCandles(
                symbol: symbol,
                timeframe: timeframe,
                limit: limit
            )
        }.value
    }

    private func reloadVisibleCandlesIfCurrent(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe,
        source: String
    ) async throws {
        guard state.selectedSymbol == symbol, state.selectedTimeframe == timeframe else {
            return
        }

        cancelLocalCandleLoad()
        state.candles = try await loadCandles(
            symbol: symbol,
            timeframe: timeframe,
            limit: candleDisplayLimit
        )
        state.candleStatus = .loaded(count: state.candles.count, source: source)
    }

    private func loadOldestCandleOpenTime(
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) async throws -> Date? {
        let repository = candleRepository
        return try await Task.detached(priority: .utility) {
            try repository.loadOldestCandleOpenTime(
                symbol: symbol,
                timeframe: timeframe
            )
        }.value
    }

    private func upsertCandles(_ candles: [Candle]) async throws {
        guard !candles.isEmpty else { return }
        let repository = candleRepository
        try await Task.detached(priority: .utility) {
            try repository.upsertCandles(candles)
        }.value
    }

    private func loadHistorySyncState(
        store: CandleHistoryStateStore,
        symbol: FuturesSymbol,
        timeframe: CandleTimeframe
    ) async throws -> CandleHistorySyncState? {
        try await Task.detached(priority: .utility) {
            try store.loadHistorySyncState(symbol: symbol, timeframe: timeframe)
        }.value
    }

    private func saveHistorySyncState(
        _ state: CandleHistorySyncState,
        store: CandleHistoryStateStore
    ) async throws {
        try await Task.detached(priority: .utility) {
            try store.saveHistorySyncState(state)
        }.value
    }

    private func shouldPublishHistoryProgress(pageCount: Int) -> Bool {
        pageCount == 1 || pageCount.isMultiple(of: 10)
    }

    private func cancelLocalCandleLoad() {
        localCandleLoadTask?.cancel()
        localCandleLoadTask = nil
        activeLocalCandleLoadID = nil
    }

    private func finishLocalCandleLoad(id: UUID) {
        guard activeLocalCandleLoadID == id else { return }
        activeLocalCandleLoadID = nil
        localCandleLoadTask = nil
    }

    private func resetBacktest() {
        backtestTask?.cancel()
        backtestTask = nil
        state.backtestStatus = .idle
        state.backtestResult = nil
        state.backtestComparisonResult = nil
    }

    private func clampedBacktestInitialCapital(_ initialCapital: Decimal) -> Decimal {
        max(initialCapital, 1)
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
        case TradingDomainError.missingAccountEquity:
            return "USDT account equity is required for live order sizing."
        case TradingDomainError.missingContractSpec(let symbol):
            return "\(symbol.rawValue) contract spec is required for live order sizing."
        case TradingDomainError.liveOrderSizeTooSmall(let symbol):
            return "\(symbol.rawValue) live order size is below Bitget minimum."
        case TradingDomainError.liveOrderFillNotConfirmed(let clientOid):
            return "Live order fill was not confirmed for \(TradeLogRedaction.identifier(clientOid))."
        case TradingDomainError.invalidProtectionPlan(let message):
            return "Invalid protection plan: \(message)"
        case TradingDomainError.protectionOrderRetryExhausted(let kind, let attempts, let cause):
            let causeText = cause.map { " Cause: \($0)" } ?? ""
            return "Protection \(kind.rawValue) order failed after \(attempts) attempts.\(causeText)"
        case let error as URLError:
            return "Network request failed: \(error.localizedDescription)"
        case BacktestEngineError.insufficientCandles(let required, let actual):
            return "백테스트에 필요한 캔들이 부족합니다. 최소 \(required)개 필요, 현재 \(actual)개입니다."
        case BacktestEngineError.invalidInitialCapital(let initialCapital):
            return "시작금액은 0보다 커야 합니다. 현재 \(initialCapital.riskText)"
        case let error as SQLiteDatabaseError:
            return "SQLite database error: \(error.description)"
        case ServerPaperRunnerClientError.invalidURL:
            return "Server runner URL is invalid."
        case ServerPaperRunnerClientError.httpStatus(let status, let message):
            if let message {
                return "Server runner request failed with HTTP \(status): \(message)"
            }
            return "Server runner request failed with HTTP \(status)."
        case ServerPaperRunnerClientError.emptyResponse:
            return "Server runner returned an empty response."
        default:
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                return "Network request failed: \(nsError.localizedDescription)"
            }
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
    var isOpenForManualCloseDetection: Bool {
        total > 0 && side != .unknown
    }

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
            positionMode: positionMode == .unknown ? previous.positionMode : positionMode,
            liquidationPrice: liquidationPrice ?? previous.liquidationPrice,
            partialTakeProfit: partialTakeProfit ?? previous.partialTakeProfit,
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
