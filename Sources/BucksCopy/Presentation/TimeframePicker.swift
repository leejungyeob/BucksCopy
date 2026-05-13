import SwiftUI

struct TimeframePicker: View {
    let selection: CandleTimeframe
    let onSelect: (CandleTimeframe) -> Void

    var body: some View {
        Picker("Timeframe", selection: Binding(
            get: { selection },
            set: onSelect
        )) {
            ForEach(CandleTimeframe.allCases) { timeframe in
                Text(timeframe.displayName)
                    .tag(timeframe)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 360)
    }
}
