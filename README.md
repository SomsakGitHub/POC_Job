# TradePulse

**SIMULATED DATA.** TradePulse is a proof-of-concept investment app for iPhone, together with the mock exchange it talks
to. There is no real market data, no real money and no broker in it: every price, account and order is invented by the
exchange server in `Server/`, and every screen of the app carries a "SIMULATED DATA" strip.

It shows three things on real protocols: live market data (a watchlist and a live candle chart), order entry and the
whole life of an order (market and limit orders, fills, cancels, rejections, portfolio and transactions), and the speed
of both, which the app measures and prints itself. Everything runs on one Mac: the exchange is a Swift program and the
app runs in the iOS Simulator.

- [What the demo shows](#what-the-demo-shows)
- [Architecture](#architecture)
- [Run it](#run-it)
- [Measured](#measured)
- [Screenshots](#screenshots)
- [Minimum OS](#minimum-os)
- [Known limitations](#known-limitations)
- [Not in this version](#not-in-this-version)
- [Repository layout](#repository-layout)
- [Documents](#documents)

## What the demo shows

The two-minute demo walks these steps on the simulator, against the real server. Each step has a screenshot below.

| Step | What you see | What carries it |
| --- | --- | --- |
| 1 | Market tab: the watchlist of 12 symbols, prices moving | REST for the list of symbols, WebSocket for the prices |
| 2 | A symbol opens: the candle chart moves live, and a latency chip shows tick to screen p50 and p99 | REST for the chart's history, WebSocket for the live candle |
| 3 | Buy at market: the order is accepted and filled; Portfolio shows the cash, the position and the transaction | gRPC `SubmitOrder` and the order event stream; REST for the account and the transactions |
| 4 | A limit buy below the market stays open; Cancel ends it Cancelled | gRPC `SubmitOrder`, `CancelOrder`, event stream |
| 5 | A wrong order is refused with its reason: a price off the tick or a quantity that is not a multiple of 100 never leaves the ticket; more than the cash is rejected by the exchange | the ticket's own checks; the exchange's answer over gRPC |
| 6 | Lab, Drop connections: a "Reconnecting..." banner, then the connections are back and the app's account agrees with the server's | WebSocket and gRPC reconnect, REST for the account check and the lab |
| 7 | Lab, Stress: the server generates 6,000 ticks a second and the live latency numbers keep counting (in the recorded Release run the p99 was 32.51 ms, with 2 hitches in 1,786 frames) | REST for the lab's settings |

Which protocol carries what:

| Protocol | Used for |
| --- | --- |
| REST (JSON over HTTP, port 18080) | symbols (with an ETag), candles, the account, transactions, the server's clock, a health check and the lab's admin calls (`/v1/*`, `/healthz`) |
| WebSocket `/ws/market` (port 18080) | the market feed: the app subscribes to symbols and the server sends binary Protobuf frames, each with the newest state of every symbol that changed; JSON text messages control the feed (subscribe, unsubscribe, ping, resync) |
| gRPC `OrderService` (HTTP/2, Protobuf, port 18051) | `SubmitOrder` (carries a client-chosen `client_order_id`, so a repeat is the same order), `CancelOrder`, and `StreamOrderEvents`, a stream of accepted, rejected, fill, cancelled and ledger events that can be resumed from a sequence number |

All of it is cleartext on loopback; there is no TLS in this version.

## Architecture

```
 iOS app (in the Simulator)                                 Exchange server (Swift, on the same Mac)
+----------------------------------------------+           +----------------------------------------------+
| SwiftUI: Market, Chart, Order ticket,        |           | SimulatedMarket --> MarketHub (conflates     |
|          Orders, Portfolio, Lab              | WebSocket |   the ticks of each connection into frames)  |
|                                              |<--------->| WebSocket  /ws/market   Protobuf frames      |
| MarketDataClient --> MarketState             |           |                                              |
|   (latest wins) --> display link --> Canvas  |   REST    | REST       /v1/*, /healthz   JSON            |
|                                              |<--------->|                                              |
| RestClient (URLSession)                      |           | gRPC       OrderService (HTTP/2, Protobuf)   |
| TradingClient (orders and event stream)      |   gRPC    |   SubmitOrder, CancelOrder, StreamOrderEvents|
|                                              |<--------->|                                              |
| LatencyRecorder: histograms, printed with    |           | ExchangeEngine: Matching, Ledger, EventLog   |
|   --print-latency                            |           | Lab controls (REST admin)                    |
+----------------------------------------------+           +----------------------------------------------+
```

How a price reaches the screen: the server simulates ticks and merges the ticks of each connection into frames, one
frame at a time per connection and at least 5 ms apart. Each frame holds the newest state of every symbol that changed,
so a slow client loses intermediate quotes and never the latest one. The app decodes frames off the main thread into a
market state in which the latest update wins, and a display link draws the chart once per display frame from that state.
Orders and the portfolio follow the order event stream, and the Lab's account check compares them with the server's
`GET /v1/account`.

## Run it

You need a Mac with Xcode and an `iPhone 18 Pro` simulator on iOS 27.2: the `Makefile` builds and tests for that device
(`SIMULATOR` at its top). It was built and run with Xcode 27.2 and Swift 6.4.2 on macOS 26.7. The Xcode project and the
generated Protobuf and gRPC code are in the repository, so neither XcodeGen nor protoc is needed. The first build fetches
the Swift packages the project depends on (see `Package.resolved` in `Packages/TradeKit` and `Server`), which needs
network access.

```
make demo
```

boots the simulator, builds the Debug app, installs it, starts the exchange server in the background (unless something
already listens on port 18080) and launches the app. Open the Simulator app to watch. When you are done:

```
make stop
```

stops the server that `make demo` started (its process id is in `build/server.pid`) and the app. A server that was
already running before `make demo` is left alone.

The same, step by step:

```
make server        # the exchange server, release build, in the foreground: REST and WebSocket on 18080, gRPC on 18051
make app           # the Debug app, in build/DerivedData
make app-release   # the Release app, in build/DerivedDataRelease
make test          # the three test suites, one after the other
```

`make test` runs `swift test --package-path Packages/TradeKit`, `swift test --package-path Server` and the app's tests
with `xcodebuild test`, and stops at the first failure. Its last run ended with exit code 0 and
1,492 tests passed: 508 in TradeKit, 388 in the server and 596 in the app.

To measure, with the server running (`make server` in another terminal) and the app built:

```
APP_PATH=build/DerivedDataRelease/Build/Products/Release-iphonesimulator/TradePulse.app \
  Scripts/measure.sh my-run 10 false 0 30
python3 -I Scripts/summarize.py docs/results
```

The arguments of `Scripts/measure.sh` are a label, the rate multiplier, stress mode (`true` or `false`), the extra
latency in milliseconds and the seconds to run. `APP_PATH` installs that build on the simulator first, so the run says
which build it measured. The script sets the lab on the server, launches the app with `--print-latency --open-symbol PTT`,
keeps the JSON lines the app prints in `docs/results/<label>.jsonl` with a record in `docs/results/<label>.run.json`, and
puts the lab back to its defaults. A label that already exists is overwritten, so give a new run a new label. The second
command prints the tables of every run in `docs/results`, and
`python3 -I Scripts/summarize.py --check docs/results README.md docs/results/summary.md` checks that the tables in those
two files are what the script prints now: it prints nothing and exits 0 when they are, and prints the difference and exits
1 when they are not. To count what the server delivers to one connection at the lab settings the runs use, run
`python3 -I docs/results/feed-probe.py 10`.

## Measured

Every figure below is a number the app printed with `--print-latency` (one JSON line every 5 seconds, cumulative since
the launch) or, for "Updates/s sent", a number counted by `docs/results/feed-probe.py`, a probe of the server that was
run once at the five lab settings and not repeated with the runs. `Scripts/summarize.py` turns the last line of each run
into milliseconds. The tables and the verdicts are generated, and the block below is identical to the one in
[`docs/results/summary.md`](docs/results/summary.md), which also holds the method, the run records, the repeat of one
run, the analysis of `clamped` and the checks of the demo. `tickToRender` ends at a display refresh, so it contains a
wait of about one and a half frames at the median: what it is is under "How to read the numbers" below.

**Loopback caveat.** All of it was measured on 26 November 2026 on one Mac (Apple M4 Pro, macOS 26.7) with the exchange
server and the app, in the iOS Simulator, talking over loopback. The numbers show the cost of the app and its pipeline.
They do not show what a real network would add. The lab's injected latency (200 ms in the runs `release-latency200`,
`orders200` and `latency200`) is there to see how the app behaves on a worse network.

**Which build.** The first table is the Release build (`make app-release`), the optimised code a latency figure should be
read on. The second is the Debug build, which is what `make app` and `make demo` give you. The order-path table lists
every run with its build.

<!-- tables:begin -->
### Tick to render, Release build (`make app-release`)

| Run | Lab setting | Ticks/s set | Updates/s sent | Feed frames/s | Display fps | Samples | p50 / p95 / p99 (ms) | p99 in frames | Clamped | Hitches / frames |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| release-baseline | rate 1x | 240 | 211 | 83.9 | 59.6 | 1,643 | 24.64 / 31.46 / 33.03 | 1.97 | 0 | 10 / 1,479 (0.68 %) |
| release-load1k | rate 4.2x | 1,008 | 634 | 89.4 | 59.8 | 2,178 | 24.12 / 30.93 / 33.03 | 1.98 | 0 | 5 / 1,783 (0.28 %) |
| release-load10x | rate 10x | 2,400 | 922 | 90.1 | 60.0 | 1,871 | 23.59 / 29.88 / 32.51 | 1.95 | 0 | 1 / 1,489 (0.07 %) |
| release-stress | stress | 6,000 | 1,894 | 169.1 | 60.0 | 2,719 | 25.17 / 31.46 / 32.51 | 1.95 | 0 | 2 / 1,786 (0.11 %) |
| release-latency200 | rate 1x, +200 ms | 240 | 56 | 4.7 | 56.3 | 118 | 230.69 / 243.27 / 243.27 | 13.70 | 0 | 90 / 1,401 (6.42 %) |
| orders | rate 1x | 240 | 211 | 83.1 | 59.4 | 15,918 | 24.64 / 31.98 / 33.03 | 1.96 | 0 | 120 / 14,266 (0.84 %) |
| orders200 | rate 1x, +200 ms | 240 | 56 | 4.8 | 56.3 | 476 | 230.69 / 239.08 / 243.27 | 13.70 | 0 | 359 / 5,635 (6.37 %) |

### Tick to render, Debug build (`make app`, `make demo`)

| Run | Lab setting | Ticks/s set | Updates/s sent | Feed frames/s | Display fps | Samples | p50 / p95 / p99 (ms) | p99 in frames | Clamped | Hitches / frames |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| baseline | rate 1x | 240 | 211 | 83.5 | 59.7 | 1,650 | 24.64 / 31.46 / 33.03 | 1.97 | 0 | 7 / 1,481 (0.47 %) |
| baseline-repeat | rate 1x | 240 | 211 | 83.8 | 59.8 | 1,638 | 25.17 / 31.46 / 32.51 | 1.94 | 0 | 2 / 1,486 (0.13 %) |
| load1k | rate 4.2x | 1,008 | 634 | 90.7 | 59.9 | 1,805 | 24.12 / 30.93 / 31.98 | 1.92 | 0 | 1 / 1,485 (0.07 %) |
| load10x | rate 10x | 2,400 | 922 | 89.6 | 60.0 | 1,896 | 23.59 / 30.41 / 32.51 | 1.95 | 0 | 2 / 1,491 (0.13 %) |
| stress | stress | 6,000 | 1,894 | 168.1 | 60.0 | 2,017 | 27.26 / 31.46 / 32.51 | 1.95 | 0 | 1 / 1,493 (0.07 %) |
| latency200 | rate 1x, +200 ms | 240 | 56 | 4.7 | 59.7 | 142 | 230.69 / 243.27 / 243.27 | 14.52 | 0 | 6 / 1,787 (0.34 %) |

### Order path, every run

Each cell: the number of samples, then p50 / p95 / p99 in milliseconds.

| Run | Build | Submit to ack | Server processing | Submit to fill |
| --- | --- | --- | --- | --- |
| release-baseline | Release | — | — | — |
| release-load1k | Release | — | — | — |
| release-load10x | Release | — | — | — |
| release-stress | Release | — | — | — |
| release-latency200 | Release | — | — | — |
| orders | Release | 102 samples: 1.18 / 1.90 / 2.16 ms | 102 samples: 0.03 / 0.06 / 0.09 ms | 102 samples: 3.80 / 5.11 / 6.95 ms |
| orders200 | Release | 26 samples: 1.44 / 2.75 / 6.03 ms | 26 samples: 0.03 / 0.06 / 0.09 ms | 26 samples: 4.98 / 7.86 / 20.45 ms |
| baseline | Debug | — | — | — |
| baseline-repeat | Debug | — | — | — |
| load1k | Debug | — | — | — |
| load10x | Debug | — | — | — |
| stress | Debug | — | — | — |
| latency200 | Debug | — | — | — |

### Targets and verdicts

The design has two targets. The p99 of `tickToRender` is to be at most 2 frames at about 1,000 updates a second or more;
it is judged on the 10x and stress runs, the ones that deliver that load. The p99 of `orderSubmitToAck` is to be at most
50 ms on loopback; it is judged on the `orders` run.

**The rule.** *p99 in frames* is the printed p99 times the run's printed Display fps, divided by 1,000, to two decimals.
A printed percentile is the upper edge of a histogram bucket, up to 3.125 % (a factor of 1.03125) above the true value.
A `tickToRender` verdict therefore has three states: **met** when p99 in frames is at most 2.00; **not met** when p99 in
frames divided by 1.03125 is above 2.00; **at the limit** in between, where the true p99 may be on either side of the
target. A row at the limit is not called met. The `orderSubmitToAck` verdict has two states: **met** when the printed
p99 is at most 50 ms, **not met** when it is above.

**What a verdict on the first target says.** `tickToRender` ends at a display refresh, so it contains the wait for the
next display-link step and the refresh itself: by construction its median is about 1.5 frames and its p99 about 2 frames
at 60 Hz, which is where the target is. A run that keeps up with the display therefore prints a p99 near 2 frames, a row
can land within one bucket of the target (it is then at the limit), and "met" says that the run kept up with the
display, not that it beat the target by a margin.

`tickToRender`, p99 at most 2 frames:

| Run | Build | Updates/s sent | p99 (ms) | p99 in frames | Clamped | Verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| release-load10x | Release | 922 | 32.51 | 1.95 | 0 of 1,871 (0.00 %) | met |
| release-stress | Release | 1,894 | 32.51 | 1.95 | 0 of 2,719 (0.00 %) | met |
| load10x | Debug | 922 | 32.51 | 1.95 | 0 of 1,896 (0.00 %) | met |
| stress | Debug | 1,894 | 32.51 | 1.95 | 0 of 2,017 (0.00 %) | met |

Clamped: how many of the run's `tickToRender` samples were clamped, of how many, and their share. What that is, and
where it came from, is in "What `clamped` shows" in `docs/results/summary.md`.

`orderSubmitToAck`, p99 at most 50 ms:

| Run | Build | Samples | p99 (ms) | Verdict |
| --- | --- | ---: | ---: | --- |
| orders | Release | 102 | 2.16 | met |
<!-- tables:end -->

The verdicts above follow the printed numbers by the rule written with them; the full discussion is in
`docs/results/summary.md`. All four rows the first target is judged on are met: the printed p99 is 1.95 frames in each,
and no sample is clamped. By construction that is close to the target, so those rows say that the app keeps up with the
display, not that it beats the target by a margin. The `orderSubmitToAck` target is met by a wide margin: a p99 of 2.16 ms
against 50 ms.

The rate the lab asks for is not the rate a client receives: the server merges the ticks of a connection into frames, so
at 4.2x, where the lab asks for 1,008 ticks a second, a connection receives 634 updates a second. The highest rate
the server accepts, 10x, delivers 922 a second, which is why the target is judged on the 10x and stress runs. The runs with
200 ms injected have no target: the profile throttles the feed to about 5 frames a second and adds its delay to every
tick. The same Debug setting run twice (`baseline` and `baseline-repeat`) printed a p99 of 33.03 and 32.51 ms, one
histogram bucket apart, so one 30-second run is one sample of its setting.

How to read the numbers:

- **Percentiles.** p50, p95 and p99 are nearest-rank percentiles of a histogram. A printed value is the upper edge of a
  histogram bucket, up to 3.125 % above the true value, so a true p99 just under a target could print as a miss: the
  verdict on `tickToRender` has a third state, "at the limit", for that.
- **`tickToApp`, `tickToApplied`, `tickToRender`.** From the server's stamp on a frame (taken just before it is sent) to the
  frame being received, to its update being applied to the market state, and to the first display refresh at or after the
  moment the frame that holds the tick was prepared or drawn. `tickToApp` does not include the up to 5 ms the server
  spends batching a frame. `tickToRender` is an estimate worked out from the display link, not a measurement of the GPU
  or of the screen. It contains the wait for the next display-link step and the refresh itself, so by construction its
  median is about 1.5 frames and its p99 about 2 frames at 60 Hz (16.7 ms a frame): in the tables its p50 is 23.59 to
  27.26 ms and its p99 31.98 to 33.03 ms in the ten runs without injected latency.
- **`orderSubmitToAck`, `orderServerProcessing`, `orderSubmitToFill`.** From just before the app calls `SubmitOrder` to its
  response, the server's own processing time that comes back with the response, and from the same start to the fill event
  arriving on the stream. The app submits no order by itself: these are empty ("—", never 0 ms) in a run that sent none.
  The orders of the `orders` and `orders200` runs were sent by hand through the ticket.
- **`clamped`.** A `tickToRender` sample below 0 (a render time that lies before the server's own stamp on the tick it
  shows) or above 10 seconds. It is counted apart and a negative one enters the distribution as 0, so it cannot lower a
  percentile unseen. No `tickToRender` sample is clamped in any run here. An earlier version of the app clamped a large
  share of them; what that was and how it was fixed is in "What `clamped` shows" in `docs/results/summary.md`.
- **Hitches.** A display-link interval above 1.5 times the frame time. Frames and hitches are counted only while the app
  is in the foreground.

## Screenshots

All of them except `11-ios18-smoke` are of the `iPhone 18 Pro` simulator (iOS 27.2, light mode unless noted) against the
real server, in `docs/results/screens/`. `11-ios18-smoke` is of an `iPhone 16 Pro` simulator on iOS 18.6 (see Minimum OS).
The two reconnect pictures with the banner are frames of screen recordings, because a screenshot takes about half a
second to write and the banner is gone by then.

| | | |
| --- | --- | --- |
| <img src="docs/results/screens/01-watchlist.png" width="200" alt="Watchlist"><br>`01-watchlist`: the Market tab: the watchlist with live prices. | <img src="docs/results/screens/02-chart-latency-chip.png" width="200" alt="Chart with the latency chip"><br>`02-chart-latency-chip`: a symbol's live candle chart with its volume bars, the Buy and Sell buttons and the latency chip. | <img src="docs/results/screens/03-market-order-filled.png" width="200" alt="Market order filled"><br>`03-market-order-filled`: the ticket after a market buy: the order reads Filled. |
| <img src="docs/results/screens/03-portfolio-after-fill.png" width="200" alt="Portfolio after the fill"><br>`03-portfolio-after-fill`: Portfolio after that fill: the cash, the position and the transaction with its commission. | <img src="docs/results/screens/04-limit-open.png" width="200" alt="Limit order open"><br>`04-limit-open`: a limit buy below the market rests as Open, with a Cancel button. | <img src="docs/results/screens/05-limit-cancelled.png" width="200" alt="Limit order cancelled"><br>`05-limit-cancelled`: the same order after Cancel: Cancelled. |
| <img src="docs/results/screens/06-order-rejected.png" width="200" alt="Order rejected"><br>`06-order-rejected`: a buy for more than the cash: the ticket warns, the exchange rejects the order and says why. | <img src="docs/results/screens/07-reconnect.png" width="200" alt="Reconnect banner"><br>`07-reconnect`: the banner while both connections reconnect, both connection rows reading "Reconnecting, attempt 1" (a frame of a screen recording). The drop was triggered by `POST /v1/admin/drop-connections` sent from the shell, not by a tap on the button. | <img src="docs/results/screens/07-reconnect-button.png" width="200" alt="Reconnect banner, from the button"><br>`07-reconnect-button`: the banner when the drop comes from a tap on the Lab's own Drop connections button (a frame of a screen recording). |
| <img src="docs/results/screens/07-reconnect-after.png" width="200" alt="After the reconnect"><br>`07-reconnect-after`: after the reconnect: both connections Connected and the account check Consistent. | <img src="docs/results/screens/08-lab-table.png" width="200" alt="Lab"><br>`08-lab-table`: the top of the Lab: connections, the latency table, the frame rate and the account check. | <img src="docs/results/screens/09-lab-stress.png" width="200" alt="Lab with Stress on"><br>`09-lab-stress`: the top of the Lab while the server runs Stress: the latency table keeps counting. The switch that turns Stress on is in `09-lab-stress-toggle`. |
| <img src="docs/results/screens/09-lab-stress-toggle.png" width="200" alt="Stress switch"><br>`09-lab-stress-toggle`: the Lab's controls with the Stress switch on. | <img src="docs/results/screens/10-chart-dark.png" width="200" alt="Chart in dark mode"><br>`10-chart-dark`: the chart in dark mode. | <img src="docs/results/screens/11-ios18-smoke.png" width="200" alt="iOS 18.6 smoke test"><br>`11-ios18-smoke`: the ticket after a market buy of 100 shares, on an iPhone 16 Pro simulator with iOS 18.6, from the unmodified Debug app (see Minimum OS). |

## Minimum OS

The deployment target is iOS 18.0. The oldest runtime installed on the Mac this was made on is iOS 18.6, so the check was
made there, on an `iPhone 16 Pro` simulator with the real server. The details are in
[`docs/results/summary.md`](docs/results/summary.md).

- **The unmodified Debug and Release apps start and work on iOS 18.6.** Both were installed as `make app` and
  `make app-release` built them, with nothing changed and nothing signed again. Each one launched, its prices moved, PTT
  opened from the watchlist and a market buy of 100 shares ended Filled; the server's account held 100 shares more after
  each buy. `11-ios18-smoke.png` is a picture of the Debug app's ticket after that buy.
- **A launch failure that the measurement found is fixed.** An earlier build quit at launch on iOS 18.6: dyld reported
  `Library not loaded: @rpath/libswiftCompatibilitySpan.dylib`, a Swift back-deployment library that the app linked and
  did not embed. The build now passes `--back-deploy-swift-span` to Xcode's library-copy step
  (`OTHER_SWIFT_STDLIB_TOOL_FLAGS` in `App/project.yml`), which puts the library into the app's `Frameworks`.
- **The build needs Xcode 27.2, which is what was tested.** That flag belongs to Xcode's own tool and was tried on Xcode
  27.2 only; why Xcode does not pass it by itself for an iOS 18.0 target is not established.
- **The keyboard fault appears on iOS 18.6.** In both apps SwiftUI logged one fault, "Invalid frame dimension (negative or
  non-finite)", when the keyboard first came up in the ticket, and one more when the ticket was closed after that. The
  ticket went on working. Its cause is not established.
- No latency figure was taken on iOS 18.6, and no other iOS version was tried.

## Known limitations

Build

- The build needs Xcode 27.2, which is what was tested: the unmodified apps start on iOS 18.6 because of a flag that
  belongs to Xcode's own library-copy step (see Minimum OS), and that flag was tried on Xcode 27.2 only. The apps ran on
  iOS 27.2, where everything here was measured, and on iOS 18.6; no other version was tried.

Measurement

- Loopback only, as above. A percentile is a bucket's upper edge, up to 3.125 % high.
- `tickToRender` is an estimate worked out from the display link, not a measurement of the GPU or of the screen, and it
  contains the wait for the next display-link step and the refresh itself (see "How to read the numbers"). Its p99 is
  about 2 frames at 60 Hz by construction, which is where the target is.
- `tickToApp` starts at the server's stamp taken just before a frame is sent, so the up to 5 ms the server spends batching
  frames is not in it.
- `--print-latency` prints its first line 5 seconds after the launch. The frame and hitch counts run only while the app
  is in the foreground, and the frame-rate meter in the Lab shows "—" for its first sample after a return to the Lab.
- With 200 ms injected, the display link's hitches are 6.42 % of the frames in `release-latency200` and 6.37 % in
  `orders200`, against 0.07 to 0.84 % in the other Release runs; the Debug run with the same setting, `latency200`, has
  0.34 %. The cause was not established.

Server

- Its state is in memory. A restarted server process starts order ids again at O-000001 and puts the lab settings back to
  their defaults. A cancel for an order of the old process that reaches the new one before the app has seen the new epoch
  could hit a new order (the app drops the old rows on an epoch change and never retries a cancel after a reconnect).
- The cash figure after an epoch change stays the old one until the next ledger entry or the next fetch on connect.
- Orders older than the server's log retention are not shown after an app restart.
- An oversized body sent to the lab gets a bare 413. The server stops hard on a signal, with no graceful drain.
- One server test, `GrpcOrderTests.grpcShutdownBeforeServeReturns`, fails now and then with a start-up stall when about a
  hundred tests build a full market at once. It passed in the `make test` run recorded in `docs/results/summary.md`.

Feed

- The lab's "Drop updates (creates gaps)" withholds every second update with the sequence still counting, so the client
  sees a gap and fetches a fresh state. It is a gap test and not a stall.
- A feed that stalls silently with both connections up is noticed only at the next tap and cannot be driven from the lab.
  Send is refused while the market data is more than 3 seconds old and comes back only with a frame that carries prices or
  a change of the market connection.
- The lab's latency, jitter and drop settings act on the market feed only, never on the order path. Injected latency delays
  every frame, one at a time, so it also throttles the feed: 200 ms gives about 5 frames a second.
- The Lab's rate slider covers 0.5x to 5x; the server accepts 0.1x to 10x, and the 10x runs were set through
  `Scripts/measure.sh`.

Chart

- A drag that starts diagonally and turns sideways later does not pan. A chart panned back shifts one candle for every new
  candle. A submit that races the nudge after a return from the background can take about 5 seconds.

Display

- Times are HH:mm:ss in the device's time zone. The app is iPhone-only and portrait-only. Its deployment target is iOS 18.0;
  it was run on iOS 18.6 and on iOS 27.2 (see Build).
- At text sizes above `large` the Lab's latency table gives way to per-metric groups, on every width. On the 375 and 390
  point phones the longest metric name wraps to a second line in the table. At the largest accessibility size the Orders
  banner takes 42 % of the screen height until it is dismissed.
- The reconnect banner shows as soon as either connection is down: after Drop connections it was on screen for about a
  quarter of a second.
- The simulated prices are very volatile on purpose (moves of 10 % within minutes), so that something happens in two
  minutes.

Lab

- A finger that rests on the rate slider without moving is not seen as an edit, so if the server's settings change during
  such a press the thumb moves away under the finger. A drag is protected.
- A server that accepts connections and never answers leaves the Lab's controls dimmed, with no line of their own, for
  about 20 seconds before "Lab settings unavailable" shows; a dead server says so at once.
- At the largest accessibility size the Reset dialog is a narrow system popover (the title hyphenates, the message scrolls
  and the button wraps); it is reachable.

## Not in this version

TLS and certificate pinning, Face ID, authentication, a physical device, iPad (and Mac or Android), push notifications,
advanced chart indicators, and the App Store. There is also no real market data, no real money and no broker, now or
later: it is a simulation.

## Repository layout

```
App/                          the iOS app (SwiftUI, iPhone, portrait)
  TradePulse/                 its sources: views, view models, the latency printer
  TradePulseTests/            its tests
  project.yml                 the XcodeGen spec; TradePulse.xcodeproj is generated from it and tracked
Packages/TradeKit/            Swift package shared by the app, tested on macOS
  Proto/                      market.proto and trading.proto
  Sources/Contracts/          the generated Protobuf and gRPC code (tracked)
  Sources/TradeCore/          prices, candles, latency histograms, backoff, the clock offset estimate
  Sources/TradeNetworking/    the REST, WebSocket and gRPC clients, the market state, the order store
Server/                       Swift package: the mock exchange
  Sources/ExchangeCore/       the simulated market, matching, the ledger, the event log
  Sources/ExchangeServerKit/  the REST, WebSocket and gRPC server and the lab controls
  Sources/ExchangeServer/     the executable (`make server`)
Scripts/                      measure.sh and summarize.py
docs/superpowers/             the design specification and the implementation plan
docs/results/                 the measurements: *.jsonl, *.run.json, feed-probe.py and .json, screens/, summary.md
Makefile                      server, app, app-release, test, demo, stop
```

## Documents

- [`docs/superpowers/specs/2026-11-22-tradepulse-poc-design.md`](docs/superpowers/specs/2026-11-22-tradepulse-poc-design.md):
  the design specification (in Thai): goals, the two-minute demo, the architecture, the metrics and their targets.
- [`docs/superpowers/plans/2026-11-22-tradepulse-poc.md`](docs/superpowers/plans/2026-11-22-tradepulse-poc.md): the
  implementation plan.
- [`docs/results/summary.md`](docs/results/summary.md): the measurements in full, with the method, the run records, the
  two targets, the repeat of one run, the analysis of `clamped`, the walk through the demo and the minimum-OS check.
- [`docs/results/`](docs/results/): the raw result lines, the run records, the feed probe and the screenshots.
