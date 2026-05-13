import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var didBootstrap = false

    var body: some View {
        HSplitView {
            leftColumn
                .frame(minWidth: 260, idealWidth: 310, maxWidth: 420)
                .padding(.trailing, 6)

            centerColumn
                .frame(minWidth: 520, idealWidth: 760)
                .padding(.horizontal, 6)

            rightColumn
                .frame(minWidth: 380, idealWidth: 480, maxWidth: 680)
                .padding(.leading, 6)
        }
        .padding(14)
        .frame(minWidth: 1180, minHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard !didBootstrap else { return }
            didBootstrap = true
            viewModel.bootstrap()
        }
    }

    private var leftColumn: some View {
        VStack(spacing: 12) {
            if viewModel.state.isConnected {
                AccountSummaryPanel(viewModel: viewModel)
            } else {
                CredentialPanel(viewModel: viewModel)
            }
            WatchlistPanel(
                symbols: viewModel.state.watchlist,
                selectedSymbol: viewModel.state.selectedSymbol,
                onSelect: viewModel.selectSymbol
            )
            StrategySettingsPanel(
                definitions: viewModel.strategyDefinitions,
                config: viewModel.state.strategyConfig,
                leverageRange: viewModel.selectedLeverageRange,
                onSelect: viewModel.updateStrategy,
                onLeverageChange: viewModel.updateLeverage
            )
            BotControlPanel(
                runState: viewModel.state.runState,
                onStart: viewModel.startPaperBot,
                onStop: viewModel.stopPaperBot
            )
            Spacer(minLength: 0)
        }
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
