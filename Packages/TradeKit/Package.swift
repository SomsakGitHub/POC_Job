// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TradeKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "Contracts", targets: ["Contracts"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.41.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
    ],
    targets: [
        .target(
            name: "Contracts",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "ContractsTests",
            dependencies: [
                "Contracts",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
            ]
        ),
    ]
)
