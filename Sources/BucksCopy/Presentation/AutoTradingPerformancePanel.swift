import SwiftUI

struct AutoTradingPerformancePanel: View {
    let session: LiveAutomationSession?
    let account: AccountSnapshot?
    let positions: [PositionSnapshot]
    let logs: [TradeEventLog]
    let runState: StrategyRunState

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let snapshot = LiveAutomationPerformanceSnapshot(
                session: session,
                account: account,
                positions: positions,
                logs: logs,
                runState: runState,
                now: context.date
            )

            DashboardPanel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("자동매매 기록")
                                .font(.headline)
                            Text(snapshot.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }

                        Spacer(minLength: 12)

                        PerformanceChip(
                            text: snapshot.statusText,
                            tone: snapshot.statusTone
                        )
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(snapshot.metrics) { metric in
                            PerformanceMetricTile(metric: metric)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct LiveAutomationPerformanceSnapshot {
    let statusText: String
    let statusTone: PerformanceTone
    let subtitle: String
    let metrics: [PerformanceMetric]

    init(
        session: LiveAutomationSession?,
        account: AccountSnapshot?,
        positions: [PositionSnapshot],
        logs: [TradeEventLog],
        runState: StrategyRunState,
        now: Date
    ) {
        let isLiveRunning: Bool
        if case .runningLive = runState {
            isLiveRunning = true
        } else {
            isLiveRunning = false
        }

        statusText = isLiveRunning ? "LIVE" : (session == nil ? "대기" : "정지")
        statusTone = isLiveRunning ? .success : (session == nil ? .neutral : .warning)

        let ledgerLogs = logs
            .filter(\.isAutomationTradingRecord)
            .sorted { $0.timestamp < $1.timestamp }
        let firstStartedAt = Self.firstStartedAt(logs: ledgerLogs, session: session)
        let latestEquity = account?.accountEquity ?? session?.latestEquity
        let latestAvailable = account?.available ?? session?.latestAvailable
        let openUnrealized = account?.unrealizedProfitLoss ?? Self.openUnrealized(positions)
        let seedEquity = Self.firstDecimalDetail(in: ledgerLogs, label: "시드 Equity") ?? session?.seedEquity
        let seedAvailable = Self.firstDecimalDetail(in: ledgerLogs, label: "시드 가용잔고") ?? session?.seedAvailable
        let equityChange = Self.subtract(latestEquity, seedEquity)
        let estimatedRealizedProfit = equityChange.map { $0 - (openUnrealized ?? 0) }
        let returnPercent = Self.returnPercent(equityChange: equityChange, seedEquity: seedEquity)
        let activeDurationSeconds = Self.activeDurationSeconds(
            logs: ledgerLogs,
            session: session,
            isLiveRunning: isLiveRunning,
            now: now
        )
        let entryCount = ledgerLogs.filter(Self.isEntryLog).count
        let closeCount = ledgerLogs.filter(Self.isCloseRequestLog).count
        let riskCount = ledgerLogs.filter { $0.category == .risk || $0.severity == .error }.count
        let openPositionCount = positions.filter { $0.total > 0 }.count

        if let firstStartedAt {
            let updatedAt = account?.updatedAt ?? session?.lastUpdatedAt
            subtitle = "\(firstStartedAt.dashboardDateTime) 첫 시작 · \(ledgerLogs.count)개 누적 · \(updatedAt?.shortDashboardTime ?? "-") 갱신"
        } else {
            subtitle = "누적 자동매매 기록 없음"
        }

        metrics = [
            PerformanceMetric(
                title: "시드",
                value: Self.usdtText(seedEquity),
                footnote: seedAvailable.map { "가용 \($0.riskText) USDT" } ?? "시작 equity",
                tone: .neutral
            ),
            PerformanceMetric(
                title: "현재 Equity",
                value: Self.usdtText(latestEquity),
                footnote: latestAvailable.map { "가용 \($0.riskText) USDT" } ?? "-",
                tone: .accent
            ),
            PerformanceMetric(
                title: "자동매매 순수익",
                value: Self.signedUSDTText(estimatedRealizedProfit),
                footnote: "미실현 PnL 제외 추정",
                tone: PerformanceTone.profit(estimatedRealizedProfit)
            ),
            PerformanceMetric(
                title: "Equity 증감",
                value: Self.signedUSDTText(equityChange),
                footnote: returnPercent.map { "\($0.percentText) 시드 대비" } ?? "시드 대비",
                tone: PerformanceTone.profit(equityChange)
            ),
            PerformanceMetric(
                title: "자동매매 기간",
                value: Self.durationText(seconds: activeDurationSeconds),
                footnote: "누적 활성 시간",
                tone: isLiveRunning ? .success : .neutral
            ),
            PerformanceMetric(
                title: "확정 승/패",
                value: "연동 전",
                footnote: "종료 PnL 필요",
                tone: .neutral
            ),
            PerformanceMetric(
                title: "진입/청산",
                value: "\(entryCount) / \(closeCount)",
                footnote: "주문 로그 기준",
                tone: entryCount > 0 || closeCount > 0 ? .accent : .neutral
            ),
            PerformanceMetric(
                title: "현재 포지션",
                value: "\(openPositionCount)개",
                footnote: "미실현 \(Self.signedUSDTText(openUnrealized))",
                tone: PerformanceTone.profit(openUnrealized)
            ),
            PerformanceMetric(
                title: "가용잔고",
                value: Self.usdtText(latestAvailable),
                footnote: "USDT-M Futures",
                tone: .neutral
            ),
            PerformanceMetric(
                title: "리스크 이벤트",
                value: "\(riskCount)건",
                footnote: "보호/차단/오류",
                tone: riskCount > 0 ? .danger : .neutral
            )
        ]
    }

    private static func firstStartedAt(logs: [TradeEventLog], session: LiveAutomationSession?) -> Date? {
        logs.first(where: isStartLog)?.timestamp ?? logs.first?.timestamp ?? session?.startedAt
    }

    private static func activeDurationSeconds(
        logs: [TradeEventLog],
        session: LiveAutomationSession?,
        isLiveRunning: Bool,
        now: Date
    ) -> Int? {
        var total = 0
        var openStartedAt: Date?

        for log in logs {
            if isStartLog(log), openStartedAt == nil {
                openStartedAt = log.timestamp
            } else if isStopLog(log), let startedAt = openStartedAt {
                total += max(0, Int(log.timestamp.timeIntervalSince(startedAt)))
                openStartedAt = nil
            }
        }

        if let openStartedAt {
            let fallbackEnd = isLiveRunning ? now : (logs.last?.timestamp ?? now)
            total += max(0, Int(fallbackEnd.timeIntervalSince(openStartedAt)))
        } else if total == 0, let session {
            total = max(0, Int((session.stoppedAt ?? now).timeIntervalSince(session.startedAt)))
        }

        if total > 0 { return total }
        return firstStartedAt(logs: logs, session: session) == nil ? nil : 0
    }

    private static func isStartLog(_ log: TradeEventLog) -> Bool {
        log.category == .automation && log.message == "Live automation session started."
    }

    private static func isStopLog(_ log: TradeEventLog) -> Bool {
        log.category == .automation && log.message == "Live automation session stopped."
    }

    private static func firstDecimalDetail(in logs: [TradeEventLog], label: String) -> Decimal? {
        for log in logs where isStartLog(log) {
            if let value = log.metadata?.details.first(where: { $0.label == label })?.value,
               let decimal = DecimalText.optional(value) {
                return decimal
            }
        }
        return nil
    }

    private static func isEntryLog(_ log: TradeEventLog) -> Bool {
        guard log.category == .liveOrder else { return false }
        let text = "\(log.metadata?.title ?? "") \(log.message)"
        return text.contains("진입") || text.contains("order submitted by")
    }

    private static func isCloseRequestLog(_ log: TradeEventLog) -> Bool {
        guard log.category == .liveOrder else { return false }
        let text = "\(log.metadata?.title ?? "") \(log.message)"
        return text.contains("청산 요청") ||
            text.contains("기존 포지션 정리") ||
            text.contains("close submitted")
    }

    private static func openUnrealized(_ positions: [PositionSnapshot]) -> Decimal? {
        guard !positions.isEmpty else { return nil }
        return positions.reduce(Decimal(0)) { $0 + $1.unrealizedProfitLoss }
    }

    private static func subtract(_ lhs: Decimal?, _ rhs: Decimal?) -> Decimal? {
        guard let lhs, let rhs else { return nil }
        return lhs - rhs
    }

    private static func returnPercent(equityChange: Decimal?, seedEquity: Decimal?) -> Decimal? {
        guard let equityChange, let seedEquity, seedEquity > 0 else { return nil }
        return equityChange / seedEquity * 100
    }

    private static func usdtText(_ value: Decimal?) -> String {
        guard let value else { return "-" }
        return "\(value.riskText) USDT"
    }

    private static func signedUSDTText(_ value: Decimal?) -> String {
        guard let value else { return "-" }
        let sign = value > 0 ? "+" : value < 0 ? "-" : ""
        let absolute = value < 0 ? -value : value
        return "\(sign)\(absolute.riskText) USDT"
    }

    private static func durationText(seconds: Int?) -> String {
        guard let seconds else { return "-" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60

        if days > 0 {
            return "\(days)일 \(hours)시간"
        }
        if hours > 0 {
            return "\(hours)시간 \(minutes)분"
        }
        if minutes > 0 {
            return "\(minutes)분 \(remainingSeconds)초"
        }
        return "\(remainingSeconds)초"
    }
}

private struct PerformanceMetric: Identifiable {
    let title: String
    let value: String
    let footnote: String
    let tone: PerformanceTone

    var id: String { title }
}

private struct PerformanceMetricTile: View {
    let metric: PerformanceMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(metric.value)
                .font(.headline.monospacedDigit().weight(.semibold))
                .foregroundStyle(metric.tone.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            Text(metric.footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(metric.tone.background)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct PerformanceChip: View {
    let text: String
    let tone: PerformanceTone

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(tone.foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tone.background))
    }
}

private enum PerformanceTone {
    case neutral
    case accent
    case success
    case warning
    case danger

    static func profit(_ value: Decimal?) -> PerformanceTone {
        guard let value else { return .neutral }
        if value > 0 { return .success }
        if value < 0 { return .danger }
        return .neutral
    }

    var foreground: Color {
        switch self {
        case .neutral:
            return .primary
        case .accent:
            return .accentColor
        case .success:
            return .green
        case .warning:
            return .orange
        case .danger:
            return .red
        }
    }

    var background: Color {
        switch self {
        case .neutral:
            return Color(nsColor: .textBackgroundColor).opacity(0.55)
        case .accent:
            return Color.accentColor.opacity(0.14)
        case .success:
            return Color.green.opacity(0.16)
        case .warning:
            return Color.orange.opacity(0.16)
        case .danger:
            return Color.red.opacity(0.16)
        }
    }
}
