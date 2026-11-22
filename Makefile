TRADEKIT := Packages/TradeKit
SERVER := Server

.PHONY: proto server

# Regenerate the protobuf messages and gRPC client/server stubs (tracked) from Packages/TradeKit/Proto.
# Run from the repository root: the plugin resolves relative paths against the working directory.
# The first run builds protoc and the two protoc plugins from source.
proto:
	mkdir -p $(TRADEKIT)/Sources/Contracts/Generated
	swift package --package-path $(TRADEKIT) --allow-writing-to-package-directory \
		generate-grpc-code-from-protos \
		--messages --clients --servers --access-level public \
		--import-path $(TRADEKIT)/Proto \
		--output-path $(TRADEKIT)/Sources/Contracts/Generated \
		-- $(TRADEKIT)/Proto/market.proto $(TRADEKIT)/Proto/trading.proto

# Build the exchange server in release mode and run it (REST+WebSocket :8080, gRPC :50051).
# Extra flags go in ARGS, e.g. `make server ARGS="--seed 7"`.
server:
	swift build --package-path $(SERVER) -c release --product ExchangeServer
	"$$(swift build --package-path $(SERVER) -c release --show-bin-path)/ExchangeServer" $(ARGS)
