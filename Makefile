TRADEKIT := Packages/TradeKit

.PHONY: proto

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
