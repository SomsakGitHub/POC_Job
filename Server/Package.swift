// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Server",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ExchangeServer", targets: ["ExchangeServer"]),
    ],
    dependencies: [
        .package(path: "../Packages/TradeKit"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.29.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.8.1"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.13.1"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.13.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.41.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.17.2"),
    ],
    targets: [
        // Pure Swift exchange core: the simulated market, matching, ledger and engine. No I/O, no clock, no networking.
        .target(
            name: "ExchangeCore",
            dependencies: [
                .product(name: "TradeCore", package: "TradeKit"),
            ]
        ),
        .target(
            name: "ExchangeServerKit",
            dependencies: [
                "ExchangeCore",
                .product(name: "Contracts", package: "TradeKit"),
                .product(name: "TradeCore", package: "TradeKit"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "ExchangeServer",
            dependencies: ["ExchangeServerKit"]
        ),
        .testTarget(
            name: "ExchangeCoreTests",
            dependencies: [
                "ExchangeCore",
                .product(name: "TradeCore", package: "TradeKit"),
            ]
        ),
        .testTarget(
            name: "ServerIntegrationTests",
            dependencies: [
                "ExchangeCore",
                "ExchangeServerKit",
                .product(name: "Contracts", package: "TradeKit"),
                .product(name: "TradeCore", package: "TradeKit"),
                .product(name: "TradeNetworking", package: "TradeKit"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "ServiceLifecycleTestKit", package: "swift-service-lifecycle"),
            ]
        ),
    ]
)
