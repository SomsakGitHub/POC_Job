TRADEKIT := Packages/TradeKit
SERVER := Server
XCODEGEN ?= xcodegen
SIMULATOR ?= platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2
DERIVED_DATA := build/DerivedData

.PHONY: bootstrap proto project server app

# Print the toolchain versions, check that xcodegen is installed, then resolve both packages.
bootstrap:
	xcodebuild -version
	swift --version
	@command -v $(XCODEGEN) >/dev/null || { echo "xcodegen not found: install it with 'brew install xcodegen'"; exit 1; }
	$(XCODEGEN) --version
	swift package --package-path $(TRADEKIT) resolve
	swift package --package-path $(SERVER) resolve

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

# Build the exchange server in release mode and run it (REST+WebSocket :18080, gRPC :18051).
# Extra flags go in ARGS, e.g. `make server ARGS="--seed 7"`.
server:
	swift build --package-path $(SERVER) -c release --product ExchangeServer
	"$$(swift build --package-path $(SERVER) -c release --show-bin-path)/ExchangeServer" $(ARGS)

# Generate App/TradePulse.xcodeproj (tracked) from App/project.yml.
project:
	$(XCODEGEN) --spec App/project.yml

# Build the iOS app for the Simulator; output: build/DerivedData/Build/Products/Debug-iphonesimulator/TradePulse.app
app:
	xcodebuild build -project App/TradePulse.xcodeproj -scheme TradePulse \
		-destination '$(SIMULATOR)' -derivedDataPath $(DERIVED_DATA)
