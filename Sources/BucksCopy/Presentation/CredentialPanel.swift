import SwiftUI

struct CredentialPanel: View {
    let credentialStatus: CredentialStatus
    let onConnect: (String, String, String) -> Void

    @State private var apiKey = ""
    @State private var secretKey = ""
    @State private var passphrase = ""

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Bitget 로그인", systemImage: "key.fill")
                        .font(.headline)
                    Spacer()
                    statusBadge
                }

                TextField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                SecureField("Secret Key", text: $secretKey)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)

                Label("api.buckscopy.com", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if case .failed(let message) = credentialStatus {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: submit) {
                    Label("로그인", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit)
            }
        }
    }

    private var canSubmit: Bool {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            !isValidating
    }

    private var isValidating: Bool {
        if case .validating = credentialStatus { return true }
        return false
    }

    private func submit() {
        onConnect(apiKey, secretKey, passphrase)
        apiKey = ""
        secretKey = ""
        passphrase = ""
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch credentialStatus {
        case .disconnected:
            Badge(text: "로그아웃", color: .secondary)
        case .saved:
            Badge(text: "저장됨", color: .blue)
        case .validating:
            Badge(text: "연결 중", color: .orange)
        case .connected:
            Badge(text: "로그인됨", color: .green)
        case .failed:
            Badge(text: "실패", color: .red)
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
