import SwiftUI

struct TradeLogPanel: View {
    let logs: [TradeEventLog]
    let language: TradeLogLanguage
    let onLanguageChange: (TradeLogLanguage) -> Void

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(language == .korean ? "자동매매 로그" : "Trade Log")
                        .font(.headline)
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
                    .frame(width: 148)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if logs.isEmpty {
                            Text(language == .korean ? "아직 기록된 이벤트가 없습니다." : "No events yet.")
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

private struct LogRow: View {
    let log: TradeEventLog
    let language: TradeLogLanguage

    private var display: TradeLogDisplay {
        TradeLogDisplay(log: log, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LogChipFlow(spacing: 8, rowSpacing: 6) {
                LogChip(
                    text: log.timestamp.shortDashboardTime,
                    tone: .neutral,
                    monospaced: true
                )
                LogChip(text: display.category, tone: categoryTone)

                if let symbol = log.symbol {
                    LogChip(text: symbol.rawValue, tone: .accent, monospaced: true)
                }

                if let severity = display.severity {
                    LogChip(text: severity, tone: severityTone)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(display.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(log.severity == .error ? .red : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !display.detail.isEmpty {
                    Text(display.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !display.tags.isEmpty {
                LogChipFlow(spacing: 8, rowSpacing: 6) {
                    ForEach(display.tags) { tag in
                        LogChip(text: tag.label, tone: tag.tone)
                    }
                }
            }

            if !display.details.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 176), spacing: 8, alignment: .topLeading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(display.details) { detail in
                        LogDetailCell(detail: detail)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 0.8)
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
            .lineLimit(2)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(valueColor)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(valueColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
