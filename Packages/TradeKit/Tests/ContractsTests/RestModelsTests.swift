import Contracts
import Foundation
import Testing

/// The REST models are a wire contract between the server and every client: the JSON key set of each one is pinned
/// exactly (a missing key and a surplus key both fail), and the numbers must survive a round trip without loss.
struct RestModelsTests {
    /// The top-level keys of `value` as JSON.
    private func keys(of value: some Encodable) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    @Test func accountEncodesExactlyItsKeys() throws {
        let account = AccountDTO(
            epoch: "e1", cash: 100_000_000, positions: [PositionDTO(symbolId: 1, quantity: 100)],
            lastEventSeq: 3, lastLedgerSeq: 1
        )
        let encoded = try keys(of: account)
        #expect(encoded == ["epoch", "cash", "positions", "lastEventSeq", "lastLedgerSeq"])
    }

    @Test func positionEncodesExactlyItsKeys() throws {
        let encoded = try keys(of: PositionDTO(symbolId: 1, quantity: 100))
        #expect(encoded == ["symbolId", "quantity"])
    }

    @Test func candleEncodesExactlyItsKeys() throws {
        let encoded = try keys(of: CandleDTO(t: 60_000, o: 3425, h: 3450, l: 3400, c: 3425, v: 1200))
        #expect(encoded == ["t", "o", "h", "l", "c", "v"])
    }

    @Test func candlesResponseEncodesExactlyItsKeys() throws {
        let candle = CandleDTO(t: 60_000, o: 3425, h: 3450, l: 3400, c: 3425, v: 1200)
        let encoded = try keys(of: CandlesResponseDTO(symbol: "PTT", interval: "1m", candles: [candle]))
        #expect(encoded == ["symbol", "interval", "candles"])
    }

    @Test func symbolEncodesExactlyItsKeys() throws {
        let symbol = SymbolDTO(
            id: 1, ticker: "PTT", nameTh: "ปตท.", nameEn: "PTT Public Company", reference: 3425, lot: 100
        )
        let encoded = try keys(of: symbol)
        #expect(encoded == ["id", "ticker", "nameTh", "nameEn", "reference", "lot"])
    }

    @Test func transactionEncodesExactlyItsKeys() throws {
        let transaction = TransactionDTO(
            ledgerSeq: 1, orderId: "O-000001", symbolId: 1, side: "buy", quantity: 100, price: 3425,
            commission: 514, cashDelta: -343_014, tsNs: 1_732_000_000_000_000_000
        )
        let encoded = try keys(of: transaction)
        #expect(encoded == [
            "ledgerSeq", "orderId", "symbolId", "side", "quantity", "price", "commission", "cashDelta", "tsNs",
        ])
    }

    @Test func transactionPageOmitsNextOnTheLastPage() throws {
        let lastPage = try keys(of: TransactionPageDTO(items: [], next: nil))
        let middlePage = try keys(of: TransactionPageDTO(items: [], next: "7"))
        #expect(lastPage == ["items"])
        #expect(middlePage == ["items", "next"])
    }

    @Test func labPatchWithOnlyStressEncodesOnlyStress() throws {
        let encoded = try keys(of: LabPatch(stress: true))
        #expect(encoded == ["stress"])
    }

    @Test func emptyLabPatchEncodesNoKeys() throws {
        let encoded = try keys(of: LabPatch())
        #expect(encoded.isEmpty)
    }

    @Test func labSettingsEncodeEveryField() throws {
        let encoded = try keys(of: LabSettings())
        #expect(encoded == ["rateMultiplier", "stress", "extraLatencyMs", "jitterMs", "dropUpdates"])
    }

    @Test func labSettingsStartAtTheNeutralValues() {
        let settings = LabSettings()
        #expect(settings.rateMultiplier == 1)
        #expect(settings.stress == false)
        #expect(settings.extraLatencyMs == 0)
        #expect(settings.jitterMs == 0)
        #expect(settings.dropUpdates == false)
    }

    /// Money, quantities, sequence numbers and timestamps are integers on the wire, so a value above 2^53 (a
    /// nanosecond timestamp, `Int64.max`) must come back exactly: a floating-point detour would round it.
    @Test func largeIntegersRoundTripExactly() throws {
        let transaction = TransactionDTO(
            ledgerSeq: .max, orderId: "O-000001", symbolId: .max, side: "sell", quantity: .max, price: .max,
            commission: .max, cashDelta: .min, tsNs: 1_732_000_000_123_456_789
        )
        let account = AccountDTO(
            epoch: "e1", cash: .max, positions: [PositionDTO(symbolId: 1, quantity: .max)],
            lastEventSeq: .max, lastLedgerSeq: .max
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decodedTransaction = try decoder.decode(TransactionDTO.self, from: encoder.encode(transaction))
        let decodedAccount = try decoder.decode(AccountDTO.self, from: encoder.encode(account))

        #expect(decodedTransaction == transaction)
        #expect(decodedAccount == account)
    }
}
