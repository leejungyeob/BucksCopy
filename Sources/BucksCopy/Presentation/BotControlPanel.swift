import SwiftUI

struct BotControlPanel: View {
    let runState: StrategyRunState
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Auto Trading")
                        .font(.headline)
                    Spacer()
                    Badge(text: statusText, color: statusColor)
                }

                HStack {
                    Button("Start Paper") {
                        onStart()
                    }
                    .disabled(isRunning)

                    Button("Stop") {
                        onStop()
                    }
                    .disabled(!isRunning)
                }
            }
        }
    }

    private var isRunning: Bool {
        if case .runningPaper = runState { return true }
        return false
    }

    private var statusText: String {
        switch runState {
        case .stopped:
            return "Stopped"
        case .runningPaper:
            return "Paper"
        }
    }

    private var statusColor: Color {
        isRunning ? .green : .secondary
    }
}
