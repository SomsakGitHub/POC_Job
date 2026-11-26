import Foundation

/// The JSON text control messages a market-feed client sends: `subscribe`, `unsubscribe`, `ping` and `resync`.
///
/// Each one is a small `Encodable` struct run through `JSONEncoder`, never a string put together by hand, so a ticker
/// with a quote or a backslash in it stays inside its JSON string. The keys come out sorted, so the same message is
/// always the same text.
enum FeedControl {
    private struct Symbols: Encodable {
        let op: String
        let symbols: [String]
    }

    private struct Ping: Encodable {
        let op = "ping"
        let clientNs: Int64
    }

    private struct Resync: Encodable {
        let op = "resync"
        let symbol: String
    }

    /// `{"op":"subscribe","symbols":[…]}`: the server sends each known ticker's full state and then its updates.
    static func subscribe(_ tickers: [String]) -> String {
        encode(Symbols(op: "subscribe", symbols: tickers))
    }

    /// `{"op":"unsubscribe","symbols":[…]}`: the server stops sending these tickers' updates.
    static func unsubscribe(_ tickers: [String]) -> String {
        encode(Symbols(op: "unsubscribe", symbols: tickers))
    }

    /// `{"op":"ping","clientNs":N}`: the server answers at once with a pong that echoes `clientNs`.
    static func ping(clientNs: Int64) -> String {
        encode(Ping(clientNs: clientNs))
    }

    /// `{"op":"resync","symbol":"…"}`: the server sends the ticker's full state again, after a gap in its updates.
    static func resync(_ ticker: String) -> String {
        encode(Resync(symbol: ticker))
    }

    private static func encode(_ message: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Encoding a struct of strings and integers cannot fail; an empty text, which the server answers with an
        // error and otherwise ignores, only keeps the signature free of `throws`.
        guard let data = try? encoder.encode(message) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A JSON text message from the market feed, decoded: a pong, an error, or anything else.
///
/// Decoding never traps: text that is not JSON, is cut short, has a field of the wrong type or is missing one, or has
/// an `op` this client does not know is `.unknown`, and the client ignores it. Keys the client does not read are
/// ignored, as the server ignores the client's.
enum FeedReply: Sendable, Equatable {
    /// The answer to a ping: `clientNs` is the client's own send time echoed back, `serverNs` the server's clock when
    /// it answered.
    case pong(clientNs: Int64, serverNs: Int64)
    /// A control message the server could not carry out; the connection stays open.
    case error(String)
    /// Anything else.
    case unknown

    /// Every field a reply this client reads may have; which ones must be there depends on `op`.
    private struct Fields: Decodable {
        let op: String
        let clientNs: Int64?
        let serverNs: Int64?
        let message: String?
    }

    /// Decodes `text`.
    init(text: String) {
        guard let fields = try? JSONDecoder().decode(Fields.self, from: Data(text.utf8)) else {
            self = .unknown
            return
        }
        switch (fields.op, fields.clientNs, fields.serverNs, fields.message) {
        case ("pong", let clientNs?, let serverNs?, _):
            self = .pong(clientNs: clientNs, serverNs: serverNs)
        case ("error", _, _, let message?):
            self = .error(message)
        default:
            self = .unknown
        }
    }
}
