import SwiftUI

struct StrategySettingsPanel: View {
    let config: StrategyConfig
    let leverageRange: ClosedRange<Int>
    let onLeverageChange: (Int) -> Void
    let onMaximumRiskPerTradeChange: (Decimal) -> Void
    let onMaximumPositionMarginChange: (Decimal) -> Void
    let onSignalConfirmationModeChange: (SignalConfirmationMode) -> Void

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("매매전략")
                    .font(.headline)

                Stepper(
                    value: Binding(
                        get: { config.leverage },
                        set: onLeverageChange
                    ),
                    in: leverageRange
                ) {
                    HStack {
                        RiskParameterLabel(text: "레버리지", info: .leverage)
                        Spacer()
                        Text("\(config.leverage)x")
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                }

                Stepper(
                    value: Binding<Double>(
                        get: {
                            NSDecimalNumber(decimal: config.maximumRiskPerTradePercent).doubleValue
                        },
                        set: {
                            onMaximumRiskPerTradeChange(Decimal($0))
                        }
                    ),
                    in: 1...NSDecimalNumber(
                        decimal: StrategyRiskPolicy.maximumConfigurableRiskPerTradePercent
                    ).doubleValue,
                    step: 0.5
                ) {
                    HStack {
                        RiskParameterLabel(text: "1회 최대 손실", info: .maximumRiskPerTrade)
                        Spacer()
                        Text("\(config.maximumRiskPerTradePercent.riskText)%")
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                }

                Stepper(
                    value: Binding<Double>(
                        get: {
                            NSDecimalNumber(decimal: config.maximumPositionMarginPercent).doubleValue
                        },
                        set: {
                            onMaximumPositionMarginChange(Decimal($0))
                        }
                    ),
                    in: NSDecimalNumber(
                        decimal: StrategyRiskPolicy.minimumConfigurablePositionMarginPercent
                    ).doubleValue...NSDecimalNumber(
                        decimal: StrategyRiskPolicy.maximumConfigurablePositionMarginPercent
                    ).doubleValue,
                    step: 5
                ) {
                    HStack {
                        RiskParameterLabel(text: "1회 최대 투입", info: .maximumPositionMargin)
                        Spacer()
                        Text("\(config.maximumPositionMarginPercent.riskText)%")
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("손절")
                            .foregroundStyle(.secondary)
                        Text("전략 기준")
                    }
                    GridRow {
                        Text("익절")
                            .foregroundStyle(.secondary)
                        Text("전략 기준")
                    }
                    GridRow {
                        Text("모드")
                            .foregroundStyle(.secondary)
                        Text("Paper")
                    }
                }
                .font(.callout)
            }
        }
    }
}

enum RiskParameterInfo {
    case leverage
    case maximumRiskPerTrade
    case maximumPositionMargin

    var title: String {
        switch self {
        case .leverage:
            return "레버리지"
        case .maximumRiskPerTrade:
            return "1회 최대 손실"
        case .maximumPositionMargin:
            return "1회 최대 투입"
        }
    }

    var message: String {
        switch self {
        case .leverage:
            return "내 돈을 몇 배 크기의 포지션으로 운용할지 정하는 값입니다.\n\n예를 들어 시드의 20%를 증거금으로 넣고 레버리지를 2x로 쓰면, 실제 시장에 노출되는 포지션 크기는 시드의 약 40%가 됩니다. 가격이 1% 움직여도 포지션 손익은 2% 움직인 것처럼 계산되기 때문에, 수익도 커지지만 손절에 닿았을 때 계좌가 받는 충격도 같이 커집니다."
        case .maximumRiskPerTrade:
            return "이 거래가 실패해서 손절이 나갔을 때, 계좌 전체에서 최대 몇 %까지 잃어도 되는지를 정하는 값입니다.\n\n예를 들어 레버리지 8x, 진입가에서 손절가까지의 거리가 4%라면, 시드를 전부 넣었을 때 계좌 손실위험은 4% x 8 = 32%입니다. 그런데 1회 최대 손실을 5%로 정해두면, 앱은 5 / 32 = 15.63%까지만 투입해서 손절 시 계좌 손실이 5% 안쪽에 머물도록 줄입니다."
        case .maximumPositionMargin:
            return "한 번 진입할 때 시드 중 실제 증거금으로 넣을 수 있는 최대 비율입니다.\n\n앱은 먼저 손절 기준으로 안전하게 넣을 수 있는 비율을 계산하고, 그 다음 이 최대 투입 한도를 한 번 더 적용합니다. 그래서 손실 제한상 15.63%까지 들어갈 수 있더라도 1회 최대 투입이 10%라면 실제 투입은 min(15.63%, 10%) = 10%가 됩니다.\n\n즉 최대 손실은 '얼마나 잃어도 되는가'이고, 최대 투입은 '애초에 얼마까지 넣을 것인가'입니다."
        }
    }
}

struct RiskParameterLabel: View {
    let text: String
    let info: RiskParameterInfo

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .foregroundStyle(.secondary)
            RiskParameterInfoButton(info: info)
        }
    }
}

private struct RiskParameterInfoButton: View {
    let info: RiskParameterInfo
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Text("!")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.secondary.opacity(0.75))
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.secondary.opacity(0.14)))
                .overlay(Circle().stroke(Color.secondary.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(info.title)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(info.title)
                    .font(.caption.weight(.semibold))
                Text(info.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 330, alignment: .leading)
        }
    }
}
