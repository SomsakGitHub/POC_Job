// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TradeKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "TradeCore", targets: ["TradeCore"]),
        .library(name: "Contracts", targets: ["Contracts"]),
        .library(name: "TradeNetworking", targets: ["TradeNetworking"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.41.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.13.1"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
    ],
    targets: [
        // Pure Swift domain primitives shared by the server and the app: no dependencies, no Foundation.
        .target(name: "TradeCore"),
        .target(
            name: "Contracts",
            dependencies: [
                "TradeCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ]
        ),
        .target(
            name: "TradeNetworking",
            dependencies: [
                "Contracts",
                "TradeCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "TradeCoreTests",
            dependencies: ["TradeCore"]
        ),
        .testTarget(
            name: "ContractsTests",
            dependencies: [
                "Contracts",
                "TradeCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
            ]
        ),
        .testTarget(
            name: "TradeNetworkingTests",
            dependencies: ["TradeNetworking", "TradeCore", "Contracts"]
        ),
    ]
)
