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
