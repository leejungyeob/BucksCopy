import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var didBootstrap = false

    var body: some View {
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
        .padding(14)
        .padding(.top, 20)
        .frame(minWidth: 1100, minHeight: 680)
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
            onSelectStrategy: viewModel.updateStrategy,
            onLeverageChange: viewModel.updateLeverage,
            onMaximumRiskPerTradeChange: viewModel.updateMaximumRiskPerTrade,
            onMaximumPositionMarginChange: viewModel.updateMaximumPositionMargin,
            onSignalConfirmationModeChange: viewModel.updateSignalConfirmationMode,
            onStartPaper: viewModel.startPaperBot,
            onStopPaper: viewModel.stopPaperBot
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
            strategyDefinitions: viewModel.strategyDefinitions(for: viewModel.state.selectedTimeframe),
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
                        Text(candleStatusText)
                            .foregroundStyle(.secondary)
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

    private var candleStatusText: String {
        let historyText: String
        switch viewModel.state.candleHistoryStatus {
        case .idle:
            historyText = ""
        case .syncing(let savedCount, let pageCount):
            historyText = " • history syncing \(savedCount) saved / \(pageCount) pages"
        case .complete(let savedCount):
            historyText = savedCount > 0
                ? " • history saved \(savedCount)"
                : " • history ready"
        case .failed:
            historyText = " • history sync failed"
        }

        switch viewModel.state.candleStatus {
        case .idle:
            return "USDT-M Futures"
        case .loading:
            return "Loading candles from Bitget..."
        case .loaded(let count, let source):
            return "\(count) candles loaded from \(source)\(historyText)"
        case .failed(let message):
            return "Candle load failed: \(message)"
        }
    }
}

private struct DashboardLeftSnapshot: Equatable {
    let credentialStatus: CredentialStatus
    let account: AccountSnapshot?
    let positionCount: Int
    let watchlist: [FuturesSymbol]
    let selectedSymbol: FuturesSymbol
    let strategyDefinitions: [StrategyDefinition]
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
    let onSelectStrategy: (String) -> Void
    let onLeverageChange: (Int) -> Void
    let onMaximumRiskPerTradeChange: (Decimal) -> Void
    let onMaximumPositionMarginChange: (Decimal) -> Void
    let onSignalConfirmationModeChange: (SignalConfirmationMode) -> Void
    let onStartPaper: () -> Void
    let onStopPaper: () -> Void

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
                    definitions: snapshot.strategyDefinitions,
                    config: snapshot.strategyConfig,
                    leverageRange: snapshot.selectedLeverageRange,
                    onSelect: onSelectStrategy,
                    onLeverageChange: onLeverageChange,
                    onMaximumRiskPerTradeChange: onMaximumRiskPerTradeChange,
                    onMaximumPositionMarginChange: onMaximumPositionMarginChange,
                    onSignalConfirmationModeChange: onSignalConfirmationModeChange
                )
                BotControlPanel(
                    runState: snapshot.runState,
                    onStart: onStartPaper,
                    onStop: onStopPaper
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.visible)
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
