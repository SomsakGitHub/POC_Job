TRADEKIT := Packages/TradeKit
SERVER := Server
XCODEGEN ?= xcodegen
SIMULATOR ?= platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2
DERIVED_DATA := build/DerivedData
DERIVED_DATA_RELEASE := build/DerivedDataRelease

# What `make demo` and `make stop` work with: the simulator by name, the app's bundle id, and where the exchange server
# that `make demo` starts leaves its process id and its log (build/ is ignored by git).
SIM_NAME ?= iPhone 18 Pro
BUNDLE_ID := dev.tradepulse.poc.TradePulse
SERVER_PID := build/server.pid
SERVER_LOG := build/server.log
# The id of the simulator called SIM_NAME (empty when there is none), looked up each time a recipe uses it. The braces
# instead of parentheses are on purpose: make would count the parentheses inside the awk program.
UDID = ${shell xcrun simctl list devices available | awk -v name='$(SIM_NAME)' 'index($$0, name " (") { match($$0, /[0-9A-F]+(-[0-9A-F]+)+/); print substr($$0, RSTART, RLENGTH); exit }'}

.PHONY: bootstrap proto project server app app-release test demo stop

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

# The same app in the Release configuration (optimised code, which is what a latency figure should be measured on);
# output: build/DerivedDataRelease/Build/Products/Release-iphonesimulator/TradePulse.app
app-release:
	xcodebuild build -project App/TradePulse.xcodeproj -scheme TradePulse -configuration Release \
		-destination '$(SIMULATOR)' -derivedDataPath $(DERIVED_DATA_RELEASE)

# Run the three test suites in turn (the shared packages, the exchange server, the app) and stop at the first failure.
test:
	swift test --package-path $(TRADEKIT)
	swift test --package-path $(SERVER)
	xcodebuild test -project App/TradePulse.xcodeproj -scheme TradePulse \
		-destination '$(SIMULATOR)' -derivedDataPath $(DERIVED_DATA)

# The whole demo in one command: boot the simulator, build and install the app, start the exchange server in the
# background (unless something already listens on port 18080) and launch the app. The server's process id goes to
# build/server.pid and its output to build/server.log. Open the Simulator app to watch; `make stop` stops the server.
demo:
	@test -n "$(UDID)" || { echo "demo: no '$(SIM_NAME)' simulator found; see 'xcrun simctl list devices available'"; exit 1; }
	xcrun simctl bootstatus $(UDID) -b
	$(MAKE) app
	@if lsof -nP -iTCP:18080 -sTCP:LISTEN -t >/dev/null 2>&1; then \
		echo "demo: something already listens on port 18080, so no server is started; 'make stop' stops only a server that an earlier 'make demo' started (build/server.pid)"; \
	else \
		swift build --package-path $(SERVER) -c release --product ExchangeServer || exit 1; \
		mkdir -p build; \
		nohup "$$(swift build --package-path $(SERVER) -c release --show-bin-path)/ExchangeServer" >$(SERVER_LOG) 2>&1 </dev/null & \
		echo $$! >$(SERVER_PID); \
		echo "demo: exchange server started (pid $$(cat $(SERVER_PID)), log $(SERVER_LOG))"; \
		for second in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
			curl -sf -o /dev/null --max-time 1 http://127.0.0.1:18080/v1/time && break; \
			sleep 1; \
		done; \
		curl -sf -o /dev/null --max-time 1 http://127.0.0.1:18080/v1/time \
			|| { echo "demo: the server did not answer within 20 s; see $(SERVER_LOG)"; exit 1; }; \
	fi
	xcrun simctl install $(UDID) $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/TradePulse.app
	xcrun simctl launch --terminate-running-process $(UDID) $(BUNDLE_ID)
	@echo "demo: TradePulse is running on $(SIM_NAME) against the server on 127.0.0.1:18080."
	@echo "demo: open the Simulator app to watch it. Stop the server and the app with: make stop"

# Stop what `make demo` started: the exchange server whose process id is in build/server.pid (only if that process runs
# an executable called ExchangeServer, so that a reused process id is not taken for it) and the app. A server that was
# already running before `make demo` is left alone.
stop:
	@if [ -f $(SERVER_PID) ]; then \
		pid=$$(cat $(SERVER_PID)); \
		if ! kill -0 $$pid 2>/dev/null; then \
			echo "stop: process $$pid from $(SERVER_PID) is not running any more"; \
		elif [ "$$(basename "$$(ps -p $$pid -o comm=)")" = ExchangeServer ]; then \
			kill $$pid && echo "stop: exchange server $$pid stopped"; \
		else \
			echo "stop: process $$pid from $(SERVER_PID) is not an exchange server, so it is left alone"; \
		fi; \
		rm -f $(SERVER_PID); \
	else \
		echo "stop: no $(SERVER_PID), so there is no server from 'make demo' to stop"; \
	fi
	@if [ -n "$(UDID)" ] && xcrun simctl terminate $(UDID) $(BUNDLE_ID) 2>/dev/null; then \
		echo "stop: app terminated"; \
	fi
