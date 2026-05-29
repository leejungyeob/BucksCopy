import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var didBootstrap = false

    var body: some View {
        VStack(spacing: 12) {
            HSplitView {
                leftColumn
                    .frame(minWidth: 248, idealWidth: 292, maxWidth: 350)
                    .padding(.trailing, 6)

                centerColumn
                    .frame(minWidth: 500, idealWidth: 760)
                    .padding(.horizontal, 6)

                rightColumn
                    .frame(minWidth: 340, idealWidth: 460, maxWidth: 640)
                    .padding(.leading, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            AutoTradingPerformancePanel(
                session: viewModel.state.liveAutomationSession,
                account: dashboardAccount,
                positions: displayPositions,
                logs: viewModel.state.automationLogs,
                runState: viewModel.state.runState
            )
            .frame(minHeight: 150, idealHeight: 170, maxHeight: 210)
        }
        .padding(14)
        .padding(.top, 20)
        .frame(minWidth: 1100, minHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard !didBootstrap else { return }
            didBootstrap = true
            viewModel.bootstrap()
        }
    }

    private var leftColumn: some View {
        DashboardLeftColumn(
            snapshot: leftSnapshot,
            onConnectCredential: { apiKey, secretKey, passphrase in
                viewModel.connectCredential(
                    apiKey: apiKey,
                    secretKey: secretKey,
                    passphrase: passphrase
                )
            },
            onRefreshCredential: viewModel.connectSavedCredential,
            onDeleteCredential: viewModel.deleteCredential,
            onSelectSymbol: viewModel.selectSymbol,
            onLeverageChange: viewModel.updateLeverage,
            onMaximumRiskPerTradeChange: viewModel.updateMaximumRiskPerTrade,
            onMaximumPositionMarginChange: viewModel.updateMaximumPositionMargin,
            onSignalConfirmationModeChange: viewModel.updateSignalConfirmationMode,
            onRefreshServerRunner: viewModel.refreshServerRunnerStatus,
            onSetServerRunnerEnabled: viewModel.setServerPaperRunnerEnabled,
            onStartLive: viewModel.startLiveBot,
            onStopLive: viewModel.stopLiveBot
        )
        .equatable()
    }

    private var leftSnapshot: DashboardLeftSnapshot {
        DashboardLeftSnapshot(
            credentialStatus: viewModel.state.credentialStatus,
            account: viewModel.state.accounts.first,
            positionCount: viewModel.state.positions.count,
            watchlist: viewModel.state.watchlist,
            selectedSymbol: viewModel.state.selectedSymbol,
            activeStrategyRoutes: activeStrategyRoutes,
            strategyConfig: viewModel.state.strategyConfig,
            selectedLeverageRange: viewModel.selectedLeverageRange,
            runState: viewModel.state.runState,
            serverRunnerEndpoint: viewModel.state.serverRunnerEndpoint,
            serverRunnerConnectionState: viewModel.state.serverRunnerConnectionState,
            serverRunnerStatus: viewModel.state.serverRunnerStatus
        )
    }

    private var centerColumn: some View {
        VStack(spacing: 12) {
            DashboardPanel {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.state.selectedSymbol.rawValue)
                            .font(.title2.weight(.semibold))
                        MarketDataBootstrapStatusView(
                            status: viewModel.state.marketDataBootstrapStatus
                        )
                    }
                    Spacer()
                    TimeframePicker(
                        selection: viewModel.state.selectedTimeframe,
                        onSelect: viewModel.selectTimeframe
                    )
                }
            }

            DashboardPanel {
                CandleChartView(
                    candles: viewModel.state.candles,
                    positions: chartPositions,
                    partialTakeProfitByPositionID: chartPartialTakeProfitByPositionID,
                    onNeedsOlderCandles: viewModel.loadMoreLocalCandles
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var rightColumn: some View {
        VSplitView {
            PositionPanel(
                positions: displayPositions,
                partialTakeProfitByPositionID: positionPartialTakeProfitByPositionID,
                strategyContextByPositionID: positionStrategyContextByPositionID,
                onRefresh: {
                    Task { await viewModel.refreshPositions() }
                }
            )
            .frame(minHeight: 220, idealHeight: 300, maxHeight: .infinity, alignment: .topLeading)

            TradeLogPanel(
                logs: viewModel.state.recentLogs,
                language: viewModel.state.logLanguage,
                onLanguageChange: viewModel.updateLogLanguage
            )
            .frame(minHeight: 260, idealHeight: 420)
        }
    }

    private var chartPositions: [PositionSnapshot] {
        displayPositions
            .filter { $0.symbol == viewModel.state.selectedSymbol }
    }

    private var chartPartialTakeProfitByPositionID: [String: Decimal] {
        Dictionary(uniqueKeysWithValues: displayPositions
            .filter { $0.symbol == viewModel.state.selectedSymbol }
            .compactMap { position in
                guard let partialTakeProfit = position.partialTakeProfit ??
                    position.chartProtectionLevels(
                        from: viewModel.state.automationLogs
                    )?.partialTakeProfit else {
                    return nil
                }
                return (position.id, partialTakeProfit)
            })
    }

    private var displayPositions: [PositionSnapshot] {
        viewModel.state.positions
            .map { $0.withChartProtectionLevels(from: viewModel.state.automationLogs) }
    }

    private var positionPartialTakeProfitByPositionID: [String: Decimal] {
        Dictionary(uniqueKeysWithValues: displayPositions.compactMap { position in
            guard let partialTakeProfit = position.partialTakeProfit ??
                position.chartProtectionLevels(
                    from: viewModel.state.automationLogs
                )?.partialTakeProfit else {
                return nil
            }
            return (position.id, partialTakeProfit)
        })
    }

    private var positionStrategyContextByPositionID: [String: PositionStrategyContext] {
        Dictionary(uniqueKeysWithValues: displayPositions.compactMap { position in
            guard let context = position.strategyContext(from: viewModel.state.automationLogs) else {
                return nil
            }
            return (position.id, context)
        })
    }

    private var dashboardAccount: AccountSnapshot? {
        viewModel.state.accounts.first { $0.marginCoin.uppercased() == "USDT" } ??
            viewModel.state.accounts.first
    }

    private var activeStrategyRoutes: [ActiveStrategyRoute] {
        viewModel.state.watchlist.flatMap { symbol in
            CandleTimeframe.liveTradingCases.flatMap { timeframe in
                viewModel.strategyDefinitions(for: timeframe, symbol: symbol).map {
                    ActiveStrategyRoute(symbol: symbol, timeframe: timeframe, definition: $0)
                }
            }
        }
    }
}

struct ChartProtectionLevels {
    let symbol: FuturesSymbol
    let side: PositionSide
    let partialTakeProfit: Decimal?
    let takeProfit: Decimal?
    let stopLoss: Decimal?
    let createdAt: Date
    let timeframe: CandleTimeframe?
    let strategyID: String?

    init(
        symbol: FuturesSymbol,
        side: PositionSide,
        partialTakeProfit: Decimal?,
        takeProfit: Decimal?,
        stopLoss: Decimal?,
        createdAt: Date,
        timeframe: CandleTimeframe? = nil,
        strategyID: String? = nil
    ) {
        self.symbol = symbol
        self.side = side
        self.partialTakeProfit = partialTakeProfit
        self.takeProfit = takeProfit
        self.stopLoss = stopLoss
        self.createdAt = createdAt
        self.timeframe = timeframe
        self.strategyID = strategyID
    }

    init?(
        position: PositionSnapshot,
        protectionOrders: [PositionProtectionOrderSnapshot],
        createdAt: Date
    ) {
        let matchingOrders = protectionOrders.filter { order in
            guard order.symbol == position.symbol else { return false }
            if order.side == position.side { return true }
            return order.side == .unknown || position.positionMode == .oneWay
        }
        guard matchingOrders.isEmpty == false else { return nil }

        let takeProfitPrices = matchingOrders
            .filter { $0.kind == .takeProfit }
            .map(\.triggerPrice)
            .sortedByDistance(from: position.openPriceAverage)
        let stopLoss = matchingOrders
            .filter { $0.kind == .stopLoss }
            .sorted {
                ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            .first?
            .triggerPrice
        let partialTakeProfit = takeProfitPrices.count > 1 ? takeProfitPrices.first : nil
        let takeProfit = takeProfitPrices.last

        guard partialTakeProfit != nil || takeProfit != nil || stopLoss != nil else {
            return nil
        }

        self.init(
            symbol: position.symbol,
            side: position.side,
            partialTakeProfit: partialTakeProfit,
            takeProfit: takeProfit,
            stopLoss: stopLoss,
            createdAt: createdAt
        )
    }
}

struct PositionStrategyContext {
    let timeframe: CandleTimeframe?
    let strategyID: String?
}

extension PositionSnapshot {
    func withChartProtectionLevels(from logs: [TradeEventLog]) -> PositionSnapshot {
        guard partialTakeProfit == nil || takeProfit == nil || stopLoss == nil else { return self }
        guard let levels = chartProtectionLevels(from: logs) else {
            return self
        }
        return withChartProtectionLevels(from: levels)
    }

    func withChartProtectionLevels(from levels: ChartProtectionLevels?) -> PositionSnapshot {
        guard partialTakeProfit == nil || takeProfit == nil || stopLoss == nil,
              let levels else {
            return self
        }
        return PositionSnapshot(
            symbol: symbol,
            side: side,
            total: total,
            available: available,
            openPriceAverage: openPriceAverage,
            markPrice: markPrice,
            unrealizedProfitLoss: unrealizedProfitLoss,
            leverage: leverage,
            marginMode: marginMode,
            positionMode: positionMode,
            liquidationPrice: liquidationPrice,
            partialTakeProfit: partialTakeProfit ?? levels.partialTakeProfit,
            takeProfit: takeProfit ?? levels.takeProfit,
            stopLoss: stopLoss ?? levels.stopLoss,
            createdAt: createdAt ?? levels.createdAt,
            updatedAt: updatedAt
        )
    }

    func chartProtectionLevels(from logs: [TradeEventLog]) -> ChartProtectionLevels? {
        logs.reversed().compactMap(\.chartProtectionLevels).first(where: { levels in
            guard levels.symbol == symbol, levels.side == side else { return false }
            if let createdAt {
                return levels.createdAt >= createdAt.addingTimeInterval(-300)
            }
            return true
        })
    }

    func strategyContext(from logs: [TradeEventLog]) -> PositionStrategyContext? {
        guard let levels = chartProtectionLevels(from: logs),
              levels.timeframe != nil || levels.strategyID != nil else {
            return nil
        }
        return PositionStrategyContext(
            timeframe: levels.timeframe,
            strategyID: levels.strategyID
        )
    }
}

extension TradeEventLog {
    var chartProtectionLevels: ChartProtectionLevels? {
        guard category == .liveOrder,
              let symbol,
              let metadata,
              metadata.title.contains("진입"),
              let side = liveEntryPositionSide else {
            return nil
        }

        let partialTakeProfit = metadata.detailValue(for: "TP1")?.chartDecimal

        guard let takeProfit = metadata.detailValue(for: "TP2")?.chartDecimal ??
            metadata.detailValue(for: "익절가")?.chartDecimal,
            let stopLoss = metadata.detailValue(for: "손절가")?.chartDecimal else {
            return nil
        }

        return ChartProtectionLevels(
            symbol: symbol,
            side: side,
            partialTakeProfit: partialTakeProfit,
            takeProfit: takeProfit,
            stopLoss: stopLoss,
            createdAt: timestamp,
            timeframe: metadata.timeframe,
            strategyID: metadata.strategyID
        )
    }

    var liveEntryPositionSide: PositionSide? {
        if message.contains("Live buy order") || metadata?.title.contains("매수") == true {
            return .long
        }
        if message.contains("Live sell order") || metadata?.title.contains("매도") == true {
            return .short
        }
        return nil
    }
}

extension TradeLogMetadata {
    func detailValue(for label: String) -> String? {
        details.first { $0.label == label }?.value
    }

    var timeframe: CandleTimeframe? {
        if let value = detailValue(for: "시간봉"),
           let timeframe = CandleTimeframe(rawValue: value) {
            return timeframe
        }
        return tags.compactMap { CandleTimeframe(rawValue: $0.label) }.first
    }

    var strategyID: String? {
        if let value = detailValue(for: "매매전략"), !value.isEmpty {
            return value
        }
        let excludedTags = Set(
            ["LIVE", "START", "STOP", "매수", "매도", "LONG", "SHORT"] +
                CandleTimeframe.allCases.map(\.rawValue)
        )
        return tags.map(\.label).first { label in
            !excludedTags.contains(label) && !label.hasSuffix("x")
        }
    }
}

extension String {
    var chartDecimal: Decimal? {
        let token = split { character in
            character == " " || character == "/" || character == "%"
        }.first
        return token.flatMap { DecimalText.optional(String($0)) }
    }
}

private extension Array where Element == Decimal {
    func sortedByDistance(from base: Decimal) -> [Decimal] {
        sorted {
            absoluteDecimal($0 - base) < absoluteDecimal($1 - base)
        }
    }
}

private struct MarketDataBootstrapStatusView: View {
    let status: MarketDataBootstrapStatus

    var body: some View {
        HStack(spacing: 8) {
            if let progress = status.progress {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .frame(width: 120)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24)
                    .opacity(isIdle ? 0 : 1)
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
    }

    private var isIdle: Bool {
        if case .idle = status { return true }
        return false
    }

    private var statusColor: Color {
        if case .failed = status {
            return .red
        }
        return .secondary
    }

    private var message: String {
        switch status {
        case .idle:
            return "시장 데이터 확인 중"
        case .syncing(_, _, let symbol, let timeframe, let savedCandles, _):
            guard savedCandles > 0 else {
                return "\(symbol.rawValue) \(timeframe.rawValue) 데이터 저장 중"
            }
            return "\(symbol.rawValue) \(timeframe.rawValue) 저장 중 · \(savedCandles)개"
        case .complete(let totalRoutes, let skippedRoutes, _):
            if totalRoutes > 0, skippedRoutes == totalRoutes {
                return "저장된 시장 데이터 사용 중"
            }
            return "시장 데이터 준비 완료"
        case .failed:
            return "시장 데이터 동기화 실패"
        }
    }
}

private struct DashboardLeftSnapshot: Equatable {
    let credentialStatus: CredentialStatus
    let account: AccountSnapshot?
    let positionCount: Int
    let watchlist: [FuturesSymbol]
    let selectedSymbol: FuturesSymbol
    let activeStrategyRoutes: [ActiveStrategyRoute]
    let strategyConfig: StrategyConfig
    let selectedLeverageRange: ClosedRange<Int>
    let runState: StrategyRunState
    let serverRunnerEndpoint: String
    let serverRunnerConnectionState: ServerRunnerConnectionState
    let serverRunnerStatus: ServerPaperRunnerStatus?

    var isConnected: Bool {
        if case .connected = credentialStatus {
            return true
        }
        return false
    }
}

private struct DashboardLeftColumn: View, Equatable {
    let snapshot: DashboardLeftSnapshot
    let onConnectCredential: (String, String, String) -> Void
    let onRefreshCredential: () -> Void
    let onDeleteCredential: () -> Void
    let onSelectSymbol: (FuturesSymbol) -> Void
    let onLeverageChange: (Int) -> Void
    let onMaximumRiskPerTradeChange: (Decimal) -> Void
    let onMaximumPositionMarginChange: (Decimal) -> Void
    let onSignalConfirmationModeChange: (SignalConfirmationMode) -> Void
    let onRefreshServerRunner: () -> Void
    let onSetServerRunnerEnabled: (Bool) -> Void
    let onStartLive: () -> Void
    let onStopLive: () -> Void

    static func == (lhs: DashboardLeftColumn, rhs: DashboardLeftColumn) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if snapshot.isConnected {
                    AccountSummaryPanel(
                        account: snapshot.account,
                        positionCount: snapshot.positionCount,
                        onRefresh: onRefreshCredential,
                        onDisconnect: onDeleteCredential
                    )
                } else {
                    CredentialPanel(
                        credentialStatus: snapshot.credentialStatus,
                        onConnect: onConnectCredential
                    )
                }
                WatchlistPanel(
                    symbols: snapshot.watchlist,
                    selectedSymbol: snapshot.selectedSymbol,
                    onSelect: onSelectSymbol
                )
                StrategySettingsPanel(
                    config: snapshot.strategyConfig,
                    leverageRange: snapshot.selectedLeverageRange,
                    onLeverageChange: onLeverageChange,
                    onMaximumRiskPerTradeChange: onMaximumRiskPerTradeChange,
                    onMaximumPositionMarginChange: onMaximumPositionMarginChange,
                    onSignalConfirmationModeChange: onSignalConfirmationModeChange
                )
                ServerRunnerPanel(
                    endpoint: snapshot.serverRunnerEndpoint,
                    connectionState: snapshot.serverRunnerConnectionState,
                    status: snapshot.serverRunnerStatus,
                    onRefresh: onRefreshServerRunner,
                    onSetEnabled: onSetServerRunnerEnabled
                )
                BotControlPanel(
                    runState: snapshot.runState,
                    isConnected: snapshot.isConnected,
                    onStart: onStartLive,
                    onStop: onStopLive
                )
                ActiveStrategyPortfolioPanel(routes: snapshot.activeStrategyRoutes)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.visible)
    }
}

private struct ActiveStrategyRoute: Equatable, Identifiable {
    let symbol: FuturesSymbol
    let timeframe: CandleTimeframe
    let definition: StrategyDefinition

    var id: String {
        "\(symbol.rawValue):\(timeframe.rawValue):\(definition.id)"
    }
}

private struct ActiveStrategyPortfolioPanel: View {
    let routes: [ActiveStrategyRoute]
    @State private var isExpanded = false

    var body: some View {
        DashboardPanel {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if routes.isEmpty {
                        Text("현재 자동매매 평가 대상 전략이 없습니다.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(routes) { route in
                            ActiveStrategyRouteRow(route: route)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Text("현재 적용중인 매매전략")
                        .font(.headline)
                    Spacer()
                    Text("\(routes.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
            }
        }
    }
}

private struct ActiveStrategyRouteRow: View {
    let route: ActiveStrategyRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(route.symbol.rawValue)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))

                Text(route.timeframe.rawValue)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))

                Text(route.definition.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }

            Text(route.definition.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct DashboardPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}
