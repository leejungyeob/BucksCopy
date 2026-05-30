import SwiftUI

struct TimeframePicker: View {
    let selection: CandleTimeframe
    let onSelect: (CandleTimeframe) -> Void

    var body: some View {
        Picker("", selection: Binding(
            get: { selection },
            set: onSelect
        )) {
            ForEach(CandleTimeframe.dashboardCases) { timeframe in
                Text(timeframe.displayName)
                    .tag(timeframe)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Timeframe")
        .frame(width: 120)
    }
}
