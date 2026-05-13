import SwiftUI

struct CredentialPanel: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var apiKey = ""
    @State private var secretKey = ""
    @State private var passphrase = ""

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("API Credential")
                        .font(.headline)
                    Spacer()
                    statusBadge
                }

                TextField("APIKey", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("SecretKey", text: $secretKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)

                Text("Connect stores keys in Keychain and validates Bitget access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.connectCredential(
                        apiKey: apiKey,
                        secretKey: secretKey,
                        passphrase: passphrase
                    )
                    apiKey = ""
                    secretKey = ""
                    passphrase = ""
                } label: {
                    Text("Connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch viewModel.state.credentialStatus {
        case .disconnected:
            Badge(text: "Disconnected", color: .secondary)
        case .saved:
            Badge(text: "Saved", color: .blue)
        case .validating:
            Badge(text: "Connecting", color: .orange)
        case .connected:
            Badge(text: "Connected", color: .green)
        case .failed:
            Badge(text: "Failed", color: .red)
        }
    }
}

struct AccountSummaryPanel: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("My Account")
                        .font(.headline)
                    Spacer()
                    Badge(text: "Connected", color: .green)
                }

                if let account = viewModel.state.accounts.first {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Equity")
                                .foregroundStyle(.secondary)
                            Text(account.accountEquity.dashboardText)
                                .fontWeight(.semibold)
                        }
                        GridRow {
                            Text("Available")
                                .foregroundStyle(.secondary)
                            Text(account.available.dashboardText)
                        }
                        GridRow {
                            Text("Unrealized")
                                .foregroundStyle(.secondary)
                            Text(account.unrealizedProfitLoss.dashboardText)
                                .foregroundStyle(account.unrealizedProfitLoss >= 0 ? .green : .red)
                        }
                        GridRow {
                            Text("Positions")
                                .foregroundStyle(.secondary)
                            Text("\(viewModel.state.positions.count)")
                        }
                    }
                    .font(.callout.monospacedDigit())
                } else {
                    Text("Connected. Account snapshot will appear after refresh.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Refresh") {
                        viewModel.connectSavedCredential()
                    }
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        viewModel.deleteCredential()
                    }
                }
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
