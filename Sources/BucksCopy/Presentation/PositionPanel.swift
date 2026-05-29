import SwiftUI

struct PositionPanel: View {
    let positions: [PositionSnapshot]
    var partialTakeProfitByPositionID: [String: Decimal] = [:]
    var strategyContextByPositionID: [String: PositionStrategyContext] = [:]
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
                                PositionCard(
                                    position: position,
                                    partialTakeProfit: position.partialTakeProfit ??
                                        partialTakeProfitByPositionID[position.id],
                                    strategyContext: strategyContextByPositionID[position.id]
                                )
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
    let partialTakeProfit: Decimal?
    let strategyContext: PositionStrategyContext?

    var body: some View {
        let partialProjection = PositionExitProjection.partialTakeProfit(
            position: position,
            price: partialTakeProfit
        )
        let finalProjection = PositionExitProjection.finalTakeProfit(
            position: position,
            partialPrice: partialTakeProfit,
            finalPrice: position.takeProfit
        )
        let stopProjection = PositionExitProjection.stopLoss(
            position: position,
            price: position.stopLoss
        )

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
                PositionMetric(
                    title: "TP1",
                    value: partialTakeProfit?.dashboardText ?? "-",
                    subtitle: partialProjection?.displayText(prefix: "예상"),
                    tint: .green,
                    subtitleTint: partialProjection?.tint
                )
                PositionMetric(
                    title: "TP2",
                    value: position.takeProfit?.dashboardText ?? "-",
                    subtitle: finalProjection?.displayText(prefix: partialTakeProfit == nil ? "예상" : "누적"),
                    tint: .green,
                    subtitleTint: finalProjection?.tint
                )
                PositionMetric(
                    title: "SL",
                    value: position.stopLoss?.dashboardText ?? "-",
                    subtitle: stopProjection?.displayText(prefix: "예상"),
                    tint: .red,
                    subtitleTint: stopProjection?.tint
                )
                PositionMetric(title: "Strategy", value: strategyContext?.strategyID ?? "-")
                PositionMetric(title: "Timeframe", value: strategyContext?.timeframe?.rawValue ?? "-")
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
    var subtitle: String?
    var tint: Color = .primary
    var subtitleTint: Color?

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
            if let subtitle {
                Text(subtitle)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(subtitleTint ?? tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: subtitle == nil ? 48 : 64, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct PositionExitProjection: Equatable {
    let amount: Decimal
    let marginReturnPercent: Decimal

    static func partialTakeProfit(
        position: PositionSnapshot,
        price: Decimal?
    ) -> PositionExitProjection? {
        guard let price else { return nil }
        return projection(
            position: position,
            legs: [
                .init(price: price, fillRatio: SplitTakeProfitPlan.partialTakeProfitRatio)
            ]
        )
    }

    static func finalTakeProfit(
        position: PositionSnapshot,
        partialPrice: Decimal?,
        finalPrice: Decimal?
    ) -> PositionExitProjection? {
        guard let finalPrice else { return nil }
        var legs: [Leg] = []
        if let partialPrice {
            legs.append(.init(price: partialPrice, fillRatio: SplitTakeProfitPlan.partialTakeProfitRatio))
            legs.append(.init(price: finalPrice, fillRatio: SplitTakeProfitPlan.finalTakeProfitRatio))
        } else {
            legs.append(.init(price: finalPrice, fillRatio: 1))
        }
        return projection(position: position, legs: legs)
    }

    static func stopLoss(
        position: PositionSnapshot,
        price: Decimal?
    ) -> PositionExitProjection? {
        guard let price else { return nil }
        return projection(position: position, legs: [.init(price: price, fillRatio: 1)])
    }

    func displayText(prefix: String) -> String {
        "\(prefix) \(amount.signedDashboardText) USDT / \(marginReturnPercent.percentText)"
    }

    var tint: Color {
        amount >= 0 ? .green : .red
    }

    private static func projection(
        position: PositionSnapshot,
        legs: [Leg]
    ) -> PositionExitProjection? {
        guard position.total > 0,
              position.openPriceAverage > 0,
              position.leverage > 0,
              position.side != .unknown,
              legs.isEmpty == false else {
            return nil
        }

        let amount = legs.reduce(Decimal(0)) { result, leg in
            guard leg.price > 0, leg.fillRatio > 0 else { return result }
            return result + perUnitProfitLoss(
                side: position.side,
                entryPrice: position.openPriceAverage,
                exitPrice: leg.price
            ) * position.total * leg.fillRatio
        }
        let margin = position.openPriceAverage * position.total / Decimal(position.leverage)
        guard margin > 0 else { return nil }

        return PositionExitProjection(
            amount: amount,
            marginReturnPercent: amount / margin * 100
        )
    }

    private static func perUnitProfitLoss(
        side: PositionSide,
        entryPrice: Decimal,
        exitPrice: Decimal
    ) -> Decimal {
        switch side {
        case .long:
            return exitPrice - entryPrice
        case .short:
            return entryPrice - exitPrice
        case .unknown:
            return 0
        }
    }

    private struct Leg {
        let price: Decimal
        let fillRatio: Decimal
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
