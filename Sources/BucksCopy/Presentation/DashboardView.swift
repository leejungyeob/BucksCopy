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
                        logs: dashboardTradeLogs,
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
                        VStack(spacing: 10) {
                            StrategySelectionPanel(
                                strategies: viewModel.state.serverRunnerStatus?.strategies?.available ?? [],
                                enabledStrategyIDs: viewModel.state.serverRunnerStatus?.strategies?.enabledStrategyIDs ?? [],
                                isRefreshing: isServerRefreshing,
                                onToggle: viewModel.setServerStrategyEnabled
                            )
                            .frame(maxWidth: .infinity, maxHeight: 245, alignment: .topLeading)

                            PositionPanel(
                                positions: displayPositions,
                                partialTakeProfitByPositionID: positionPartialTakeProfitByPositionID,
                                strategyContextByPositionID: positionStrategyContextByPositionID,
                                onRefresh: {
                                    Task { await viewModel.refreshPositions() }
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .frame(minWidth: 360, idealWidth: 440, maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)

                        TradeLogPanel(
                            logs: dashboardTradeLogs,
                            positions: displayPositions,
                            automationStartedAt: viewModel.state.serverRunnerStatus?.control?.updatedAt,
                            language: viewModel.state.logLanguage,
                            onLanguageChange: viewModel.updateLogLanguage
                        )
                        .frame(minWidth: 500, idealWidth: 760, maxHeight: .infinity)
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

private struct TradingCommandPanel: View {
    let endpoint: String
    let connectionState: ServerRunnerConnectionState
    let status: ServerPaperRunnerStatus?
    let credentialStatus: CredentialStatus
    let isConnected: Bool
    let account: AccountSnapshot?
    let positions: [PositionSnapshot]
    let logs: [TradeEventLog]
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
                        TradingCommandMetric(title: "승률", value: winRateText, footnote: closeRecordText)
                        TradingCommandMetric(title: "실현손익", value: realizedProfitText, tone: realizedProfitTone)
                        TradingCommandMetric(title: "미실현", value: unrealizedProfitText, tone: unrealizedProfitTone)
                        TradingCommandMetric(title: "포지션", value: "\(positions.count)개", footnote: positionFootnote)
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

    private var closeSummary: (wins: Int, losses: Int, breakevens: Int) {
        performanceLogs.reduce(into: (wins: 0, losses: 0, breakevens: 0)) { result, log in
            if let profitLoss = Self.closeProfitLoss(in: log) {
                if profitLoss > 0 {
                    result.wins += 1
                } else if profitLoss < 0 {
                    result.losses += 1
                } else {
                    result.breakevens += 1
                }
                return
            }

            guard let outcome = log.metadata?.detailValue(for: "청산 판정") else { return }
            if outcome.contains("승") {
                result.wins += 1
            } else if outcome.contains("패") {
                result.losses += 1
            } else {
                result.breakevens += 1
            }
        }
    }

    private var performanceLogs: [TradeEventLog] {
        guard let startedAt = status?.control?.updatedAt else { return logs }
        return logs.filter { $0.timestamp >= startedAt }
    }

    private var realizedProfit: Decimal {
        performanceLogs.reduce(Decimal(0)) { partial, log in
            partial + (Self.closeProfitLoss(in: log) ?? 0)
        }
    }

    private var unrealizedProfit: Decimal {
        positions.reduce(Decimal(0)) { $0 + $1.unrealizedProfitLoss }
    }

    private var realizedProfitText: String {
        realizedProfit.signedDashboardText
    }

    private var unrealizedProfitText: String {
        unrealizedProfit.signedDashboardText
    }

    private var realizedProfitTone: Color {
        realizedProfit >= 0 ? .green : .red
    }

    private var unrealizedProfitTone: Color {
        unrealizedProfit >= 0 ? .green : .red
    }

    private var winRateText: String {
        let summary = closeSummary
        let total = summary.wins + summary.losses
        guard total > 0 else { return "-" }
        let rate = Decimal(summary.wins) / Decimal(total) * 100
        return "\(rate.dashboardText)%"
    }

    private var closeRecordText: String {
        let summary = closeSummary
        guard summary.wins + summary.losses + summary.breakevens > 0 else {
            return "확정 청산 대기"
        }
        return "\(summary.wins)승 \(summary.losses)패"
    }

    private static func closeProfitLoss(in log: TradeEventLog) -> Decimal? {
        guard isCloseLog(log) else { return nil }
        for label in ["실현 PnL", "청산 PnL", "청산 직전 PnL", "미실현 PnL"] {
            if let value = log.metadata?.detailValue(for: label),
               let profitLoss = DecimalText.optional(value) {
                return profitLoss
            }
        }
        return nil
    }

    private static func isCloseLog(_ log: TradeEventLog) -> Bool {
        guard log.category == .liveOrder else { return false }
        let text = "\(log.metadata?.title ?? "") \(log.metadata?.subtitle ?? "") \(log.message)"
        return text.contains("청산") ||
            text.contains("close submitted") ||
            text.contains("External/manual close detected")
    }

    private var positionFootnote: String {
        "미실현 \(unrealizedProfit.signedDashboardText)"
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: onToggle
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(disableToggle)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(strategy.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        Badge(text: strategy.symbol, color: .secondary)
                        Badge(text: strategy.timeframe, color: .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 158, alignment: .leading)

            if let backtest = strategy.backtest {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 40), spacing: 5, alignment: .leading)],
                    alignment: .leading,
                    spacing: 3
                ) {
                    strategyMetric("수익", "\(backtest.netReturnPercent)%", tone: .green)
                    strategyMetric("승률", "\(backtest.winRatePercent)%")
                    strategyMetric("MDD", "\(backtest.maxDrawdownPercent)%", tone: .orange)
                    strategyMetric("거래", "\(backtest.totalTrades)")
                    strategyMetric("PF", backtest.profitFactor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func strategyMetric(_ label: String, _ value: String, tone: Color = .primary) -> some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
