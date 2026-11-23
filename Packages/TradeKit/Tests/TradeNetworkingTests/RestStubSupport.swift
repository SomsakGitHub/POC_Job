import Foundation
import Synchronization
import TradeNetworking

// A `URLProtocol` stub for the REST client tests: it answers every request of a session from a script and keeps what
// it saw, so a test can read the request exactly as it would have gone on the wire.
//
// Each suite that uses it gives itself a subclass of `StubProtocol` that holds its own ledger in a `static let`, and
// runs `.serialized`. Swift Testing runs suites in parallel and tests of one suite one after another only when asked,
// so a stub class shared by two suites, or by parallel tests of one suite, would have them overwrite each other's
// script and requests.

/// What a stubbed server answers.
enum StubAnswer: Sendable {
    /// An HTTP answer.
    case http(status: Int, body: Data = Data())
    /// An answer that is a plain `URLResponse`, not an HTTP one.
    case notHTTP
    /// A failure of the transport before any answer arrives.
    case failure(URLError.Code)

    /// A JSON body answered with `status` (200 unless told otherwise).
    static func json(_ text: String, status: Int = 200) -> StubAnswer {
        .http(status: status, body: Data(text.utf8))
    }
}

/// One request as the stub saw it.
struct SeenRequest: Sendable {
    let request: URLRequest
    /// The body that was sent; the URL loading system hands it to a protocol as a stream.
    let body: Data

    var method: String { request.httpMethod ?? "" }
    var path: String { request.url?.path ?? "" }

    /// The query as it went on the wire, still percent-encoded; nil when the URL has none.
    var rawQuery: String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.percentEncodedQuery
    }

    /// The query items in the order they were sent, percent-decoded.
    var queryItems: [URLQueryItem] {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
    }

    /// The query as a dictionary; a name that was sent twice shows as one entry with its first value.
    var query: [String: String] {
        Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    func header(_ name: String) -> String? {
        request.value(forHTTPHeaderField: name)
    }
}

/// The script of one stub class and what it has seen. Guarded by a `Mutex`: the URL loading system calls the stub on
/// its own threads while the test reads.
final class StubLedger: Sendable {
    private struct State {
        var answer = StubAnswer.http(status: 200)
        var seen: [SeenRequest] = []
    }

    private let state = Mutex(State())

    /// Forgets what was seen and sets what the stub answers from now on.
    func prepare(answer: StubAnswer) {
        state.withLock { $0 = State(answer: answer, seen: []) }
    }

    /// Notes `request` and returns the answer to give.
    func answer(to request: SeenRequest) -> StubAnswer {
        state.withLock {
            $0.seen.append(request)
            return $0.answer
        }
    }

    var requests: [SeenRequest] {
        state.withLock { $0.seen }
    }
}

/// A `URLProtocol` that answers every request from `ledger`. A subclass names its own ledger.
class StubProtocol: URLProtocol {
    /// The ledger of this stub class: a subclass returns a `static let` of its own.
    class var ledger: StubLedger {
        preconditionFailure("a stub class names its own ledger")
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let seen = SeenRequest(request: request, body: Self.body(of: request))
        let answer = type(of: self).ledger.answer(to: seen)
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch answer {
        case .http(let status, let body):
            guard let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .notHTTP:
            let response = URLResponse(
                url: url, mimeType: "application/json", expectedContentLength: 2, textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    /// The body of `request`, whether it is in `httpBody` or, as it is for a request that went through a session,
    /// in `httpBodyStream`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A REST client whose requests go to one stub class and nowhere else.
struct StubRig {
    let client: URLSessionRestClient
    private let ledger: StubLedger
    private let session: URLSession

    /// Scripts `stub` with `answer` (forgetting what it saw before) and builds a client over a session that uses it.
    init(_ stub: StubProtocol.Type, answer: StubAnswer, config: ClientConfig = ClientConfig()) {
        ledger = stub.ledger
        ledger.prepare(answer: answer)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [stub]
        session = URLSession(configuration: configuration)
        client = URLSessionRestClient(config: config, session: session)
    }

    /// Everything the stub has seen since the rig was made, oldest first.
    var requests: [SeenRequest] {
        ledger.requests
    }

    /// Ends the session; a test calls it when it is done with the rig.
    func finish() {
        session.finishTasksAndInvalidate()
    }
}
