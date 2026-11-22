# TradePulse POC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build TradePulse: an iOS (Swift) investment-app POC fed by a Swift mock exchange over real WebSocket, gRPC and REST, with live measured latency, so a viewer sees that it works.

**Architecture:** Two SwiftPM packages and one Xcode app. `Packages/TradeKit` (shared: `Contracts` = protobuf + REST models, `TradeCore` = pure domain and measurement, `TradeNetworking` = clients and client state) is used by `Server` (`ExchangeCore` pure simulator/ledger/engine → `ExchangeServerKit` Hummingbird REST+WebSocket and gRPC wiring → `ExchangeServer` executable) and by `App` (SwiftUI, XcodeGen project). Market data is conflated per-symbol state pulled once per display frame; orders and ledger are an event-sourced, idempotent, resumable gRPC stream.

**Tech Stack:** Swift 6.4 (language mode 6), SwiftUI + Observation, Swift Testing, swift-protobuf, grpc-swift-2 (+ nio-transport, protobuf plugin), Hummingbird 2 + hummingbird-websocket, XcodeGen, iOS Simulator.

**Spec:** `docs/superpowers/specs/2026-11-22-tradepulse-poc-design.md` (Thai; "§" below refers to its sections)

## Global Constraints

- Toolchain: Xcode 27.2 / Swift 6.4.2, Swift 6 language mode with complete strict concurrency. Packages declare `platforms: [.macOS(.v15), .iOS(.v18)]` (gRPC Swift 2 floor). App: iOS 18.0 deployment target, iPhone, portrait. Verify on Simulator `iPhone 18 Pro` (iOS 27.2); smoke-test once on iOS 18.6.
- Money: every price and amount is `Int64` satang (1 THB = 100 satang). No `Double`/`Decimal` in domain or wire; format only at the UI edge.
- Market rules (simulation parameters modelled on SET, not claims of rule accuracy): board lot 100; price band ±30% of reference; max order 10,000,000 shares; starting cash ฿1,000,000 = `100_000_000` satang; commission 15 bps. Orders are Market or Limit (Day); the simulation has no session close, so a Limit order rests until it is filled, cancelled or the server resets.
- Real protocols only: market data = WebSocket `/ws/market` (Protobuf binary `Tp_MarketFrame` + JSON text control); orders = gRPC `tp.OrderService`; reference/history/account = REST JSON. Fakes exist only in unit tests, never in the app.
- Ports: REST + WebSocket `8080`, gRPC `50051`; `0` means ephemeral in tests. The app reads the host from env `TRADEPULSE_HOST` (default `127.0.0.1`).
- Timing constants: gRPC deadline 2 s (≤ 3 attempts, same `client_order_id`); WebSocket watchdog 5 s of silence; market data older than 3 s blocks order submit; server sends an empty heartbeat frame after 1 s idle; frame batching ≤ 5 ms; event log keeps 10,000 events; default 20 updates/s/symbol over 12 symbols; stress mode ≥ 5,000 updates/s aggregate.
- Data policy: market data is conflated (latest-wins) and the UI redraws at most once per display frame; order and ledger events are never dropped or reordered.
- UI copy: label "SIMULATED DATA" on every screen that shows prices; no Kasikorn name, logo or branding anywhere in the app; UI text English, company names Thai. Light and dark mode both supported (system semantic colors only; up/down are distinguishable by sign and arrow, not color alone); no third-party branding.
- Out of v1 (leave seams only): TLS, certificate pinning, Face ID, login/auth, physical-device support. The only seam built is an optional bearer token in `ClientConfig` (Task 14) that all three clients attach when set and the server ignores.
- Latency claims only from measured numbers. Targets, reported as measured (pass or miss): tick→render p99 ≤ 33 ms at 1,000 ticks/s aggregate; order submit→ack p99 ≤ 50 ms on loopback. The README states that all numbers are loopback.
- Tooling: `protoc` is not installed; generate code with the SwiftPM plugin from `grpc-swift-protobuf`. The only expected install is `xcodegen`, and the user must be asked first. Generated protobuf sources and `App/TradePulse.xcodeproj` are tracked files.
- Git: do not commit or push unless the user has said to. If authorised, work on branch `feat/tradepulse-poc` (never `main`), one commit per task. Every task ends with a Checkpoint step for this.

## Review Focus

Input classes the spec implies but no task exercises by default; each has a pinned test in the task named in brackets.

1. Order inputs at the edges: quantity 0, negative, not a multiple of 100, or absurdly large; limit prices exactly on the ±30% band edge and just outside it; prices where the tick size changes (100.00); a market order the book cannot fully absorb → a clear reject/cancel reason, ledger untouched, no crash. [Tasks 4, 9, 10]
2. The app is backgrounded, the Mac sleeps or Wi-Fi drops: sockets die silently and prices freeze → UI shows "Reconnecting", blocks ordering, then resyncs without relaunch. [Tasks 15, 20, 21]
3. The server restarts or is reset while the app holds pending or resting orders → no phantom orders or fills and no row stuck in "pending". [Tasks 10, 16, 17]
4. A client slower than the feed, or stress mode → server queue stays bounded by conflation while order events still arrive complete and in order. [Tasks 12, 17]
5. Degenerate numbers: negative or oversized latency samples (clock skew), empty data, a flat price series (high == low) → HUD never shows negative/NaN values ("—" when empty) and the chart never divides by zero. [Tasks 6, 14, 19]

## File Structure

```
Makefile                          bootstrap · proto · project · server · app · test · demo
Scripts/measure.sh                one latency scenario → docs/results/<label>.jsonl
Packages/TradeKit/                shared SwiftPM package
  Proto/{market,trading}.proto
  Sources/Contracts/              Generated/ (tracked) · WireMapping.swift · RestModels.swift
  Sources/TradeCore/              pure Swift: Price, MoneyFormat, OrderTypes, TickRules, PriceParser, PriceChange, Candle,
                                  CandleAggregator, RingBuffer, CandleSeries, LatencyHistogram, LatencyRecorder,
                                  LatencyFormat, ClockOffsetEstimator, ReconnectBackoff, HitchDetector, WallClock, ChartLayout
  Sources/TradeNetworking/        ClientConfig, RestClient, MarketState, Supervisor, MarketDataClient,
                                  TradingReducer, TradingClient, TradingStore
  Tests/{ContractsTests,TradeCoreTests,TradeNetworkingTests}
Server/                           SwiftPM package (macOS 15)
  Sources/ExchangeCore/           SymbolCatalog, SeededGenerator, BookDepth, SimulatedMarket, Matching, Ledger,
                                  EventLog, ExchangeEngine
  Sources/ExchangeServerKit/      ServerConfig, ExchangeServerApp, RestRoutes, LabControls, MarketHub,
                                  MarketWebSocket, MarketRunner, OrderServiceImpl, WireConversion
  Sources/ExchangeServer/main.swift
  Tests/{ExchangeCoreTests,ServerIntegrationTests}   (client integration tests live here: they need server + TradeKit)
App/                              project.yml · TradePulse.xcodeproj (generated, tracked) · TradePulse/ · TradePulseTests/
docs/{superpowers/specs,superpowers/plans,results}
```

Deviation from spec §6.7: that section sketches one root package; this plan uses two (`Packages/TradeKit` builds for iOS and macOS, `Server` is macOS-only) so the app target never resolves the server's Hummingbird/NIO dependencies. Everything else in §6.7 holds.

Test commands used below: `T` = `swift test --package-path Packages/TradeKit`, `S` = `swift test --package-path Server`; append `--filter <Suite>` to narrow. `make test` runs both plus the app's tests.

---

## Milestone 0: Walking skeleton (proves the toolchain and all three protocols before features)

### Task 1: TradeKit package, protobuf contracts, code generation

**Files:**
- Create: `Packages/TradeKit/Package.swift` (tools 6.1; platforms above; dependencies swift-protobuf, grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf at their latest stable `from:` versions; product and target `Contracts`; test target `ContractsTests`)
- Create: `Packages/TradeKit/Proto/market.proto`, `Packages/TradeKit/Proto/trading.proto`
- Create (generated, tracked): `Packages/TradeKit/Sources/Contracts/Generated/*.swift`
- Create: `Packages/TradeKit/Tests/ContractsTests/RoundTripTests.swift`, `Makefile` (`proto` target), `.gitignore` (`.build/`, `build/`, `.tools/`, `*.xcuserstate`, `.DS_Store`)

**Interfaces:**
- Produces: `Tp_Candle`, `Tp_SymbolUpdate`, `Tp_MarketFrame`, `Tp_Side` (`.buy/.sell`), `Tp_OrderType` (`.market/.limit`), `Tp_RejectReason`, `Tp_SubmitOrderRequest`, `Tp_SubmitOrderResponse`, `Tp_ServerTiming`, `Tp_CancelOrderRequest`, `Tp_CancelOrderResponse`, `Tp_StreamOrderEventsRequest`, `Tp_OrderEvent` (oneof `event`: `.accepted/.rejected/.fill/.cancelled/.ledgerEntry`), `Tp_OrderAccepted`, `Tp_OrderRejected`, `Tp_OrderFill`, `Tp_OrderCancelled`, `Tp_LedgerEntry`, and the gRPC namespace `Tp_OrderService` (client and service protocols). Generated field names follow swift-protobuf's rules (`symbol_id` → `symbolID`, `order_id` → `orderID`, `client_order_id` → `clientOrderID`); this plan writes them that way. Check the generated files once and adjust the plan's spelling if a name differs.

`market.proto` (`package tp;`, prices in satang, times wall-clock ns unless `_ms`):
```proto
syntax = "proto3";
package tp;
message Candle { int64 open_time_ms = 1; int64 open = 2; int64 high = 3; int64 low = 4; int64 close = 5; int64 volume = 6; }
message SymbolUpdate {
  uint32 symbol_id = 1;
  uint64 seq = 2;                       // +1 per update sent on this connection for this symbol
  int64 last = 3; int64 bid = 4; int64 ask = 5; int64 bid_qty = 6; int64 ask_qty = 7; int64 day_volume = 8;
  Candle candle_1s = 9; Candle candle_1m = 10; Candle candle_5m = 11;   // current candles (server-aggregated)
  int64 event_ns = 12;                  // when the simulator produced this state
}
message MarketFrame { int64 server_send_ns = 1; uint64 frame_seq = 2; repeated SymbolUpdate updates = 3; }  // empty updates = heartbeat
```
`trading.proto`:
```proto
syntax = "proto3";
package tp;
enum Side { SIDE_UNSPECIFIED = 0; SIDE_BUY = 1; SIDE_SELL = 2; }
enum OrderType { ORDER_TYPE_UNSPECIFIED = 0; ORDER_TYPE_MARKET = 1; ORDER_TYPE_LIMIT = 2; }
enum RejectReason {
  REJECT_REASON_UNSPECIFIED = 0; REJECT_REASON_INVALID_QUANTITY = 1; REJECT_REASON_INVALID_LOT = 2;
  REJECT_REASON_INVALID_TICK = 3; REJECT_REASON_OUTSIDE_PRICE_BAND = 4; REJECT_REASON_INSUFFICIENT_FUNDS = 5;
  REJECT_REASON_INSUFFICIENT_POSITION = 6; REJECT_REASON_UNKNOWN_SYMBOL = 7; REJECT_REASON_NO_LIQUIDITY = 8;
  REJECT_REASON_INVALID_DUPLICATE = 9;
}
message SubmitOrderRequest { string client_order_id = 1; uint32 symbol_id = 2; Side side = 3; OrderType type = 4; int64 quantity = 5; int64 limit_price = 6; }
message ServerTiming { int64 recv_ns = 1; int64 ack_ns = 2; }
message SubmitOrderResponse { bool accepted = 1; string order_id = 2; RejectReason reject_reason = 3; ServerTiming timing = 4; }
message CancelOrderRequest { string order_id = 1; }
message CancelOrderResponse { bool cancelled = 1; }
message StreamOrderEventsRequest { uint64 from_event_seq = 1; string client_epoch = 2; }   // events with event_seq > from_event_seq
message OrderAccepted { string order_id = 1; string client_order_id = 2; uint32 symbol_id = 3; Side side = 4; OrderType type = 5; int64 quantity = 6; int64 limit_price = 7; }
message OrderRejected { string client_order_id = 1; RejectReason reason = 2; }
message OrderFill { string order_id = 1; uint32 symbol_id = 2; Side side = 3; int64 quantity = 4; int64 price = 5; int64 remaining = 6; }
message OrderCancelled { string order_id = 1; int64 remaining = 2; RejectReason reason = 3; }
message LedgerEntry { uint64 ledger_seq = 1; string order_id = 2; uint32 symbol_id = 3; Side side = 4; int64 quantity = 5; int64 price = 6; int64 commission = 7; int64 cash_delta = 8; int64 cash_after = 9; int64 position_after = 10; int64 ts_ns = 11; }
message OrderEvent {
  uint64 event_seq = 1; string server_epoch = 2; int64 server_ts_ns = 3;
  oneof event { OrderAccepted accepted = 10; OrderRejected rejected = 11; OrderFill fill = 12; OrderCancelled cancelled = 13; LedgerEntry ledger_entry = 14; }
}
service OrderService {
  rpc SubmitOrder(SubmitOrderRequest) returns (SubmitOrderResponse);
  rpc CancelOrder(CancelOrderRequest) returns (CancelOrderResponse);
  rpc StreamOrderEvents(StreamOrderEventsRequest) returns (stream OrderEvent);
}
```

- [ ] **Step 1: Write both `.proto` files exactly as above, plus `Package.swift`, `Makefile` `proto` target and `.gitignore`.**
- [ ] **Step 2: Write the failing tests in `RoundTripTests.swift`:** `marketFrameRoundTrip` (frame with two `Tp_SymbolUpdate` `symbolID` 1 and 2, `last` 3425; `serializedData()` → `Tp_MarketFrame(serializedBytes:)` equals the original); `orderEventFillRoundTrip` (`eventSeq` 7, `serverEpoch` "e1", `.fill` with `quantity` 100, `price` 3425 decodes to the same case and values); `orderServiceNamespaceExists` (`_ = Tp_OrderService.self`).
- [ ] **Step 3: Run `T --filter RoundTripTests`.** Expected: FAIL (types not defined).
- [ ] **Step 4: Generate code.** Run `swift package --package-path Packages/TradeKit generate-grpc-code-from-protos --help` to learn the flags, then run it with `--allow-writing-to-package-directory`, import path `Proto`, output `Sources/Contracts/Generated`, both proto files, messages and gRPC client+server stubs; put the exact command in `make proto`. The first run compiles `protoc` from source (several minutes; run it in the background). If the plugin emits only gRPC stubs, generate messages with the swift-protobuf plugin the same way. If the plugin cannot run on this toolchain, stop and ask the user before `brew install protobuf`.
- [ ] **Step 5: Run `T`.** Expected: 3 tests PASS.
- [ ] **Step 6: Checkpoint.** `T` green; if commits are authorised: `git add Makefile .gitignore Packages && git commit -m "feat: protobuf contracts and codegen"`.

### Task 2: Server skeleton and client probe (macOS-tested)

**Files:**
- Create: `Server/Package.swift` (tools 6.2; macOS 15; dependencies: TradeKit by path `../Packages/TradeKit`, hummingbird, hummingbird-websocket, grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf, swift-service-lifecycle; targets `ExchangeServerKit`, executable `ExchangeServer`, test `ServerIntegrationTests`)
- Create: `Server/Sources/ExchangeServerKit/{ServerConfig.swift,ExchangeServerApp.swift}`, `Server/Sources/ExchangeServer/main.swift`
- Modify: `Packages/TradeKit/Package.swift` (add product + target `TradeNetworking` depending on `Contracts`, `GRPCCore`, `GRPCNIOTransportHTTP2`, `GRPCProtobuf`)
- Create: `Packages/TradeKit/Sources/TradeNetworking/SkeletonProbe.swift`, `Server/Tests/ServerIntegrationTests/SkeletonTests.swift`; Modify: `Makefile` (`server`: build release and run)

**Interfaces:**
- Produces:
```swift
public struct ServerConfig: Sendable { public var host = "127.0.0.1"; public var restPort = 8080; public var grpcPort = 50051; public var seed: UInt64 = 42; public init() }
public struct BoundPorts: Sendable { public let rest: Int; public let grpc: Int }
public final class ExchangeServerApp: Sendable { public init(config: ServerConfig); public func run() async throws; public func waitUntilListening() async -> BoundPorts }
public struct SkeletonProbe: Sendable { public init(host: String, restPort: Int, grpcPort: Int)
  public func rest() async throws -> String            // "ok"
  public func webSocketLast() async throws -> Int64     // 3425
  public func grpcOrderId() async throws -> String }    // "skeleton"
```
- Skeleton behaviour (replaced in Tasks 11–13): `GET /healthz` → `{"status":"ok"}`; WebSocket `/ws/market` sends one binary `Tp_MarketFrame` with one `Tp_SymbolUpdate` (`symbolID` 1, `last` 3425) after upgrade; gRPC `SubmitOrder` returns `accepted` with `orderID` "skeleton". REST+WebSocket (Hummingbird) and gRPC run as services of one `ServiceGroup`.

- [ ] **Step 1: Write failing tests in `SkeletonTests.swift`:** start `ExchangeServerApp` with restPort/grpcPort 0 in a `Task`, `waitUntilListening()`, then `restHealthz` (`probe.rest() == "ok"`), `webSocketDeliversFrame` (`probe.webSocketLast() == 3425`), `grpcSubmitAccepted` (`probe.grpcOrderId() == "skeleton"`); cancel the task at the end.
- [ ] **Step 2: Run `S --filter SkeletonTests`.** Expected: FAIL (does not compile).
- [ ] **Step 3: Implement the skeleton server, `SkeletonProbe` (URLSession REST, `URLSessionWebSocketTask`, grpc-swift-2 client with plaintext HTTP/2) and `main.swift` (`--rest-port`, `--grpc-port`, `--seed` flags).** Follow the library docs for `HummingbirdWebSocket` upgrades and `GRPCServer`/`HTTP2ServerTransport.Posix`.
- [ ] **Step 4: Run `S --filter SkeletonTests`.** Expected: 3 tests PASS. If the sandbox blocks local sockets, ask the user before retrying unsandboxed.
- [ ] **Step 5: Checkpoint.** `S` and `T` green; commit per Global Constraints: `feat: server skeleton and client probe`.

### Task 3: iOS app skeleton and Simulator proof

**Files:**
- Create: `App/project.yml` (XcodeGen: name `TradePulse`, iOS 18.0, Swift 6, strict concurrency complete, local package `../Packages/TradeKit` with products `TradeNetworking`, `Contracts`, `TradeCore`; app target `TradePulse`, unit-test target `TradePulseTests`; Info.plist properties `NSAppTransportSecurity.NSAllowsLocalNetworking = true`, portrait only)
- Create: `App/TradePulse/{TradePulseApp.swift,SkeletonView.swift}`, `App/TradePulseTests/SmokeTests.swift`, generated `App/TradePulse.xcodeproj`; Modify: `Makefile` (`bootstrap`: print the versions of `xcodebuild`, `swift` and `xcodegen`, fail with the install hint when `xcodegen` is missing, then `swift package resolve` for both packages; `project`: `xcodegen --spec App/project.yml`; `app`: `xcodebuild` build to `build/DerivedData`)

**Interfaces:**
- Consumes: `SkeletonProbe(host:restPort:grpcPort:)` and its three methods (Task 2).
- Produces: `make project`, `make app` (output `build/DerivedData/Build/Products/Debug-iphonesimulator/TradePulse.app`), bundle id `dev.tradepulse.poc.TradePulse`.

- [ ] **Step 1: Ask the user for permission to run `brew install xcodegen`.** If declined: `git clone --depth 1 https://github.com/yonaskolb/XcodeGen .tools/XcodeGen && swift build -c release --package-path .tools/XcodeGen` and use `.tools/XcodeGen/.build/release/xcodegen`.
- [ ] **Step 2: Write `SmokeTests.swift` (failing):** `appModuleBuilds` asserts `SkeletonViewModel().rows.count == 3` with initial states `.pending`.
- [ ] **Step 3: Implement `project.yml`, `TradePulseApp`, `SkeletonView` + `SkeletonViewModel` (runs the three probe calls against `TRADEPULSE_HOST`, shows rows "REST", "WebSocket", "gRPC" with ✓ and the returned value).** Run `make project`.
- [ ] **Step 4: Run `xcodebuild test -project App/TradePulse.xcodeproj -scheme TradePulse -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' -derivedDataPath build/DerivedData`.** Expected: `** TEST SUCCEEDED **`. If gRPC cannot connect from the Simulator with the Posix transport, switch the client to the `TransportServices` transport.
- [ ] **Step 5: Verify on the Simulator.** Open the live panel first (iOS Simulator tool, action `attach`) so the user can watch; run `make server` in the background and `make app`; then install and launch `TradePulse.app` (tool action `launch`) and take a screenshot. Expected: three rows ✓ — "REST ok", "WebSocket 34.25", "gRPC skeleton".
- [ ] **Step 6: Checkpoint.** Commit per Global Constraints: `feat: iOS skeleton talks to all three protocols` (includes generated `.xcodeproj`).

---

## Milestone 1: Core libraries (pure Swift, `TradeCore`)

### Task 4: Money and order primitives

**Files:**
- Modify: `Packages/TradeKit/Package.swift` (add product + target `TradeCore`, test target `TradeCoreTests`; `Contracts` depends on `TradeCore`)
- Create: `Packages/TradeKit/Sources/TradeCore/{Price.swift,MoneyFormat.swift,OrderTypes.swift,TickRules.swift,PriceParser.swift,PriceChange.swift}`, `Packages/TradeKit/Sources/Contracts/WireMapping.swift`
- Test: `Packages/TradeKit/Tests/TradeCoreTests/{PriceTests.swift,MoneyFormatTests.swift,TickRulesTests.swift,PriceParserTests.swift}`, `Packages/TradeKit/Tests/ContractsTests/WireMappingTests.swift`

**Interfaces:**
- Produces:
```swift
public typealias Quantity = Int64
public struct Price: Hashable, Comparable, Sendable, CustomStringConvertible {
  public var satang: Int64; public init(satang: Int64)
  public var description: String                       // "34.25", "0.01", "-0.50"
  public func notional(quantity: Quantity) -> Int64?   // satang; nil on overflow
}
public enum Side: Int32, Sendable { case buy = 1, sell = 2 }
public enum OrderType: Int32, Sendable { case market = 1, limit = 2 }
public enum OrderStatus: Sendable { case pending, accepted, partiallyFilled, filled, cancelled, rejected, unknown }
public enum RejectReason: Int32, Sendable { case invalidQuantity = 1, invalidLot, invalidTick, outsidePriceBand, insufficientFunds, insufficientPosition, unknownSymbol, noLiquidity, invalidDuplicate }
public enum TickRules {
  public static let boardLot: Quantity = 100, maxOrderQuantity: Quantity = 10_000_000
  public static func tickSize(at: Price) -> Price      // <200→1, <500→2, <1000→5, <2500→10, <10000→25, <20000→50, <40000→100, else 200 (satang)
  public static func isOnTick(_ p: Price) -> Bool
  public static func band(reference: Price) -> ClosedRange<Price>   // floor(ref*70/100) ... floor(ref*130/100)
  public static func validate(type: OrderType, quantity: Quantity, limit: Price?, reference: Price) -> RejectReason?  // checks in order: quantity, lot, tick (nil/≤0 limit on a limit order → invalidTick), band
}
public enum PriceParser { public static func parse(_ text: String) -> Price? }   // "34"→3400, "34.2"→3420, "34.25"→3425; nil for "", "-1", "34.256", "abc", "1e3"
public struct PriceChange { public init(last: Price, reference: Price); public let delta: Price; public let basisPoints: Int
  public var percentText: String { get }   // "+0.73%", "-1.20%", "0.00%"
  public var direction: Direction { get }  // enum Direction { case up, down, flat }
}
public enum MoneyFormat { public static func baht(satang: Int64) -> String }   // "฿1,000,000.00", "-฿500.00", "฿0.05"; never traps (Int64.min included)
// Contracts/WireMapping.swift: Side/OrderType/RejectReason each get `init?(wire:)` (nil for .unspecified) and `var wire`
```

- [ ] **Step 1: Write failing tests.** `PriceTests`: `Price(satang: 3425).description == "34.25"`, `Price(satang: 1).description == "0.01"`, `Price(satang: -50).description == "-0.50"`, `Price(satang: 3425).notional(quantity: 100) == 342_500`, `Price(satang: .max).notional(quantity: 2) == nil`. `TickRulesTests` (reference 3425): `tickSize` at 199→1, 200→2, 9999→25, 10000→50; `isOnTick(10000)`, `isOnTick(9975)` true and `isOnTick(10025)` false; `band == Price(2397)...Price(4452)`; `validate(.limit,100,4450)==nil`; `validate(.limit,100,4452)==.invalidTick`; `validate(.limit,100,4475)==.outsidePriceBand`; `validate(.limit,100,2400)==nil` and `validate(.limit,100,2390)==.outsidePriceBand` (the lower band edge is 2397; 2400 is the first on-tick price above it); `validate(.limit,100,nil)==.invalidTick`; quantity 0 and -100 → `.invalidQuantity`; 150 → `.invalidLot`; 20_000_000 → `.invalidQuantity`; `validate(.market,100,nil)==nil`. `PriceParserTests`: the accepted/rejected strings above. `MoneyFormatTests`: `baht(satang: 100_000_000) == "฿1,000,000.00"`, `baht(satang: -50_000) == "-฿500.00"`, `baht(satang: 5) == "฿0.05"`, `baht(satang: .min)` does not trap. `PriceChange(last: 3450, reference: 3425)`: `percentText == "+0.73%"`, `.direction == .up`; reference 0 → `"0.00%"`, `.flat`. `WireMappingTests`: `Side(wire: .buy) == .buy`, `Side(wire: .unspecified) == nil`, every `RejectReason` round-trips.
- [ ] **Step 2: Run `T`.** Expected: FAIL.
- [ ] **Step 3: Implement the signatures above** (integer arithmetic only; `description` must handle `Int64.min` without trapping).
- [ ] **Step 4: Run `T`.** Expected: PASS.
- [ ] **Step 5: Checkpoint.** Commit per Global Constraints: `feat: money and order primitives`.

### Task 5: Candles, ring buffer and series

**Files:**
- Create: `Packages/TradeKit/Sources/TradeCore/{Candle.swift,CandleAggregator.swift,RingBuffer.swift,CandleSeries.swift}`; Modify: `Packages/TradeKit/Sources/Contracts/WireMapping.swift`
- Test: `Packages/TradeKit/Tests/TradeCoreTests/{CandleAggregatorTests.swift,RingBufferTests.swift,CandleSeriesTests.swift}`

**Interfaces:**
- Consumes: `Price` (Task 4).
- Produces:
```swift
public enum CandleInterval: Int, CaseIterable, Sendable { case s1 = 1, m1 = 60, m5 = 300
  public var seconds: Int { get }; public var label: String { get }   // "1s","1m","5m"
  public func bucketStartMs(forMs ms: Int64) -> Int64 }
public struct Candle: Equatable, Sendable { public var openTimeMs: Int64; public var open, high, low, close: Price; public var volume: Int64 }
public struct CandleAggregator: Sendable { public init(interval: CandleInterval); public private(set) var current: Candle?
  public mutating func add(price: Price, quantity: Int64, atMs: Int64) -> Candle? }   // returns the candle that just closed when this trade opens a new bucket
public struct RingBuffer<Element: Sendable>: Sendable { public init(capacity: Int); public mutating func append(_ e: Element); public var count: Int { get }
  public subscript(i: Int) -> Element { get }  /* 0 = oldest */; public func toArray() -> [Element]; public mutating func removeAll() }
public struct CandleSeries: Sendable { public init(interval: CandleInterval, capacity: Int = 1000)
  public mutating func seed(history: [Candle]); public mutating func apply(current: Candle)
  public var all: [Candle] { get }   // ascending: closed + current
  public private(set) var version: UInt64 }
// WireMapping: extension Candle { init(wire: Tp_Candle); var wire: Tp_Candle }
```

- [ ] **Step 1: Write failing tests.** `CandleAggregatorTests`: three trades inside one second → one candle with open = first price, high/low = extremes, close = last, volume = sum, `add` returned nil each time; first trade of the next second returns the previous candle; a 5-second gap yields no phantom candles. `RingBufferTests`: capacity 3 after 5 appends → `toArray()` is the last three in order; capacity 1 works; `removeAll` empties. `CandleSeriesTests`: `seed` then `apply(current:)` with the same `openTimeMs` replaces the last candle; later `openTimeMs` appends; earlier `openTimeMs` is ignored; `seed([])` then `apply` works; `version` changes only when content changes; a flat candle (`high == low`) round-trips through `Candle.wire`.
- [ ] **Step 2: Run `T`.** Expected: FAIL.
- [ ] **Step 3: Implement the signatures above** (`bucketStartMs` = `ms - ms % (seconds*1000)`).
- [ ] **Step 4: Run `T`.** Expected: PASS.
- [ ] **Step 5: Checkpoint.** Commit per Global Constraints: `feat: candles, ring buffer, series`.

### Task 6: Latency and timing utilities

**Files:**
- Create: `Packages/TradeKit/Sources/TradeCore/{WallClock.swift,LatencyHistogram.swift,LatencyRecorder.swift,LatencyFormat.swift,ClockOffsetEstimator.swift,ReconnectBackoff.swift,HitchDetector.swift}`
- Test: `Packages/TradeKit/Tests/TradeCoreTests/{LatencyHistogramTests.swift,LatencyRecorderTests.swift,LatencyFormatTests.swift,ClockOffsetEstimatorTests.swift,ReconnectBackoffTests.swift,HitchDetectorTests.swift}`

**Interfaces:**
- Produces:
```swift
public enum WallClock { public static func nowNs() -> Int64 }   // CLOCK_REALTIME in ns
public struct LatencyHistogram: Sendable { public init()
  public mutating func record(nanos: Int64)   // log-scale buckets 1 µs…10 s, ≤ 5% relative width; negative → 0 and oversized → top bucket, both counted in clampedCount
  public var count: Int { get }; public var clampedCount: Int { get }
  public func percentile(_ p: Double) -> Int64? }   // ns; nil when empty
public enum LatencyMetric: String, CaseIterable, Sendable, Codable { case tickToApp, tickToApplied, tickToRender, orderSubmitToAck, orderServerProcessing, orderSubmitToFill }   // six metrics; orderServerProcessing = server ackNs − recvNs, reported apart from the round trip (spec §6.5)
public struct PercentileSummary: Sendable, Codable, Equatable { public let count: Int; public let p50Ns, p95Ns, p99Ns: Int64?; public let clamped: Int }
public final class LatencyRecorder: Sendable { public init(); public func record(_ m: LatencyMetric, nanos: Int64)
  public func summary(_ m: LatencyMetric) -> PercentileSummary; public func snapshot() -> [LatencyMetric: PercentileSummary]; public func reset() }
public enum LatencyFormat { public static func string(ns: Int64?) -> String }   // nil→"—", 950→"0.95 µs", 1_234_567→"1.23 ms", 2_500_000_000→"2.50 s"
public struct ClockOffsetEstimator: Sendable { public init()
  public mutating func add(clientSendNs: Int64, serverNs: Int64, clientRecvNs: Int64)
  public var offsetNs: Int64 { get }       // server − client from the minimum-RTT sample; 0 when empty
  public var bestRttNs: Int64? { get } }
public struct ReconnectBackoff: Sendable { public init(base: Duration = .milliseconds(250), cap: Duration = .seconds(10))
  public func delay(attempt: Int, jitter: Double) -> Duration }   // base·2^attempt capped, scaled by 0.5+0.5·jitter (jitter in 0…1)
public struct HitchDetector: Sendable { public init(); public mutating func record(frameIntervalNs: Int64, expectedNs: Int64)
  public var frames: Int { get }; public var hitches: Int { get } }   // hitch = interval > 1.5×expected; first frame ignored
```

- [ ] **Step 1: Write failing tests.** Histogram: samples 1…1000 µs → `percentile(0.5)` within ±5% of 500 µs and `percentile(0.99)` within ±5% of 990 µs; empty → nil; `record(nanos: -5)` → `clampedCount == 1` and `count == 1`; 60 s sample → clamped to top bucket; 1M records keep memory constant (count only). Recorder: 8 concurrent tasks × 10,000 records → `summary(.tickToRender).count == 80_000`; `reset()` empties; `snapshot().count == 6`. Format: the four strings above plus `string(ns: 0) == "0 ns"`. ClockOffset: samples (rtt 10 ms, offset +5 ms) and (rtt 2 ms, offset +5 ms) → `offsetNs == 5_000_000`, `bestRttNs == 2_000_000`; empty → 0. Backoff with jitter 1.0: attempts 0…6 → 250 ms, 500 ms, 1 s, 2 s, 4 s, 8 s, 10 s; jitter 0 halves each; attempt 1000 does not overflow. Hitch: expected 16.7 ms → 16.7 ms no hitch, 30 ms hitch, first frame ignored.
- [ ] **Step 2: Run `T`.** Expected: FAIL.
- [ ] **Step 3: Implement the signatures above** (`LatencyRecorder` guards a `LatencyHistogram` per metric with a lock; `WallClock` via `clock_gettime_nsec_np(CLOCK_REALTIME)`).
- [ ] **Step 4: Run `T`.** Expected: PASS.
- [ ] **Step 5: Checkpoint.** Commit per Global Constraints: `feat: latency and timing utilities`.

---

## Milestone 2: Mock exchange (`Server`)

### Task 7: Simulated market

**Files:**
- Modify: `Server/Package.swift` (add target `ExchangeCore` depending on `TradeCore`; test target `ExchangeCoreTests`)
- Create: `Server/Sources/ExchangeCore/{SeededGenerator.swift,SymbolCatalog.swift,BookDepth.swift,SimulatedMarket.swift}`
- Test: `Server/Tests/ExchangeCoreTests/SimulatedMarketTests.swift`

**Interfaces:**
- Consumes: `Price`, `TickRules`, `Candle`, `CandleInterval`, `CandleAggregator`, `Quantity` (Tasks 4–5).
- Produces:
```swift
public struct SymbolInfo: Sendable, Equatable { public let id: UInt32; public let ticker: String; public let nameTh: String; public let nameEn: String; public let reference: Price }
public enum SymbolCatalog { public static let defaultSymbols: [SymbolInfo] }   // 12 SET-style tickers incl. PTT, AOT, KBANK; ids 1…12; invented reference prices
public struct SeededGenerator: RandomNumberGenerator, Sendable { public init(seed: UInt64) }   // SplitMix64
public struct BookLevel: Sendable, Equatable { public var price: Price; public var quantity: Quantity }
public struct BookDepth: Sendable, Equatable { public var bids: [BookLevel]; public var asks: [BookLevel] }   // best first, 5 levels each side
public struct SymbolQuote: Sendable, Equatable { public let symbolId: UInt32; public var last, bid, ask: Price; public var bidQty, askQty: Quantity
  public var dayVolume: Int64; public var candle1s, candle1m, candle5m: Candle; public var eventNs: Int64 }
public struct SimulatedMarket: Sendable { public init(symbols: [SymbolInfo], seed: UInt64, startMs: Int64)
  public mutating func advance(toMs: Int64, updatesPerSymbolPerSecond: Double) -> [SymbolQuote]   // one conflated quote per symbol that changed
  public func quote(_ id: UInt32) -> SymbolQuote?; public func depth(_ id: UInt32) -> BookDepth?
  public mutating func updateDepth(_ id: UInt32, _ body: (inout BookDepth) -> Void)
  public func history(symbolId: UInt32, interval: CandleInterval, limit: Int) -> [Candle] }   // ascending, contiguous, last = current bucket
```

- [ ] **Step 1: Write failing tests:** `sameSeedSameSequence` (two markets, seed 42, same advances → equal quotes) and `differentSeedDiffers`; `pricesStayOnTickAndInsideBand` (100,000 steps over all symbols: `isOnTick(last/bid/ask)`, `band(reference).contains(last)`, `bid < ask`); `updateRateMatches` (10 s simulated at 20/s/symbol → total quotes within ±25% of 12×20×10); `stressRateReachesFiveThousand` (1 s at 500/s/symbol → ≥ 5,000 quotes); `candleInvariants` (`low ≤ open,close ≤ high` for all three intervals); `historyAscendingContiguous` (`limit` 300 → 300 candles, each `openTimeMs` = previous + interval, last equals the current bucket); `depthHasFiveLevels` (strictly monotone, on tick) and `depthReplenishesAfterConsumption` (empty the best ask level via `updateDepth`, advance 1 s → five ask levels again).
- [ ] **Step 2: Run `S --filter SimulatedMarketTests`.** Expected: FAIL.
- [ ] **Step 3: Implement.** Per-symbol random walk with changing volatility regimes, spread 1–3 ticks, depth replenishment toward a target size, Poisson-style update counts per `advance`, candles from `CandleAggregator`, history generated from the same process (seeded) at init.
- [ ] **Step 4: Run `S --filter SimulatedMarketTests`.** Expected: PASS.
- [ ] **Step 5: Checkpoint.** Commit per Global Constraints: `feat: simulated market`.

### Task 8: Ledger with reservations

**Files:**
- Create: `Server/Sources/ExchangeCore/Ledger.swift`; Test: `Server/Tests/ExchangeCoreTests/LedgerTests.swift`

**Interfaces:**
- Consumes: `Price`, `Side`, `Quantity`.
- Produces:
```swift
public struct LedgerEntry: Sendable, Equatable { public let ledgerSeq: UInt64; public let orderId: String; public let symbolId: UInt32; public let side: Side
  public let quantity: Quantity; public let price: Price; public let commission: Int64; public let cashDelta: Int64; public let cashAfter: Int64; public let positionAfter: Quantity; public let tsNs: Int64 }
public enum Commission { public static func compute(notional: Int64, bps: Int) -> Int64 }   // half-up rounding
public struct Ledger: Sendable { public init(startingCash: Int64 = 100_000_000, commissionBps: Int = 15)
  public var cash: Int64 { get }; public var positions: [UInt32: Quantity] { get }; public var entries: [LedgerEntry] { get }
  public var availableCash: Int64 { get }
  public func availableQuantity(symbolId: UInt32) -> Quantity
  public mutating func reserve(orderId: String, side: Side, symbolId: UInt32, quantity: Quantity, price: Price) -> Bool   // buy reserves notional + commission; sell reserves shares
  public mutating func release(orderId: String)
  public mutating func applyFill(orderId: String, symbolId: UInt32, side: Side, quantity: Quantity, price: Price, tsNs: Int64) -> LedgerEntry?
  public func invariantsHold() -> Bool }   // cash ≥ 0, positions ≥ 0, availableCash ≥ 0, Σ cashDelta == cash − startingCash, ledgerSeq contiguous from 1
```

- [ ] **Step 1: Write failing tests:** `commissionRoundsHalfUp` (notional 342_500 at 15 bps → 514); `buyReducesCashAddsPosition` and `sellAddsCashReducesPosition`; `cannotOverCommitCashAcrossRestingBuys` (cash 1,000,000 satang: reserve 600,000 true, second 600,000 false); `cannotOversellAcrossRestingSells`; `releaseRestoresAvailable` (after `release`, `availableCash == cash`); `fillAtBetterPriceReleasesDifference` (reserve at limit 3450, fill at 3425 → `availableCash` reflects the cheaper cost); `randomizedOperationsKeepInvariants` (seeded 10,000 random reserve/fill/release operations; `invariantsHold()` after every one).
- [ ] **Step 2: Run `S --filter LedgerTests`.** Expected: FAIL.
- [ ] **Step 3: Implement** (reservations per order id track reserved amount and remaining quantity; use `Price.notional` and trap-free overflow handling).
- [ ] **Step 4: Run `S --filter LedgerTests`.** Expected: PASS.
- [ ] **Step 5: Checkpoint.** Commit per Global Constraints: `feat: ledger with reservations`.

### Task 9: Matching

**Files:**
- Create: `Server/Sources/ExchangeCore/Matching.swift`; Test: `Server/Tests/ExchangeCoreTests/MatchingTests.swift`

**Interfaces:**
- Consumes: `BookDepth`, `BookLevel`, `SymbolQuote` (Task 7), `Side`, `Price`, `Quantity`.
- Produces:
```swift
public struct Fill: Sendable, Equatable { public let price: Price; public let quantity: Quantity }
public struct SweepResult: Sendable, Equatable { public let fills: [Fill]; public let remaining: Quantity }
public enum Matching {
  public static func sweep(side: Side, quantity: Quantity, limit: Price?, depth: BookDepth) -> SweepResult   // pure; buy walks asks ascending while ask ≤ limit; sell walks bids descending while bid ≥ limit; nil limit = market
  public static func restingFill(side: Side, limit: Price, remaining: Quantity, quote: SymbolQuote) -> Fill?   // buy fills when quote.ask ≤ limit at price = limit, qty = min(remaining, quote.askQty); sell when quote.bid ≥ limit
}
extension BookDepth { public mutating func consume(side: Side, fills: [Fill]) }   // side = aggressor side; removes liquidity, drops emptied levels
```

- [ ] **Step 1: Write failing tests:** `marketBuySweepsMultipleLevels` (asks (3425,200),(3450,300), qty 400 → fills [(3425,200),(3450,200)], remaining 0); `marketBuyBeyondDepthLeavesRemaining` (qty 1,000 vs 500 available → remaining 500); `limitBuyStopsAtLimit` (limit 3425 → one fill 200, remaining 200); `limitSellSweepsBidsDescending`; `nonMarketableLimitHasNoFills`; `restingBuyFillsWhenAskCrossesLimit` (ask 3400 ≤ limit 3425 → price 3425, qty min(remaining, askQty)); `restingBuyIgnoredAboveLimit`; `consumeRemovesLiquidityAndEmptiedLevels`.
- [ ] **Step 2: Run `S --filter MatchingTests`.** Expected: FAIL.
- [ ] **Step 3: Implement the signatures above** (pure functions; no state).
- [ ] **Step 4: Run `S --filter MatchingTests`.** Expected: PASS.
- [ ] **Step 5: Checkpoint.** Commit per Global Constraints: `feat: matching`.

### Task 10: Exchange engine, event log, idempotency, epoch

**Files:**
- Create: `Server/Sources/ExchangeCore/{EventLog.swift,ExchangeEngine.swift}`
- Test: `Server/Tests/ExchangeCoreTests/{EventLogTests.swift,ExchangeEngineTests.swift}`

**Interfaces:**
- Consumes: `SimulatedMarket`, `SymbolInfo`, `SymbolQuote` (Task 7), `Ledger`, `LedgerEntry` (Task 8), `Matching`, `Fill` (Task 9), `TickRules`, `RejectReason` (Task 4).
- Produces:
```swift
public struct OrderRequest: Sendable, Equatable { public let clientOrderId: String; public let symbolId: UInt32; public let side: Side; public let type: OrderType; public let quantity: Quantity; public let limitPrice: Price? }
public struct ServerTimingNs: Sendable, Equatable { public let recvNs: Int64; public let ackNs: Int64 }
public enum SubmitOutcome: Sendable, Equatable { case accepted(orderId: String, timing: ServerTimingNs); case rejected(RejectReason, timing: ServerTimingNs) }
public enum OrderEventPayload: Sendable, Equatable {
  case accepted(orderId: String, clientOrderId: String, symbolId: UInt32, side: Side, type: OrderType, quantity: Quantity, limitPrice: Price?)
  case rejected(clientOrderId: String, reason: RejectReason)
  case fill(orderId: String, symbolId: UInt32, side: Side, quantity: Quantity, price: Price, remaining: Quantity)
  case cancelled(orderId: String, remaining: Quantity, reason: RejectReason?)
  case ledger(LedgerEntry) }
public struct OrderEventRecord: Sendable, Equatable { public let seq: UInt64; public let epoch: String; public let tsNs: Int64; public let payload: OrderEventPayload }
public enum EventLogError: Error, Equatable { case outOfRange(oldestRetained: UInt64) }
public struct EventLog: Sendable { public init(capacity: Int = 10_000)
  public mutating func append(_ p: OrderEventPayload, epoch: String, tsNs: Int64) -> OrderEventRecord
  public func events(after seq: UInt64) throws(EventLogError) -> [OrderEventRecord]; public var lastSeq: UInt64 { get } }
public struct AccountSnapshot: Sendable, Equatable { public let epoch: String; public let cash: Int64; public let positions: [UInt32: Quantity]; public let lastEventSeq: UInt64; public let lastLedgerSeq: UInt64 }
public actor ExchangeEngine {
  public init(symbols: [SymbolInfo], seed: UInt64, nowNs: @escaping @Sendable () -> Int64, eventLogCapacity: Int = 10_000, startingCash: Int64 = 100_000_000, commissionBps: Int = 15)
  public var epoch: String { get }
  public func advance(toMs: Int64, updatesPerSymbolPerSecond: Double) -> [SymbolQuote]   // steps the market, fills resting orders, returns changed quotes
  public func quotes() -> [SymbolQuote]   // current state of every symbol (seeds the market hub at startup)
  public func submit(_ r: OrderRequest) -> SubmitOutcome
  public func cancel(orderId: String) -> Bool
  public func eventStream(after seq: UInt64, clientEpoch: String?) throws(EventLogError) -> AsyncStream<OrderEventRecord>   // replay then live; epoch mismatch replays from 0
  public func account() -> AccountSnapshot
  public func transactions(before ledgerSeq: UInt64?, limit: Int) -> [LedgerEntry]   // newest first
  public func candles(symbolId: UInt32, interval: CandleInterval, limit: Int) -> [Candle]
  public func symbols() -> [SymbolInfo]
  public func reset()        // new epoch, empty orders/ledger/log, finishes live streams
  public func dropStreams()  // finishes live streams without reset }
```
- Behaviour: order ids `O-000001`…; check order: unknown symbol → quantity → lot → tick/band → funds/position (via `Ledger.reserve`); a market order sweeps immediately (it first reserves the sweep's worst price × swept quantity and releases the surplus after the fills) and any unfilled remainder is cancelled with `.noLiquidity`; a marketable limit sweeps then rests; resting limits fill via `Matching.restingFill` on each `advance`; every fill event is followed by its `ledger` event (consecutive seq); same `clientOrderId` + same payload returns the original outcome without a new event, a different payload returns `.rejected(.invalidDuplicate)`; reject outcomes append one `rejected` event and never touch the ledger.

- [ ] **Step 1: Write failing tests.** `EventLogTests`: `appendAssignsContiguousSeq`; `eventsAfterSeqReturnsTail`; `tooOldThrowsOutOfRange` (capacity 10, 25 appends, `events(after: 2)` throws `.outOfRange(oldestRetained: 16)`). `ExchangeEngineTests`: `marketBuyFillsAndUpdatesLedger` (events accepted, fill, ledger with seq 1,2,3; cash = start − notional − commission; position 100); `limitBuyRestsThenFillsWhenPriceCrosses` (rests, then `advance` until a fill at the limit price; a partial fill when `askQty` < remaining yields ≥ 2 fills); `cancelReleasesReservation` (true, then `cancelled` event with remaining = quantity, `availableCash` restored, second cancel false); `marketRemainderCancelledNoLiquidity`; `rejectsInvalidInputsWithoutTouchingLedger` (table: qty 0, -100, 150, 20_000_000; off-tick; outside band; unknown symbol; insufficient funds; insufficient position → expected reasons; `account()` unchanged; exactly one `rejected` event per attempt); `duplicateClientOrderIdReturnsOriginalOutcome` (same outcome, one `accepted` event; same id with other quantity → `.invalidDuplicate`); `eventStreamReplaysThenGoesLive`; `eventStreamResumesAfterSeq` (after 3 starts at 4); `eventStreamOutOfRangeWhenTooOld`; `eventStreamIgnoresSeqWhenEpochDiffers`; `resetStartsNewEpochAndFinishesStreams` (epoch changes, account initial, old stream ends, new events restart at seq 1); `randomOrderFlowKeepsLedgerInvariants` (seeded 2,000 random submits/cancels interleaved with `advance`; cash ≥ 0, positions ≥ 0, Σ `transactions` cashDelta == cash − start, and for every order `quantity − Σ fill.quantity == remaining` on its last fill event).
- [ ] **Step 2: Run `S --filter ExchangeCoreTests`.** Expected: FAIL.
- [ ] **Step 3: Implement.** The engine owns one `SimulatedMarket`, `Ledger`, `EventLog` and the order table; live streams are `AsyncStream` continuations held in the actor and finished on `reset()`/`dropStreams()`.
- [ ] **Step 4: Run `S --filter ExchangeCoreTests`.** Expected: PASS.
- [ ] **Step 5: Checkpoint.** Commit per Global Constraints: `feat: exchange engine`.

### Task 11: REST routes, lab controls, shared REST models

**Files:**
- Create: `Packages/TradeKit/Sources/Contracts/RestModels.swift`; Test: `Packages/TradeKit/Tests/ContractsTests/RestModelsTests.swift`
- Create: `Server/Sources/ExchangeServerKit/{LabControls.swift,RestRoutes.swift,MarketRunner.swift}`; Modify: `Server/Sources/ExchangeServerKit/{ServerConfig.swift,ExchangeServerApp.swift}`, `Server/Package.swift` (`ExchangeServerKit` depends on `ExchangeCore`, `Contracts`, `TradeCore`)
- Test: `Server/Tests/ServerIntegrationTests/RestTests.swift`

**Interfaces:**
- Consumes: `ExchangeEngine` (Task 10), `SymbolCatalog` (Task 7).
- Produces: JSON models in `Contracts` (all `Codable, Sendable, Equatable`; satang as integers):
```swift
public struct SymbolDTO: Identifiable { id: UInt32; ticker: String; nameTh: String; nameEn: String; reference: Int64; lot: Int64 }
public struct PositionDTO { symbolId: UInt32; quantity: Int64 }
public struct AccountDTO { epoch: String; cash: Int64; positions: [PositionDTO]; lastEventSeq: UInt64; lastLedgerSeq: UInt64 }
public struct TransactionDTO { ledgerSeq: UInt64; orderId: String; symbolId: UInt32; side: String /* "buy"|"sell" */; quantity: Int64; price: Int64; commission: Int64; cashDelta: Int64; tsNs: Int64 }
public struct TransactionPageDTO { items: [TransactionDTO]; next: String? }   // newest first; cursor = last ledgerSeq returned; next page = entries with ledgerSeq < cursor
public struct CandleDTO { t: Int64; o: Int64; h: Int64; l: Int64; c: Int64; v: Int64 }
public struct CandlesResponseDTO { symbol: String; interval: String; candles: [CandleDTO] }   // ascending
public struct LabSettings { rateMultiplier: Double = 1; stress: Bool = false; extraLatencyMs: Int = 0; jitterMs: Int = 0; dropUpdates: Bool = false }
public struct LabPatch { all optional, same names }
```
  `ServerConfig` gains `eventLogCapacity: Int = 10_000` and `commissionBps: Int = 15` (both passed to the engine); `ExchangeServerApp` gains `public let engine: ExchangeEngine` and `public let lab: LabControls` (tests drive them directly); `public actor LabControls { public func settings() -> LabSettings; public func apply(_ p: LabPatch) -> LabSettings }`. `MarketRunner` loops `engine.advance` every 10 ms (2 ms when `stress`) with `updatesPerSymbolPerSecond = 20 × rateMultiplier` (500 when `stress`); its output is wired to the hub in Task 12.
- Routes: `GET /healthz` → `{"status":"ok","epoch":"…"}`; `GET /v1/time` → `{"serverNs":N}`; `GET /v1/symbols` (sends an `ETag` and `Cache-Control: no-cache`; a matching `If-None-Match` gets 304 with no body); `GET /v1/candles?symbol=PTT&interval=1s|1m|5m&limit=N` (limit clamped to 1…1000; unknown symbol/interval → 400); `GET /v1/account`; `GET /v1/transactions?cursor=&limit=` (default 50, max 200); `GET /v1/admin/lab`, `POST /v1/admin/lab` (partial patch → full settings); `POST /v1/admin/drop-connections` → 204 (engine `dropStreams()` + hub drop in Task 12); `POST /v1/admin/reset` → `{"epoch":"…"}`.

- [ ] **Step 1: Write failing tests.** `RestModelsTests`: encoded `AccountDTO` has exactly the keys `epoch, cash, positions, lastEventSeq, lastLedgerSeq`; `CandleDTO` keys `t,o,h,l,c,v`; `LabPatch` with only `stress` encodes only `stress`. `RestTests` (real `URLSession` against an ephemeral-port server): `healthzReportsEpoch`; `symbolsListTwelveWithThaiNames` (count 12, `PTT` present, `nameTh` non-empty, `lot == 100`); `symbolsSupportsETag` (a second request carrying the returned `ETag` as `If-None-Match` → 304); `candlesAscendingContiguous` (`1m`, limit 50 → 50 items, `t` steps of 60_000); `candlesLimitClamped` (limit 5000 → 1000); `candlesBadIntervalIs400`; `accountInitial` (cash 100_000_000, no positions); `accountMatchesTransactionsAfterFills` (after three market fills via `app.engine.submit`: `cash == 100_000_000 + Σ transactions.cashDelta` and positions equal Σ signed quantities); `transactionsPaginate` (three market fills via `app.engine.submit`, `limit=2` → `next` non-nil, next page returns 1 and `next == nil`); `labPatchIsPartial` (POST `{"stress":true}` → `stress == true`, `rateMultiplier` still 1); `resetChangesEpoch`; `timeIsCloseToNow` (±1 s); `unknownRouteIs404`.
- [ ] **Step 2: Run `T --filter RestModelsTests` and `S --filter RestTests`.** Expected: FAIL.
- [ ] **Step 3: Implement the models, `LabControls`, `MarketRunner`, routes, and wire `ExchangeEngine` into `ExchangeServerApp`** (seed from `ServerConfig`, `nowNs` from `WallClock`).
- [ ] **Step 4: Run both commands.** Expected: PASS (`SkeletonTests.restHealthz` keeps passing against the real route).
- [ ] **Step 5: Checkpoint.** `T` and `S` green; commit per Global Constraints: `feat: REST routes and lab controls`.

### Task 12: WebSocket market feed

**Files:**
- Create: `Server/Sources/ExchangeServerKit/{MarketHub.swift,MarketWebSocket.swift}`; Modify: `Server/Sources/ExchangeServerKit/{ExchangeServerApp.swift,MarketRunner.swift}`, `Server/Tests/ServerIntegrationTests/SkeletonTests.swift` (delete `webSocketDeliversFrame`; the skeleton frame handler is gone)
- Test: `Server/Tests/ServerIntegrationTests/{MarketHubTests.swift,WebSocketFeedTests.swift}`

**Interfaces:**
- Consumes: `SymbolQuote` (Task 7), `LabControls`/`LabSettings` (Task 11), `Tp_MarketFrame`/`Tp_SymbolUpdate` (Task 1), `WallClock`.
- Produces (`ExchangeServerApp` also gains `public let hub: MarketHub`; startup calls `hub.publish(await engine.quotes())` so the first subscriber gets full state):
```swift
public typealias ConnectionID = UInt64
public actor MarketHub {
  public init(symbols: [SymbolInfo], lab: LabControls, nowNs: @escaping @Sendable () -> Int64 = { WallClock.nowNs() })
  public func register(send: @escaping @Sendable (Tp_MarketFrame) async throws -> Void, close: @escaping @Sendable () async -> Void) -> ConnectionID
  public func unregister(_ id: ConnectionID)
  public func subscribe(_ id: ConnectionID, tickers: [String]) -> [String]   // returns the unknown tickers
  public func unsubscribe(_ id: ConnectionID, tickers: [String])
  public func resync(_ id: ConnectionID, ticker: String) -> Bool             // false for an unknown ticker
  public func publish(_ quotes: [SymbolQuote])                               // keeps the latest quote per symbol; marks it pending for each subscriber
  public func dropAll() async                                                // closes every connection
  public func maxPendingCount() -> Int }                                     // test hook: the largest pending-quote count over all connections
```
  Wire protocol:
  - Client → server JSON text: `{"op":"subscribe","symbols":["PTT"]}`, `{"op":"unsubscribe","symbols":[…]}`, `{"op":"ping","clientNs":N}`, `{"op":"resync","symbol":"PTT"}`.
  - Server → client text: `{"op":"pong","clientNs":N,"serverNs":M}`, `{"op":"error","message":"…"}`; binary: one `Tp_MarketFrame` per flush.
  - Behaviour: subscribe sends the current full state of each subscribed symbol immediately; each `SymbolUpdate` carries the latest state (not a delta) with a per-connection per-symbol `seq`; each connection keeps at most one pending quote per symbol (latest-wins) and flushes at most every 5 ms; an empty frame is sent after 1 s idle; `server_send_ns` is stamped at flush, then lab `extraLatencyMs` + random `jitterMs` delay the send; `dropUpdates` assigns a `seq` to every other update but does not send it, so the client sees a gap (resync replies are never dropped); `dropAll()` closes every socket.

- [ ] **Step 1: Write failing tests.** `MarketHubTests` (fake `send`): `subscribeSendsFullStateImmediately`; `seqIncreasesPerSymbol`; `framesBatchWithin5ms` (1,000 publishes of 12 symbols in 200 ms → ≤ 60 frames); `slowConsumerIsConflated` (a `send` that blocks 500 ms while 5,000 publishes arrive → `maxPendingCount() ≤ 12`, the next frame carries the latest `last` per symbol); `heartbeatWhenIdle` (no publishes for 1.2 s → a frame with 0 updates); `labLatencyDelaysDelivery` (`extraLatencyMs` 100 → receipt time − `serverSendNs` ≥ 100 ms); `dropUpdatesCreatesGap`; `dropAllClosesConnections`. `WebSocketFeedTests` (real `URLSessionWebSocketTask`): `subscribeReceivesBinaryFrames`; `pingPong` (`pong.clientNs == 123`, `serverNs` within 1 s of now); `resyncSendsFullState`; `unsubscribeStopsUpdates`; `malformedTextGetsErrorNotDisconnect`.
- [ ] **Step 2: Run `S --filter MarketHubTests` and `S --filter WebSocketFeedTests`.** Expected: FAIL.
- [ ] **Step 3: Implement the hub and the `/ws/market` route (the route serialises each `Tp_MarketFrame` to a binary message; text messages are the JSON controls); replace the skeleton WebSocket handler and delete `webSocketDeliversFrame` from `SkeletonTests.swift`; feed `MarketRunner` output to `hub.publish`; make `drop-connections` call `hub.dropAll()` too.**
- [ ] **Step 4: Run both filters.** Expected: PASS.
- [ ] **Step 5: Checkpoint.** `S` green; commit per Global Constraints: `feat: WebSocket market feed`.

### Task 13: gRPC OrderService and server executable

**Files:**
- Create: `Server/Sources/ExchangeServerKit/{OrderServiceImpl.swift,WireConversion.swift}`; Modify: `Server/Sources/ExchangeServerKit/ExchangeServerApp.swift`, `Server/Sources/ExchangeServer/main.swift`
- Test: `Server/Tests/ServerIntegrationTests/GrpcOrderTests.swift`; delete `SkeletonTests.swift`

**Interfaces:**
- Consumes: `ExchangeEngine`, `OrderRequest`, `SubmitOutcome`, `OrderEventRecord`, `EventLogError` (Task 10), `Tp_*` messages and `Tp_OrderService` (Task 1), `Side/OrderType/RejectReason` wire mapping (Task 4).
- Produces: `OrderServiceImpl` implementing `Tp_OrderService`; `WireConversion.swift` with `Tp_OrderEvent(record:)`. Mapping rules: `.unspecified` side/type → gRPC `invalidArgument`; business rejects are normal `SubmitOrderResponse(accepted: false, rejectReason:)`; `timing` filled from `ServerTimingNs`; `StreamOrderEvents(fromEventSeq, clientEpoch)` → `engine.eventStream`; `EventLogError.outOfRange` → RPC error `outOfRange`; the stream completes when the engine finishes streams (reset / drop).

- [ ] **Step 1: Write failing tests with the raw generated client:** `submitMarketBuyAcceptedAndStreamed` (stream from 0 yields accepted, fill, ledgerEntry with consecutive `eventSeq` and the same `serverEpoch`); `duplicateSubmitSameResponse` (same `orderID`, one `accepted` event); `unspecifiedSideIsInvalidArgument`; `businessRejectIsNotRpcError` (quantity 150 → `accepted == false`, `rejectReason == .invalidLot`); `streamResumesFromSeq`; `streamOutOfRangeStatus` (server `eventLogCapacity` 10, 25 events, `fromEventSeq` 2 → `outOfRange`); `resetEndsStream`; `timingIsOrdered` (`ackNs >= recvNs`).
- [ ] **Step 2: Run `S --filter GrpcOrderTests`.** Expected: FAIL.
- [ ] **Step 3: Implement the service and conversions, remove the skeleton gRPC handler and `SkeletonTests`, and make `main.swift` accept `--rest-port`, `--grpc-port`, `--seed`, `--event-log-capacity`, `--commission-bps` and print `listening rest=<p> grpc=<p>`.**
- [ ] **Step 4: Run `S`.** Expected: all server tests PASS. Then `make server` in the background and `curl -s localhost:8080/healthz` → `{"status":"ok",…}`.
- [ ] **Step 5: Checkpoint.** Commit per Global Constraints: `feat: gRPC OrderService and server executable`.

---

## Milestone 3: Client libraries (`TradeNetworking`)

### Task 14: REST client and market state

**Files:**
- Create: `Packages/TradeKit/Sources/TradeNetworking/{ClientConfig.swift,RestClient.swift,MarketState.swift}`; Modify: `Packages/TradeKit/Package.swift` (`TradeNetworking` also depends on `TradeCore`; add test target `TradeNetworkingTests` depending on `TradeNetworking`, `TradeCore`, `Contracts`), `Server/Package.swift` (`ServerIntegrationTests` depends on `TradeNetworking`)
- Test: `Packages/TradeKit/Tests/TradeNetworkingTests/{MarketStateTests.swift,ClientConfigTests.swift,RestAuthHeaderTests.swift}`, `Server/Tests/ServerIntegrationTests/RestClientTests.swift`

**Interfaces:**
- Consumes: DTOs (Task 11), `Candle`, `CandleInterval`, `LatencyRecorder`, `LatencyMetric`, `WallClock` (Tasks 5–6), `Tp_MarketFrame` (Task 1).
- Produces:
```swift
public struct ClientConfig: Sendable { public var host: String; public var restPort: Int; public var grpcPort: Int
  public var authToken: String?   // v1 seam: sent as `authorization: Bearer <token>` by all three clients when non-nil; the server ignores it
  public init(host: String = "127.0.0.1", restPort: Int = 8080, grpcPort: Int = 50051, authToken: String? = nil)
  public var restBase: URL { get }; public var webSocketURL: URL { get }
  public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ClientConfig }   // TRADEPULSE_HOST, TRADEPULSE_REST_PORT, TRADEPULSE_GRPC_PORT, TRADEPULSE_TOKEN
public enum RestError: Error, Equatable { case http(status: Int), decoding }
public protocol RestAPI: Sendable {
  func symbols() async throws -> [SymbolDTO]
  func candles(ticker: String, interval: CandleInterval, limit: Int) async throws -> [Candle]
  func account() async throws -> AccountDTO
  func transactions(cursor: String?, limit: Int) async throws -> TransactionPageDTO
  func serverTimeNs() async throws -> Int64
  func lab() async throws -> LabSettings; func setLab(_ p: LabPatch) async throws -> LabSettings
  func dropConnections() async throws; func resetServer() async throws -> String }
public final class URLSessionRestClient: RestAPI { public init(config: ClientConfig, session: URLSession = .shared) }
public struct SymbolSnapshot: Sendable, Equatable { public let symbolId: UInt32; public let seq: UInt64; public let last, bid, ask: Price; public let bidQty, askQty: Quantity
  public let dayVolume: Int64; public let candle1s, candle1m, candle5m: Candle; public let appliedAtNs: Int64
  public let gapCount: Int }   // seq gaps seen on this symbol since the connection began
public final class MarketState: Sendable { public init(latency: LatencyRecorder)
  public func setClockOffset(_ ns: Int64)
  public func beginConnection()                                   // forgets per-symbol seq (server restarts seq per connection)
  public func apply(frame: Tp_MarketFrame, receivedAtNs: Int64) -> [UInt32]   // returns symbol ids whose seq jumped (need resync); records tickToApp and tickToApplied
  public func snapshot(_ symbolId: UInt32) -> SymbolSnapshot?
  public func markRendered(atNs: Int64)                           // records tickToRender for the oldest not-yet-rendered frame, once
  public var version: UInt64 { get }; public var lastFrameAtNs: Int64 { get }
  public func isFresh(nowNs: Int64, maxAgeNs: Int64) -> Bool; public func reset() }
```
  Latency formula: sample = (clientNs + offset) − `serverSendNs`, with `offset = server − client`.

- [ ] **Step 1: Write failing tests.** `MarketStateTests`: `applyStoresSnapshot`; `tickToAppUsesOffset` (send 1_000, received 1_500, offset +200 → 700 ns); `gapIsReported` (seq 3 then 5 → `[symbolId]`, and `snapshot.gapCount == 1`); `staleSeqIgnored` (seq 5 then 4 keeps 5); `beginConnectionResetsSeq`; `markRenderedRecordsOncePerApply`; `emptyFrameDoesNotBumpVersionButUpdatesLastFrameAt`; `isFreshHonoursMaxAge`; `negativeLatencyIsClamped` (offset wrong by seconds → `summary(.tickToApp).clamped == 1`, never a negative percentile). `ClientConfigTests`: `fromEnvironmentReadsHostPortsAndToken` (`TRADEPULSE_HOST=10.0.0.5` → `host == "10.0.0.5"`; every unset variable keeps its default). `RestAuthHeaderTests` (a `URLProtocol` stub): `authTokenHeaderAttachedWhenSet` and `noAuthHeaderWhenNil`. `RestClientTests`: `symbolsDecode`; `candlesDecodeToDomainCandles` (ascending, equal to `app.engine.candles`); `accountDecode`; `labPatchRoundTrip`; `non200ThrowsHttpError` (`.http(status: 400)` for a bad interval).
- [ ] **Step 2: Run `T --filter MarketStateTests` and `S --filter RestClientTests`.** Expected: FAIL.
- [ ] **Step 3: Implement** (`MarketState` guards its dictionary with a `Mutex` from `Synchronization`; `apply` allocates nothing beyond decoded protobuf values).
- [ ] **Step 4: Run both.** Expected: PASS.
- [ ] **Step 5: Checkpoint.** Commit per Global Constraints: `feat: REST client and market state`.

### Task 15: Connection supervisor and WebSocket market client

**Files:**
- Create: `Packages/TradeKit/Sources/TradeNetworking/{Supervisor.swift,MarketDataClient.swift}`; delete `SkeletonProbe.swift` later in Task 18
- Test: `Packages/TradeKit/Tests/TradeNetworkingTests/SupervisorTests.swift`, `Server/Tests/ServerIntegrationTests/MarketDataClientTests.swift`

**Interfaces:**
- Consumes: `ReconnectBackoff`, `ClockOffsetEstimator`, `LatencyRecorder` (Task 6), `MarketState`, `ClientConfig` (Task 14), `SymbolDTO` (Task 11).
- Produces:
```swift
public enum ConnectionState: Sendable, Equatable { case connecting, connected, reconnecting(attempt: Int), stopped }
public final class ConnectionSupervisor: Sendable {
  public init(name: String, backoff: ReconnectBackoff = .init(), stableAfter: Duration = .seconds(5),
              jitter: @escaping @Sendable () -> Double = { .random(in: 0...1) },
              sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
  public var states: AsyncStream<ConnectionState> { get }
  public func start(_ run: @escaping @Sendable (_ markConnected: @Sendable () -> Void) async throws -> Void)
  public func nudge()          // cancels a pending backoff wait; if connected, cancels and restarts the current run
  public func stop() async }
public protocol MarketDataClient: Sendable {
  var connection: AsyncStream<ConnectionState> { get }
  func start(); func stop() async
  func subscribe(_ tickers: [String]) async; func unsubscribe(_ tickers: [String]) async
  func nudge(); var clockOffsetNs: Int64 { get } }
public final class WebSocketMarketDataClient: MarketDataClient {
  public init(config: ClientConfig, symbols: [SymbolDTO], state: MarketState, latency: LatencyRecorder,
              watchdog: Duration = .seconds(5), session: URLSession = .shared)
  public var resyncCount: Int { get } }   // resync messages sent (test hook)
```
- Behaviour: the connection is a `URLSessionWebSocketTask` (with `authToken` as a header when set); on each connect call `state.beginConnection()`, resend stored subscriptions, run 8 ping/pong rounds 50 ms apart to set the clock offset (`state.setClockOffset`), re-ping every 30 s; the receive loop decodes binary frames into `state.apply` and sends `resync` for each returned gap, at most once per symbol per second; any text or binary message resets the watchdog; silence for `watchdog` cancels the run and the supervisor reconnects; `attempt` resets after a run stays up `stableAfter`.

- [ ] **Step 1: Write failing tests.** `SupervisorTests` (injected `sleep`, fake run): `retriesWithBackoffAfterFailure` (delays 250 ms, 500 ms, 1 s at jitter 1.0); `attemptResetsAfterStableRun`; `nudgeSkipsBackoffWait`; `nudgeWhileConnectedRestartsRun`; `stopCancelsRun`; `emitsStateSequence` (connecting → connected → reconnecting(1) → connecting → connected). `MarketDataClientTests` (real server): `receivesLiveUpdatesForSubscribedSymbols` (all 12 symbols have snapshots within 1 s); `reconnectsAfterServerDropsConnections` (admin drop → state `.reconnecting` → `.connected` within 3 s, subscriptions restored, `MarketState.version` keeps increasing); `watchdogReconnectsWhenFeedGoesSilent` (watchdog 1 s, lab `extraLatencyMs` 10_000 → `.reconnecting` within 3 s); `nudgeAfterSilentDeathReconnectsImmediately` (same setup, `nudge()` → `.reconnecting` within 500 ms); `clockOffsetNearZeroOnLoopback` (|offset| < 5 ms); `gapTriggersResync` (lab `dropUpdates` → a full-state update follows within 1.5 s); `resyncIsRateLimited` (`dropUpdates` on for 3 s → `resyncCount ≤ 12 × 4`).
- [ ] **Step 2: Run `T --filter SupervisorTests` and `S --filter MarketDataClientTests`.** Expected: FAIL.
- [ ] **Step 3: Implement** (supervisor loop: `connecting` → run → on return/throw `reconnecting(attempt)` → `sleep(backoff.delay(attempt, jitter))`; `nudge` interrupts the sleep or cancels the run).
- [ ] **Step 4: Run both.** Expected: PASS.
- [ ] **Step 5: Checkpoint.** Commit per Global Constraints: `feat: connection supervisor and WebSocket client`.

### Task 16: Trading reducer

**Files:**
- Create: `Packages/TradeKit/Sources/TradeNetworking/TradingReducer.swift`; Test: `Packages/TradeKit/Tests/TradeNetworkingTests/TradingReducerTests.swift`

**Interfaces:**
- Consumes: `Tp_OrderEvent` and message types (Task 1), `Side`, `OrderType`, `OrderStatus`, `RejectReason`, `Price`, `Quantity` (Task 4), `AccountDTO` (Task 11).
- Produces:
```swift
public struct OrderDraft: Sendable, Equatable { public let clientOrderId: String; public let symbolId: UInt32; public let side: Side; public let type: OrderType; public let quantity: Quantity; public let limitPrice: Price? }
public struct OrderRow: Identifiable, Sendable, Equatable { public let id: String /* clientOrderId */; public var orderId: String?; public var symbolId: UInt32; public var side: Side
  public var type: OrderType; public var quantity: Quantity; public var limitPrice: Price?; public var filledQuantity: Quantity; public var averageFillPrice: Price?
  public var status: OrderStatus; public var rejectReason: RejectReason?; public var createdNs: Int64 }
public struct LedgerRow: Identifiable, Sendable, Equatable { public var id: UInt64 /* ledgerSeq */; public let orderId: String; public let symbolId: UInt32; public let side: Side
  public let quantity: Quantity; public let price: Price; public let commission: Int64; public let cashDelta: Int64; public let tsNs: Int64 }
public struct TradingState: Sendable, Equatable { public var epoch: String?; public var lastEventSeq: UInt64; public var epochChanges: Int /* times a different server epoch was seen */; public var orders: [OrderRow] /* newest first */
  public var ledger: [LedgerRow] /* newest first */; public var cash: Int64; public var positions: [UInt32: Quantity]; public init() }
public enum TradingAction: Sendable { case localSubmitted(OrderDraft, createdNs: Int64); case submitRejected(clientOrderId: String, reason: RejectReason)
  case submitUnconfirmed(clientOrderId: String); case event(Tp_OrderEvent); case account(AccountDTO, adoptEventSeq: Bool); case clear }
public enum TradingReducer { public static func reduce(_ s: inout TradingState, _ a: TradingAction) }
```
- Rules: an event with `eventSeq <= lastEventSeq` in the same epoch is ignored; an event whose `serverEpoch` differs from a non-nil `state.epoch` resets orders, ledger and positions (rows still `pending`/`unknown` are dropped), increments `epochChanges`, and then applies; `accepted` upgrades the matching pending row (by `clientOrderId`) or creates a row when none exists (replay after relaunch); `fill` accumulates `filledQuantity` and a half-up integer VWAP; `ledgerEntry` sets `cash = cashAfter` and the position to `positionAfter`; `cancelled` sets `.cancelled`; `rejected` sets `.rejected` with reason; `submitUnconfirmed` sets `.unknown`; `account` sets cash, positions and epoch, and sets `lastEventSeq` only when `adoptEventSeq` is true (a relaunch replays the log from 0 to rebuild the order rows; recovery from `outOfRange` adopts the account's sequence).

- [ ] **Step 1: Write failing tests:** `acceptedFillLedgerBuildsState` (market buy 200 as fills 100@3425 and 100@3450 → `filledQuantity == 200`, `averageFillPrice == Price(satang: 3438)`, status `.filled`, cash equals the last `cashAfter`, position 200); `duplicateAndStaleEventsIgnored` (replaying seq 5 twice leaves state unchanged); `epochChangeClearsPhantomOrders` (state with a pending and an accepted row, event with a new epoch and seq 1 → old rows gone, `lastEventSeq == 1`, `epochChanges == 1`); `submitRejectedMarksRow`; `unconfirmedThenAcceptedResolves` (`.unknown` → `.accepted` when the event arrives); `replayFromZeroRebuildsOrders` (events for orders with no local row create rows); `partialFillThenCancelKeepsFilled`; `accountActionSeedsCashAndPositions` (`adoptEventSeq: false` leaves `lastEventSeq` at 0, `true` sets it to the account's).
- [ ] **Step 2: Run `T --filter TradingReducerTests`.** Expected: FAIL.
- [ ] **Step 3: Implement the reducer** (pure; no I/O).
- [ ] **Step 4: Run `T --filter TradingReducerTests`.** Expected: PASS.
- [ ] **Step 5: Checkpoint.** Commit per Global Constraints: `feat: trading reducer`.

### Task 17: gRPC trading client and store

**Files:**
- Create: `Packages/TradeKit/Sources/TradeNetworking/{TradingClient.swift,TradingStore.swift}`; Test: `Server/Tests/ServerIntegrationTests/TradingClientTests.swift`, `Packages/TradeKit/Tests/TradeNetworkingTests/TradingStoreReconcileTests.swift`

**Interfaces:**
- Consumes: `Tp_OrderService`, `Tp_*` (Task 1), `ConnectionSupervisor`, `ConnectionState` (Task 15), `TradingState`, `TradingAction`, `TradingReducer`, `OrderDraft` (Task 16), `RestAPI` (Task 14), `LatencyRecorder`.
- Produces:
```swift
public struct SubmitResult: Sendable, Equatable { public let orderId: String?; public let accepted: Bool; public let rejectReason: RejectReason?
  public let serverRecvNs: Int64; public let serverAckNs: Int64; public let clientRoundTripNs: Int64 }
public protocol TradingClient: Sendable {
  func submit(_ d: OrderDraft) async throws -> SubmitResult    // 2 s deadline per attempt; ≤ 3 attempts on unavailable/deadlineExceeded with the same clientOrderId; records orderSubmitToAck and orderServerProcessing
  func cancel(orderId: String) async throws -> Bool            // 2 s deadline, no retry
  func startEventStream(resumeFrom: @escaping @Sendable () -> (seq: UInt64, epoch: String?),
                        onEvent: @escaping @Sendable (Tp_OrderEvent) async -> Void,
                        onOutOfRange: @escaping @Sendable () async -> Void)   // supervised; reconnects with backoff
  var connection: AsyncStream<ConnectionState> { get }
  func nudge(); func stop() async }
public final class GRPCTradingClient: TradingClient { public init(config: ClientConfig, latency: LatencyRecorder) }
@MainActor @Observable public final class TradingStore {
  public private(set) var state: TradingState
  public init(client: TradingClient, rest: RestAPI, latency: LatencyRecorder)
  public func start() async                         // account via REST (`.account(dto, adoptEventSeq: false)`) for initial cash and epoch, then the event stream from (state.lastEventSeq, state.epoch); that is 0 on a fresh launch, so the replay rebuilds the order rows
  public func submit(_ d: OrderDraft) async         // optimistic pending row; dispatches submitRejected / submitUnconfirmed; records orderSubmitToFill on the matching first fill
  public func retryUnconfirmed(clientOrderId: String) async   // same id, safe
  public func cancel(orderId: String) async
  public func reconcile() async -> Reconciliation } // GET /v1/account vs state: `.inFlight` when account.lastEventSeq != state.lastEventSeq, else `.consistent`, or `.drift(description)` when cash or positions differ
public enum Reconciliation: Sendable, Equatable { case consistent, inFlight, drift(String) }
```
- `onOutOfRange` handling in the store: `.clear`, reload `account()` via REST, apply `.account(dto, adoptEventSeq: true)`, resume from `account.lastEventSeq`.

- [ ] **Step 1: Write failing integration tests (real server):** `submitMarketBuyEndToEnd` (row `.filled`, cash decreased, position 100, `summary(.orderSubmitToAck).count == 1`); `invalidOrderShowsRejectNotCrash` (quantity 150 → row `.rejected(.invalidLot)`); `resubmittingSameDraftDoesNotDuplicate` (two `submit` calls, one row, one server order); `streamResumesAfterDropWithoutDuplicates` (submit 20 orders while the admin drops connections twice → exactly 20 rows, `lastEventSeq` contiguous, Σ ledger `cashDelta` == `cash − 100_000_000`); `serverResetClearsPhantomState` (resting limit order, `resetServer()` → no rows, epoch updated, no `.pending`); `eventsNeverDroppedUnderBurst` (lab `stress` on; 1,000 sequential tiny market orders → the store's `lastEventSeq == engine's lastEventSeq`, seq strictly increasing via a recording `onEvent`); `ordersUnaffectedByStalledMarketClient` (a raw `URLSessionWebSocketTask` subscribes to all symbols and never reads, `stress` on, 200 orders → every event arrives in order and `app.hub.maxPendingCount() ≤ 12`); `outOfRangeRecoversFromAccount` (server `eventLogCapacity` 10; stop the client, submit 50 orders through `app.engine`, start it again → the stream answers `outOfRange` and the store recovers with correct cash/positions); `cancelRestingOrder`; `reconcileConsistentAfterFills` (`reconcile() == .consistent` once the burst test has settled). `TradingStoreReconcileTests` (fake `TradingClient` and fake `RestAPI`): `reconcileDetectsDrift` (equal `lastEventSeq`, different cash → `.drift`) and `reconcileReportsInFlight` (different `lastEventSeq` → `.inFlight`).
- [ ] **Step 2: Run `S --filter TradingClientTests`.** Expected: FAIL.
- [ ] **Step 3: Implement the client (grpc-swift-2 client with plaintext HTTP/2 and `authToken` as call metadata when set; one long-lived connection opened by `startEventStream` and reused by the unary calls so the first order pays no connection setup; keepalive every 30 s; unary calls with a 2 s `CallOptions` timeout; a supervised server-streaming call) and the store (all state changes go through `TradingReducer.reduce`).**
- [ ] **Step 4: Run `S --filter TradingClientTests`.** Expected: PASS.
- [ ] **Step 5: Checkpoint.** `T` and `S` green; commit per Global Constraints: `feat: gRPC trading client and store`.

---

## Milestone 4: iOS app

### Task 18: App shell, environment and live market list

**Files:**
- Create: `App/TradePulse/{AppEnvironment.swift,FramePump.swift,Views/RootTabView.swift,Views/MarketListView.swift,Views/ConnectionBanner.swift,Views/SimulatedBadge.swift}`
- Modify: `App/TradePulse/TradePulseApp.swift`; delete: `App/TradePulse/SkeletonView.swift`, `App/TradePulseTests/SmokeTests.swift`, `Packages/TradeKit/Sources/TradeNetworking/SkeletonProbe.swift`
- Test: `App/TradePulseTests/{AppEnvironmentTests.swift,FramePumpTests.swift}`

**Interfaces:**
- Consumes: `ClientConfig`, `URLSessionRestClient`, `MarketState`, `WebSocketMarketDataClient`, `GRPCTradingClient`, `TradingStore`, `ConnectionState`, `PriceChange`, `HitchDetector`, `LatencyRecorder`.
- Produces:
```swift
@MainActor public final class AppEnvironment { public let config: ClientConfig; public let latency: LatencyRecorder; public let marketState: MarketState
  public let rest: URLSessionRestClient; public let trading: TradingStore; public let pump: FramePump
  public private(set) var symbols: [SymbolDTO]; public private(set) var marketConnection: ConnectionState; public private(set) var tradingConnection: ConnectionState
  public init(config: ClientConfig = .fromEnvironment())
  public func bootstrap() async          // loads symbols (retries with backoff until the server is up), starts the WebSocket client subscribed to all tickers, starts the trading store
  public func appDidBecomeActive(); public func appDidEnterBackground() }   // become-active nudges both clients
@MainActor @Observable public final class FramePump { public private(set) var tick: UInt64; public private(set) var frames: Int; public private(set) var hitches: Int
  public init(marketState: MarketState, hitchDetector: HitchDetector = .init(),
              now: @escaping @Sendable () -> Int64 = { WallClock.nowNs() }, mediaNow: @escaping () -> CFTimeInterval = { CACurrentMediaTime() })
  public func start(); public func stop()
  public func notifyRendered(drawNs: Int64)        // views call it at the end of a draw: `marketState.markRendered(atNs: lastPresentNs)` and records `drawNs`
  public var drawCost: PercentileSummary { get }   // draw time p50/p95/p99 from its own LatencyHistogram
  func step(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval, duration: CFTimeInterval) }   // internal: the CADisplayLink callback and the tests call it
```
- `step` bumps `tick` only when `marketState.version` changed, feeds `HitchDetector` (interval = `timestamp` − previous timestamp, expected = `duration`), and sets `lastPresentNs = now() + (targetTimestamp − mediaNow()) × 1e9`, the moment that frame is committed to screen. `tick→render` is reported from the chart's `Canvas` draw (the Market list has no draw callback), so that metric is populated while a chart is on screen.
- Screens: `RootTabView` tabs Market · Orders · Portfolio · Lab (Orders/Portfolio/Lab placeholders until Tasks 20–21); `MarketListView` shows 12 rows (ticker, Thai name, last, `PriceChange` text colored by direction) refreshed from `pump.tick`; `SimulatedBadge` text "SIMULATED DATA"; `ConnectionBanner` text "Reconnecting…" when either connection is not `.connected`.

- [ ] **Step 1: Write failing tests:** `AppEnvironmentTests.bootstrapRetriesUntilServerIsUp` (fake `RestAPI` failing twice then succeeding → symbols loaded, no crash); `FramePumpTests`: `tickAdvancesOnlyWhenVersionChanges` (drive `step` directly), `renderStampUsesTargetTimestamp` (injected `now`/`mediaNow`; `step` with `targetTimestamp` 16 ms ahead, then `notifyRendered(drawNs: 2_000_000)` → the `tickToRender` sample equals `now + 16 ms − serverSendNs` and `drawCost.count == 1`), `hitchCountedWhenIntervalExceedsOnePointFiveFrames`.
- [ ] **Step 2: Run `xcodebuild test` (as in Task 3).** Expected: FAIL.
- [ ] **Step 3: Implement the files above.** `FramePump` wraps a `CADisplayLink` and exposes an internal `step(timestamp:targetTimestamp:duration:)` the test calls directly; remove the skeleton files.
- [ ] **Step 4: Run `xcodebuild test`.** Expected: PASS.
- [ ] **Step 5: Verify on the Simulator** (`make server` in the background, `make app`, launch, two screenshots 2 s apart). Expected: 12 rows with changing prices and a "SIMULATED DATA" badge; stop the server → banner "Reconnecting…" within 6 s; restart it → banner disappears and prices resume.
- [ ] **Step 6: Checkpoint.** Commit per Global Constraints: `feat: app shell and live market list`.

### Task 19: Stock detail and chart

**Files:**
- Create: `Packages/TradeKit/Sources/TradeCore/ChartLayout.swift`; Test: `Packages/TradeKit/Tests/TradeCoreTests/ChartLayoutTests.swift`
- Create: `App/TradePulse/Views/{StockDetailView.swift,CandleChartView.swift,LatencyChip.swift}`, `App/TradePulse/StockDetailViewModel.swift`; Modify: `MarketListView.swift` (navigation to detail); Test: `App/TradePulseTests/StockDetailViewModelTests.swift`

**Interfaces:**
- Consumes: `Candle`, `CandleSeries`, `CandleInterval`, `Price` (Tasks 4–5), `RestAPI.candles`, `MarketState.snapshot`, `FramePump`, `LatencyRecorder`, `LatencyFormat`.
- Produces:
```swift
public struct ChartLayout: Sendable { public init(size: CGSize, visibleCount: Int, priceRange: ClosedRange<Price>, volumeFraction: Double = 0.2)
  public func x(index: Int) -> CGFloat; public var candleWidth: CGFloat { get }; public func y(price: Price) -> CGFloat
  public func volumeHeight(volume: Int64, maxVolume: Int64) -> CGFloat
  public static func visibleWindow(total: Int, visibleCount: Int, panOffset: Int) -> Range<Int>
  public static func paddedRange(of candles: ArraySlice<Candle>) -> ClosedRange<Price> }   // never zero height
@MainActor @Observable final class StockDetailViewModel { init(symbol: SymbolDTO, interval: CandleInterval, rest: RestAPI, marketState: MarketState)
  var series: CandleSeries { get }; var interval: CandleInterval; var style: ChartStyle /* candle | line */; var visibleCount: Int; var panOffset: Int
  func loadHistory() async; func refreshFromState() }   // refreshFromState applies the current candle of the chosen interval from MarketState; loadHistory(limit: 300)
```
- UI: header (ticker, Thai name, last, `PriceChange`, `SimulatedBadge`), `LatencyChip` text `tick→screen p50 <x> · p99 <y>` from `.tickToRender` via `LatencyFormat` ("—" when empty), interval picker 1s/1m/5m, Candle|Line toggle, drag to pan, pinch to zoom (`visibleCount` 20…300). `CandleChartView` draws with `Canvas` (candles, volume bars, last-price line, only the visible window) and calls `pump.notifyRendered(drawNs:)` at the end of the draw closure with the closure's own duration (the renderer runs on the main thread; use `MainActor.assumeIsolated` if the compiler requires it). `enum ChartStyle { case candle, line }` lives in `StockDetailViewModel.swift`. History reloads on appear, on interval change, when the market connection returns to `.connected`, and when `snapshot.gapCount` for the symbol increases (at most once per second). The launch argument `--open-symbol <TICKER>` opens that symbol's detail screen at launch (used by the measurement script and screenshots). Navigation back does not leak the model (no timers; it reads `pump.tick`).

- [ ] **Step 1: Write failing tests.** `ChartLayoutTests`: `yDecreasesAsPriceIncreases`; `flatSeriesGetsNonZeroRange` (all candles high == low == 3425 → `paddedRange` width ≥ 1 tick-size multiple, `y(price:)` finite); `emptyCandlesGiveDefaultRange`; `visibleWindowClampsPan` (pan beyond bounds clamps; `total < visibleCount` → `0..<total`); `volumeHeightZeroMaxIsZero` (no NaN). `StockDetailViewModelTests` (fake `RestAPI`): `historySeedsSeries` (300 candles → `series.all.count == 300`); `liveCandleReplacesLast` (snapshot with the same `openTimeMs` replaces, a later one appends); `intervalChangeReloadsHistory`; `staleSnapshotIgnored`; `gapReloadsHistoryOncePerSecond` (injected clock; `gapCount` 0→1→2 within 1 s → exactly one extra `candles` call).
- [ ] **Step 2: Run `T --filter ChartLayoutTests` and `xcodebuild test`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run both.** Expected: PASS.
- [ ] **Step 5: Verify on the Simulator** (server running, open PTT, screenshots 3 s apart, switch 1s/1m/5m, pan, pinch). Expected: candles update live, latency chip shows numbers (not "—"), no crash while switching symbols quickly; Lab hitch counter (Task 21) is checked there.
- [ ] **Step 6: Checkpoint.** Commit per Global Constraints: `feat: stock detail and live chart`.

### Task 20: Order ticket, Orders and Portfolio

**Files:**
- Create: `App/TradePulse/OrderTicketViewModel.swift`, `App/TradePulse/Views/{OrderTicketView.swift,OrdersView.swift,PortfolioView.swift}`; Modify: `StockDetailView.swift` (BUY/SELL buttons open the ticket), `RootTabView.swift`
- Test: `App/TradePulseTests/{OrderTicketViewModelTests.swift,PortfolioViewModelTests.swift}`

**Interfaces:**
- Consumes: `TickRules`, `PriceParser`, `Price`, `MoneyFormat`, `OrderDraft`, `LedgerRow`, `TradingStore`, `MarketState.isFresh`, `ConnectionState`, `SymbolDTO`.
- Produces:
```swift
@MainActor @Observable final class OrderTicketViewModel {
  init(symbol: SymbolDTO, store: TradingStore, marketState: MarketState, now: @escaping () -> Int64 = WallClock.nowNs)
  var side: Side; var type: OrderType; var quantityText: String; var priceText: String
  var validationMessage: String? { get }          // from TickRules.validate + funds hint; nil when valid
  var estimatedCost: String { get }
  func canSubmit(tradingConnected: Bool) -> Bool  // false when invalid, market data older than 3 s, trading channel down, or a submit is in flight
  func submit() async }                           // fresh UUID per submit; sets inFlight until the response
@MainActor struct PortfolioViewModel { init(state: TradingState, snapshots: (UInt32) -> SymbolSnapshot?, symbols: [SymbolDTO])
  var cashText: String { get }; var equityText: String { get }; var rows: [PositionRow] { get } }   // equity = cash + Σ quantity × last; money text via `MoneyFormat.baht`
struct PositionRow: Identifiable { let id: UInt32 /* symbolId */; let ticker: String; let quantity: Quantity; let last: Price?; let marketValueSatang: Int64? }
```
- UI: Orders tab lists `OrderRow`s (status chip, filled/quantity, average price), a Cancel button for `.accepted`/`.partiallyFilled`, "Unconfirmed — Retry" for `.unknown`; rejected rows show the reason in plain English; Portfolio tab shows cash, equity, positions and the transactions list (first REST page merged with live `TradingState.ledger`). The Orders tab shows a dismissible banner "Server restarted — your orders and balances were reloaded" whenever `TradingState.epochChanges` increases. `StockDetailView` lists the five most recent `LedgerRow`s of its symbol under the BUY/SELL buttons (the "Recent fills" area of the spec §6.4 sketch).

- [ ] **Step 1: Write failing tests.** `OrderTicketViewModelTests`: `submitDisabledWhenMarketDataStale` (`isFresh` false); `submitDisabledWhenTradingDisconnected`; `submitDisabledWhileInFlight` (double tap sends one order); `limitRequiresPrice` (`validationMessage` non-nil for an empty price); `quantityMustBeMultipleOfLot` (150 → message mentions 100); `nonNumericQuantityIsInvalid` ("", "abc", "1e3", "-100", "100.5" → message non-nil and `canSubmit` false); `priceOffTickMessage` (44.52 on reference 34.25); `freshUuidPerSubmitButRetryReusesId`; `draftMapsFieldsExactly` (symbol, side, type, quantity, `Price(satang: 3425)`). `PortfolioViewModelTests`: `equityIsCashPlusMarketValue` (cash 90_000_000 + 100 × 3450 → `equityText == "฿903,450.00"`); `emptyPositionsShowsCashOnly`.
- [ ] **Step 2: Run `xcodebuild test`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `xcodebuild test`.** Expected: PASS.
- [ ] **Step 5: Verify on the Simulator** (spec §3 rows 0:45 and 1:10). Buy 100 PTT at market → row `.filled`, cash down, position 100, transaction listed; place a limit well below the market → row stays `.accepted`; cancel it → `.cancelled`; submit quantity 150 → blocked with the lot message; stop the server → ticket disabled with a reason; restart it, then `curl -X POST localhost:8080/v1/admin/reset` → the Orders tab shows the server-restarted banner and no phantom rows. Expected: all as described, screenshots saved to `docs/results/screens/`.
- [ ] **Step 6: Checkpoint.** Commit per Global Constraints: `feat: order ticket, orders and portfolio`.

### Task 21: Lab, latency HUD, reporter and lifecycle

**Files:**
- Create: `App/TradePulse/{LatencyReporter.swift,LabViewModel.swift}`, `App/TradePulse/Views/{LabView.swift,LatencyHUD.swift}`; Modify: `TradePulseApp.swift` (scene phase, launch argument), `RootTabView.swift`
- Test: `App/TradePulseTests/{LatencyReporterTests.swift,LabViewModelTests.swift}`

**Interfaces:**
- Consumes: `LatencyRecorder`, `LatencyMetric`, `PercentileSummary`, `LatencyFormat`, `FramePump` (incl. `drawCost`), `RestAPI.setLab/dropConnections/resetServer`, `LabSettings`, `LabPatch`, `TradingStore.reconcile()`, `Reconciliation`, `AppEnvironment.appDidBecomeActive()`.
- Produces:
```swift
struct LatencyReporter { static func jsonLine(timestampMs: Int64, metrics: [LatencyMetric: PercentileSummary], frames: Int, hitches: Int) -> String
  /* {"t":…,"metrics":{"tickToRender":{"count":…,"p50Ns":…,"p95Ns":…,"p99Ns":…,"clamped":…},…},"frames":…,"hitches":…}; metrics keyed by raw value; null for missing percentiles */ }
@MainActor @Observable final class LabViewModel { init(rest: RestAPI, latency: LatencyRecorder, pump: FramePump, trading: TradingStore)
  var settings: LabSettings; var reconciliation: Reconciliation
  func load() async; func apply(_ patch: LabPatch) async; func dropConnections() async; func resetAccount() async; func resetStats(); func refreshReconciliation() async }
```
- Behaviour: Lab tab shows the market, trading and REST connection states; a table of all six metrics with count, p50/p95/p99 (`LatencyFormat`, "—" when empty, "clamped n" when > 0) refreshed twice a second; fps and hitch count/percentage; chart draw time p50/p99 (`pump.drawCost`); an "Account check" row showing `consistent` / `in flight` / `drift: …` from `trading.reconcile()` every 5 s; controls: rate multiplier slider (0.5–5), Stress toggle, injected latency 0/50/200 ms, jitter 0/20 ms, Drop connections, Reset account, Reset stats. Launching with argument `--print-latency` prints one `LatencyReporter` line to stdout every 5 s. `scenePhase == .active` calls `appDidBecomeActive()` (nudges both clients and reloads chart history); `.background` is a no-op.

- [ ] **Step 1: Write failing tests.** `LatencyReporterTests`: `jsonLineContainsAllSixMetricsAndNoNegatives` (parse the line; six keys; every percentile ≥ 0 or null); `emptyMetricsAreNull`. `LabViewModelTests` (fake `RestAPI`): `applyPatchUpdatesSettings`; `dropConnectionsCallsRest`; `resetStatsClearsRecorder`.
- [ ] **Step 2: Run `xcodebuild test`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `xcodebuild test`.** Expected: PASS.
- [ ] **Step 5: Verify on the Simulator** (spec §3 rows 1:30 and 1:45). With the server running, open Lab → numbers populate; Drop connections → states show reconnecting then connected, chart and orders continue; Stress on → UI stays responsive and p99/hitches are displayed; press Home, wait 10 s, reopen → app reconnects within 3 s without relaunch. Launch with `xcrun simctl launch --console booted dev.tradepulse.poc.TradePulse --print-latency` → one JSON line every 5 s.
- [ ] **Step 6: Checkpoint.** Commit per Global Constraints: `feat: lab, latency HUD and lifecycle`.

---

## Milestone 5: Verification

### Task 22: Measurements, demo run, README, one-command demo

**Files:**
- Create: `Scripts/measure.sh`, `docs/results/{summary.md,*.jsonl,screens/*.png}`, `README.md`; Modify: `Makefile` (`demo`, `test`)

**Interfaces:**
- Consumes: everything above; `LatencyReporter` JSON lines (Task 21); admin REST (Task 11).
- Produces: `Scripts/measure.sh <label> <rateMultiplier> <stress:true|false> <extraLatencyMs> <seconds>` (sets lab via `curl`; launches the app with `--print-latency --open-symbol PTT` on the booted Simulator so a chart is on screen and `tickToRender` is populated; captures its stdout for `<seconds>` with `simctl launch --console` in the background; writes `docs/results/<label>.jsonl`; terminates the app; resets lab); `make demo` (boots `iPhone 18 Pro`, builds, installs, launches, starts `make server` in the background).

- [ ] **Step 1: Run the full suites fresh:** `make test`. Expected: every suite green; paste the summary counts into `docs/results/summary.md`.
- [ ] **Step 2: Measure.** With the release server (`make server`), run `Scripts/measure.sh baseline 1 false 0 30`, `Scripts/measure.sh load1k 4.2 false 0 30` (≈ 1,000 updates/s aggregate), `Scripts/measure.sh stress 1 true 0 30`, `Scripts/measure.sh latency200 1 false 200 30`. Expected: four `.jsonl` files each with ≥ 5 lines.
- [ ] **Step 3: Summarise in `docs/results/summary.md`:** a table of the last line per scenario (tickToRender, orderSubmitToAck and orderServerProcessing p50/p95/p99, hitches/frames) next to the two targets, marked pass or miss as measured, plus the loopback caveat. If a target is missed, keep the number and add one sentence on the likely cause.
- [ ] **Step 4: Run the two-minute demo of spec §3 end to end on the Simulator** and save a screenshot per row to `docs/results/screens/` (watchlist, chart + latency chip, filled market order, resting then cancelled limit, rejected order, reconnect, stress Lab), plus one dark-mode screenshot of the chart (`set_appearance` dark). Expected: every row behaves as described; anything that does not is fixed or recorded in the README under Known limitations.
- [ ] **Step 5: Smoke-test the minimum OS.** Boot an iOS 18.6 iPhone simulator (`xcrun simctl list devices available`), install and launch the app against the running server. Expected: watchlist prices move and one market order fills; save `docs/results/screens/ios18-smoke.png`. If it fails, fix it or record it under Known limitations.
- [ ] **Step 6: Write `README.md`:** what it is and the "SIMULATED DATA" statement; architecture diagram (spec §6.1); run instructions (`make server`, `make app` or `make demo`); the measured table with the loopback caveat; v1 non-goals (TLS, pinning, Face ID, auth, device); links to the spec, plan and results.
- [ ] **Step 7: Final verification checklist** (each item needs fresh evidence from this task): `make test` green; demo screenshots present; four result files present; README numbers equal `summary.md`; `git status` shows only intended files; no file mentions Kasikorn branding (`grep -ril kasikorn App Packages Server` returns nothing).
- [ ] **Step 8: Checkpoint.** Commit per Global Constraints: `docs: results and README`.
