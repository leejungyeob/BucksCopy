import SwiftUI

struct BotControlPanel: View {
    let runState: StrategyRunState
    let isConnected: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    @State private var isArmed = false

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Auto Trading")
                        .font(.headline)
                    Spacer()
                    Badge(text: statusText, color: statusColor)
                }

                Toggle("실거래 동의", isOn: $isArmed)
                    .toggleStyle(.checkbox)
                    .disabled(isRunning)

                HStack {
                    Button("Start Live") {
                        onStart()
                    }
                    .disabled(isRunning || !isConnected || !isArmed)

                    Button("Stop") {
                        onStop()
                    }
                    .disabled(!isRunning)
                }
            }
        }
    }

    private var isRunning: Bool {
        if case .runningLive = runState { return true }
        return false
    }

    private var statusText: String {
        switch runState {
        case .stopped:
            return "Stopped"
        case .runningLive:
            return "Live"
        }
    }

    private var statusColor: Color {
        isRunning ? .green : .secondary
    }
}
