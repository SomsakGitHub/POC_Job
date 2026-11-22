import CryptoKit
import Foundation
import Hummingbird

/// Writes every JSON body of the REST API.
///
/// One encoder, with sorted keys, is shared by all the routes, so the same value always gives the same bytes. The
/// validator of the symbol list depends on that, and so does anyone who compares two bodies.
enum RestJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// The `Content-Type` of every JSON answer, an error included.
    static let contentType = "application/json; charset=utf-8"

    /// An answer whose body is `value` as JSON.
    static func response(
        _ value: some Encodable, status: HTTPResponse.Status = .ok, headers: HTTPFields = [:]
    ) throws -> Response {
        response(data: try encoder.encode(value), status: status, headers: headers)
    }

    /// An answer whose body is `data`, which is JSON already.
    static func response(data: Data, status: HTTPResponse.Status = .ok, headers: HTTPFields = [:]) -> Response {
        var headers = headers
        headers[.contentType] = contentType
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}

/// A refusal the routes answer themselves: its status, and `{"error":"<message>"}` as the body.
///
/// The framework's own error body nests the message one level deeper, so the routes throw this instead. The message
/// is a fixed phrase that names the parameter at fault and never repeats what the client sent.
struct RestError: HTTPResponseError {
    let status: HTTPResponse.Status
    let message: String

    static func badRequest(_ message: String) -> RestError {
        RestError(status: .badRequest, message: message)
    }

    /// `{"error":"<message>"}`, with the message escaped by the encoder.
    func jsonBody() throws -> Data {
        try RestJSON.encoder.encode(ErrorBody(error: message))
    }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        RestJSON.response(data: try jsonBody(), status: status)
    }

    private struct ErrorBody: Encodable {
        let error: String
    }
}

/// The query parameters of a request, read the way every route reads them: a value is percent-decoded and a parameter
/// that is repeated is read from its first occurrence.
extension Request {
    /// The value of the query parameter `name`; nil when it is absent.
    private func queryValue(_ name: String) -> String? {
        uri.queryParameters[Substring(name)].map(String.init)
    }

    /// The value of the query parameter `name`, which has to be present and not empty.
    func requiredQuery(_ name: String) throws -> String {
        guard let value = queryValue(name), !value.isEmpty else {
            throw RestError.badRequest("\(name) is required")
        }
        return value
    }

    /// The query parameter `limit` as an integer clamped into `range`; `defaultValue` when it is absent. A value that
    /// is not an integer is refused. An integer too large for `Int` is still an integer, so it clamps by its sign.
    func queryLimit(default defaultValue: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let text = queryValue("limit") else { return defaultValue }
        let digits = text.first == "-" || text.first == "+" ? text.dropFirst() : text[...]
        guard !digits.isEmpty, digits.utf8.allSatisfy(Self.isDigit) else {
            throw RestError.badRequest("limit must be an integer")
        }
        guard let value = Int(text) else { return text.first == "-" ? range.lowerBound : range.upperBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// The query parameter `cursor`: nil when it is absent or empty, which means "from the newest"; otherwise a
    /// decimal number that fits in `UInt64`, and anything else is refused.
    func queryCursor() throws -> UInt64? {
        guard let text = queryValue("cursor"), !text.isEmpty else { return nil }
        guard text.utf8.allSatisfy(Self.isDigit), let cursor = UInt64(text) else {
            throw RestError.badRequest("cursor must be a decimal number")
        }
        return cursor
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}

/// The validator of a response that clients may keep and revalidate.
enum RestETag {
    /// A strong validator for `body`: the lowercase hex of the first 16 bytes of its SHA-256, in quotes. The same bytes
    /// always give the same validator, in every process and on every run: the standard library's `Hasher` is seeded
    /// afresh for each process and so would not.
    static func validator(for body: Data) -> String {
        let hex = SHA256.hash(data: body).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\"\(hex)\""
    }

    /// Whether any of the `If-None-Match` header values names `validator`. A header holds a comma-separated list and
    /// may be repeated; a weak mark (`W/`) is ignored, as the comparison for this header is a weak one; `*` names
    /// every validator.
    static func matches(_ headerValues: [String], validator: String) -> Bool {
        headerValues.contains { header in
            header.split(separator: ",").contains { candidate in
                let tag = candidate.trimmingCharacters(in: .whitespaces)
                return tag == "*" || tag == validator || tag == "W/" + validator
            }
        }
    }
}
