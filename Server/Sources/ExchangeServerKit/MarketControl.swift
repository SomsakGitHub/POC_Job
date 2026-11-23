import Foundation

/// A control message a market-feed client sends as JSON text, decoded.
///
/// - `{"op":"subscribe","symbols":["PTT"]}` and `{"op":"unsubscribe","symbols":[…]}`
/// - `{"op":"ping","clientNs":N}`, answered with a pong that echoes `clientNs`
/// - `{"op":"resync","symbol":"PTT"}`
enum MarketControl: Equatable, Sendable {
    case subscribe([String])
    case unsubscribe([String])
    case ping(clientNs: Int64)
    case resync(String)

    /// Why a text is not a control message; the message of the error reply.
    struct Invalid: Error, Equatable {
        let message: String
    }

    /// Every field any message has; which ones are required depends on `op`. A field of the wrong type fails the
    /// decoding of the whole message.
    private struct Fields: Decodable {
        let op: String
        let symbols: [String]?
        let clientNs: Int64?
        let symbol: String?
    }

    /// Decodes `text`, or throws `Invalid` saying what is wrong with it.
    static func decode(_ text: String) throws(Invalid) -> MarketControl {
        let fields: Fields
        do {
            fields = try JSONDecoder().decode(Fields.self, from: Data(text.utf8))
        } catch {
            throw Invalid(message: "not a control message: expected a JSON object with an \"op\" and its fields")
        }
        switch fields.op {
        case "subscribe":
            guard let symbols = fields.symbols else { throw missing("symbols", of: fields.op) }
            return .subscribe(symbols)
        case "unsubscribe":
            guard let symbols = fields.symbols else { throw missing("symbols", of: fields.op) }
            return .unsubscribe(symbols)
        case "ping":
            guard let clientNs = fields.clientNs else { throw missing("clientNs", of: fields.op) }
            return .ping(clientNs: clientNs)
        case "resync":
            guard let symbol = fields.symbol else { throw missing("symbol", of: fields.op) }
            return .resync(symbol)
        default:
            throw Invalid(message: "unknown op \"\(fields.op)\"")
        }
    }

    private static func missing(_ field: String, of op: String) -> Invalid {
        Invalid(message: "\"\(op)\" needs \"\(field)\"")
    }
}

/// A JSON text the market feed sends a client: a pong or an error.
enum MarketReply: Sendable {
    /// Answers a ping: `clientNs` echoed, `serverNs` the server's clock when it answered.
    case pong(clientNs: Int64, serverNs: Int64)
    /// A control message that could not be carried out; the connection stays open.
    case error(String)

    private struct Pong: Encodable {
        let op = "pong"
        let clientNs: Int64
        let serverNs: Int64
    }

    private struct Failure: Encodable {
        let op = "error"
        let message: String
    }

    /// The reply as JSON text.
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data: Data?
        switch self {
        case .pong(let clientNs, let serverNs):
            data = try? encoder.encode(Pong(clientNs: clientNs, serverNs: serverNs))
        case .error(let message):
            data = try? encoder.encode(Failure(message: message))
        }
        // Encoding these plain structs cannot fail; the fallback only keeps the signature honest.
        return data.map { String(decoding: $0, as: UTF8.self) } ?? #"{"op":"error","message":"internal error"}"#
    }
}
