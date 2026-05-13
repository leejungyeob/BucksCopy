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
                Text("Strategy")
                    .font(.headline)

                Picker("Method", selection: Binding(
                    get: { config.strategyID },
                    set: onSelect
                )) {
                    ForEach(definitions) { definition in
                        Text(definition.name)
                            .tag(definition.id)
                    }
                }
                .pickerStyle(.menu)

                Stepper(
                    value: Binding(
                        get: { config.leverage },
                        set: onLeverageChange
                    ),
                    in: leverageRange
                ) {
                    HStack {
                        Text("Leverage")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(config.leverage)x")
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Stop")
                            .foregroundStyle(.secondary)
                        Text("Strategy")
                    }
                    GridRow {
                        Text("Take")
                            .foregroundStyle(.secondary)
                        Text("Strategy")
                    }
                    GridRow {
                        Text("Mode")
                            .foregroundStyle(.secondary)
                        Text("Paper")
                    }
                }
                .font(.callout)
            }
        }
    }
}
