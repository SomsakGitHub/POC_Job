# Measurements

SIMULATED DATA. The exchange is the mock server in `Server/`, every price, account and order is invented, and nothing in
these runs leaves the Mac. Every figure below is a number the app printed (or, for "Updates/s sent", a number a small
separate client counted), converted to milliseconds by `Scripts/summarize.py`. The tables and the verdicts on the two
targets are generated and are not typed in by hand; the README holds the same block.

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

`make test` runs the three suites in turn and stops at the first failure. The figures below are from its last run, made
once after the measurements on the code as it is now; it ended with exit code 0 and no failed test.

| Suite | Command | Tests passed |
| --- | --- | ---: |
| TradeKit | `swift test --package-path Packages/TradeKit` | 509 (three test runs: 248, 229 and 32) |
| Server | `swift test --package-path Server` | 388 (two test runs: 190 and 198) |
| App | `xcodebuild test -project App/TradePulse.xcodeproj -scheme TradePulse -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' -derivedDataPath build/DerivedData` | 601 in 46 suites |

That is 1,498 tests. The server's tests let at most three of them build a server, and with it a full simulated market,
at the same time, and the test of a gRPC shutdown that comes before the service starts waits up to a minute for it to
return. With that, `swift test --package-path Server` passed ten runs in a row on the final code, each taking 64 to 68
seconds of wall time.

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
seconds with 200 ms injected. The app submits no order by itself, so orders were sent by taps on the ticket in the
Simulator while each of those two runs was going: 102 market orders of 100 shares (76 buys and 26 sells) in `orders`
and 26 market buys of 100 shares in `orders200`.

`Updates/s sent` comes from `docs/results/feed-probe.py`, which opens its own market-feed connection, subscribes to every
symbol and counts frames and symbol updates for 10 seconds at each lab setting the runs used. It is a probe of the server,
run once and not repeated with the runs (the server has not changed since). It is one connection at another time than the
run's, so it is a cross-check of the load and not a part of any run.

## What the metrics are

The app keeps a histogram for each of these and prints the count, p50, p95 and p99 of each in every line.

- `tickToApp`: from the server's stamp on a frame of the market feed (taken just before the frame is sent) to the moment
  the app receives it. The up to 5 ms the server spends batching a frame is not in it.
- `tickToApplied`: from the same stamp to the moment the update has been applied to the app's market state.
- `tickToRender`: from the same stamp to the first display refresh at or after the moment the frame that holds the tick was
  prepared or drawn. The app works that refresh out from the display link (the due time of the newest frame and the
  frame length), and a stamp is never earlier than the clock when it was taken, so it is an estimate and not a
  measurement of the GPU or of the screen. It contains the wait for the next display-link step and the refresh itself:
  by construction its median is about 1.5 frames and its p99 about 2 frames at 60 Hz.
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
  this is a count of frames, not of updates. The probe counted frames too (`framesPerSecond` in
  `docs/results/feed-probe.json`): at the same lab setting the app's figure is 0.5 to 7.3 % higher than the probe's (that
  is worked out from this column and from the probe's file; the probe's figures are not in the tables).
- **Display fps** is the growth of the app's `frames` over the same seconds: the frames of the display link, counted while
  the app is in the foreground.
- **Samples, p50 / p95 / p99** are those of `tickToRender`, the time from the server's stamp on a tick to the first display
  refresh at or after the moment the frame that holds it was prepared or drawn (see "What the metrics are"), in
  milliseconds. A percentile is the upper edge of a histogram bucket, up to 3.125 % above the true value. The metric
  contains the wait for the next display-link step and the refresh itself, so by construction its median is about 1.5
  frames and its p99 about 2 frames at 60 Hz (16.7 ms a frame): in the ten runs without injected latency the p50 is 23.59
  to 27.26 ms and the p99 is 31.98 to 33.03 ms.
- **p99 in frames** is the printed p99 times the printed Display fps of the run, divided by 1,000, to two decimals, so that
  it can be repeated from a row. The verdicts at the end of the tables are worked out from it.
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

The order metrics are empty in every run that sent no order. The order-path runs are `orders` and `orders200`.

The run record, from `docs/results/<label>.run.json`:

<!-- runs:begin -->
| Run | Build | Seconds | JSON lines | Started (UTC) | CPU idle before the run (%) | CPU idle after the run (%) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| release-baseline | Release | 30 | 5 | 2026-11-26T07:50:57Z | 82.0 | 89.9 |
| release-load1k | Release | 30 | 6 | 2026-11-26T07:51:45Z | 86.9 | 92.6 |
| release-load10x | Release | 30 | 5 | 2026-11-26T07:52:37Z | 83.1 | 86.2 |
| release-stress | Release | 30 | 6 | 2026-11-26T07:53:29Z | 78.9 | 89.9 |
| release-latency200 | Release | 30 | 5 | 2026-11-26T07:54:19Z | 82.7 | 93.8 |
| orders | Release | 240 | 48 | 2026-11-26T07:55:25Z | 82.6 | 86.5 |
| orders200 | Release | 100 | 20 | 2026-11-26T07:59:55Z | 82.9 | 91.5 |
| baseline | Debug | 30 | 5 | 2026-11-26T07:45:02Z | 75.5 | 88.9 |
| baseline-repeat | Debug | 30 | 5 | 2026-11-26T07:46:35Z | 83.8 | 91.5 |
| load1k | Debug | 30 | 5 | 2026-11-26T07:47:28Z | 88.1 | 87.8 |
| load10x | Debug | 30 | 5 | 2026-11-26T07:48:18Z | 85.0 | 92.4 |
| stress | Debug | 30 | 5 | 2026-11-26T07:49:10Z | 78.6 | 86.5 |
| latency200 | Debug | 30 | 6 | 2026-11-26T07:50:01Z | 86.1 | 91.3 |
<!-- runs:end -->

## The two targets

The verdicts are in the last part of the tables above ("Targets and verdicts"), with the rule they follow; the README holds
the same block. What goes with them is below. The targets are the design's: `tickToRender` p99 at most 2 frames (about
33 ms at 60 Hz) at about 1,000 updates a second, and `orderSubmitToAck` p99 at most 50 ms on loopback.

**`tickToRender`, at about 1,000 updates a second.** 4.2x does not deliver that load: it delivers 634 updates a second. The
10x runs deliver 922 and the stress runs 1,894, so the target is judged on those four runs (`release-load10x`,
`release-stress`, `load10x` and `stress`). All four are met: each prints a p99 of 32.51 ms, which is 1.95 frames, and none
has a clamped sample. None is at the limit, where the true p99 could be on either side of the line. A p99 near 2 frames
is what the metric gives by construction, so "met" here says that the app kept up with the display, not that it beat the
target by a margin.

Every other run without injected latency is below the target's load and is reported without a verdict: `release-baseline`,
`release-load1k` and `orders` on the Release build, and `baseline`, `baseline-repeat` and `load1k` on the Debug build.
Their p99 is from 31.98 ms (`load1k`, Debug) to 33.03 ms, from 1.92 to 1.98 frames. The p50 is 23.59 to 27.26 ms in all ten
runs without injected latency, about 1.5 frames: the tick waits for the next display-link step (half a frame on average)
and then for the refresh itself (one frame), which is how the metric is built.

The three runs with 200 ms injected (`release-latency200`, `orders200`, `latency200`) have no target. The profile throttles
the feed to about 5 frames a second and adds its delay to every tick, so their p50 of 230.69 ms is the 200 ms plus the
time a tick usually takes to reach the screen; it shows that the profile works and is not a miss.

**`orderSubmitToAck`, on loopback.** On the `orders` run (Release, 102 samples) the p50 is 1.18 ms, the p95
1.90 ms and the p99 2.16 ms: met, with the target at 50 ms. With that many samples the p99 is the second
slowest sample. The slowest was an early order: the first line that counted orders already printed a p99 of
`orderSubmitToFill` far above the final 6.95 ms, and that one sample does not show in the final p99 (the lines are in
`docs/results/orders.jsonl`). An early order probably pays for the first use of the order connection and its stream; that
was not tested. The server's own processing
time (`orderServerProcessing`) is 0.09 ms at the p99.

The `orders200` run has 26 samples, so its p99 is its slowest sample: 6.03 ms to the ack, with 200 ms
injected. The lab's latency, jitter and drop settings act on the market feed and not on the order path, and these numbers
agree: the acks are in single milliseconds, nowhere near 200 ms. That run is too short to say more than that.

## Spread between runs of the same setting

`baseline` and `baseline-repeat` are the same Debug run made twice in a row. Their p50 is 24.64 and 25.17 ms, their p95
31.46 and 31.46 ms and their p99 33.03 and 32.51 ms, so the p99 of two identical Debug runs was one histogram bucket
apart. Their hitches were 7 and 2. The Release runs have no repeat of one setting; the four Release tick runs without
injected latency (`release-baseline`, `release-load1k`, `release-load10x` and `release-stress`), at four different loads,
have p99 figures within one histogram bucket of each other (32.51 to 33.03 ms). A single 30-second run is one sample of
its setting.

## What `clamped` shows

A sample of `tickToRender` is clamped when it is below 0, a render time that lies before the server's own stamp on the tick
it shows, or above 10 s. The histogram records a negative one as 0 and counts it in `clamped`, so that the figure stays
visible and cannot lower a percentile unseen.

**What the first pass found.** The first pass of these measurements, before a fix to how the app stamps a render, found
12.6 % to 34.1 % of the `tickToRender` samples clamped in every run with a chart on screen and no latency injected (none
with 200 ms injected), at a steady rate from the first line of a run to the last. The cause was the stamp. The app stamped a
render with the display link's own target time, and the Simulator's display link calls back about 0.5 ms after that target,
so a tick that was applied between a step and the draw of the chart (about 2 ms later, in about 15 % of the frames) was
stamped before it had arrived. That is fixed: a render is now stamped with the first display refresh at or after the
moment it was worked out, on the display link's grid, and never earlier than the clock when it was taken. (The 0.5 ms and
the 15 % come from the analysis that led to the fix, not from these runs.)

**The same fix moved the whole distribution up by about one frame.** The first pass stamped a refresh that had already
gone by, because a frame cannot be on screen at a refresh that is past, so every sample was one refresh (16.7 ms) too
small: its p50 was 6.95 to 8.65 ms and its p99 15.73 to 25.17 ms, against 23.59 to 27.26 ms and 31.98 to 33.03 ms in the
ten runs without injected latency that were measured again on the fixed build and are tabulated above. These first-pass
figures appear here and nowhere else: the old result files were replaced by the new ones.

**After the fix.** No `tickToRender` sample is clamped in any of the 13 runs, at the first, the middle or the last line.
How the count grows in each run:

<!-- clamped:begin -->
| Run | Metric | Lines | First line: samples / clamped | Middle line: samples / clamped | Last line: samples / clamped | Clamped share at the last line | Clamped per second after the first line |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| release-baseline | tickToApp | 5 | 406 / 4 | 1,243 / 4 | 2,085 / 4 | 0.19 % | 0.0 |
| release-baseline | tickToApplied | 5 | 406 / 4 | 1,243 / 4 | 2,085 / 4 | 0.19 % | 0.0 |
| release-baseline | tickToRender | 5 | 314 / 0 | 975 / 0 | 1,643 / 0 | 0.00 % | 0.0 |
| release-load1k | tickToApp | 6 | 430 / 4 | 1,767 / 4 | 2,667 / 4 | 0.15 % | 0.0 |
| release-load1k | tickToApplied | 6 | 430 / 2 | 1,767 / 2 | 2,667 / 2 | 0.07 % | 0.0 |
| release-load1k | tickToRender | 6 | 352 / 0 | 1,453 / 0 | 2,178 / 0 | 0.00 % | 0.0 |
| release-load10x | tickToApp | 5 | 433 / 1 | 1,336 / 1 | 2,240 / 1 | 0.04 % | 0.0 |
| release-load10x | tickToApplied | 5 | 433 / 1 | 1,336 / 1 | 2,240 / 1 | 0.04 % | 0.0 |
| release-load10x | tickToRender | 5 | 359 / 0 | 1,121 / 0 | 1,871 / 0 | 0.00 % | 0.0 |
| release-stress | tickToApp | 6 | 810 / 5 | 3,347 / 5 | 5,047 / 5 | 0.10 % | 0.0 |
| release-stress | tickToApplied | 6 | 810 / 4 | 3,347 / 4 | 5,047 / 4 | 0.08 % | 0.0 |
| release-stress | tickToRender | 6 | 418 / 0 | 1,800 / 0 | 2,719 / 0 | 0.00 % | 0.0 |
| release-latency200 | tickToApp | 5 | 23 / 0 | 70 / 0 | 118 / 0 | 0.00 % | 0.0 |
| release-latency200 | tickToApplied | 5 | 23 / 0 | 70 / 0 | 118 / 0 | 0.00 % | 0.0 |
| release-latency200 | tickToRender | 5 | 23 / 0 | 70 / 0 | 118 / 0 | 0.00 % | 0.0 |
| orders | tickToApp | 48 | 399 / 3 | 10,392 / 3 | 19,940 / 3 | 0.02 % | 0.0 |
| orders | tickToApplied | 48 | 399 / 2 | 10,392 / 2 | 19,940 / 2 | 0.01 % | 0.0 |
| orders | tickToRender | 48 | 316 / 0 | 8,247 / 0 | 15,918 / 0 | 0.00 % | 0.0 |
| orders | orderSubmitToAck | 48 | 0 / 0 | 62 / 0 | 102 / 0 | 0.00 % | 0.0 |
| orders | orderServerProcessing | 48 | 0 / 0 | 62 / 0 | 102 / 0 | 0.00 % | 0.0 |
| orders | orderSubmitToFill | 48 | 0 / 0 | 62 / 0 | 102 / 0 | 0.00 % | 0.0 |
| orders200 | tickToApp | 20 | 23 / 0 | 261 / 0 | 476 / 0 | 0.00 % | 0.0 |
| orders200 | tickToApplied | 20 | 23 / 0 | 261 / 0 | 476 / 0 | 0.00 % | 0.0 |
| orders200 | tickToRender | 20 | 23 / 0 | 261 / 0 | 476 / 0 | 0.00 % | 0.0 |
| orders200 | orderSubmitToAck | 20 | 0 / 0 | 20 / 0 | 26 / 0 | 0.00 % | 0.0 |
| orders200 | orderServerProcessing | 20 | 0 / 0 | 20 / 0 | 26 / 0 | 0.00 % | 0.0 |
| orders200 | orderSubmitToFill | 20 | 0 / 0 | 20 / 0 | 26 / 0 | 0.00 % | 0.0 |
| baseline | tickToApp | 5 | 405 / 2 | 1,253 / 2 | 2,081 / 2 | 0.10 % | 0.0 |
| baseline | tickToApplied | 5 | 405 / 0 | 1,253 / 0 | 2,081 / 0 | 0.00 % | 0.0 |
| baseline | tickToRender | 5 | 312 / 0 | 987 / 0 | 1,650 / 0 | 0.00 % | 0.0 |
| baseline-repeat | tickToApp | 5 | 404 / 0 | 1,245 / 0 | 2,085 / 0 | 0.00 % | 0.0 |
| baseline-repeat | tickToApplied | 5 | 404 / 0 | 1,245 / 0 | 2,085 / 0 | 0.00 % | 0.0 |
| baseline-repeat | tickToRender | 5 | 299 / 0 | 965 / 0 | 1,638 / 0 | 0.00 % | 0.0 |
| load1k | tickToApp | 5 | 435 / 3 | 1,343 / 3 | 2,250 / 3 | 0.13 % | 0.0 |
| load1k | tickToApplied | 5 | 435 / 0 | 1,343 / 0 | 2,250 / 0 | 0.00 % | 0.0 |
| load1k | tickToRender | 5 | 343 / 0 | 1,077 / 0 | 1,805 / 0 | 0.00 % | 0.0 |
| load10x | tickToApp | 5 | 420 / 0 | 1,319 / 0 | 2,219 / 0 | 0.00 % | 0.0 |
| load10x | tickToApplied | 5 | 420 / 0 | 1,319 / 0 | 2,219 / 0 | 0.00 % | 0.0 |
| load10x | tickToRender | 5 | 356 / 0 | 1,124 / 0 | 1,896 / 0 | 0.00 % | 0.0 |
| stress | tickToApp | 5 | 827 / 0 | 2,512 / 0 | 4,201 / 0 | 0.00 % | 0.0 |
| stress | tickToApplied | 5 | 827 / 0 | 2,512 / 0 | 4,201 / 0 | 0.00 % | 0.0 |
| stress | tickToRender | 5 | 383 / 0 | 1,199 / 0 | 2,017 / 0 | 0.00 % | 0.0 |
| latency200 | tickToApp | 6 | 23 / 0 | 95 / 0 | 142 / 0 | 0.00 % | 0.0 |
| latency200 | tickToApplied | 6 | 23 / 0 | 95 / 0 | 142 / 0 | 0.00 % | 0.0 |
| latency200 | tickToRender | 6 | 23 / 0 | 94 / 0 | 142 / 0 | 0.00 % | 0.0 |
<!-- clamped:end -->

What the data show:

- `tickToRender` has no clamped sample, in any run: the share is 0 at every line, in the Debug and the Release build, at
  every load, with and without latency injected. The verdict rows say the same for the four runs the first target is
  judged on.
- `tickToApp` and `tickToApplied` have at most 5 clamped samples in a run (at most 0.19 %), all of them already in the
  first line of the run: the last column reads 0.0 in every row. The first seconds of a run are where the clock-offset
  estimate is still settling, which would fit; that was not tested. The order metrics have none.

## Things that look odd, and what was made of them

- No run had a fully idle machine: 75.5 to 88.1 % of the CPU was idle just before the runs and 86.2 to 93.8 % just after
  them (the whole machine, as `top` reports it; see the run record above).
- With 200 ms injected the display frame rate is 56.3 fps in the two Release runs (`release-latency200` and `orders200`)
  and 59.7 fps in the Debug run, and the hitches are 6.42 % and 6.37 % of the frames in the two Release runs, against 0.34 %
  in the Debug run (`latency200`) and 0.07 to 0.84 % in the other Release runs. The cause was not established: the feed
  delivers about five frames a second and the screen changes rarely in all three runs with 200 ms injected, but only the two
  Release runs have the hitches.
- Without injected latency the hitches are 0.07 % to 0.84 % of the frames. The highest are `orders` (120 in 14,266, 0.84 %;
  orders were sent by taps on the ticket in the Simulator during it) and `release-baseline` (10 in 1,479, 0.68 %). The
  cause was not established.
- The Debug `baseline` has 7 hitches in 1,481 frames (0.47 %) and `baseline-repeat` 2 in 1,486 (0.13 %): the same
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
was made there: an `iPhone 16 Pro` simulator against the real server, on loopback. It was made after everything above, and
it took no latency figures: it checks that the app starts and works, nothing more.

**The unmodified apps start and work on iOS 18.6.** The Debug app (`make app`, from `build/DerivedData`) and then the Release
app (`make app-release`, from `build/DerivedDataRelease`) were installed on the device as built: no copy, nothing changed,
nothing signed again. Each one:

- launched with no arguments, and its prices moved: the PTT line of the watchlist read 32.25 and then 33.75 in the Debug
  app, and 35.50 and then 36.00 in the Release app, within seconds, and the other symbols moved too;
- opened PTT from the watchlist (the live chart with its latency chip and the Buy and Sell buttons);
- took a market buy of 100 shares of PTT from the Buy ticket and showed it Filled, 100 / 100 at an average of 31.75 in the
  Debug app (`docs/results/screens/11-ios18-smoke.png` is a picture of that ticket) and 36.00 in the Release app; the
  server's account (`GET /v1/account`) held 100 shares of PTT more after each of the two buys;
- brought the keyboard up for the quantity field (with a Done button above the keypad) and put it away with Done.

No crash report was written for either run.

**A launch failure that this check found, and that is fixed.** Earlier builds of the app quit at launch on iOS 18.6: the
dynamic linker reported `Library not loaded: @rpath/libswiftCompatibilitySpan.dylib`, a Swift back-deployment library that
the app linked and did not embed. The build now passes `--back-deploy-swift-span` to Xcode's library-copy step
(`OTHER_SWIFT_STDLIB_TOOL_FLAGS` in `App/project.yml`), and that step puts `libswiftCompatibilitySpan.dylib` into the app's
`Frameworks` folder (both built apps have it there), so the unmodified apps start. **The build needs Xcode 27.2, which is
what was tested:** the flag belongs to Xcode's own tool and was tried on Xcode 27.2 only, and why Xcode does not pass it by
itself for an iOS 18.0 target is not established.

**The keyboard fault.** It appears on iOS 18.6, in both apps. `log show --last 5m --predicate 'eventMessage CONTAINS
"Invalid frame dimension"'` on the device lists lines of type Fault, from SwiftUI: "Invalid frame dimension (negative or
non-finite)". Each app logged one when the keyboard first came up in the ticket and one more when the ticket was closed
afterwards (in the Release app, the Done button alone logged none, and opening and closing the ticket without the keyboard
logged none). The ticket went on working: the keyboard was dismissed and the orders were sent and filled. Its cause is not
established.

What this check does not show: it is one pass by hand, on one device, with each build once; it took no latency figure, and
no other iOS version was tried (the apps ran on 27.2, where everything above was measured, and on 18.6).

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
