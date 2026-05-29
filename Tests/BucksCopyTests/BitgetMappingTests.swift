import XCTest
@testable import BucksCopy

final class BitgetMappingTests: XCTestCase {
    func testWebSocketCandlePayloadMapsToInProgressCandle() throws {
        let json = """
        {
          "action": "snapshot",
          "arg": {
            "instType": "USDT-FUTURES",
            "channel": "candle15m",
            "instId": "BTCUSDT"
          },
          "data": [
            [
              "1695685500000",
              "27000",
              "27000.5",
              "26990",
              "27000.25",
              "0.057",
              "1539.0155",
              "1539.0155"
            ]
          ],
          "ts": 1695715462250
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(BitgetWebSocketCandlePayload.self, from: json)
        let row = try XCTUnwrap(payload.data?.first)
        let candle = try XCTUnwrap(BitgetCandleRow(values: row).domain(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            isClosed: false
        ))

        XCTAssertEqual(payload.arg?.channel, "candle15m")
        XCTAssertEqual(candle.close, Decimal(string: "27000.25"))
        XCTAssertFalse(candle.isClosed)
    }

    func testRESTCandlePayloadKeepsCurrentCandleOpenUntilTimeframeCompletes() throws {
        let openTime = Date(timeIntervalSince1970: 1_695_685_500)
        let row = BitgetCandleRow(values: [
            String(Int(openTime.timeIntervalSince1970 * 1000)),
            "27000",
            "27000.5",
            "26990",
            "27000.25",
            "0.057"
        ])

        let inProgress = try XCTUnwrap(row.domain(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            receivedAt: openTime.addingTimeInterval(899)
        ))
        let closed = try XCTUnwrap(row.domain(
            symbol: FuturesSymbol("BTCUSDT"),
            timeframe: .fifteenMinutes,
            receivedAt: openTime.addingTimeInterval(900)
        ))

        XCTAssertFalse(inProgress.isClosed)
        XCTAssertTrue(closed.isClosed)
    }

    func testAccountDTOMappingKeepsBalanceFields() throws {
        let json = """
        {
          "marginCoin": "USDT",
          "available": "100.25",
          "accountEquity": "125.50",
          "unrealizedPL": "-2.75"
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(BitgetAccountDTO.self, from: json)
        let account = dto.domain

        XCTAssertEqual(account.marginCoin, "USDT")
        XCTAssertEqual(account.available, Decimal(string: "100.25"))
        XCTAssertEqual(account.accountEquity, Decimal(string: "125.50"))
        XCTAssertEqual(account.unrealizedProfitLoss, Decimal(string: "-2.75"))
    }

    func testPositionDTOMappingKeepsPositionReadOnlyFields() throws {
        let json = """
        {
          "symbol": "BTCUSDT",
          "marginCoin": "USDT",
          "holdSide": "short",
          "available": "0.0155",
          "total": "0.0155",
          "leverage": "14",
          "openPriceAvg": "88505.233333333333",
          "marginMode": "crossed",
          "unrealizedPL": "-72.8215833333333385",
          "liquidationPrice": "5737867.8639926850760812",
          "markPrice": "93203.4",
          "takeProfit": "",
          "stopLoss": "",
          "cTime": "1766103799183",
          "uTime": "1767682800537"
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(BitgetPositionDTO.self, from: json)
        let position = dto.domain

        XCTAssertEqual(position.symbol, FuturesSymbol("BTCUSDT"))
        XCTAssertEqual(position.side, .short)
        XCTAssertEqual(position.leverage, 14)
        XCTAssertEqual(position.marginMode, "crossed")
        XCTAssertNil(position.takeProfit)
        XCTAssertNil(position.stopLoss)
        XCTAssertEqual(position.createdAt?.timeIntervalSince1970 ?? 0, 1_766_103_799.183, accuracy: 0.001)
    }

    func testPositionWebSocketPayloadMapsInstIdAndNumericLeverage() throws {
        let json = """
        {
          "action": "snapshot",
          "arg": {
            "instType": "USDT-FUTURES",
            "channel": "positions",
            "instId": "default"
          },
          "data": [
            {
              "instId": "ETHUSDT",
              "marginCoin": "USDT",
              "holdSide": "long",
              "available": "0.2",
              "total": "0.2",
              "leverage": 20,
              "openPriceAvg": "2500",
              "marginMode": "crossed",
              "unrealizedPL": "12.5",
              "liquidationPrice": "1200",
              "markPrice": "2562.5",
              "cTime": "1695649246169",
              "uTime": "1695711602568"
            }
          ],
          "ts": 1695717430441
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(BitgetPositionWebSocketPayload.self, from: json)
        let position = try XCTUnwrap(payload.data?.first?.domain)

        XCTAssertEqual(payload.arg?.channel, "positions")
        XCTAssertEqual(position.symbol, FuturesSymbol("ETHUSDT"))
        XCTAssertEqual(position.side, .long)
        XCTAssertEqual(position.leverage, 20)
        XCTAssertEqual(position.unrealizedProfitLoss, Decimal(string: "12.5"))
        XCTAssertEqual(position.markPrice, Decimal(string: "2562.5"))
        XCTAssertEqual(position.createdAt?.timeIntervalSince1970 ?? 0, 1_695_649_246.169, accuracy: 0.001)
    }

    func testTPSLRequestMapsTakeProfitToLimitAndStopLossToMarket() throws {
        let signal = StrategySignal(
            id: UUID(),
            strategyID: "fixture",
            symbol: FuturesSymbol("BTCUSDT"),
            side: .sell,
            entryPrice: 100,
            stopLoss: 110,
            takeProfit: 80,
            reason: "fixture",
            generatedAt: Date()
        )
        let plan = ExchangeProtectionPlan(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000321")!,
            signal: signal,
            size: Decimal(string: "0.25")!,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(plan.orders.count, 3)

        let firstTakeProfitDTO = BitgetTPSLOrderRequestDTO(order: plan.orders[0])
        let finalTakeProfitDTO = BitgetTPSLOrderRequestDTO(order: plan.orders[1])
        let stopLossDTO = BitgetTPSLOrderRequestDTO(order: plan.orders[2])

        XCTAssertEqual(firstTakeProfitDTO.planType, "profit_plan")
        XCTAssertEqual(firstTakeProfitDTO.holdSide, "short")
        XCTAssertEqual(firstTakeProfitDTO.triggerPrice, "90")
        XCTAssertEqual(firstTakeProfitDTO.executePrice, "90")
        XCTAssertEqual(firstTakeProfitDTO.size, "0.125")
        XCTAssertEqual(finalTakeProfitDTO.planType, "profit_plan")
        XCTAssertEqual(finalTakeProfitDTO.triggerPrice, "80")
        XCTAssertEqual(finalTakeProfitDTO.executePrice, "80")
        XCTAssertEqual(finalTakeProfitDTO.size, "0.125")
        XCTAssertEqual(stopLossDTO.planType, "loss_plan")
        XCTAssertEqual(stopLossDTO.holdSide, "short")
        XCTAssertEqual(stopLossDTO.triggerPrice, "110")
        XCTAssertEqual(stopLossDTO.executePrice, "0")
        XCTAssertEqual(stopLossDTO.productType, ProductType.usdtFutures.rawValue)
    }

    func testTPSLRequestUsesOneWayHoldSideAndContractPrecision() throws {
        let signal = StrategySignal(
            id: UUID(),
            strategyID: "fixture",
            symbol: FuturesSymbol("ETHUSDT"),
            side: .buy,
            entryPrice: Decimal(string: "100.123")!,
            stopLoss: Decimal(string: "90.126")!,
            takeProfit: Decimal(string: "120.128")!,
            reason: "fixture",
            generatedAt: Date()
        )
        let plan = ExchangeProtectionPlan(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000654")!,
            signal: signal,
            size: Decimal(string: "0.1234")!,
            positionMode: .oneWay,
            contractSpec: ContractSpec(
                symbol: FuturesSymbol("ETHUSDT"),
                baseCoin: "ETH",
                quoteCoin: "USDT",
                symbolStatus: "normal",
                supportMarginCoins: ["USDT"],
                minTradeNum: Decimal(string: "0.0001")!,
                minTradeUSDT: 5,
                sizeMultiplier: Decimal(string: "0.01")!,
                pricePlace: 2,
                volumePlace: 2,
                minLeverage: 1,
                maxLeverage: 10
            ),
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let firstTakeProfitDTO = BitgetTPSLOrderRequestDTO(order: plan.orders[0])
        let stopLossDTO = BitgetTPSLOrderRequestDTO(order: plan.orders[2])

        XCTAssertEqual(firstTakeProfitDTO.holdSide, "buy")
        XCTAssertEqual(firstTakeProfitDTO.triggerPrice, "110.13")
        XCTAssertEqual(firstTakeProfitDTO.executePrice, "110.13")
        XCTAssertEqual(firstTakeProfitDTO.size, "0.06")
        XCTAssertEqual(stopLossDTO.holdSide, "buy")
        XCTAssertEqual(stopLossDTO.triggerPrice, "90.13")
        XCTAssertEqual(stopLossDTO.executePrice, "0")
        XCTAssertEqual(stopLossDTO.size, "0.12")
    }

    func testLiveMarketOrderRequestMapsToBitgetOpenOrderPayload() {
        let request = LiveOrderRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            symbol: FuturesSymbol("BTCUSDT"),
            side: .buy,
            purpose: .open,
            size: Decimal(string: "0.25")!,
            leverage: 10,
            marginMode: "isolated",
            clientOid: "client-1"
        )

        let dto = BitgetPlaceOrderRequestDTO(request: request)

        XCTAssertEqual(dto.symbol, "BTCUSDT")
        XCTAssertEqual(dto.productType, ProductType.usdtFutures.rawValue)
        XCTAssertEqual(dto.marginMode, "isolated")
        XCTAssertEqual(dto.marginCoin, "USDT")
        XCTAssertEqual(dto.size, "0.25")
        XCTAssertEqual(dto.side, "buy")
        XCTAssertEqual(dto.tradeSide, "open")
        XCTAssertEqual(dto.orderType, "market")
        XCTAssertEqual(dto.clientOid, "client-1")
        XCTAssertEqual(dto.reduceOnly, "NO")
    }

    func testLiveOrderDetailMapsBitgetFillAliasesToFilledReceipt() throws {
        let json = """
        {
          "orderId": "order-1",
          "clientOid": "client-1",
          "state": "full-fill",
          "baseVolume": "0.25",
          "priceAvg": "100.5"
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(BitgetOrderDetailDTO.self, from: json)
        let receipt = dto.receipt(
            symbol: FuturesSymbol("BTCUSDT"),
            fallbackClientOid: "fallback-client"
        )

        XCTAssertEqual(receipt.orderID, "order-1")
        XCTAssertEqual(receipt.clientOid, "client-1")
        XCTAssertEqual(receipt.status, .filled)
        XCTAssertEqual(receipt.filledSize, Decimal(string: "0.25"))
        XCTAssertEqual(receipt.averagePrice, Decimal(string: "100.5"))
    }

    func testClosePositionRequestKeepsHedgeHoldSide() {
        let dto = BitgetClosePositionRequestDTO(
            symbol: "BTCUSDT",
            productType: ProductType.usdtFutures.rawValue,
            holdSide: "long"
        )

        XCTAssertEqual(dto.symbol, "BTCUSDT")
        XCTAssertEqual(dto.productType, ProductType.usdtFutures.rawValue)
        XCTAssertEqual(dto.holdSide, "long")
    }

    func testSetLeverageRequestUsesUSDTFuturesScope() {
        let dto = BitgetSetLeverageRequestDTO(
            symbol: "BTCUSDT",
            productType: ProductType.usdtFutures.rawValue,
            marginCoin: "USDT",
            leverage: "10"
        )

        XCTAssertEqual(dto.symbol, "BTCUSDT")
        XCTAssertEqual(dto.productType, ProductType.usdtFutures.rawValue)
        XCTAssertEqual(dto.marginCoin, "USDT")
        XCTAssertEqual(dto.leverage, "10")
    }

    func testPendingPlanOrdersMapManualTPSLProtection() throws {
        let json = """
        {
          "entrustedList": [
            {
              "planType": "profit_loss",
              "symbol": "ethusdt",
              "size": "0.05",
              "orderId": "tp1",
              "triggerPrice": "2050",
              "executePrice": "2050",
              "posSide": "long",
              "orderSource": "profit_limit",
              "uTime": "1710000001000"
            },
            {
              "planType": "profit_loss",
              "symbol": "ethusdt",
              "size": "0.1",
              "orderId": "sl1",
              "triggerPrice": "1900",
              "executePrice": "0",
              "posSide": "long",
              "orderSource": "loss_market",
              "uTime": "1710000002000"
            }
          ],
          "endId": "sl1"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(BitgetPendingPlanOrdersResponseDTO.self, from: json)
        let orders = response.entrustedList.compactMap(\.domain)

        XCTAssertEqual(orders.count, 2)
        XCTAssertEqual(orders[0].symbol, FuturesSymbol("ETHUSDT"))
        XCTAssertEqual(orders[0].side, .long)
        XCTAssertEqual(orders[0].kind, .takeProfit)
        XCTAssertEqual(orders[0].triggerPrice, 2050)
        XCTAssertEqual(orders[1].kind, .stopLoss)
        XCTAssertEqual(orders[1].triggerPrice, 1900)
    }

    func testCandleRowMappingUsesBitgetArrayOrder() throws {
        let json = """
        [
          "1695835800000",
          "26210.5",
          "26220.5",
          "26194.5",
          "26200.5",
          "26.26",
          "687897.63"
        ]
        """.data(using: .utf8)!

        let row = try JSONDecoder().decode(BitgetCandleRow.self, from: json)
        let candle = try XCTUnwrap(row.domain(symbol: FuturesSymbol("BTCUSDT"), timeframe: .fifteenMinutes))

        XCTAssertEqual(candle.symbol, FuturesSymbol("BTCUSDT"))
        XCTAssertEqual(candle.timeframe, .fifteenMinutes)
        XCTAssertEqual(candle.open, Decimal(string: "26210.5"))
        XCTAssertEqual(candle.high, Decimal(string: "26220.5"))
        XCTAssertEqual(candle.low, Decimal(string: "26194.5"))
        XCTAssertEqual(candle.close, Decimal(string: "26200.5"))
        XCTAssertEqual(candle.volume, Decimal(string: "26.26"))
        XCTAssertTrue(candle.isClosed)
    }

    func testContractConfigMapsTradableUSDTFuturesSymbol() throws {
        let json = """
        {
          "symbol": "BTCUSDT",
          "baseCoin": "BTC",
          "quoteCoin": "USDT",
          "supportMarginCoins": ["USDT"],
          "minTradeNum": "0.0001",
          "minTradeUSDT": "5",
          "sizeMultiplier": "0.0001",
          "pricePlace": "1",
          "volumePlace": "4",
          "symbolStatus": "normal",
          "minLever": "1",
          "maxLever": "150"
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(BitgetContractConfigDTO.self, from: json)
        let spec = try XCTUnwrap(dto.domain)

        XCTAssertEqual(spec.symbol, FuturesSymbol("BTCUSDT"))
        XCTAssertEqual(spec.maxLeverage, 150)
        XCTAssertTrue(spec.isUSDTFuturesTradable)
    }

    func testContractConfigRejectsNonNormalOrNonUSDTMarginCandidate() throws {
        let suspended = ContractSpec(
            symbol: FuturesSymbol("OLDUSDT"),
            baseCoin: "OLD",
            quoteCoin: "USDT",
            symbolStatus: "maintain",
            supportMarginCoins: ["USDT"],
            minTradeNum: 1,
            minTradeUSDT: 5,
            sizeMultiplier: 1,
            pricePlace: 4,
            volumePlace: 0,
            minLeverage: 1,
            maxLeverage: 20
        )
        let coinMargined = ContractSpec(
            symbol: FuturesSymbol("BTCUSD"),
            baseCoin: "BTC",
            quoteCoin: "USD",
            symbolStatus: "normal",
            supportMarginCoins: ["BTC"],
            minTradeNum: 1,
            minTradeUSDT: 5,
            sizeMultiplier: 1,
            pricePlace: 1,
            volumePlace: 0,
            minLeverage: 1,
            maxLeverage: 20
        )

        XCTAssertFalse(suspended.isUSDTFuturesTradable)
        XCTAssertFalse(coinMargined.isUSDTFuturesTradable)
    }
}
