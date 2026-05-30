import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var didBootstrap = false

    var body: some View {
        Group {
            if isAuthenticated {
                VStack(spacing: 10) {
                    TradingCommandPanel(
                        endpoint: viewModel.state.serverRunnerEndpoint,
                        connectionState: viewModel.state.serverRunnerConnectionState,
                        status: viewModel.state.serverRunnerStatus,
                        credentialStatus: viewModel.state.credentialStatus,
                        isConnected: isAuthenticated,
                        account: dashboardAccount,
                        positions: displayPositions,
                        onRefreshServer: viewModel.refreshServerRunnerStatus,
                        onRefreshPositions: {
                            Task { await viewModel.refreshPositions() }
                        },
                        onToggleAutomation: {
                            viewModel.setServerPaperRunnerEnabled(
                                !(viewModel.state.serverRunnerStatus?.control?.enabled ?? false)
                            )
                        },
                        onLogout: viewModel.deleteCredential
                    )

                    HSplitView {
                        VSplitView {
                            PositionPanel(
                                positions: displayPositions,
                                partialTakeProfitByPositionID: positionPartialTakeProfitByPositionID,
                                strategyContextByPositionID: positionStrategyContextByPositionID,
                                onRefresh: {
                                    Task { await viewModel.refreshPositions() }
                                }
                            )
                            .frame(minHeight: 120, idealHeight: 170, maxHeight: .infinity, alignment: .topLeading)

                            DashboardChartPanel(
                                symbol: viewModel.state.selectedSymbol,
                                timeframe: viewModel.state.selectedTimeframe,
                                watchlist: viewModel.state.watchlist,
                                candles: viewModel.state.candles,
                                candleStatus: viewModel.state.candleStatus,
                                positions: chartPositions,
                                partialTakeProfitByPositionID: positionPartialTakeProfitByPositionID,
                                onSelectSymbol: viewModel.selectSymbol,
                                onSelectTimeframe: viewModel.selectTimeframe,
                                onNeedsOlderCandles: viewModel.loadMoreLocalCandles
                            )
                            .frame(minHeight: 180, idealHeight: 320, maxHeight: .infinity, alignment: .topLeading)

                            StrategySelectionPanel(
                                strategies: viewModel.state.serverRunnerStatus?.strategies?.available ?? [],
                                enabledStrategyIDs: viewModel.state.serverRunnerStatus?.strategies?.enabledStrategyIDs ?? [],
                                isRefreshing: isServerRefreshing,
                                onToggle: viewModel.setServerStrategyEnabled
                            )
                            .frame(minHeight: 150, idealHeight: 230, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .frame(minWidth: 520, idealWidth: 720, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                        TradeLogPanel(
                            logs: dashboardTradeLogs,
                            positions: displayPositions,
                            automationStartedAt: viewModel.state.serverRunnerStatus?.control?.updatedAt,
                            language: viewModel.state.logLanguage,
                            onLanguageChange: viewModel.updateLogLanguage
                        )
                        .frame(minWidth: 340, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
                .frame(maxWidth: 520, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(12)
        .padding(.top, 8)
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard !didBootstrap else { return }
            didBootstrap = true
            viewModel.bootstrap()
        }
    }

    private var isAuthenticated: Bool {
        viewModel.state.serverRunnerHasAuthToken || viewModel.state.isConnected
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

    private var chartPositions: [PositionSnapshot] {
        displayPositions.filter { $0.symbol == viewModel.state.selectedSymbol }
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

    private var dashboardTradeLogs: [TradeEventLog] {
        viewModel.state.recentLogs.filter { log in
            guard log.isAutomationTradingRecord else { return false }
            return !log.isServerHeartbeat
        }
    }

    private var isServerRefreshing: Bool {
        if case .refreshing = viewModel.state.serverRunnerConnectionState {
            return true
        }
        return false
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

    var isServerHeartbeat: Bool {
        metadata?.title == "Paper runner heartbeat" ||
            message.hasPrefix("Paper runner heartbeat.")
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

private struct DashboardChartPanel: View {
    let symbol: FuturesSymbol
    let timeframe: CandleTimeframe
    let watchlist: [FuturesSymbol]
    let candles: [Candle]
    let candleStatus: CandleLoadStatus
    let positions: [PositionSnapshot]
    let partialTakeProfitByPositionID: [String: Decimal]
    let onSelectSymbol: (FuturesSymbol) -> Void
    let onSelectTimeframe: (CandleTimeframe) -> Void
    let onNeedsOlderCandles: () -> Void

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("차트")
                        .font(.headline)
                    Badge(text: "\(candles.count)", color: candles.isEmpty ? .secondary : .blue)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { symbol },
                        set: onSelectSymbol
                    )) {
                        ForEach(watchlist) { symbol in
                            Text(symbol.rawValue).tag(symbol)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 122)

                    TimeframePicker(selection: timeframe, onSelect: onSelectTimeframe)
                        .controlSize(.small)
                }

                CandleChartView(
                    candles: candles,
                    positions: positions,
                    partialTakeProfitByPositionID: partialTakeProfitByPositionID,
                    onNeedsOlderCandles: onNeedsOlderCandles
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusText: String {
        switch candleStatus {
        case .idle:
            return "-"
        case .loading:
            return "로딩"
        case .loaded(_, let source):
            return source
        case .failed:
            return "실패"
        }
    }

    private var statusColor: Color {
        switch candleStatus {
        case .failed:
            return .red
        case .loading:
            return .orange
        case .idle:
            return .secondary
        case .loaded:
            return .secondary
        }
    }
}

private struct TradingCommandPanel: View {
    let endpoint: String
    let connectionState: ServerRunnerConnectionState
    let status: ServerPaperRunnerStatus?
    let credentialStatus: CredentialStatus
    let isConnected: Bool
    let account: AccountSnapshot?
    let positions: [PositionSnapshot]
    let onRefreshServer: () -> Void
    let onRefreshPositions: () -> Void
    let onToggleAutomation: () -> Void
    let onLogout: () -> Void

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            DashboardPanel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 14) {
                        HStack(alignment: .center, spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(statusTint.opacity(0.12))
                                    .frame(width: 34, height: 34)
                                Image(systemName: statusIconName)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(statusTint)
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                Text(titleText)
                                    .font(.headline.weight(.semibold))
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Badge(text: automationBadgeText, color: statusTint)
                                    Badge(text: liveBadgeText, color: liveBadgeColor)
                                    Text(subtitleText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                        HStack(spacing: 8) {
                            Button(action: {
                                onRefreshServer()
                                onRefreshPositions()
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.borderless)
                            .disabled(isRefreshing)
                            .help("새로고침")

                            if isConnected {
                                Button(action: onLogout) {
                                    Label("로그아웃", systemImage: "rectangle.portrait.and.arrow.right")
                                }
                                .buttonStyle(.bordered)
                            }

                            Button(action: onToggleAutomation) {
                                Label(primaryButtonText, systemImage: primaryButtonIcon)
                                    .font(.callout.weight(.semibold))
                                    .frame(minWidth: 128)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(isAutomationEnabled ? .red : .green)
                            .disabled(!isConnected || isRefreshing)
                        }
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        TradingCommandMetric(title: "경과", value: elapsedText(now: context.date), tone: statusTint)
                        TradingCommandMetric(title: "최근 마감", value: latestClosedText)
                        TradingCommandMetric(title: "포지션", value: "\(positions.count)개", footnote: positionFootnote)
                        TradingCommandMetric(title: "전략", value: strategyCountText, footnote: "활성 전략")
                        TradingCommandMetric(title: "Equity", value: account?.accountEquity.dashboardText ?? "-")
                        TradingCommandMetric(title: "가용", value: account?.available.dashboardText ?? "-", footnote: liveLimitText)
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
    }

    private var metricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 6, alignment: .leading)]
    }

    private var isRefreshing: Bool {
        if case .refreshing = connectionState { return true }
        return false
    }

    private var isAutomationEnabled: Bool {
        status?.control?.enabled == true
    }

    private var isOrderExecutionEnabled: Bool {
        status?.live?.orderExecutionEnabled == true
    }

    private var isLiveTradingActive: Bool {
        isAutomationEnabled && isOrderExecutionEnabled
    }

    private var statusTint: Color {
        if !isConnected { return .secondary }
        if case .failed = connectionState { return .orange }
        if isLiveTradingActive { return .green }
        if isAutomationEnabled { return .orange }
        return .secondary
    }

    private var statusIconName: String {
        if !isConnected { return "person.crop.circle.badge.exclamationmark" }
        return isAutomationEnabled ? "bolt.circle.fill" : "pause.circle.fill"
    }

    private var titleText: String {
        if !isConnected { return "로그인이 필요합니다" }
        if isLiveTradingActive { return "자동매매 실행 중" }
        if isAutomationEnabled { return "자동매매 준비 중" }
        return "자동매매 정지"
    }

    private var subtitleText: String {
        let host = URL(string: endpoint)?.host ?? "api.buckscopy.com"
        let checkedAt = status?.updatedAt?.shortDashboardTime ?? "-"
        return "\(host) · \(checkedAt) 갱신"
    }

    private var automationBadgeText: String {
        guard isConnected else { return "로그인 필요" }
        return isAutomationEnabled ? "ON" : "OFF"
    }

    private var liveBadgeText: String {
        isOrderExecutionEnabled ? "실주문" : "대기"
    }

    private var liveBadgeColor: Color {
        isOrderExecutionEnabled ? .orange : .secondary
    }

    private var primaryButtonText: String {
        isAutomationEnabled ? "자동매매 중단" : "자동매매 시작"
    }

    private var primaryButtonIcon: String {
        isAutomationEnabled ? "stop.fill" : "play.fill"
    }

    private var latestClosedText: String {
        latestClosedAt?.shortDashboardTime ?? "-"
    }

    private var latestClosedAt: Date? {
        status?.latestClosedCandleOpenTimeDate?.addingTimeInterval(CandleTimeframe.fifteenMinutes.duration)
    }

    private func elapsedText(now: Date) -> String {
        guard isAutomationEnabled,
              let startedAt = status?.control?.updatedAt else {
            return "-"
        }
        let seconds = max(Int(now.timeIntervalSince(startedAt)), 0)
        return Self.durationText(seconds: seconds)
    }

    private static func durationText(seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private var positionFootnote: String {
        "열린 포지션"
    }

    private var strategyCountText: String {
        guard let strategies = status?.strategies else { return "-" }
        return "\(strategies.enabledCount)/\(strategies.available.count)"
    }

    private var liveLimitText: String {
        guard let ratio = status?.live?.executionConfig?.availableBalanceRatio else {
            return "USDT-M"
        }
        let percent = DecimalText.parse(ratio) * 100
        return "주문한도 가용 \(percent.dashboardText)%"
    }

    private var alertText: String? {
        if case .failed(let message) = connectionState {
            return message
        }
        if case .failed(let message) = credentialStatus {
            return message
        }
        if isConnected,
           status?.live?.orderExecutionEnabled == false,
           let blocker = status?.live?.orderBlockers.first ?? status?.live?.blockers.first {
            return "대기 사유: \(localizedLiveBlocker(blocker))"
        }
        return nil
    }

    private var alertColor: Color {
        if case .failed = connectionState { return .orange }
        if case .failed = credentialStatus { return .red }
        return .secondary
    }

    private func localizedLiveBlocker(_ text: String) -> String {
        switch text {
        case "live order execution env switch is disabled":
            return "서버 실주문 스위치 꺼짐"
        case "live order margin USDT is not configured":
            return "주문한도 미설정"
        case "live consent is disabled":
            return "자동매매 실주문 동의 꺼짐"
        case "Bitget credential is not loaded":
            return "Bitget 로그인 필요"
        case "fresh account/position snapshot is required":
            return "계정/포지션 최신 정보 대기"
        default:
            return text
        }
    }
}

private struct TradingCommandMetric: View {
    let title: String
    let value: String
    var footnote: String?
    var tone: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.46))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct StrategySelectionPanel: View {
    let strategies: [ServerRunnerStrategy]
    let enabledStrategyIDs: [String]
    let isRefreshing: Bool
    let onToggle: (String, Bool) -> Void

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("매매전략")
                        .font(.headline)
                    Spacer()
                    Badge(text: "\(enabledStrategyIDs.count)/\(strategies.count)", color: .blue)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if strategies.isEmpty {
                            Text("서버 전략 정보를 불러오는 중입니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(strategies) { strategy in
                                StrategySelectionRow(
                                    strategy: strategy,
                                    isEnabled: enabledStrategyIDs.contains(strategy.id),
                                    disableToggle: isRefreshing || shouldDisableToggle(for: strategy),
                                    onToggle: { isEnabled in
                                        onToggle(strategy.id, isEnabled)
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func shouldDisableToggle(for strategy: ServerRunnerStrategy) -> Bool {
        enabledStrategyIDs.contains(strategy.id) && enabledStrategyIDs.count <= 1
    }
}

private struct StrategySelectionRow: View {
    let strategy: ServerRunnerStrategy
    let isEnabled: Bool
    let disableToggle: Bool
    let onToggle: (Bool) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: onToggle
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(disableToggle)

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Text(strategy.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                                Badge(text: strategy.symbol, color: .secondary)
                                Badge(text: strategy.timeframe, color: .secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let backtest = strategy.backtest {
                            summaryMetric("수익", "\(backtest.netReturnPercent)%", tone: .green)
                            summaryMetric("승률", "\(backtest.winRatePercent)%")
                        }

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                    }
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                StrategyBacktestDetail(backtest: strategy.backtest)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isEnabled ? Color.green.opacity(0.08) : Color(nsColor: .textBackgroundColor).opacity(0.38))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isEnabled ? Color.green.opacity(0.25) : Color(nsColor: .separatorColor).opacity(0.35))
        }
    }

    private func summaryMetric(_ label: String, _ value: String, tone: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tone)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: 58, alignment: .leading)
    }
}

private struct StrategyBacktestDetail: View {
    let backtest: ServerStrategyBacktestSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let backtest {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 72), spacing: 6, alignment: .leading)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    detailMetric("수익률", "\(backtest.netReturnPercent)%", tone: .green)
                    detailMetric("승률", "\(backtest.winRatePercent)%")
                    detailMetric("MDD", "\(backtest.maxDrawdownPercent)%", tone: .orange)
                    detailMetric("거래수", "\(backtest.totalTrades)")
                    detailMetric("연간거래", backtest.annualTrades ?? "-")
                    detailMetric("PF", backtest.profitFactor)
                }

                Text(backtest.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("백테스트 결과가 아직 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 24)
        .padding(.top, 2)
    }

    private func detailMetric(_ label: String, _ value: String, tone: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct DashboardPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}
