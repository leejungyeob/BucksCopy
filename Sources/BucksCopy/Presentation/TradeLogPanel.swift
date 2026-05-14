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
        HStack(alignment: .top, spacing: 8) {
            Text(log.timestamp.shortDashboardTime)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            Text(display.category)
                .font(.caption.weight(.semibold))
                .foregroundStyle(categoryColor)
                .frame(width: 82, alignment: .leading)

            if let symbol = log.symbol {
                Text(symbol.rawValue)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(display.title)
                        .font(.callout.weight(.semibold))
                    if display.severity != nil {
                        Text(display.severity ?? "")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(severityColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(severityColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                Text(display.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .foregroundStyle(log.severity == .error ? .red : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.35))
                .frame(height: 0.5)
        }
    }

    private var severityColor: Color {
        switch log.severity {
        case .info:
            return .secondary
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var categoryColor: Color {
        switch log.category {
        case .bot:
            return .blue
        case .credential:
            return .orange
        case .signal:
            return .purple
        case .paperOrder:
            return .green
        case .risk:
            return .red
        case .position:
            return .teal
        }
    }
}

private struct TradeLogDisplay {
    let title: String
    let detail: String
    let category: String
    let severity: String?

    init(log: TradeEventLog, language: TradeLogLanguage) {
        category = Self.categoryLabel(log.category, language: language)
        severity = Self.severityLabel(log.severity, language: language)

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
        if message.contains("Paper") && message.contains("order created") {
            return ("페이퍼 매매 기록", message)
        }
        if message.contains("Paper bot evaluated") && message.contains("no signal") {
            return ("전략 평가 완료: 신호 없음", "Paper runner가 선택 전략을 평가했지만 진입 조건이 충족되지 않았습니다.")
        }
        if message.contains("Signal generated") {
            return ("전략 신호 발생", "전략이 진입 신호를 만들었습니다. 실제 주문은 v1 정책상 차단되고 Paper 흐름만 사용합니다.")
        }
        if message == "Paper bot stopped." {
            return ("Paper 봇 정지", "자동매매 평가 루프를 중지했습니다.")
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
        if message.contains("Paper") && message.contains("order created") {
            return ("Paper trade record", message)
        }
        if message.contains("Paper bot evaluated") && message.contains("no signal") {
            return ("Strategy checked: no signal", "The paper runner evaluated the selected strategy and found no entry condition.")
        }
        if message.contains("Signal generated") {
            return ("Strategy signal generated", "A strategy produced an entry signal. Live orders remain disabled in v1.")
        }
        if message == "Paper bot stopped." {
            return ("Paper bot stopped", "The paper auto-trading runner was stopped.")
        }
        return (fallbackTitle(for: log, language: .english), message)
    }

    private static func categoryLabel(_ category: TradeEventCategory, language: TradeLogLanguage) -> String {
        switch (category, language) {
        case (.bot, .korean): return "봇"
        case (.credential, .korean): return "인증"
        case (.signal, .korean): return "신호"
        case (.paperOrder, .korean): return "페이퍼"
        case (.risk, .korean): return "리스크"
        case (.position, .korean): return "포지션"
        case (.bot, .english): return "Bot"
        case (.credential, .english): return "Auth"
        case (.signal, .english): return "Signal"
        case (.paperOrder, .english): return "Paper"
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
        case (.position, _, .korean): return "포지션 이벤트"
        case (.bot, _, .korean): return "봇 이벤트"
        case (_, .error, .english): return "Operation failed"
        case (_, .warning, .english): return "Needs attention"
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
