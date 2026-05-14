import SwiftUI

struct BacktestPanel: View {
    let definitions: [StrategyDefinition]
    let symbols: [FuturesSymbol]
    let configuration: BacktestConfiguration
    let leverageRange: ClosedRange<Int>
    let status: BacktestStatus
    let result: BacktestResult?
    let comparison: BacktestComparisonResult?
    let onSymbolChange: (FuturesSymbol) -> Void
    let onTimeframeChange: (CandleTimeframe) -> Void
    let onStrategyChange: (String) -> Void
    let onLeverageChange: (Int) -> Void
    let onMaximumRiskPerTradeChange: (Decimal) -> Void
    let onMaximumPositionMarginChange: (Decimal) -> Void
    let onInitialCapitalChange: (Decimal) -> Void
    let onSignalConfirmationModeChange: (SignalConfirmationMode) -> Void
    let onCompareSignalConfirmationChange: (Bool) -> Void
    let onRun: () -> Void

    private var strategyDefinitions: [StrategyDefinition] {
        definitions
    }

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("백테스트")
                        .font(.headline)
                    Spacer()
                    StatusBadge(status: status)
                }

                SettingBlock(title: "코인") {
                    HStack(spacing: 6) {
                        ForEach(symbols) { symbol in
                            SelectionButton(
                                title: symbol.rawValue.replacingOccurrences(of: "USDT", with: ""),
                                isSelected: configuration.symbol == symbol
                            ) {
                                onSymbolChange(symbol)
                            }
                        }
                    }
                }

                SettingBlock(title: "시간봉") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 5)], spacing: 5) {
                        ForEach(CandleTimeframe.allCases) { timeframe in
                            SelectionButton(
                                title: timeframe.displayName,
                                isSelected: configuration.timeframe == timeframe
                            ) {
                                onTimeframeChange(timeframe)
                            }
                        }
                    }
                }

                SettingBlock(title: "전략") {
                    VStack(spacing: 4) {
                        ForEach(strategyDefinitions) { definition in
                            Button {
                                guard definition.id != configuration.strategyConfig.strategyID else { return }
                                onStrategyChange(definition.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(definition.name)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                        Spacer()
                                        if definition.id == configuration.strategyConfig.strategyID {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    Text(definition.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(definition.id == configuration.strategyConfig.strategyID ? Color.accentColor.opacity(0.14) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Stepper(
                    value: Binding(
                        get: { configuration.strategyConfig.leverage },
                        set: onLeverageChange
                    ),
                    in: leverageRange
                ) {
                    HStack {
                        RiskParameterLabel(text: "레버리지", info: .leverage)
                        Spacer()
                        Text("\(configuration.strategyConfig.leverage)x")
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                }

                Stepper(
                    value: Binding<Double>(
                        get: {
                            NSDecimalNumber(
                                decimal: configuration.strategyConfig.maximumRiskPerTradePercent
                            ).doubleValue
                        },
                        set: {
                            onMaximumRiskPerTradeChange(Decimal($0))
                        }
                    ),
                    in: 1...NSDecimalNumber(
                        decimal: StrategyRiskPolicy.maximumConfigurableRiskPerTradePercent
                    ).doubleValue,
                    step: 0.5
                ) {
                    HStack {
                        RiskParameterLabel(text: "1회 최대 손실", info: .maximumRiskPerTrade)
                        Spacer()
                        Text("\(configuration.strategyConfig.maximumRiskPerTradePercent.riskText)%")
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                }

                Stepper(
                    value: Binding<Double>(
                        get: {
                            NSDecimalNumber(
                                decimal: configuration.strategyConfig.maximumPositionMarginPercent
                            ).doubleValue
                        },
                        set: {
                            onMaximumPositionMarginChange(Decimal($0))
                        }
                    ),
                    in: NSDecimalNumber(
                        decimal: StrategyRiskPolicy.minimumConfigurablePositionMarginPercent
                    ).doubleValue...NSDecimalNumber(
                        decimal: StrategyRiskPolicy.maximumConfigurablePositionMarginPercent
                    ).doubleValue,
                    step: 5
                ) {
                    HStack {
                        RiskParameterLabel(text: "1회 최대 투입", info: .maximumPositionMargin)
                        Spacer()
                        Text("\(configuration.strategyConfig.maximumPositionMarginPercent.riskText)%")
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                }

                SettingBlock(title: "시작금액") {
                    HStack(spacing: 6) {
                        Text("$")
                            .foregroundStyle(.secondary)
                        TextField(
                            "100",
                            value: Binding<Double>(
                                get: {
                                    NSDecimalNumber(decimal: configuration.initialCapital).doubleValue
                                },
                                set: {
                                    onInitialCapitalChange(Decimal($0))
                                }
                            ),
                            format: .number.precision(.fractionLength(0...2))
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospacedDigit())
                    }
                }

                Toggle(
                    "보조지표 적용 비교",
                    isOn: Binding(
                        get: { configuration.comparesSignalConfirmation },
                        set: onCompareSignalConfirmationChange
                    )
                )
                .font(.callout)

                Button(action: onRun) {
                    HStack {
                        if status.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(status.isRunning ? "계산 중" : "백테스트 실행")
                            .font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(status.isRunning)

                BacktestResultSummary(status: status, result: result, comparison: comparison)
            }
        }
    }
}

private struct SettingBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct SelectionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 26)
                .padding(.horizontal, 8)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .textBackgroundColor))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct StatusBadge: View {
    let status: BacktestStatus

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var text: String {
        switch status {
        case .idle:
            return "대기"
        case .running:
            return "실행"
        case .complete:
            return "완료"
        case .failed:
            return "오류"
        }
    }

    private var color: Color {
        switch status {
        case .idle:
            return .secondary
        case .running:
            return .blue
        case .complete:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct BacktestResultSummary: View {
    let status: BacktestStatus
    let result: BacktestResult?
    let comparison: BacktestComparisonResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch (status, result) {
            case (.failed(let message), _):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            case (_, let result?):
                HStack {
                    Text(verdict(for: result))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(verdictColor(for: result))
                    Spacer()
                    Text(result.completedAt.dashboardDateTime)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 5) {
                    metric("시작금액", money(result.initialCapital))
                    metric("최종잔고", money(result.finalBalance))
                    metric("승률", "\(result.winRatePercent.riskText)%")
                    metric("거래 수", "\(result.totalTrades)")
                    metric("순손익", "\(result.netReturnPercent.percentText) / \(money(result.netProfitAmount))")
                    metric("평균 투입비율", "\(result.averagePositionMarginPercent.riskText)%")
                    metric("평균 계좌위험", "\(result.averageAccountRiskPercent.riskText)%")
                    metric("평균 손익비", "\(result.averageRewardRiskRatio.riskText):1")
                    metric("최대 낙폭", "-\(result.maxDrawdownPercent.riskText)%")
                    metric("차단 신호", "\(result.blockedSignals)")
                    if result.confirmationBlockedSignals > 0 || result.averageConfirmationScore > 0 {
                        metric("보조 차단", "\(result.confirmationBlockedSignals)")
                        metric("평균 보조점수", result.averageConfirmationScore.riskText)
                    }
                }
                .font(.caption)

                if let latestTrade = result.trades.last {
                    HStack {
                        Text(latestTrade.outcome == .win ? "최근 거래 승" : "최근 거래 패")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(latestTrade.outcome == .win ? .green : .red)
                        Spacer()
                        Text("\(latestTrade.leveragedReturnPercent.percentText) -> \(money(latestTrade.endingBalance))")
                            .font(.caption.monospacedDigit())
                    }
                }

                if !result.blockedSignalSummaries.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("차단 사유")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(result.blockedSignalSummaries.prefix(3)) { summary in
                            metric(summary.reason, "\(summary.count)")
                        }
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }

                if !result.confirmationBlockedSignalSummaries.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("보조 차단 사유")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(result.confirmationBlockedSignalSummaries.prefix(3)) { summary in
                            metric(summary.reason, "\(summary.count)")
                        }
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }

                if let comparison {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("보조지표 적용 비교")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        metric(
                            "적용 전",
                            "\(money(comparison.withoutSignalConfirmation.finalBalance)) / \(comparison.withoutSignalConfirmation.netReturnPercent.percentText)"
                        )
                        metric(
                            "적용 전 승률/거래",
                            "\(comparison.withoutSignalConfirmation.winRatePercent.riskText)% / \(comparison.withoutSignalConfirmation.totalTrades)"
                        )
                        metric(
                            "적용 후",
                            "\(money(comparison.withSignalConfirmation.finalBalance)) / \(comparison.withSignalConfirmation.netReturnPercent.percentText)"
                        )
                        metric(
                            "적용 후 승률/거래",
                            "\(comparison.withSignalConfirmation.winRatePercent.riskText)% / \(comparison.withSignalConfirmation.totalTrades)"
                        )
                        metric(
                            "최종잔고 차이",
                            signedMoney(comparison.finalBalanceDelta),
                            valueColor: signedValueColor(comparison.finalBalanceDelta)
                        )
                        metric(
                            "순손익률 차이",
                            comparison.netReturnDeltaPercent.percentText,
                            valueColor: signedValueColor(comparison.netReturnDeltaPercent)
                        )
                        metric(
                            "최대낙폭 차이",
                            comparison.maxDrawdownDeltaPercent.percentText,
                            valueColor: signedValueColor(comparison.maxDrawdownDeltaPercent)
                        )
                        metric("순 제외 거래", "\(comparison.netFilteredOutTradeCount)건")
                        metric(
                            "놓친 상승분 합산",
                            "\(percentagePoints(comparison.missedUpsidePercentPoints)) / \(comparison.missedUpsideTradeCount)건",
                            valueColor: signedValueColor(comparison.missedUpsidePercentPoints)
                        )
                        metric(
                            "방어 하락분 합산",
                            "\(percentagePoints(comparison.defendedDownsidePercentPoints)) / \(comparison.defendedDownsideTradeCount)건",
                            valueColor: signedValueColor(comparison.defendedDownsidePercentPoints)
                        )
                    }
                    .font(.caption)
                    .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("적용 기준")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        metric("내용", comparison.optimizationReport.reason)
                        if let candidate = comparison.optimizationReport.recommendedCandidate {
                            metric(
                                "후보 성과",
                                "\(candidate.netReturnPercent.percentText) / 차이 \(candidate.netReturnDeltaPercent.percentText) / 거래 \(candidate.totalTrades)"
                            )
                        }
                        if !comparison.optimizationReport.candidates.isEmpty {
                            ForEach(comparison.optimizationReport.candidates.prefix(3)) { candidate in
                                metric(
                                    "\(candidate.requiredScore.riskText)점 후보",
                                    "\(candidate.netReturnDeltaPercent.percentText) / 거래 \(candidate.totalTrades)"
                                )
                            }
                        }
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }

                if !result.confirmationScoreBuckets.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("점수 구간별 성과")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(result.confirmationScoreBuckets) { bucket in
                            metric(
                                bucket.bucket.label,
                                "\(bucket.netReturnPercent.percentText) / 승률 \(bucket.winRatePercent.riskText)% / 거래 \(bucket.tradeCount) / 신호 \(bucket.signalCount)"
                            )
                        }
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }

                Text("진입 시장가, 익절 예약 지정가, 손절 예약 시장가 수수료를 반영했습니다. 슬리피지는 미반영입니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case (.running, nil):
                Text("캔들 로드와 전략 계산을 백그라운드에서 처리 중입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                Text("결과 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private func metric(
        _ title: String,
        _ value: String,
        valueColor: Color = .primary
    ) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }

    private func money(_ value: Decimal) -> String {
        let sign = value < 0 ? "-" : ""
        let absolute = value < 0 ? -value : value
        return "\(sign)$\(absolute.dashboardText)"
    }

    private func signedMoney(_ value: Decimal) -> String {
        let sign = value > 0 ? "+" : value < 0 ? "-" : ""
        let absolute = value < 0 ? -value : value
        return "\(sign)$\(absolute.dashboardText)"
    }

    private func percentagePoints(_ value: Decimal) -> String {
        let sign = value > 0 ? "+" : value < 0 ? "-" : ""
        let absolute = value < 0 ? -value : value
        return "\(sign)\(absolute.riskText)%p"
    }

    private func signedValueColor(_ value: Decimal) -> Color {
        guard value != 0 else { return .primary }
        return value > 0 ? .green : .red
    }

    private func verdict(for result: BacktestResult) -> String {
        guard result.totalTrades > 0 else { return "거래 없음" }
        return result.winRatePercent >= 50 ? "50% 기준 통과" : "50% 미달"
    }

    private func verdictColor(for result: BacktestResult) -> Color {
        guard result.totalTrades > 0 else { return .secondary }
        return result.winRatePercent >= 50 ? .green : .orange
    }
}

private extension BacktestStatus {
    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}
