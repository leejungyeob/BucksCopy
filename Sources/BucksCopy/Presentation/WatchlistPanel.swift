import SwiftUI

struct WatchlistPanel: View {
    let symbols: [FuturesSymbol]
    let selectedSymbol: FuturesSymbol
    let onSelect: (FuturesSymbol) -> Void

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Markets")
                        .font(.headline)
                    Spacer()
                    Text("\(symbols.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 3) {
                    ForEach(symbols) { symbol in
                        Button {
                            onSelect(symbol)
                        } label: {
                            HStack {
                                Text(symbol.rawValue)
                                    .font(.callout.monospacedDigit())
                                Spacer()
                                if selectedSymbol == symbol {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 7, height: 7)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(selectedSymbol == symbol ? Color.accentColor.opacity(0.14) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
    }
}
