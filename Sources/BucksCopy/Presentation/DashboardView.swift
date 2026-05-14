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
                positions: viewModel.state.positions,
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
            runState: viewModel.state.runState
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
                    onNeedsOlderCandles: viewModel.loadMoreLocalCandles
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var rightColumn: some View {
        VSplitView {
            PositionPanel(
                positions: viewModel.state.positions,
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
        viewModel.state.positions.filter { $0.symbol == viewModel.state.selectedSymbol }
    }

    private var dashboardAccount: AccountSnapshot? {
        viewModel.state.accounts.first { $0.marginCoin.uppercased() == "USDT" } ??
            viewModel.state.accounts.first
    }

    private var activeStrategyRoutes: [ActiveStrategyRoute] {
        CandleTimeframe.allCases.flatMap { timeframe in
            viewModel.strategyDefinitions(for: timeframe).map {
                ActiveStrategyRoute(timeframe: timeframe, definition: $0)
            }
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
    let timeframe: CandleTimeframe
    let definition: StrategyDefinition

    var id: String {
        "\(timeframe.rawValue):\(definition.id)"
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
