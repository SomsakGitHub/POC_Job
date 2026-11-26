# Measurements

SIMULATED DATA. The exchange is the mock server in `Server/`, every price, account and order is invented, and nothing in
these runs leaves the Mac. Every figure below is a number the app printed (or, for "Updates/s sent", a number a small
separate client counted), converted to milliseconds by `Scripts/summarize.py`. The tables are generated and are not typed
in by hand; the README holds the same tables.

## What was measured, and on what

| | |
| --- | --- |
| Machine | Apple M4 Pro, 14 cores, 24 GiB, macOS 26.7 |
| Toolchain | Xcode 27.2 (27B52), Swift 6.4.2 |
| App | TradePulse on an `iPhone 18 Pro` simulator, iOS 27.2, 402 x 874 points, light mode, text size `large` |
| Server | the exchange server built in release mode (`make server`), on the same Mac, reached over loopback (127.0.0.1: REST and WebSocket on 18080, gRPC on 18051) |
| Market | 12 simulated symbols; at rate 1x each one ticks about 20 times a second |
| Builds | Release (`make app-release`: optimised code) and Debug (`make app`, `make demo`: unoptimised code made for testing). Every run says which build it used |
| Day | 26 November 2026 (start times, in UTC, are in the run record below) |

Everything is measured on loopback on one Mac with the app in the iOS Simulator. The numbers show the cost of the app and
its pipeline. They do not show what a real network would add.

## Tests

`make test` runs the three suites in turn and stops at the first failure. It was run twice, once before the
measurements and once after them; both runs ended with exit code 0 and no failed test.

| Suite | Command | Tests passed |
| --- | --- | ---: |
| TradeKit | `swift test --package-path Packages/TradeKit` | 508 (three test runs: 247, 229 and 32) |
| Server | `swift test --package-path Server` | 388 (two test runs: 190 and 198) |
| App | `xcodebuild test -project App/TradePulse.xcodeproj -scheme TradePulse -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' -derivedDataPath build/DerivedData` | 584 in 46 suites |

That is 1,480 tests. One Server test, `GrpcOrderTests.grpcShutdownBeforeServeReturns`, is known to fail now and then with a
start-up stall when about a hundred tests build a full market at once. It passed in both runs, so no suite was repeated.

## How the runs were made

`Scripts/measure.sh <label> <rateMultiplier> <stress> <extraLatencyMs> <seconds>` sets the lab on the server, reads the
settings back (the server clamps what it is given, and the run is labelled with what the server confirmed), launches the
app on the simulator with `--print-latency --open-symbol PTT`, lets it run, terminates it and puts the lab back to its
defaults. The app prints one JSON line five seconds after it starts and one more every five seconds. Every line is
cumulative since the launch, so the last line of `docs/results/<label>.jsonl` is the run's result. `--open-symbol PTT` puts
a chart on screen, which is what gives `tickToRender` its samples. Every run starts from a fresh launch, so the first
connection and the clock-offset estimate are part of every run.

Runs of 30 seconds give five or six lines. A Release run installs the Release app first:

```
APP_PATH=build/DerivedDataRelease/Build/Products/Release-iphonesimulator/TradePulse.app \
  Scripts/measure.sh release-load10x 10 false 0 30
```

A Debug run does the same with `build/DerivedData/Build/Products/Debug-iphonesimulator/TradePulse.app`. The rate, the stress
mode and the injected latency of each run are in the "Lab setting" column; the build, the duration and the state of the
machine are in the run record. The `orders` run is a Release run of 240 seconds and `orders200` a Release run of 100
seconds with 200 ms injected. The app submits no order by itself, so orders were sent by hand through the ticket on the
simulator while each of those two runs was going: 102 market orders of 100 shares (76 buys and 26 sells) in `orders` and 25
market orders in `orders200`.

`Updates/s sent` comes from `docs/results/feed-probe.py`, which opens its own market-feed connection, subscribes to every
symbol and counts frames and symbol updates for 10 seconds at each lab setting the runs used. It is one connection at
another time than the run's, so it is a cross-check of the load and not a part of any run.

## What the metrics are

The app keeps a histogram for each of these and prints the count, p50, p95 and p99 of each in every line.

- `tickToApp`: from the server's stamp on a frame of the market feed (taken just before the frame is sent) to the moment
  the app receives it. The up to 5 ms the server spends batching a frame is not in it.
- `tickToApplied`: from the same stamp to the moment the update has been applied to the app's market state.
- `tickToRender`: from the same stamp to the display-link frame that draws the tick. It moves in steps of one display
  frame.
- `orderSubmitToAck`: from just before the app calls `SubmitOrder` to the response.
- `orderServerProcessing`: the server's own processing time of that call, returned in the response.
- `orderSubmitToFill`: from the same start to the fill event arriving on the order stream.
- `frames` and `hitches` count display-link frames and slow ones, and only while the app is in the foreground.

Times are wall-clock nanoseconds. The app corrects for the offset between its clock and the server's with an estimate
from request and response pings (the one with the shortest round trip is used), which is part of every run.

## Reading the tables

- **Ticks/s set** is what the lab asks the market to generate: symbols x 20 x rate, or symbols x 500 in stress mode. It is
  worked out from the settings the server confirmed and is not a measurement.
- **Updates/s sent** is the number of symbol updates a connection receives per second at that setting (the probe above).
  The server merges the ticks of a connection into frames and sends the newest quote of each symbol that changed, so this
  is lower than the ticks set: at 4.2x the lab asks for 1,008 ticks a second and a connection receives 634 updates a
  second. The highest rate the server accepts, 10x (the app's own slider stops at 5x), delivers 922 a second, and stress
  mode 1,894.
- **Feed frames/s** is what the app counted: the growth of the `tickToApp` count from the first line of a run to the last,
  over the seconds between their timestamps. The app records one `tickToApp` sample for every frame of the market feed, so
  this is a count of frames, not of updates. The probe counted frames too, and its frames a second agree with these
  within 6 %.
- **Display fps** is the growth of the app's `frames` over the same seconds: the frames of the display link, counted while
  the app is in the foreground.
- **Samples, p50 / p95 / p99** are those of `tickToRender`, the time from the server's stamp on a tick to the display-link
  frame that draws it, in milliseconds. A percentile is the upper edge of a histogram bucket, up to 3.125 % above the true
  value. The display link moves in steps of one frame (16.7 ms at 60 Hz), so a p99 of about one frame is close to the
  least this method can show.
- **p99 in frames** is that p99 divided by the time one display frame takes at the run's own Display fps.
- **Clamped** is the number of `tickToRender` samples that were below 0 or above 10 s, and its share of the samples. A
  negative sample enters the distribution as 0. `Samples` already includes the clamped samples, so the share is clamped
  divided by samples. A dash is a metric with no samples, never 0.
- **Hitches / frames**: a hitch is a display-link interval above 1.5 times the frame time; the share is of the frames
  counted.

## Results

<!-- tables:begin -->
### Tick to render, Release build (`make app-release`)

| Run | Lab setting | Ticks/s set | Updates/s sent | Feed frames/s | Display fps | Samples | p50 / p95 / p99 (ms) | p99 in frames | Clamped | Hitches / frames |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| release-baseline | rate 1x | 240 | 211 | 80.2 | 59.9 | 1,984 | 7.73 / 14.68 / 15.99 | 1.0 | 302 (15.22 %) | 1 / 1,787 (0.06 %) |
| release-load1k | rate 4.2x | 1,008 | 634 | 87.1 | 60.0 | 2,145 | 7.34 / 14.42 / 15.73 | 0.9 | 372 (17.34 %) | 1 / 1,789 (0.06 %) |
| release-load10x | rate 10x | 2,400 | 922 | 86.9 | 60.0 | 2,129 | 7.73 / 14.68 / 15.73 | 0.9 | 326 (15.31 %) | 0 / 1,790 (0.00 %) |
| release-stress | stress | 6,000 | 1,894 | 166.2 | 60.0 | 2,704 | 8.65 / 14.42 / 15.73 | 0.9 | 909 (33.62 %) | 0 / 1,787 (0.00 %) |
| release-latency200 | rate 1x, +200 ms | 240 | 56 | 4.8 | 57.2 | 142 | 218.10 / 234.88 / 239.08 | 13.7 | 0 | 77 / 1,714 (4.49 %) |
| orders | rate 1x | 240 | 211 | 79.4 | 59.8 | 15,815 | 7.73 / 14.94 / 16.25 | 1.0 | 2,450 (15.49 %) | 44 / 14,352 (0.31 %) |
| orders200 | rate 1x, +200 ms | 240 | 56 | 4.7 | 56.3 | 475 | 218.10 / 234.88 / 239.08 | 13.5 | 0 | 359 / 5,637 (6.37 %) |

### Tick to render, Debug build (`make app`, `make demo`)

| Run | Lab setting | Ticks/s set | Updates/s sent | Feed frames/s | Display fps | Samples | p50 / p95 / p99 (ms) | p99 in frames | Clamped | Hitches / frames |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| baseline | rate 1x | 240 | 211 | 82.4 | 59.2 | 1,980 | 8.00 / 15.73 / 25.17 | 1.5 | 284 (14.34 %) | 20 / 1,770 (1.13 %) |
| baseline-repeat | rate 1x | 240 | 211 | 82.8 | 59.8 | 1,651 | 7.73 / 14.94 / 18.35 | 1.1 | 256 (15.51 %) | 6 / 1,485 (0.40 %) |
| load1k | rate 4.2x | 1,008 | 634 | 88.9 | 60.0 | 2,080 | 8.13 / 14.68 / 23.07 | 1.4 | 263 (12.64 %) | 2 / 1,792 (0.11 %) |
| load10x | rate 10x | 2,400 | 922 | 87.0 | 60.0 | 2,221 | 6.95 / 13.89 / 15.99 | 1.0 | 445 (20.04 %) | 1 / 1,787 (0.06 %) |
| stress | stress | 6,000 | 1,894 | 168.5 | 60.0 | 2,261 | 8.65 / 14.68 / 15.73 | 0.9 | 770 (34.06 %) | 2 / 1,486 (0.13 %) |
| latency200 | rate 1x, +200 ms | 240 | 56 | 4.7 | 56.5 | 118 | 218.10 / 239.08 / 239.08 | 13.5 | 0 | 85 / 1,413 (6.02 %) |

### Order path, every run

Each cell: the number of samples, then p50 / p95 / p99 in milliseconds.

| Run | Build | Submit to ack | Server processing | Submit to fill |
| --- | --- | --- | --- | --- |
| release-baseline | Release | — | — | — |
| release-load1k | Release | — | — | — |
| release-load10x | Release | — | — | — |
| release-stress | Release | — | — | — |
| release-latency200 | Release | — | — | — |
| orders | Release | 102 samples: 1.21 / 1.74 / 2.69 ms | 102 samples: 0.03 / 0.07 / 0.12 ms | 102 samples: 3.93 / 4.85 / 6.82 ms |
| orders200 | Release | 25 samples: 1.41 / 3.15 / 4.59 ms | 25 samples: 0.03 / 0.05 / 0.05 ms | 25 samples: 4.59 / 11.27 / 13.11 ms |
| baseline | Debug | — | — | — |
| baseline-repeat | Debug | — | — | — |
| load1k | Debug | — | — | — |
| load10x | Debug | — | — | — |
| stress | Debug | — | — | — |
| latency200 | Debug | — | — | — |
<!-- tables:end -->

The order metrics are empty in every run that sent no order. The order-path runs are `orders` and `orders200`.

The run record, from `docs/results/<label>.run.json`:

<!-- runs:begin -->
| Run | Build | Seconds | JSON lines | Started (UTC) | CPU idle before the run (%) | CPU idle after the run (%) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| release-baseline | Release | 30 | 6 | 2026-11-26T05:08:31Z | 84.6 | 4.5 |
| release-load1k | Release | 30 | 6 | 2026-11-26T05:10:00Z | 75.7 | 95.9 |
| release-load10x | Release | 30 | 6 | 2026-11-26T05:35:00Z | 82.6 | 92.4 |
| release-stress | Release | 30 | 6 | 2026-11-26T05:10:48Z | 75.9 | 86.6 |
| release-latency200 | Release | 30 | 6 | 2026-11-26T05:11:34Z | 82.4 | 89.7 |
| orders | Release | 240 | 48 | 2026-11-26T05:13:37Z | 86.9 | 85.2 |
| orders200 | Release | 100 | 20 | 2026-11-26T05:18:27Z | 81.2 | 93.9 |
| baseline | Debug | 30 | 6 | 2026-11-26T05:01:35Z | 70.5 | 86.3 |
| baseline-repeat | Debug | 30 | 5 | 2026-11-26T05:04:54Z | 86.3 | 90.5 |
| load1k | Debug | 30 | 6 | 2026-11-26T05:02:23Z | 78.9 | 82.3 |
| load10x | Debug | 30 | 6 | 2026-11-26T05:35:49Z | 83.2 | 90.2 |
| stress | Debug | 30 | 5 | 2026-11-26T05:03:11Z | 82.8 | 95.7 |
| latency200 | Debug | 30 | 5 | 2026-11-26T05:04:03Z | 75.7 | 95.4 |
<!-- runs:end -->

## The two targets

The targets are the design's: `tickToRender` p99 at most 2 frames (about 33 ms at 60 Hz) at about 1,000 updates a second,
and `orderSubmitToAck` p99 at most 50 ms on loopback. A verdict follows the printed number. A percentile is a bucket's
upper edge, so a true p99 just under a target can print as a miss; none of the numbers below is close enough to a target
for that to matter.

**`tickToRender`, at about 1,000 updates a second.** 4.2x does not deliver that load: it delivers 634 updates a second. The
10x runs deliver 922 and the stress runs 1,894, so the target is judged on those four runs.

| Run | Updates/s sent | p99 | In frames | Verdict |
| --- | ---: | ---: | ---: | --- |
| `release-load10x` | 922 | 15.73 ms | 0.9 | met |
| `load10x` (Debug) | 922 | 15.99 ms | 1.0 | met |
| `release-stress` | 1,894 | 15.73 ms | 0.9 | met |
| `stress` (Debug) | 1,894 | 15.73 ms | 0.9 | met |

Every other run without injected latency is below the target's load and is reported without a target. Its p99 is also under
33 ms: from 15.73 ms (`release-load1k`) to 16.25 ms (`orders`) on the Release build, and from 18.35 ms
(`baseline-repeat`) to 25.17 ms (`baseline`, 1.5 frames, 7.83 ms under the line) on the Debug build. The p50 is
6.95 to 8.65 ms in all ten runs without injected latency, about half a frame, which is what a tick that arrives at a random
moment would wait for the next display-link frame (an explanation that fits the figures and was not tested on its own).

The three runs with 200 ms injected (`release-latency200`, `orders200`, `latency200`) have no target. The profile throttles
the feed to about 5 frames a second and adds its delay to every tick, so their p50 of 218.10 ms is the 200 ms plus the
usual wait for a frame; it shows that the profile works and is not a miss.

**`orderSubmitToAck`, on loopback.** On the `orders` run (Release, 102 samples) the p50 is 1.21 ms, the p95
1.74 ms and the p99 2.69 ms: met, with the target at 50 ms. With that many samples the p99 is the second
slowest sample. The slowest was the first order of the run: its ack took at most 4.00 ms and its fill at most
42.99 ms (the first line that counted it printed those figures), where the p99 of `orderSubmitToFill` without it is
6.82 ms. A first order probably pays for the first use of the order connection and its stream; that was not tested. The
server's own processing time (`orderServerProcessing`) is 0.12 ms at the p99.

The `orders200` run has 25 samples, so its p99 is its slowest sample: 4.59 ms to the ack, with 200 ms
injected. The lab's latency, jitter and drop settings act on the market feed and not on the order path, and these numbers
agree: the acks are in single milliseconds, nowhere near 200 ms. That run is too short to say more than that.

## Spread between runs of the same setting

`baseline` and `baseline-repeat` are the same Debug run made twice in a row. Their p50 is 8.00 and 7.73
ms, their p95 15.73 and 14.94 ms and their p99 25.17 and 18.35 ms, so the p99 of two
identical Debug runs was 6.82 ms apart (0.4 of a frame). Their hitches were 20 and 6. The Release
runs have no repeat of one setting; the four Release tick runs, at four different loads, have p99 figures within
0.26 ms of each other (15.73 to 15.99 ms). A single 30-second run is one sample of its setting, and the Debug build
in particular varies from run to run.

## What `clamped` shows

A sample of `tickToRender` below 0 is a frame time that lies before the server's own stamp on the tick it shows. The
histogram records it as 0 and counts it in `clamped`, so that the figure stays visible and cannot lower a percentile
unseen. How the count grows in each run:

<!-- clamped:begin -->
| Run | Metric | Lines | First line: samples / clamped | Middle line: samples / clamped | Last line: samples / clamped | Clamped share at the last line | Clamped per second after the first line |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| release-baseline | tickToApp | 6 | 401 / 1 | 1,607 / 1 | 2,409 / 1 | 0.04 % | 0.0 |
| release-baseline | tickToApplied | 6 | 401 / 1 | 1,607 / 1 | 2,409 / 1 | 0.04 % | 0.0 |
| release-baseline | tickToRender | 6 | 328 / 52 | 1,314 / 195 | 1,984 / 302 | 15.22 % | 10.0 |
| release-load1k | tickToApp | 6 | 406 / 5 | 1,711 / 5 | 2,587 / 5 | 0.19 % | 0.0 |
| release-load1k | tickToApplied | 6 | 406 / 4 | 1,711 / 4 | 2,587 / 4 | 0.15 % | 0.0 |
| release-load1k | tickToRender | 6 | 343 / 59 | 1,424 / 247 | 2,145 / 372 | 17.34 % | 12.5 |
| release-load10x | tickToApp | 6 | 405 / 1 | 1,708 / 1 | 2,581 / 1 | 0.04 % | 0.0 |
| release-load10x | tickToApplied | 6 | 405 / 0 | 1,708 / 0 | 2,581 / 0 | 0.00 % | 0.0 |
| release-load10x | tickToRender | 6 | 331 / 40 | 1,416 / 219 | 2,129 / 326 | 15.31 % | 11.4 |
| release-stress | tickToApp | 6 | 825 / 8 | 3,316 / 8 | 4,984 / 8 | 0.16 % | 0.0 |
| release-stress | tickToApplied | 6 | 825 / 5 | 3,316 / 5 | 4,984 / 5 | 0.10 % | 0.0 |
| release-stress | tickToRender | 6 | 422 / 129 | 1,801 / 606 | 2,704 / 909 | 33.62 % | 31.2 |
| release-latency200 | tickToApp | 6 | 23 / 0 | 94 / 0 | 142 / 0 | 0.00 % | 0.0 |
| release-latency200 | tickToApplied | 6 | 23 / 0 | 94 / 0 | 142 / 0 | 0.00 % | 0.0 |
| release-latency200 | tickToRender | 6 | 23 / 0 | 94 / 0 | 142 / 0 | 0.00 % | 0.0 |
| orders | tickToApp | 48 | 366 / 4 | 9,843 / 4 | 19,049 / 4 | 0.02 % | 0.0 |
| orders | tickToApplied | 48 | 366 / 4 | 9,843 / 4 | 19,049 / 4 | 0.02 % | 0.0 |
| orders | tickToRender | 48 | 312 / 43 | 8,185 / 1,263 | 15,815 / 2,450 | 15.49 % | 10.2 |
| orders | orderSubmitToAck | 48 | 0 / 0 | 53 / 0 | 102 / 0 | 0.00 % | 0.0 |
| orders | orderServerProcessing | 48 | 0 / 0 | 53 / 0 | 102 / 0 | 0.00 % | 0.0 |
| orders | orderSubmitToFill | 48 | 0 / 0 | 53 / 0 | 102 / 0 | 0.00 % | 0.0 |
| orders200 | tickToApp | 20 | 23 / 0 | 261 / 0 | 475 / 0 | 0.00 % | 0.0 |
| orders200 | tickToApplied | 20 | 23 / 0 | 261 / 0 | 475 / 0 | 0.00 % | 0.0 |
| orders200 | tickToRender | 20 | 23 / 0 | 261 / 0 | 475 / 0 | 0.00 % | 0.0 |
| orders200 | orderSubmitToAck | 20 | 0 / 0 | 7 / 0 | 25 / 0 | 0.00 % | 0.0 |
| orders200 | orderServerProcessing | 20 | 0 / 0 | 7 / 0 | 25 / 0 | 0.00 % | 0.0 |
| orders200 | orderSubmitToFill | 20 | 0 / 0 | 7 / 0 | 25 / 0 | 0.00 % | 0.0 |
| baseline | tickToApp | 6 | 404 / 2 | 1,643 / 2 | 2,469 / 2 | 0.08 % | 0.0 |
| baseline | tickToApplied | 6 | 404 / 1 | 1,643 / 1 | 2,469 / 1 | 0.04 % | 0.0 |
| baseline | tickToRender | 6 | 309 / 33 | 1,312 / 186 | 1,980 / 284 | 14.34 % | 10.0 |
| baseline-repeat | tickToApp | 5 | 402 / 5 | 1,235 / 5 | 2,063 / 5 | 0.24 % | 0.0 |
| baseline-repeat | tickToApplied | 5 | 402 / 3 | 1,235 / 3 | 2,063 / 3 | 0.15 % | 0.0 |
| baseline-repeat | tickToRender | 5 | 307 / 34 | 977 / 141 | 1,651 / 256 | 15.51 % | 11.1 |
| load1k | tickToApp | 6 | 428 / 0 | 1,765 / 0 | 2,656 / 0 | 0.00 % | 0.0 |
| load1k | tickToApplied | 6 | 428 / 0 | 1,765 / 0 | 2,656 / 0 | 0.00 % | 0.0 |
| load1k | tickToRender | 6 | 333 / 38 | 1,384 / 173 | 2,080 / 263 | 12.64 % | 9.0 |
| load10x | tickToApp | 6 | 408 / 0 | 1,719 / 0 | 2,585 / 0 | 0.00 % | 0.0 |
| load10x | tickToApplied | 6 | 408 / 0 | 1,719 / 0 | 2,585 / 0 | 0.00 % | 0.0 |
| load10x | tickToRender | 6 | 351 / 66 | 1,473 / 292 | 2,221 / 445 | 20.04 % | 15.1 |
| stress | tickToApp | 5 | 817 / 3 | 2,500 / 3 | 4,187 / 3 | 0.07 % | 0.0 |
| stress | tickToApplied | 5 | 817 / 0 | 2,500 / 0 | 4,187 / 0 | 0.00 % | 0.0 |
| stress | tickToRender | 5 | 432 / 143 | 1,342 / 451 | 2,261 / 770 | 34.06 % | 31.3 |
| latency200 | tickToApp | 5 | 23 / 0 | 70 / 0 | 118 / 0 | 0.00 % | 0.0 |
| latency200 | tickToApplied | 5 | 23 / 0 | 70 / 0 | 118 / 0 | 0.00 % | 0.0 |
| latency200 | tickToRender | 5 | 23 / 0 | 70 / 0 | 118 / 0 | 0.00 % | 0.0 |
<!-- clamped:end -->

What the data show:

- It is a property of `tickToRender` only. `tickToApp` and `tickToApplied` have at most 8 clamped samples in a run (at most
  0.24 %), and the order metrics none.
- It is not a start-up effect. In `release-baseline` 52 of the 328 samples at the first line (15.9 %) were clamped, 195 of
  1,314 (14.8 %) at the middle line and 302 of 1,984 (15.2 %) at the last. The `orders` run, which lasted four minutes, shows
  the same: 43 of 312 (13.8 %), 1,263 of 8,185 (15.4 %) and 2,450 of 15,815 (15.5 %). The count grows at a steady rate
  from the first line on.
- The share is similar in the Debug and Release builds at rate 1x (14.3 to 15.5 %), 15.3 % (Release) and 20.0 % (Debug) at
  10x, and about a third (33.6 % and 34.1 %) in stress mode, where the count grows by about 31 a second instead of about
  10. With 200 ms injected it is 0 in all three runs.
- A share above 5 % on the metric the first target uses is reported here as such: every run without injected latency is
  above it, from 12.6 % to 34.1 %.
- What it does to the figures: clamped samples enter at 0 ms, so they pull the p50 and the p95 down. They hardly move the
  p99. With a share s of samples at 0, the p99 of all samples is the (0.99 - s) / (1 - s) quantile of the others: the
  98.8th percentile of the unclamped samples at s = 15.2 %, and the 98.5th at s = 33.6 %. That is arithmetic, not a second
  measurement.
- The cause is not established. The data point at the render stamp and not at the feed, since the two earlier stamps are
  clean, but they do not say why about a seventh of the stamps lies before the tick's own. One explanation fits them and
  was not tested: a tick that is applied after the previous display-link step began is paired with that earlier step's
  due time.

## Things that look odd, and what was made of them

- `release-baseline` shows 4.5 % of the machine's CPU idle after the run (the figure was taken after the app had been
  terminated). Something other than the app was using the CPU at that moment: a look at the busiest processes right
  afterwards showed background system daemons at the top (usage statistics, storage management, indexing and a security
  agent), none of them part of the measurement. The run's own figures (p99 15.99 ms, 1 hitch in 1,787
  frames) do not differ from the runs next to it, so it was kept and not repeated. No run had a fully idle machine: 70.5 to
  86.9 % of the CPU was idle just before the runs.
- With 200 ms injected the display frame rate drops to 56.3 to 57.2 fps and the hitches rise to 4.49 % (Release), 6.02 %
  (Debug) and 6.37 % (`orders200`) of the frames, against 0.00 to 0.40 % in the other runs except the Debug `baseline`
  (1.13 %). The cause was not established: the feed then delivers about five frames a second, the screen changes rarely,
  and the display link may be paced less evenly when little is drawn.
- The Debug `baseline` has 20 hitches in 1,770 frames (1.13 %) and `baseline-repeat` 6 in 1,485 (0.40 %): the same
  setting and a different count, which is what the spread above is about.
- The rate the lab is asked for is not the rate a client receives (see "Reading the tables"): the ratio of 634 to 1,008 at
  4.2x is the server merging the ticks of a frame.

## The demo walk

The two-minute demo of the design was walked on the `iPhone 18 Pro` simulator against the real server, with the lab at its
defaults, and one screenshot was saved per row (`docs/results/screens/`). Every row behaved as the design says. What
the walk added to the figures above:

- The reconnect banner is on screen for about a quarter of a second after the lab's Drop connections. In a screen
  recording at the display's rate, with the button tapped through the Simulator, the banner was on screen in 14 frames in
  a row, from 3.967 s to 4.192 s of the recording, and gone in the next frame (4.225 s): it was up for at least 0.225 s and
  at most 0.258 s. A screenshot takes about half a second to write, so `07-reconnect.png` and
  `07-reconnect-button.png` are frames of two such recordings, and not screenshots. In the first the same request that the
  button sends (`POST /v1/admin/drop-connections`) was sent from the shell, so that the connection rows were on screen as
  well: both connections read "Reconnecting, attempt 1" while the banner was up. After the reconnect the Lab reads
  Connected for the market and for trading, the account check reads Consistent, and the sequence gap count is 0
  (`07-reconnect-after.png`).
- A bad order is stopped in two places. The ticket refuses a price off the tick ("The price is not a valid price step. A
  price must be a multiple of 0.25 at this price level.") and a quantity that is not a multiple of 100 ("The quantity
  must be a multiple of 100 shares.") before anything is sent: Send is off, the estimate reads a dash and the message
  says why. Cash and holdings are checked by the exchange: a market buy of
  1,000,000 shares is sent after the ticket warns that the estimate is more than the cash it knows of, and comes back
  Rejected with "There is not enough cash for this order." (`06-order-rejected.png`).
- The market order of `03-market-order-filled.png` and the rows of `03-portfolio-after-fill.png` agree: the transaction
  is 100 shares at 34.25 plus a commission of 5.14, and the cash is the starting cash less that amount.
- Switching Stress on and off in the Lab changes the server's settings and nothing else: after switching it off, the
  server's lab settings read their defaults again (`rateMultiplier` 1, `stress` false, no latency, no jitter, no dropped
  updates).

## Minimum OS: iOS 18.6

The deployment target of the app is iOS 18.0. The oldest runtime installed on this Mac is iOS 18.6 (build 22G86), so the check
was made there: an `iPhone 16 Pro` simulator against the real server of `make demo`, on loopback. It was made last, after
everything above, and it took no latency figures: it checks that the app starts and works, nothing more.

**The app as built here does not start on iOS 18.6.** The Debug build (`make app`) and the Release build (`make app-release`)
both quit at launch. Three crash reports were written (two for Debug, one for Release) and all three give the same reason,
from the dynamic linker: `Library not loaded: @rpath/libswiftCompatibilitySpan.dylib`. The linker looked for the file in the
runtime's `/usr/lib/swift` ("no such file, not in dyld cache") and in the app's own folders, and found it in none. What the
files show:

- Both binaries list `@rpath/libswiftCompatibilitySpan.dylib` as a dependency (`otool -L`: in `TradePulse.debug.dylib` for the
  Debug build and in `TradePulse` for the Release build). It is a back-deployment library that comes with Xcode's toolchain
  (`usr/lib/swift-6.2/iphonesimulator`).
- Neither built `TradePulse.app` has a `Frameworks/` folder, and the build setting `ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES`
  is `NO` for the app target.
- The same two builds run on the iOS 27.2 simulator that every measurement above was made on.

This is **not fixed**: the product code and the project settings are as they were.

To go on with the rest of the check, a scratch copy of the Debug app was made outside the repository: Xcode's own
`libswiftCompatibilitySpan.dylib` was copied into its `Frameworks/` folder and the bundle was signed again with an ad hoc
signature. Nothing else in it was changed. That copy started on iOS 18.6, and:

- the prices moved: the ticket's line for PTT read Last 34.25, then 32.00, then 33.50 within about two minutes;
- PTT opened from the watchlist, and its Buy ticket opened from the chart screen;
- a vertical swipe that started on the chart scrolled the screen, and a swipe back returned it;
- the keyboard came up for the quantity field (with a Done button above the keypad) and went away with Done;
- a market buy of 100 shares of PTT was sent and the order read Filled, 100 / 100 at an average of 32.75
  (`docs/results/screens/11-ios18-smoke.png` is a picture of that copy).

**The keyboard fault.** It appears on iOS 18.6. `log show --last 15m --predicate 'eventMessage CONTAINS "Invalid frame
dimension"'` on the device lists one line, of type Fault, from SwiftUI: "Invalid frame dimension (negative or non-finite)".
It is stamped 13:08:06, in the minute in which the keyboard first came up in the ticket (the status bar read 13:08 with the
keypad showing), and there is no second line in the 15 minutes the app ran. The ticket went on working: the keyboard was
dismissed and the order was sent and filled. Its cause is not established.

What this check does not show: it is one pass by hand, on one device, with the Debug copy and not the Release build, and no
other iOS version was tried (the builds ran on 27.2 and did not start on 18.6).

A likely fix is for the build to embed the library in the app (for example `ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES` set to
`YES` for the app target). It was not tried as a setting: only the copy of the file above was tried, and that shows that the
app runs on iOS 18.6 once the library is in its `Frameworks/` folder.

## Reproducing the tables

```
make server                                   # in one terminal; leave it running
make app-release                              # the Release build (`make app` is the Debug build)
APP_PATH=build/DerivedDataRelease/Build/Products/Release-iphonesimulator/TradePulse.app \
  Scripts/measure.sh my-run 10 false 0 30     # label, rate multiplier, stress, extra latency in ms, seconds
python3 -I docs/results/feed-probe.py 10      # Updates/s sent, at the five lab settings the runs use
python3 -I Scripts/summarize.py docs/results  # the tables above, with my-run added
```

A label that already exists is overwritten, so a new run gets a new label; in the tables a new label comes after the
runs recorded here for its build.

`python3 -I Scripts/summarize.py --check docs/results README.md docs/results/summary.md` prints nothing and exits 0 when
the generated blocks in both files are identical to what the script prints now.
