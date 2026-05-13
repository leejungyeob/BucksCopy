import SwiftUI

struct PositionPanel: View {
    let positions: [PositionSnapshot]
    let onRefresh: () -> Void

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Positions")
                        .font(.headline)
                    Spacer()
                    Button("Refresh", action: onRefresh)
                }

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if positions.isEmpty {
                            EmptyPositionCard()
                        } else {
                            ForEach(positions) { position in
                                PositionCard(position: position)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PositionCard: View {
    let position: PositionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(position.symbol.rawValue)
                            .font(.headline.monospacedDigit())

                        Text(position.side.displayName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(position.side.tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(position.side.tint.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text("\(position.marginMode.uppercased()) / \(position.leverage)x / Size \(position.total.dashboardText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 20)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(position.unrealizedProfitLoss.dashboardText)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(position.profitTint)
                    Text(position.priceMovePercent?.percentText ?? "-")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(position.profitTint)
                }
            }

            LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                PositionMetric(title: "Entry", value: position.openPriceAverage.dashboardText)
                PositionMetric(title: "Mark", value: position.markPrice.dashboardText)
                PositionMetric(title: "Available", value: position.available.dashboardText)
                PositionMetric(title: "Liquidation", value: position.liquidationPrice?.dashboardText ?? "-")
                PositionMetric(title: "Take Profit", value: position.takeProfit?.dashboardText ?? "-", tint: .green)
                PositionMetric(title: "Stop Loss", value: position.stopLoss?.dashboardText ?? "-", tint: .red)
                PositionMetric(title: "Entry Time", value: position.createdAt?.dashboardDateTime ?? "-")
                PositionMetric(title: "Updated", value: position.updatedAt?.dashboardDateTime ?? "-")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(position.side.tint.opacity(0.22), lineWidth: 0.8)
        }
    }

    private var metricColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: 116, maximum: 180),
                spacing: 8,
                alignment: .leading
            )
        ]
    }
}

private struct PositionMetric: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct EmptyPositionCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No open positions")
                .font(.callout.weight(.semibold))
            Text("Live USDT-M Futures positions will appear here after the account syncs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.6)
        }
    }
}

private extension PositionSnapshot {
    var profitTint: Color {
        unrealizedProfitLoss >= 0 ? .green : .red
    }
}

private extension PositionSide {
    var displayName: String {
        switch self {
        case .long:
            return "LONG"
        case .short:
            return "SHORT"
        case .unknown:
            return "UNKNOWN"
        }
    }

    var tint: Color {
        switch self {
        case .long:
            return .green
        case .short:
            return .red
        case .unknown:
            return .secondary
        }
    }
}
