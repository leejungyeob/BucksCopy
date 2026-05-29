import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var didBootstrap = false
    @State private var isChartVisible = false
    @State private var isSetupVisible = false

    var body: some View {
        VStack(spacing: 10) {
            CompactAutomationStatusPanel(
                endpoint: viewModel.state.serverRunnerEndpoint,
                connectionState: viewModel.state.serverRunnerConnectionState,
                status: viewModel.state.serverRunnerStatus,
                account: dashboardAccount,
                positions: displayPositions,
                showsChart: isChartVisible,
                showsSettings: isSetupVisible,
                onRefreshServer: viewModel.refreshServerRunnerStatus,
                onRefreshPositions: {
                    Task { await viewModel.refreshPositions() }
                },
                onSetServerEnabled: viewModel.setServerPaperRunnerEnabled,
                onToggleChart: { isChartVisible.toggle() },
                onToggleSettings: { isSetupVisible.toggle() }
            )

            if isSetupVisible {
                setupRow
            }

            if isChartVisible {
                chartSection
            }

            HSplitView {
                PositionPanel(
                    positions: displayPositions,
                    partialTakeProfitByPositionID: positionPartialTakeProfitByPositionID,
                    strategyContextByPositionID: positionStrategyContextByPositionID,
                    onRefresh: {
                        Task { await viewModel.refreshPositions() }
                    }
                )
                .frame(minWidth: 360, idealWidth: 460, maxWidth: 620, maxHeight: .infinity, alignment: .topLeading)

                TradeLogPanel(
                    logs: viewModel.state.recentLogs,
                    language: viewModel.state.logLanguage,
                    onLanguageChange: viewModel.updateLogLanguage
                )
                .frame(minWidth: 460, idealWidth: 720, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .padding(.top, 10)
        .frame(minWidth: 920, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard !didBootstrap else { return }
            didBootstrap = true
            viewModel.bootstrap()
        }
    }

    private var setupRow: some View {
        HStack(alignment: .top, spacing: 10) {
            if leftSnapshot.isConnected {
                AccountSummaryPanel(
                    account: leftSnapshot.account,
                    positionCount: displayPositions.count,
                    onRefresh: viewModel.connectSavedCredential,
                    onDisconnect: viewModel.deleteCredential
                )
            } else {
                CredentialPanel(
                    credentialStatus: viewModel.state.credentialStatus,
                    onConnect: { apiKey, secretKey, passphrase in
                        viewModel.connectCredential(
                            apiKey: apiKey,
                            secretKey: secretKey,
                            passphrase: passphrase
                        )
                    }
                )
            }

            ServerRunnerPanel(
                endpoint: viewModel.state.serverRunnerEndpoint,
                hasAuthToken: viewModel.state.serverRunnerHasAuthToken,
                redactedAuthToken: viewModel.state.serverRunnerRedactedAuthToken,
                connectionState: viewModel.state.serverRunnerConnectionState,
                status: viewModel.state.serverRunnerStatus,
                onSaveConnection: viewModel.saveServerRunnerConnection,
                onDeleteConnection: viewModel.deleteServerRunnerConnection,
                onRefresh: viewModel.refreshServerRunnerStatus,
                onSetEnabled: viewModel.setServerPaperRunnerEnabled
            )

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var chartSection: some View {
        DashboardPanel {
            CandleChartView(
                candles: viewModel.state.candles,
                positions: chartPositions,
                partialTakeProfitByPositionID: chartPartialTakeProfitByPositionID,
                onNeedsOlderCandles: viewModel.loadMoreLocalCandles
            )
            .frame(minHeight: 260, idealHeight: 320, maxHeight: 420)
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
            onSaveServerRunnerConnection: viewModel.saveServerRunnerConnection,
            onDeleteServerRunnerConnection: viewModel.deleteServerRunnerConnection,
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
            serverRunnerHasAuthToken: viewModel.state.serverRunnerHasAuthToken,
            serverRunnerRedactedAuthToken: viewModel.state.serverRunnerRedactedAuthToken,
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
            .filter { $0.total > 0 && $0.side != .unknown }
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

private struct CompactAutomationStatusPanel: View {
    let endpoint: String
    let connectionState: ServerRunnerConnectionState
    let status: ServerPaperRunnerStatus?
    let account: AccountSnapshot?
    let positions: [PositionSnapshot]
    let showsChart: Bool
    let showsSettings: Bool
    let onRefreshServer: () -> Void
    let onRefreshPositions: () -> Void
    let onSetServerEnabled: (Bool) -> Void
    let onToggleChart: () -> Void
    let onToggleSettings: () -> Void

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("서버 자동매매")
                                .font(.headline)
                            Badge(text: serverBadgeText, color: serverBadgeColor)
                            Badge(text: status?.mode.uppercased() ?? "PAPER", color: .blue)
                            Badge(text: liveBadgeText, color: liveBadgeColor)
                        }

                        Text(subtitleText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Toggle("Paper", isOn: serverEnabledBinding)
                        .toggleStyle(.switch)
                        .disabled(status == nil || isRefreshing)
                        .labelsHidden()
                        .help("서버 paper 평가 ON/OFF")

                    compactIconButton("arrow.clockwise", help: "새로고침", action: onRefreshServer)
                        .disabled(isRefreshing)
                    compactLabeledButton(
                        showsChart ? "닫기" : "차트",
                        systemName: "chart.xyaxis.line",
                        help: "차트 보기/숨기기",
                        action: onToggleChart
                    )
                    compactLabeledButton(
                        "설정",
                        systemName: "slider.horizontal.3",
                        help: "연결/설정",
                        action: onToggleSettings
                    )
                    .foregroundStyle(showsSettings ? Color.accentColor : Color.primary)
                }

                LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                    compactMetric("포지션", "\(positions.count)")
                    compactMetric("Equity", account?.accountEquity.dashboardText ?? "-")
                    compactMetric("가용", account?.available.dashboardText ?? "-")
                    compactMetric("미실현", account?.unrealizedProfitLoss.dashboardText ?? "-", tint: accountProfitTint)
                    compactMetric("저장 캔들", status.map { "\($0.savedCandles)" } ?? "-")
                    compactMetric("신호", status.map { "\($0.signals)" } ?? "-")
                    compactMetric("최근 마감", latestClosedText)
                    compactMetric("주문금액", liveMarginText)
                }

                if let alertText {
                    Text(alertText)
                        .font(.caption)
                        .foregroundStyle(alertColor)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var serverEnabledBinding: Binding<Bool> {
        Binding(
            get: { status?.control?.enabled ?? false },
            set: onSetServerEnabled
        )
    }

    private var metricColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 8, alignment: .leading)
        ]
    }

    private var isRefreshing: Bool {
        if case .refreshing = connectionState { return true }
        return false
    }

    private var serverBadgeText: String {
        switch connectionState {
        case .idle:
            return "대기"
        case .refreshing:
            return "동기화"
        case .connected:
            return status?.control?.enabled == true ? "자동화 ON" : "자동화 OFF"
        case .failed:
            return "확인 필요"
        }
    }

    private var serverBadgeColor: Color {
        switch connectionState {
        case .connected:
            return status?.control?.enabled == true ? .green : .secondary
        case .refreshing:
            return .blue
        case .failed:
            return .orange
        case .idle:
            return .secondary
        }
    }

    private var liveBadgeText: String {
        status?.live?.orderExecutionEnabled == true ? "실주문 ON" : "실주문 OFF"
    }

    private var liveBadgeColor: Color {
        status?.live?.orderExecutionEnabled == true ? .orange : .secondary
    }

    private var subtitleText: String {
        let host = URL(string: endpoint)?.host ?? "서버 미설정"
        let checkedAt = status?.updatedAt?.shortDashboardTime ?? "-"
        return "\(host) · \(checkedAt) 갱신"
    }

    private var latestClosedText: String {
        status?.latestClosedCandleOpenTimeDate?.shortDashboardTime ?? "-"
    }

    private var accountProfitTint: Color {
        guard let value = account?.unrealizedProfitLoss else { return .primary }
        return value >= 0 ? .green : .red
    }

    private var alertText: String? {
        if case .failed(let message) = connectionState {
            return message
        }
        if let failure = status?.failures.first {
            return failure
        }
        if status?.live?.orderExecutionEnabled == false,
           let blocker = status?.live?.orderBlockers.first ?? status?.live?.blockers.first {
            return "실주문 대기: \(localizedLiveBlocker(blocker))"
        }
        return nil
    }

    private var liveMarginText: String {
        guard let margin = status?.live?.executionConfig?.marginUSDT else {
            return "0 USDT"
        }
        return "\(margin) USDT"
    }

    private var alertColor: Color {
        if case .failed = connectionState {
            return .orange
        }
        return status?.failures.isEmpty == false ? .orange : .secondary
    }

    private func compactMetric(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func compactIconButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func localizedLiveBlocker(_ text: String) -> String {
        switch text {
        case "live order execution env switch is disabled":
            return "서버 실주문 스위치 꺼짐"
        case "live order margin USDT is not configured":
            return "주문금액 0 USDT"
        case "live consent is disabled":
            return "실거래 동의 꺼짐"
        case "Bitget credential is not loaded":
            return "Bitget credential 미로드"
        case "fresh account/position snapshot is required":
            return "계정/포지션 최신 snapshot 대기"
        default:
            return text
        }
    }

    private func compactLabeledButton(
        _ title: String,
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .help(help)
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
    let serverRunnerHasAuthToken: Bool
    let serverRunnerRedactedAuthToken: String?
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
    let onSaveServerRunnerConnection: (String, String) -> Void
    let onDeleteServerRunnerConnection: () -> Void
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
                    hasAuthToken: snapshot.serverRunnerHasAuthToken,
                    redactedAuthToken: snapshot.serverRunnerRedactedAuthToken,
                    connectionState: snapshot.serverRunnerConnectionState,
                    status: snapshot.serverRunnerStatus,
                    onSaveConnection: onSaveServerRunnerConnection,
                    onDeleteConnection: onDeleteServerRunnerConnection,
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
