import SwiftUI

struct ServerRunnerPanel: View {
    let endpoint: String
    let hasAuthToken: Bool
    let redactedAuthToken: String?
    let connectionState: ServerRunnerConnectionState
    let status: ServerPaperRunnerStatus?
    let onSaveConnection: (String, String) -> Void
    let onDeleteConnection: () -> Void
    let onRefresh: () -> Void
    let onSetEnabled: (Bool) -> Void

    @State private var endpointDraft = ""
    @State private var showsAdvancedSettings = false

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Cloud Runner")
                        .font(.headline)
                    Spacer()
                    Badge(text: statusText, color: statusColor)
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRefreshing)
                    .help("서버 상태 새로고침")
                }

                HStack(spacing: 6) {
                    Image(systemName: endpoint.isEmpty ? "cloud.slash" : "cloud")
                        .foregroundStyle(.secondary)
                    Text(endpointHostText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("Paper 판단", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .disabled(status == nil || isRefreshing)

                HStack(spacing: 10) {
                    metric("캔들", value: status.map { "\($0.savedCandles)" } ?? "-")
                    metric("평가", value: status.map { "\($0.evaluations)" } ?? "-")
                    metric("신호", value: status.map { "\($0.signals)" } ?? "-")
                }

                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text(latestClosedText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let failureText {
                    Text(failureText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                DisclosureGroup("고급", isExpanded: $showsAdvancedSettings) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Server URL", text: $endpointDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)

                        HStack(spacing: 8) {
                            Button {
                                onSaveConnection(endpointDraft, "")
                            } label: {
                                Image(systemName: "tray.and.arrow.down")
                                    .frame(width: 16, height: 16)
                            }
                            .disabled(endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help("저장")

                            Button {
                                endpointDraft = ""
                                onDeleteConnection()
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .frame(width: 16, height: 16)
                            }
                            .disabled(endpoint.isEmpty && !hasAuthToken)
                            .help("초기화")

                            Spacer()

                            if let redactedAuthToken {
                                Label(redactedAuthToken, systemImage: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
        }
        .onAppear {
            syncDraftEndpointIfNeeded()
        }
        .onChange(of: endpoint) { _, _ in
            syncDraftEndpointIfNeeded()
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { status?.control?.enabled ?? false },
            set: onSetEnabled
        )
    }

    private var isRefreshing: Bool {
        if case .refreshing = connectionState { return true }
        return false
    }

    private func syncDraftEndpointIfNeeded() {
        guard endpointDraft.isEmpty || endpointDraft == endpoint else { return }
        endpointDraft = endpoint
    }

    private var statusText: String {
        switch connectionState {
        case .idle:
            return "Idle"
        case .refreshing:
            return "Sync"
        case .connected:
            return status?.control?.enabled == true ? "On" : "Off"
        case .failed:
            return "Check"
        }
    }

    private var statusColor: Color {
        switch connectionState {
        case .connected:
            return status?.control?.enabled == true ? .green : .secondary
        case .failed:
            return .orange
        case .refreshing:
            return .blue
        case .idle:
            return .secondary
        }
    }

    private var latestClosedText: String {
        guard let date = status?.latestClosedCandleOpenTimeDate else {
            return "최근 마감: -"
        }
        return "최근 마감: \(Self.dateFormatter.string(from: date))"
    }

    private var endpointHostText: String {
        guard let host = URL(string: endpoint)?.host, !host.isEmpty else {
            return "미설정"
        }
        return host
    }

    private var failureText: String? {
        switch connectionState {
        case .failed(let message):
            return message
        default:
            guard let first = status?.failures.first else { return nil }
            return first
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
