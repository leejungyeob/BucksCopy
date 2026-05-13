import SwiftUI

struct WatchlistPanel: View {
    let symbols: [FuturesSymbol]
    let selectedSymbol: FuturesSymbol
    let onSelect: (FuturesSymbol) -> Void

    @State private var searchText = ""

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("USDT-M Symbols")
                        .font(.headline)
                    Spacer()
                    Text("\(filteredSymbols.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                TextField("Search symbol", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredSymbols) { symbol in
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
                .frame(minHeight: 180, idealHeight: 290, maxHeight: 360)
            }
        }
    }

    private var filteredSymbols: [FuturesSymbol] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !query.isEmpty else { return symbols }
        return symbols.filter { $0.rawValue.contains(query) }
    }
}
