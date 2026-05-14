import SwiftUI

struct StrategySettingsPanel: View {
    let definitions: [StrategyDefinition]
    let config: StrategyConfig
    let leverageRange: ClosedRange<Int>
    let onSelect: (String) -> Void
    let onLeverageChange: (Int) -> Void

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("자동매매 전략")
                    .font(.headline)

                VStack(spacing: 4) {
                    ForEach(definitions) { definition in
                        Button {
                            guard definition.id != config.strategyID else { return }
                            onSelect(definition.id)
                        } label: {
                            HStack(spacing: 8) {
                                Text(definition.name)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer()
                                if definition.id == config.strategyID {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(definition.id == config.strategyID ? Color.accentColor.opacity(0.14) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Stepper(
                    value: Binding(
                        get: { config.leverage },
                        set: onLeverageChange
                    ),
                    in: leverageRange
                ) {
                    HStack {
                        Text("레버리지")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(config.leverage)x")
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
