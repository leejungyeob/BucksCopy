import SwiftUI

struct CandleChartView: View {
    let candles: [Candle]
    let positions: [PositionSnapshot]
    let partialTakeProfitByPositionID: [String: Decimal]
    let onNeedsOlderCandles: () -> Void

    init(
        candles: [Candle],
        positions: [PositionSnapshot] = [],
        partialTakeProfitByPositionID: [String: Decimal] = [:],
        onNeedsOlderCandles: @escaping () -> Void = {}
    ) {
        self.candles = candles
        self.positions = positions
        self.partialTakeProfitByPositionID = partialTakeProfitByPositionID
        self.onNeedsOlderCandles = onNeedsOlderCandles
    }

    @State private var candleSpacing = 0.9
    @State private var rightEdgeIndex: Double?
    @State private var verticalOffsetRatio = 0.0
    @State private var priceRangeScale = 1.0
    @State private var activeDrag: ChartPointerDrag?
    @State private var indicatorVisibility = ChartIndicatorVisibility.all

    private let defaultCandleSpacing = 0.9
    private let minCandleSpacing = 0.42
    private let maxCandleSpacing = 34.0
    private let rightPaddingCandles = 2.0

    var body: some View {
        GeometryReader { proxy in
            let chartCandles = candles
            let chartRect = chartRect(for: proxy.size)
            let spacing = effectiveCandleSpacing
            let viewport = viewport(
                candleCount: chartCandles.count,
                chartRect: chartRect,
                spacing: spacing
            )

            Canvas(rendersAsynchronously: true) { context, size in
                draw(
                    context: context,
                    size: size,
                    candles: chartCandles,
                    positions: positions,
                    partialTakeProfitByPositionID: partialTakeProfitByPositionID,
                    viewport: viewport,
                    spacing: spacing
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .overlay {
                ChartInteractionOverlay(
                    onDragChanged: { drag in
                        activeDrag = drag
                    },
                    onDragEnded: { drag in
                        commitDrag(
                            drag,
                            candleCount: chartCandles.count,
                            chartRect: chartRect,
                            spacing: spacing
                        )
                        activeDrag = nil
                    },
                    onScroll: { event in
                        handleScroll(
                            event,
                            candleCount: chartCandles.count,
                            chartRect: chartRect,
                            spacing: spacing
                        )
                    },
                    onMagnify: { event in
                        handleMagnify(
                            event,
                            candleCount: chartCandles.count,
                            chartRect: chartRect
                        )
                    }
                )
            }
            .overlay(alignment: .topLeading) {
                chartControls(candleCount: chartCandles.count, chartRect: chartRect)
                    .padding(.top, 10)
                    .padding(.leading, 20)
            }
            .onChange(of: chartCandles.first?.openTime) { oldFirstOpenTime, newFirstOpenTime in
                preserveViewportAfterOlderCandlesLoaded(
                    oldFirstOpenTime: oldFirstOpenTime,
                    newFirstOpenTime: newFirstOpenTime,
                    candles: chartCandles
                )
            }
            .onChange(of: chartCandles.count) { _, newCount in
                clampViewport(candleCount: newCount, chartRect: chartRect)
            }
        }
        .frame(minHeight: 360)
    }

    private var effectiveCandleSpacing: Double {
        candleSpacing
    }

    private func chartControls(candleCount: Int, chartRect: CGRect) -> some View {
        HStack(spacing: 6) {
            Button {
                zoomHorizontally(
                    by: 1.22,
                    anchorX: chartRect.midX,
                    candleCount: candleCount,
                    chartRect: chartRect
                )
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")

            Button {
                zoomHorizontally(
                    by: 0.82,
                    anchorX: chartRect.midX,
                    candleCount: candleCount,
                    chartRect: chartRect
                )
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")

            Button {
                resetViewport()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help("Reset chart")

            Menu {
                Toggle("MA 25", isOn: $indicatorVisibility.movingAverage25)
                Toggle("MA 50", isOn: $indicatorVisibility.movingAverage50)
                Toggle("MA 100", isOn: $indicatorVisibility.movingAverage100)
                Toggle("MA 200", isOn: $indicatorVisibility.movingAverage200)
                Divider()
                Toggle("VWMA 100", isOn: $indicatorVisibility.volumeWeightedMovingAverage100)
            } label: {
                Image(systemName: "chart.line.uptrend.xyaxis")
            }
            .help("Indicators")

            indicatorLegend
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var indicatorLegend: some View {
        HStack(spacing: 5) {
            ForEach(activeIndicatorStyles) { style in
                HStack(spacing: 4) {
                    Circle()
                        .fill(style.color)
                        .frame(width: 6, height: 6)
                    Text(style.kind.label)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(style.color)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private func draw(
        context: GraphicsContext,
        size: CGSize,
        candles chartCandles: [Candle],
        positions: [PositionSnapshot],
        partialTakeProfitByPositionID: [String: Decimal],
        viewport: ChartViewport,
        spacing: Double
    ) {
        let chartRect = chartRect(for: size)
        drawBackground(context: context, chartRect: chartRect)

        guard !chartCandles.isEmpty else {
            drawEmptyState(context: context, chartRect: chartRect)
            return
        }

        let visibleCandles = chartCandles[viewport.startIndex..<viewport.endIndex]
        let indicatorSeries = visibleIndicatorSeries(candles: chartCandles, viewport: viewport)
        guard !visibleCandles.isEmpty,
              let priceRange = priceRange(
                for: visibleCandles,
                positions: positions,
                partialTakeProfitByPositionID: partialTakeProfitByPositionID,
                indicatorSeries: indicatorSeries,
                chartRect: chartRect
            ) else {
            return
        }

        drawCandles(
            context: context,
            chartRect: chartRect,
            candles: visibleCandles,
            rightEdgeIndex: viewport.rightEdgeIndex,
            priceRange: priceRange,
            spacing: spacing
        )
        drawIndicators(
            context: context,
            chartRect: chartRect,
            series: indicatorSeries,
            rightEdgeIndex: viewport.rightEdgeIndex,
            priceRange: priceRange,
            spacing: spacing
        )
        drawPositionLevels(
            context: context,
            chartRect: chartRect,
            positions: positions,
            partialTakeProfitByPositionID: partialTakeProfitByPositionID,
            allCandles: chartCandles,
            visibleCandles: visibleCandles,
            rightEdgeIndex: viewport.rightEdgeIndex,
            priceRange: priceRange,
            spacing: spacing
        )
        drawPriceAxis(
            context: context,
            chartRect: chartRect,
            priceRange: priceRange,
            lastPrice: visibleCandles.last?.close.chartDouble
        )
        drawTimeAxis(
            context: context,
            chartRect: chartRect,
            candles: visibleCandles,
            rightEdgeIndex: viewport.rightEdgeIndex,
            spacing: spacing
        )
    }

    private func drawCandles(
        context: GraphicsContext,
        chartRect: CGRect,
        candles visibleCandles: ArraySlice<Candle>,
        rightEdgeIndex: Double,
        priceRange: ClosedRange<Double>,
        spacing: Double
    ) {
        let bodyWidth = min(max(spacing * 0.72, 0.55), 18)
        let wickWidth = max(min(spacing * 0.12, 1.4), 0.45)
        var upWicks = Path()
        var downWicks = Path()
        var upBodies = Path()
        var downBodies = Path()

        func y(_ price: Double) -> Double {
            let ratio = (price - priceRange.lowerBound) / max(priceRange.upperBound - priceRange.lowerBound, 1)
            return chartRect.maxY - chartRect.height * ratio
        }

        for candleIndex in visibleCandles.indices {
            let candle = visibleCandles[candleIndex]
            let absoluteIndex = Double(candleIndex)
            let x = chartRect.maxX - (rightEdgeIndex - absoluteIndex) * spacing
            guard x >= chartRect.minX - spacing, x <= chartRect.maxX + spacing else {
                continue
            }

            let openY = y(candle.open.chartDouble)
            let closeY = y(candle.close.chartDouble)
            let highY = y(candle.high.chartDouble)
            let lowY = y(candle.low.chartDouble)
            let isUp = candle.close >= candle.open

            let bodyTop = min(openY, closeY)
            let bodyHeight = max(abs(openY - closeY), 1)
            let rect = CGRect(
                x: x - bodyWidth / 2,
                y: bodyTop,
                width: bodyWidth,
                height: bodyHeight
            )
            if isUp {
                upWicks.move(to: CGPoint(x: x, y: highY))
                upWicks.addLine(to: CGPoint(x: x, y: lowY))
                upBodies.addRect(rect)
            } else {
                downWicks.move(to: CGPoint(x: x, y: highY))
                downWicks.addLine(to: CGPoint(x: x, y: lowY))
                downBodies.addRect(rect)
            }
        }

        context.stroke(upWicks, with: .color(Color.green.opacity(0.82)), lineWidth: wickWidth)
        context.stroke(downWicks, with: .color(Color.red.opacity(0.82)), lineWidth: wickWidth)
        context.fill(upBodies, with: .color(Color.green.opacity(0.78)))
        context.fill(downBodies, with: .color(Color.red.opacity(0.9)))
    }

    private func drawIndicators(
        context: GraphicsContext,
        chartRect: CGRect,
        series: [ChartIndicatorSeries],
        rightEdgeIndex: Double,
        priceRange: ClosedRange<Double>,
        spacing: Double
    ) {
        guard !series.isEmpty else { return }

        func y(_ price: Double) -> Double {
            let ratio = (price - priceRange.lowerBound) / max(priceRange.upperBound - priceRange.lowerBound, 1)
            return chartRect.maxY - chartRect.height * ratio
        }

        for line in series {
            guard line.points.count >= 2,
                  let style = indicatorStyle(for: line.kind) else { continue }

            var path = Path()
            var hasStarted = false
            for point in line.points {
                let x = chartRect.maxX - (rightEdgeIndex - Double(point.candleIndex)) * spacing
                guard x >= chartRect.minX - spacing, x <= chartRect.maxX + spacing else {
                    continue
                }

                let position = CGPoint(x: x, y: y(point.value.chartDouble))
                if hasStarted {
                    path.addLine(to: position)
                } else {
                    path.move(to: position)
                    hasStarted = true
                }
            }

            guard hasStarted else { continue }
            context.stroke(
                path,
                with: .color(style.color.opacity(0.92)),
                style: StrokeStyle(lineWidth: style.lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func drawPositionLevels(
        context: GraphicsContext,
        chartRect: CGRect,
        positions: [PositionSnapshot],
        partialTakeProfitByPositionID: [String: Decimal],
        allCandles: [Candle],
        visibleCandles: ArraySlice<Candle>,
        rightEdgeIndex: Double,
        priceRange: ClosedRange<Double>,
        spacing: Double
    ) {
        guard !positions.isEmpty else { return }

        func y(_ price: Double) -> Double {
            let ratio = (price - priceRange.lowerBound) / max(priceRange.upperBound - priceRange.lowerBound, 1)
            return chartRect.maxY - chartRect.height * ratio
        }

        for position in positions {
            let partialTakeProfit = partialTakeProfitByPositionID[position.id]
            for level in PositionChartLevel.levels(for: position, partialTakeProfit: partialTakeProfit) {
                let levelY = y(level.price)
                guard levelY >= chartRect.minY - 12, levelY <= chartRect.maxY + 12 else {
                    continue
                }

                var path = Path()
                path.move(to: CGPoint(x: chartRect.minX, y: levelY))
                path.addLine(to: CGPoint(x: chartRect.maxX, y: levelY))
                context.stroke(
                    path,
                    with: .color(level.color.opacity(0.82)),
                    style: StrokeStyle(lineWidth: 1.1, dash: level.dash)
                )

                let labelRect = CGRect(x: chartRect.maxX + 8, y: levelY - 10, width: 82, height: 20)
                context.fill(
                    Path(roundedRect: labelRect, cornerRadius: 5),
                    with: .color(level.color.opacity(0.15))
                )
                context.draw(
                    Text(level.label)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(level.color),
                    at: CGPoint(x: labelRect.midX, y: labelRect.midY)
                )
            }

            drawEntryMarker(
                context: context,
                chartRect: chartRect,
                position: position,
                allCandles: allCandles,
                visibleCandles: visibleCandles,
                rightEdgeIndex: rightEdgeIndex,
                priceRange: priceRange,
                spacing: spacing
            )
        }
    }

    private func drawEntryMarker(
        context: GraphicsContext,
        chartRect: CGRect,
        position: PositionSnapshot,
        allCandles: [Candle],
        visibleCandles: ArraySlice<Candle>,
        rightEdgeIndex: Double,
        priceRange: ClosedRange<Double>,
        spacing: Double
    ) {
        guard let createdAt = position.createdAt else { return }
        guard let candleIndex = allCandles.firstIndex(where: { $0.openTime >= createdAt }) else {
            return
        }
        guard candleIndex >= visibleCandles.startIndex, candleIndex < visibleCandles.endIndex else {
            return
        }

        let entryPrice = position.openPriceAverage.chartDouble
        let ratio = (entryPrice - priceRange.lowerBound) / max(priceRange.upperBound - priceRange.lowerBound, 1)
        let markerY = chartRect.maxY - chartRect.height * ratio
        let markerX = chartRect.maxX - (rightEdgeIndex - Double(candleIndex)) * spacing
        guard markerX >= chartRect.minX - 10,
              markerX <= chartRect.maxX + 10,
              markerY >= chartRect.minY - 10,
              markerY <= chartRect.maxY + 10 else {
            return
        }

        let color = position.side == .short ? Color.red : Color.green
        let markerRect = CGRect(x: markerX - 5, y: markerY - 5, width: 10, height: 10)
        var marker = Path()
        marker.move(to: CGPoint(x: markerRect.midX, y: markerRect.minY))
        marker.addLine(to: CGPoint(x: markerRect.maxX, y: markerRect.midY))
        marker.addLine(to: CGPoint(x: markerRect.midX, y: markerRect.maxY))
        marker.addLine(to: CGPoint(x: markerRect.minX, y: markerRect.midY))
        marker.closeSubpath()
        context.fill(marker, with: .color(color.opacity(0.9)))
    }

    private func drawBackground(context: GraphicsContext, chartRect: CGRect) {
        let gridColor = Color(nsColor: .separatorColor).opacity(0.26)

        for row in 0...4 {
            let y = chartRect.minY + chartRect.height * Double(row) / 4
            var path = Path()
            path.move(to: CGPoint(x: chartRect.minX, y: y))
            path.addLine(to: CGPoint(x: chartRect.maxX, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }

        var axis = Path()
        axis.move(to: CGPoint(x: chartRect.maxX, y: chartRect.minY))
        axis.addLine(to: CGPoint(x: chartRect.maxX, y: chartRect.maxY))
        context.stroke(axis, with: .color(Color(nsColor: .separatorColor).opacity(0.55)), lineWidth: 0.7)
    }

    private func drawPriceAxis(
        context: GraphicsContext,
        chartRect: CGRect,
        priceRange: ClosedRange<Double>,
        lastPrice: Double?
    ) {
        let formatter = Self.priceFormatter

        for tick in 0...4 {
            let ratio = Double(tick) / 4
            let price = priceRange.upperBound - (priceRange.upperBound - priceRange.lowerBound) * ratio
            let y = chartRect.minY + chartRect.height * ratio
            let text = formatter.string(from: NSNumber(value: price)) ?? "\(price)"
            context.draw(
                Text(text)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary),
                at: CGPoint(x: chartRect.maxX + 44, y: y)
            )
        }

        guard let lastPrice else { return }
        let lastY = chartRect.maxY - chartRect.height *
            ((lastPrice - priceRange.lowerBound) / max(priceRange.upperBound - priceRange.lowerBound, 1))

        var line = Path()
        line.move(to: CGPoint(x: chartRect.minX, y: lastY))
        line.addLine(to: CGPoint(x: chartRect.maxX, y: lastY))
        context.stroke(
            line,
            with: .color(Color.accentColor.opacity(0.62)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
        )

        let lastText = formatter.string(from: NSNumber(value: lastPrice)) ?? "\(lastPrice)"
        let labelRect = CGRect(x: chartRect.maxX + 8, y: lastY - 11, width: 78, height: 22)
        context.fill(
            Path(roundedRect: labelRect, cornerRadius: 5),
            with: .color(Color.accentColor.opacity(0.18))
        )
        context.draw(
            Text(lastText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.accentColor),
            at: CGPoint(x: labelRect.midX, y: labelRect.midY)
        )
    }

    private func drawTimeAxis(
        context: GraphicsContext,
        chartRect: CGRect,
        candles visibleCandles: ArraySlice<Candle>,
        rightEdgeIndex: Double,
        spacing: Double
    ) {
        guard visibleCandles.count >= 2 else { return }

        let gridColor = Color(nsColor: .separatorColor).opacity(0.24)
        let axisColor = Color(nsColor: .separatorColor).opacity(0.55)
        let labelY = chartRect.maxY + 22

        var baseline = Path()
        baseline.move(to: CGPoint(x: chartRect.minX, y: chartRect.maxY))
        baseline.addLine(to: CGPoint(x: chartRect.maxX, y: chartRect.maxY))
        context.stroke(baseline, with: .color(axisColor), lineWidth: 0.7)

        let targetTickCount = max(Int(chartRect.width / 84), 6)
        let onscreenCapacity = chartRect.width / safeCandleSpacing(spacing)
        let step = max(Int(ceil(onscreenCapacity / Double(targetTickCount))), 1)
        var drawnLabels = Set<String>()

        for candleIndex in stride(from: visibleCandles.startIndex, to: visibleCandles.endIndex, by: step) {
            let candle = visibleCandles[candleIndex]
            let absoluteIndex = Double(candleIndex)
            let x = chartRect.maxX - (rightEdgeIndex - absoluteIndex) * spacing
            guard x >= chartRect.minX + 18, x <= chartRect.maxX - 18 else {
                continue
            }

            let label = timeAxisLabel(for: candle.openTime, visibleCandles: visibleCandles)
            guard !drawnLabels.contains(label) else { continue }
            drawnLabels.insert(label)

            var gridLine = Path()
            gridLine.move(to: CGPoint(x: x, y: chartRect.minY))
            gridLine.addLine(to: CGPoint(x: x, y: chartRect.maxY))
            context.stroke(gridLine, with: .color(gridColor), lineWidth: 0.5)

            var tick = Path()
            tick.move(to: CGPoint(x: x, y: chartRect.maxY))
            tick.addLine(to: CGPoint(x: x, y: chartRect.maxY + 4))
            context.stroke(tick, with: .color(axisColor), lineWidth: 0.7)

            context.draw(
                Text(label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary),
                at: CGPoint(x: x, y: labelY)
            )
        }
    }

    private func timeAxisLabel(for date: Date, visibleCandles: ArraySlice<Candle>) -> String {
        guard let first = visibleCandles.first?.openTime,
              let last = visibleCandles.last?.openTime else {
            return Self.shortTimeFormatter.string(from: date)
        }

        let span = max(last.timeIntervalSince(first), 0)
        let formatter: DateFormatter
        switch span {
        case (365 * 24 * 60 * 60)...:
            formatter = Self.yearMonthFormatter
        case (90 * 24 * 60 * 60)..<365 * 24 * 60 * 60:
            formatter = Self.yearMonthFormatter
        case (14 * 24 * 60 * 60)..<90 * 24 * 60 * 60:
            formatter = Self.monthDayFormatter
        case (2 * 24 * 60 * 60)..<14 * 24 * 60 * 60:
            formatter = Self.monthDayHourFormatter
        default:
            formatter = Self.shortTimeFormatter
        }
        return formatter.string(from: date)
    }

    private func drawEmptyState(context: GraphicsContext, chartRect: CGRect) {
        context.draw(
            Text("No candle data")
                .font(.headline)
                .foregroundStyle(.secondary),
            at: CGPoint(x: chartRect.midX, y: chartRect.midY)
        )
    }

    private func priceRange(
        for candles: ArraySlice<Candle>,
        positions: [PositionSnapshot],
        partialTakeProfitByPositionID: [String: Decimal],
        indicatorSeries: [ChartIndicatorSeries],
        chartRect: CGRect
    ) -> ClosedRange<Double>? {
        var minPrice = Double.greatestFiniteMagnitude
        var maxPrice = -Double.greatestFiniteMagnitude

        for candle in candles {
            minPrice = min(minPrice, candle.low.chartDouble)
            maxPrice = max(maxPrice, candle.high.chartDouble)
        }

        for position in positions {
            let partialTakeProfit = partialTakeProfitByPositionID[position.id]
            for level in PositionChartLevel.levels(for: position, partialTakeProfit: partialTakeProfit) {
                minPrice = min(minPrice, level.price)
                maxPrice = max(maxPrice, level.price)
            }
        }

        for series in indicatorSeries {
            for point in series.points {
                minPrice = min(minPrice, point.value.chartDouble)
                maxPrice = max(maxPrice, point.value.chartDouble)
            }
        }

        guard minPrice.isFinite, maxPrice.isFinite, maxPrice > minPrice else {
            return nil
        }

        let rawRange = maxPrice - minPrice
        let livePriceScale = priceRangeScale * livePriceRangeScale(chartRect: chartRect)
        let paddedRange = max(rawRange * 1.18 * livePriceScale, maxPrice * 0.001)
        let liveOffset = chartDragTranslation(chartRect: chartRect).height / max(chartRect.height, 1) * paddedRange
        let center = (minPrice + maxPrice) / 2 + verticalOffsetRatio * paddedRange + liveOffset
        return (center - paddedRange / 2)...(center + paddedRange / 2)
    }

    private func viewport(candleCount: Int, chartRect: CGRect, spacing: Double) -> ChartViewport {
        guard candleCount > 0 else {
            return ChartViewport(startIndex: 0, endIndex: 0, rightEdgeIndex: 0)
        }

        let liveRightEdge = resolvedRightEdgeIndex(candleCount: candleCount)
            - chartDragTranslation(chartRect: chartRect).width / safeCandleSpacing(spacing)
        let visibleCapacity = chartRect.width / safeCandleSpacing(spacing)
        let edgeBuffer = viewportEdgeBuffer(visibleCapacity: visibleCapacity)
        let startIndex = min(max(Int(floor(liveRightEdge - visibleCapacity - edgeBuffer)), 0), candleCount)
        let endIndex = min(max(Int(ceil(liveRightEdge + edgeBuffer)), 0), candleCount)
        return ChartViewport(
            startIndex: min(startIndex, endIndex),
            endIndex: max(startIndex, endIndex),
            rightEdgeIndex: liveRightEdge
        )
    }

    private func commitDrag(
        _ drag: ChartPointerDrag,
        candleCount: Int,
        chartRect: CGRect,
        spacing: Double
    ) {
        guard candleCount > 0 else { return }

        if dragMode(for: drag.startLocation, chartRect: chartRect) == .priceAxis {
            priceRangeScale = clamp(
                priceRangeScale * priceRangeScaleMultiplier(for: drag.translation.height),
                0.22,
                5
            )
            return
        }

        let nextRightEdge = resolvedRightEdgeIndex(candleCount: candleCount)
            - Double(drag.translation.width) / safeCandleSpacing(spacing)
        rightEdgeIndex = nextRightEdge
        requestOlderCandlesIfNeeded(
            rightEdgeIndex: nextRightEdge,
            candleCount: candleCount,
            chartRect: chartRect,
            spacing: spacing
        )

        let chartHeight = max(chartRect.height, 1)
        verticalOffsetRatio = clamp(
            verticalOffsetRatio + Double(drag.translation.height) / chartHeight,
            -4,
            4
        )
    }

    private func resetViewport() {
        candleSpacing = defaultCandleSpacing
        rightEdgeIndex = nil
        verticalOffsetRatio = 0
        priceRangeScale = 1
    }

    private func clampViewport(candleCount: Int, chartRect: CGRect) {
        guard rightEdgeIndex != nil, candleCount == 0 else { return }
        rightEdgeIndex = nil
    }

    private func resolvedRightEdgeIndex(candleCount: Int) -> Double {
        rightEdgeIndex ?? Double(max(candleCount - 1, 0)) + rightPaddingCandles
    }

    private func handleScroll(
        _ event: ChartScrollEvent,
        candleCount: Int,
        chartRect: CGRect,
        spacing: Double
    ) {
        guard candleCount > 0 else { return }

        if abs(event.deltaX) > 0.1 {
            let nextRightEdge = resolvedRightEdgeIndex(candleCount: candleCount)
                - Double(event.deltaX) / safeCandleSpacing(spacing)
            rightEdgeIndex = nextRightEdge
            requestOlderCandlesIfNeeded(
                rightEdgeIndex: nextRightEdge,
                candleCount: candleCount,
                chartRect: chartRect,
                spacing: spacing
            )
        }

        guard abs(event.deltaY) > 0.1 else { return }
        let sensitivity = event.hasPreciseDeltas ? 0.012 : 0.08
        let scale = clamp(exp(Double(event.deltaY) * sensitivity), 0.78, 1.28)

        if event.location.x >= chartRect.maxX {
            priceRangeScale = clamp(priceRangeScale / scale, 0.22, 5)
        } else {
            zoomHorizontally(
                by: scale,
                anchorX: clamp(Double(event.location.x), chartRect.minX, chartRect.maxX),
                candleCount: candleCount,
                chartRect: chartRect
            )
        }
    }

    private func preserveViewportAfterOlderCandlesLoaded(
        oldFirstOpenTime: Date?,
        newFirstOpenTime: Date?,
        candles chartCandles: [Candle]
    ) {
        guard let oldFirstOpenTime,
              let newFirstOpenTime,
              newFirstOpenTime < oldFirstOpenTime,
              let rightEdgeIndex,
              let insertedCount = chartCandles.firstIndex(where: { $0.openTime >= oldFirstOpenTime }) else {
            return
        }
        self.rightEdgeIndex = rightEdgeIndex + Double(insertedCount)
    }

    private func requestOlderCandlesIfNeeded(
        rightEdgeIndex: Double,
        candleCount: Int,
        chartRect: CGRect,
        spacing: Double
    ) {
        let visibleCapacity = chartRect.width / safeCandleSpacing(spacing)
        let startIndex = Int(floor(rightEdgeIndex - visibleCapacity))
        guard startIndex <= Int(viewportEdgeBuffer(visibleCapacity: visibleCapacity)), candleCount > 0 else { return }
        onNeedsOlderCandles()
    }

    private func handleMagnify(
        _ event: ChartMagnifyEvent,
        candleCount: Int,
        chartRect: CGRect
    ) {
        let scale = clamp(1 + Double(event.magnification), 0.82, 1.24)
        zoomHorizontally(
            by: scale,
            anchorX: clamp(Double(event.location.x), chartRect.minX, chartRect.maxX),
            candleCount: candleCount,
            chartRect: chartRect
        )
    }

    private func zoomHorizontally(
        by scale: Double,
        anchorX: Double,
        candleCount: Int,
        chartRect: CGRect
    ) {
        guard candleCount > 0, scale > 0 else { return }

        let oldSpacing = candleSpacing
        let nextSpacing = clamp(oldSpacing * scale, minCandleSpacing, maxCandleSpacing)
        guard abs(nextSpacing - oldSpacing) > 0.001 else { return }

        let currentRightEdge = resolvedRightEdgeIndex(candleCount: candleCount)
        let anchorIndex = currentRightEdge - (chartRect.maxX - anchorX) / safeCandleSpacing(oldSpacing)
        let nextRightEdge = anchorIndex + (chartRect.maxX - anchorX) / safeCandleSpacing(nextSpacing)
        rightEdgeIndex = nextRightEdge
        candleSpacing = nextSpacing
        requestOlderCandlesIfNeeded(
            rightEdgeIndex: nextRightEdge,
            candleCount: candleCount,
            chartRect: chartRect,
            spacing: nextSpacing
        )
    }

    private func chartDragTranslation(chartRect: CGRect) -> CGSize {
        guard let activeDrag,
              dragMode(for: activeDrag.startLocation, chartRect: chartRect) == .chart else {
            return .zero
        }
        return activeDrag.translation
    }

    private func viewportEdgeBuffer(visibleCapacity: Double) -> Double {
        clamp(visibleCapacity * 0.14, 12, 320)
    }

    private func visibleIndicatorSeries(candles chartCandles: [Candle], viewport: ChartViewport) -> [ChartIndicatorSeries] {
        let range = viewport.startIndex..<viewport.endIndex
        return activeIndicatorStyles.compactMap { style in
            switch style.kind {
            case .simpleMovingAverage(let period):
                return ChartIndicatorCalculator.simpleMovingAverage(
                    period: period,
                    candles: chartCandles,
                    visibleRange: range
                )
            case .volumeWeightedMovingAverage(let period):
                return ChartIndicatorCalculator.volumeWeightedMovingAverage(
                    period: period,
                    candles: chartCandles,
                    visibleRange: range
                )
            }
        }
    }

    private var activeIndicatorStyles: [ChartIndicatorStyle] {
        ChartIndicatorStyle.all.filter { indicatorVisibility.isVisible($0.kind) }
    }

    private func indicatorStyle(for kind: ChartIndicatorKind) -> ChartIndicatorStyle? {
        ChartIndicatorStyle.all.first { $0.kind == kind }
    }

    private func safeCandleSpacing(_ spacing: Double) -> Double {
        max(spacing, 0.01)
    }

    private func livePriceRangeScale(chartRect: CGRect) -> Double {
        guard let activeDrag,
              dragMode(for: activeDrag.startLocation, chartRect: chartRect) == .priceAxis else {
            return 1
        }
        return priceRangeScaleMultiplier(for: activeDrag.translation.height)
    }

    private func priceRangeScaleMultiplier(for verticalTranslation: CGFloat) -> Double {
        clamp(exp(Double(verticalTranslation) * 0.006), 0.22, 5)
    }

    private func dragMode(for location: CGPoint, chartRect: CGRect) -> ChartDragMode {
        location.x >= chartRect.maxX ? .priceAxis : .chart
    }

    private func chartRect(for size: CGSize) -> CGRect {
        CGRect(
            x: 16,
            y: 20,
            width: max(size.width - 108, 1),
            height: max(size.height - 66, 1)
        )
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private static let yearMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yy.MM"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let monthDayHourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d HH"
        return formatter
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let priceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 4
        formatter.minimumFractionDigits = 0
        formatter.numberStyle = .decimal
        return formatter
    }()
}

private struct ChartViewport {
    let startIndex: Int
    let endIndex: Int
    let rightEdgeIndex: Double
}

private enum ChartDragMode {
    case chart
    case priceAxis
}

private struct ChartIndicatorVisibility: Equatable {
    var movingAverage25: Bool
    var movingAverage50: Bool
    var movingAverage100: Bool
    var movingAverage200: Bool
    var volumeWeightedMovingAverage100: Bool

    static let all = ChartIndicatorVisibility(
        movingAverage25: true,
        movingAverage50: true,
        movingAverage100: true,
        movingAverage200: true,
        volumeWeightedMovingAverage100: true
    )

    func isVisible(_ kind: ChartIndicatorKind) -> Bool {
        switch kind {
        case .simpleMovingAverage(25):
            return movingAverage25
        case .simpleMovingAverage(50):
            return movingAverage50
        case .simpleMovingAverage(100):
            return movingAverage100
        case .simpleMovingAverage(200):
            return movingAverage200
        case .volumeWeightedMovingAverage(100):
            return volumeWeightedMovingAverage100
        default:
            return false
        }
    }
}

private struct ChartIndicatorStyle: Identifiable {
    let kind: ChartIndicatorKind
    let color: Color
    let lineWidth: CGFloat

    var id: String { kind.label }

    static let all: [ChartIndicatorStyle] = [
        ChartIndicatorStyle(kind: .simpleMovingAverage(period: 25), color: .orange, lineWidth: 1.1),
        ChartIndicatorStyle(kind: .simpleMovingAverage(period: 50), color: .green, lineWidth: 1.1),
        ChartIndicatorStyle(kind: .simpleMovingAverage(period: 100), color: Color(red: 0.35, green: 0.78, blue: 1), lineWidth: 1.2),
        ChartIndicatorStyle(kind: .simpleMovingAverage(period: 200), color: .red, lineWidth: 1.25),
        ChartIndicatorStyle(kind: .volumeWeightedMovingAverage(period: 100), color: .white, lineWidth: 1.45)
    ]
}

private struct PositionChartLevel {
    let price: Double
    let label: String
    let color: Color
    let dash: [CGFloat]

    static func levels(for position: PositionSnapshot, partialTakeProfit: Decimal? = nil) -> [PositionChartLevel] {
        var levels = [
            PositionChartLevel(
                price: position.openPriceAverage.chartDouble,
                label: "ENTRY",
                color: position.side == .short ? .red : .green,
                dash: [6, 4]
            )
        ]

        if let partialTakeProfit = partialTakeProfit ?? position.partialTakeProfit {
            levels.append(PositionChartLevel(
                price: partialTakeProfit.chartDouble,
                label: "TP1",
                color: .green,
                dash: [2, 4]
            ))
        }

        if let takeProfit = position.takeProfit {
            levels.append(PositionChartLevel(
                price: takeProfit.chartDouble,
                label: "TP2",
                color: .green,
                dash: [3, 3]
            ))
        }

        if let stopLoss = position.stopLoss {
            levels.append(PositionChartLevel(
                price: stopLoss.chartDouble,
                label: "SL",
                color: .red,
                dash: [3, 3]
            ))
        }

        return levels
    }
}
