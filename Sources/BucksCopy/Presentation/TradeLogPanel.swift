import SwiftUI

struct TradeLogPanel: View {
    let logs: [TradeEventLog]
    let positions: [PositionSnapshot]
    let automationStartedAt: Date?
    let language: TradeLogLanguage
    let onLanguageChange: (TradeLogLanguage) -> Void

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(language == .korean ? "매매기록" : "Trade History", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    Badge(text: "\(logs.count)", color: logs.isEmpty ? .secondary : .blue)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { language },
                        set: onLanguageChange
                    )) {
                        ForEach(TradeLogLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 128)
                }

                TradeHistorySummaryStrip(
                    logs: logs,
                    positions: positions,
                    automationStartedAt: automationStartedAt,
                    language: language
                )

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if logs.isEmpty {
                            Text(language == .korean ? "아직 매매기록이 없습니다." : "No trades yet.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(logs.reversed()) { log in
                                LogRow(log: log, language: language)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .defaultScrollAnchor(.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct TradeHistorySummaryStrip: View {
    let logs: [TradeEventLog]
    let positions: [PositionSnapshot]
    let automationStartedAt: Date?
    let language: TradeLogLanguage

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            summaryCell(title: label("실현손익", "Realized"), value: realizedProfit.signedDashboardText, tone: realizedProfit >= 0 ? .green : .red)
            summaryCell(title: label("미실현", "Unrealized"), value: unrealizedProfit.signedDashboardText, tone: unrealizedProfit >= 0 ? .green : .red)
            summaryCell(title: label("승률", "Win Rate"), value: winRateText)
            summaryCell(title: label("청산", "Closed"), value: "\(wins)W \(losses)L")
            summaryCell(title: label("진입", "Entries"), value: "\(entryCount)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scopedLogs: [TradeEventLog] {
        guard let automationStartedAt else { return logs }
        return logs.filter { $0.timestamp >= automationStartedAt }
    }

    private var entryCount: Int {
        scopedLogs.filter { log in
            let text = "\(log.metadata?.title ?? "") \(log.message)"
            return text.contains("진입") ||
                text.contains("entry") ||
                text.contains("Paper signal")
        }.count
    }

    private var realizedProfit: Decimal {
        scopedLogs.reduce(Decimal(0)) { partial, log in
            partial + (Self.closeProfitLoss(in: log) ?? 0)
        }
    }

    private var unrealizedProfit: Decimal {
        positions.reduce(Decimal(0)) { $0 + $1.unrealizedProfitLoss }
    }

    private var wins: Int {
        closeOutcomes.wins
    }

    private var losses: Int {
        closeOutcomes.losses
    }

    private var closeOutcomes: (wins: Int, losses: Int, breakevens: Int) {
        scopedLogs.reduce(into: (wins: 0, losses: 0, breakevens: 0)) { result, log in
            if let profitLoss = Self.closeProfitLoss(in: log) {
                if profitLoss > 0 {
                    result.wins += 1
                } else if profitLoss < 0 {
                    result.losses += 1
                } else {
                    result.breakevens += 1
                }
                return
            }

            guard let outcome = log.metadata?.details.first(where: { $0.label == "청산 판정" })?.value else { return }
            if outcome.contains("승") {
                result.wins += 1
            } else if outcome.contains("패") {
                result.losses += 1
            } else {
                result.breakevens += 1
            }
        }
    }

    private var winRateText: String {
        let total = wins + losses
        guard total > 0 else { return "-" }
        return "\((Decimal(wins) / Decimal(total) * 100).dashboardText)%"
    }

    private func summaryCell(title: String, value: String, tone: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tone)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.44))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func label(_ korean: String, _ english: String) -> String {
        language == .korean ? korean : english
    }

    private static func closeProfitLoss(in log: TradeEventLog) -> Decimal? {
        guard isCloseLog(log) else { return nil }
        for label in ["실현 PnL", "청산 PnL", "청산 직전 PnL", "미실현 PnL"] {
            if let value = log.metadata?.details.first(where: { $0.label == label })?.value,
               let profitLoss = DecimalText.optional(value) {
                return profitLoss
            }
        }
        return nil
    }

    private static func isCloseLog(_ log: TradeEventLog) -> Bool {
        guard log.category == .liveOrder else { return false }
        let text = "\(log.metadata?.title ?? "") \(log.metadata?.subtitle ?? "") \(log.message)"
        return text.contains("청산") ||
            text.contains("close submitted") ||
            text.contains("External/manual close detected")
    }
}

private struct LogRow: View {
    let log: TradeEventLog
    let language: TradeLogLanguage
    @State private var isExpanded = false

    private var display: TradeLogDisplay {
        TradeLogDisplay(log: log, language: language)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if !display.detail.isEmpty {
                    Text(display.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !display.tags.isEmpty {
                    LogChipFlow(spacing: 5, rowSpacing: 4) {
                        ForEach(display.tags) { tag in
                            LogChip(text: tag.label, tone: tag.tone)
                        }
                    }
                }

                if !display.details.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 96), spacing: 4, alignment: .topLeading)],
                        alignment: .leading,
                        spacing: 4
                    ) {
                        ForEach(display.details) { detail in
                            LogDetailCell(detail: detail)
                        }
                    }
                }
            }
            .padding(.top, 5)
        } label: {
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(rowAccent)
                    .frame(width: 7, height: 7)

                Text(log.timestamp.dashboardDateTime)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 66, alignment: .leading)
                    .lineLimit(1)

                LogChip(text: display.category, tone: categoryTone)

                if let symbol = log.symbol {
                    LogChip(text: symbol.rawValue, tone: .accent, monospaced: true)
                }

                Text(display.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(log.severity == .error ? .red : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let profitLoss = closeProfitLoss {
                    Text(profitLoss.signedDashboardText)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(profitLoss >= 0 ? .green : .red)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(borderColor, lineWidth: 0.6)
        }
    }

    private var closeProfitLoss: Decimal? {
        guard log.category == .liveOrder else { return nil }
        let text = "\(log.metadata?.title ?? "") \(log.metadata?.subtitle ?? "") \(log.message)"
        guard text.contains("청산") ||
            text.contains("close submitted") ||
            text.contains("External/manual close detected") else {
            return nil
        }
        for label in ["실현 PnL", "청산 PnL", "청산 직전 PnL", "미실현 PnL"] {
            if let value = log.metadata?.details.first(where: { $0.label == label })?.value,
               let profitLoss = DecimalText.optional(value) {
                return profitLoss
            }
        }
        return nil
    }

    private var rowAccent: Color {
        switch log.severity {
        case .info:
            return categoryTone.color
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var severityTone: TradeLogTone {
        switch log.severity {
        case .info:
            return .neutral
        case .warning:
            return .warning
        case .error:
            return .danger
        }
    }

    private var categoryTone: TradeLogTone {
        switch log.category {
        case .automation:
            return .success
        case .bot:
            return .accent
        case .credential:
            return .warning
        case .signal:
            return .accent
        case .liveOrder:
            return .success
        case .risk:
            return .danger
        case .position:
            return .accent
        }
    }

    private var rowBackground: Color {
        switch log.severity {
        case .info:
            return Color(nsColor: .controlBackgroundColor).opacity(0.75)
        case .warning:
            return Color.orange.opacity(0.08)
        case .error:
            return Color.red.opacity(0.08)
        }
    }

    private var borderColor: Color {
        switch log.severity {
        case .info:
            return Color(nsColor: .separatorColor).opacity(0.35)
        case .warning:
            return .orange.opacity(0.28)
        case .error:
            return .red.opacity(0.32)
        }
    }
}

private struct LogChip: View {
    let text: String
    let tone: TradeLogTone
    var monospaced = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize(horizontal: true, vertical: true)
    }

    private var foreground: Color {
        switch tone {
        case .neutral:
            return .secondary
        case .accent:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        case .danger:
            return .red
        }
    }

    private var background: Color {
        foreground.opacity(tone == .neutral ? 0.10 : 0.13)
    }
}

private struct LogDetailCell: View {
    let detail: TradeLogDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(detail.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(detail.value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(valueColor)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(valueColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var valueColor: Color {
        switch detail.tone {
        case .neutral:
            return .primary
        case .accent:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        case .danger:
            return .red
        }
    }
}

private extension TradeLogTone {
    var color: Color {
        switch self {
        case .neutral:
            return .secondary
        case .accent:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        case .danger:
            return .red
        }
    }
}

private struct LogChipFlow: Layout {
    let spacing: CGFloat
    let rowSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let rows = rows(for: subviews, maxWidth: maxWidth)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.enumerated().reduce(CGFloat(0)) { partial, row in
            partial + row.element.height + (row.offset == 0 ? 0 : rowSpacing)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = rows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [FlowRow] {
        var rows: [FlowRow] = []
        var current = FlowRow()
        let effectiveMaxWidth = max(maxWidth, 1)

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width
            if current.indices.isEmpty == false, proposedWidth > effectiveMaxWidth {
                rows.append(current)
                current = FlowRow()
            }
            current.append(index: index, size: size, spacing: spacing)
        }

        if current.indices.isEmpty == false {
            rows.append(current)
        }
        return rows
    }

    private struct FlowRow {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(index: Int, size: CGSize, spacing: CGFloat) {
            if indices.isEmpty {
                width = size.width
            } else {
                width += spacing + size.width
            }
            height = max(height, size.height)
            indices.append(index)
        }
    }
}

private struct TradeLogDisplay {
    let title: String
    let detail: String
    let category: String
    let severity: String?
    let tags: [TradeLogTag]
    let details: [TradeLogDetail]

    init(log: TradeEventLog, language: TradeLogLanguage) {
        category = Self.categoryLabel(log.category, language: language)
        severity = Self.severityLabel(log.severity, language: language)
        tags = log.metadata?.tags ?? []
        details = log.metadata?.details ?? []

        if let metadata = log.metadata {
            title = metadata.title
            detail = metadata.subtitle ?? log.message
            return
        }

        switch language {
        case .korean:
            let parsed = Self.koreanMessage(for: log)
            title = parsed.title
            detail = parsed.detail
        case .english:
            let parsed = Self.englishMessage(for: log)
            title = parsed.title
            detail = parsed.detail
        }
    }

    private static func koreanMessage(for log: TradeEventLog) -> (title: String, detail: String) {
        let message = log.message
        if message == "Bitget connected and credential stored in Keychain." {
            return ("Bitget 연결 완료", "API 키 검증이 끝났고 credential은 macOS Keychain에 저장됐습니다.")
        }
        if message == "Credential deleted." {
            return ("API 키 삭제", "저장된 Bitget credential을 삭제했고 계정/포지션 정보를 초기화했습니다.")
        }
        if let count = firstNumber(in: message), message.contains("read-only position") {
            return ("포지션 동기화", "실계정 USDT-M Futures 포지션 \(count)개를 읽기 전용으로 불러왔습니다.")
        }
        if message.contains("Bitget WebSocket") {
            return ("실시간 연결 상태 확인 필요", message)
        }
        if message.contains("Live") && message.contains("order") {
            return ("실거래 주문 기록", message)
        }
        if message.contains("Live auto trading started") {
            return ("실거래 자동매매 시작", "Watchlist 전체 시간봉 감시를 시작했습니다.")
        }
        if message == "Live auto trading stopped." {
            return ("실거래 자동매매 정지", "자동매매 평가 루프를 중지했습니다.")
        }
        if message.contains("Missing saved credential") {
            return ("Credential 없음", "저장된 API 키가 없어 private API/소켓 연결을 시작할 수 없습니다.")
        }
        if message.contains("Bitget API error") || message.contains("request failed") {
            return ("Bitget 요청 실패", message)
        }
        return (fallbackTitle(for: log, language: .korean), message)
    }

    private static func englishMessage(for log: TradeEventLog) -> (title: String, detail: String) {
        let message = log.message
        if message == "Bitget connected and credential stored in Keychain." {
            return ("Bitget connected", "The API key was validated and the credential is stored in macOS Keychain.")
        }
        if message == "Credential deleted." {
            return ("Credential deleted", "Stored Bitget credentials were removed and account/position data was cleared.")
        }
        if let count = firstNumber(in: message), message.contains("read-only position") {
            return ("Positions synced", "Loaded \(count) read-only USDT-M Futures position(s) from the live account.")
        }
        if message.contains("Live") && message.contains("order") {
            return ("Live order record", message)
        }
        if message.contains("Live auto trading started") {
            return ("Live auto trading started", "Started monitoring every Watchlist timeframe.")
        }
        if message == "Live auto trading stopped." {
            return ("Live auto trading stopped", "The live auto-trading loop was stopped.")
        }
        return (fallbackTitle(for: log, language: .english), message)
    }

    private static func categoryLabel(_ category: TradeEventCategory, language: TradeLogLanguage) -> String {
        switch (category, language) {
        case (.automation, .korean): return "자동매매"
        case (.bot, .korean): return "봇"
        case (.credential, .korean): return "인증"
        case (.signal, .korean): return "신호"
        case (.liveOrder, .korean): return "실주문"
        case (.risk, .korean): return "리스크"
        case (.position, .korean): return "포지션"
        case (.automation, .english): return "Automation"
        case (.bot, .english): return "Bot"
        case (.credential, .english): return "Auth"
        case (.signal, .english): return "Signal"
        case (.liveOrder, .english): return "Live"
        case (.risk, .english): return "Risk"
        case (.position, .english): return "Position"
        }
    }

    private static func severityLabel(_ severity: TradeEventSeverity, language: TradeLogLanguage) -> String? {
        switch (severity, language) {
        case (.info, _):
            return nil
        case (.warning, .korean):
            return "주의"
        case (.error, .korean):
            return "오류"
        case (.warning, .english):
            return "WARN"
        case (.error, .english):
            return "ERROR"
        }
    }

    private static func fallbackTitle(for log: TradeEventLog, language: TradeLogLanguage) -> String {
        switch (log.category, log.severity, language) {
        case (_, .error, .korean): return "작업 실패"
        case (_, .warning, .korean): return "확인 필요"
        case (.automation, _, .korean): return "자동매매 기록"
        case (.position, _, .korean): return "포지션 이벤트"
        case (.bot, _, .korean): return "봇 이벤트"
        case (_, .error, .english): return "Operation failed"
        case (_, .warning, .english): return "Needs attention"
        case (.automation, _, .english): return "Automation record"
        case (.position, _, .english): return "Position event"
        case (.bot, _, .english): return "Bot event"
        default:
            return language == .korean ? "시스템 이벤트" : "System event"
        }
    }

    private static func firstNumber(in text: String) -> String? {
        text.split(whereSeparator: { !$0.isNumber }).first.map(String.init)
    }
}
