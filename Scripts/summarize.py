#!/usr/bin/env python3
"""Turn the latency runs in a results folder into markdown tables.

Usage:
    python3 -I Scripts/summarize.py docs/results
        Print the tables: one row per run, taken from the LAST line of docs/results/<label>.jsonl (every line is
        cumulative since the launch, so the last one is the run's result) and from docs/results/<label>.run.json, the
        record Scripts/measure.sh writes of the settings and the build the run used.

    python3 -I Scripts/summarize.py --clamped docs/results
        Print how the clamped counts grow inside each run: the first, the middle and the last line.

    python3 -I Scripts/summarize.py --runs docs/results
        Print the record of every run: its build, how long it ran, how many lines it kept, when it started and how
        much of the machine's CPU was idle just before and just after it.

    python3 -I Scripts/summarize.py --check docs/results FILE...
        Check that the block between <!-- tables:begin --> and <!-- tables:end --> in every FILE is exactly what this
        script prints now (and the same for <!-- clamped:begin --> and <!-- clamped:end -->, and for
        <!-- runs:begin --> and <!-- runs:end -->, where a FILE has them). Prints nothing and exits 0 when they are
        identical; otherwise prints the difference and exits 1.

Python 3 standard library only. Nothing here is rounded in the run's favour: a percentile is the number the app printed
in nanoseconds, shown in milliseconds with two decimals; "-" (an em dash) stands for a metric with no samples and for a
percentile the app printed as null, never 0.

What the columns are:
    Ticks/s set      what the lab asks the market to generate: symbols x 20 x rate, or symbols x 500 in stress mode.
                     It is worked out from the settings the server confirmed and is not a measurement.
    Updates/s sent   symbol updates per second that a separate client counted on its own market-feed connection at the
                     same lab setting (docs/results/feed-probe.json, written by docs/results/feed-probe.py). The server
                     merges the ticks of a connection into frames, so this is lower than Ticks/s set. It is another
                     connection at another time than the run's; a dash means no probe was made at that setting.
    Feed frames/s    what the app counted: the growth of the tickToApp count from the first line to the last, over the
                     seconds between their timestamps. The app records one tickToApp sample per frame of the market
                     feed, and a frame carries the newest quote of every symbol that changed since the previous frame,
                     so this is a count of frames, not of symbol updates.
    Display fps      the growth of `frames` (the display link's frames, counted while the app is in the foreground)
                     over the same seconds.
    p99 in frames    the p99 divided by the time one display frame takes at that Display fps.
"""

import difflib
import glob
import json
import os
import sys

METRICS = [
    "tickToApp",
    "tickToApplied",
    "tickToRender",
    "orderSubmitToAck",
    "orderServerProcessing",
    "orderSubmitToFill",
]
TICK_METRICS = ["tickToApp", "tickToApplied", "tickToRender"]
ORDER_METRICS = [
    ("orderSubmitToAck", "Submit to ack"),
    ("orderServerProcessing", "Server processing"),
    ("orderSubmitToFill", "Submit to fill"),
]

# The market's rates in ticks per symbol per second (Server/Sources/ExchangeServerKit/MarketRunner.swift:
# `normalRate` and `stressRate`); the lab's multiplier scales the first one and does nothing in stress mode.
NORMAL_RATE = 20
STRESS_RATE = 500

NS_PER_MS = 1_000_000
DASH = "—"

# The order the runs are listed in. A label that is not here comes after these, in alphabetical order.
LABEL_ORDER = [
    "release-baseline",
    "release-load1k",
    "release-load10x",
    "release-stress",
    "release-latency200",
    "orders",
    "orders200",
    "baseline",
    "baseline-repeat",
    "load1k",
    "load10x",
    "stress",
    "latency200",
]

BUILDS = ["Release", "Debug"]

# The five fields of the lab that a run, and a probe of the feed, are identified by.
LAB_FIELDS = ("rateMultiplier", "stress", "extraLatencyMs", "jitterMs", "dropUpdates")
PROBE_FILE = "feed-probe.json"

TABLES_BEGIN = "<!-- tables:begin -->"
TABLES_END = "<!-- tables:end -->"
CLAMPED_BEGIN = "<!-- clamped:begin -->"
CLAMPED_END = "<!-- clamped:end -->"
RUNS_BEGIN = "<!-- runs:begin -->"
RUNS_END = "<!-- runs:end -->"


# --- Reading ---------------------------------------------------------------------------------------------------------


def read_json_lines(path):
    """Every JSON line of a .jsonl file, in order."""
    lines = []
    with open(path, encoding="utf-8") as handle:
        for number, text in enumerate(handle, start=1):
            if not text.strip():
                continue
            try:
                lines.append(json.loads(text))
            except ValueError as error:
                raise SystemExit("%s line %d is not JSON: %s" % (path, number, error))
    return lines


def read_record(folder, label):
    """The run record Scripts/measure.sh wrote next to the result, or None when there is none."""
    path = os.path.join(folder, label + ".run.json")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def lab_key(lab):
    return tuple(lab[field] for field in LAB_FIELDS)


def read_probe(folder):
    """The feed probe's results by lab setting: {lab key: result}. Empty when the folder has no probe file."""
    path = os.path.join(folder, PROBE_FILE)
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as handle:
        return {lab_key(result["lab"]): result for result in json.load(handle)}


def load_runs(folder):
    """One dict per <label>.jsonl in the folder, in the order of LABEL_ORDER: the label, its lines, its record and the
    probe result made at the same lab setting (None when there is none)."""
    probe = read_probe(folder)
    runs = []
    for path in sorted(glob.glob(os.path.join(folder, "*.jsonl"))):
        label = os.path.basename(path)[: -len(".jsonl")]
        lines = read_json_lines(path)
        if lines:
            record = read_record(folder, label)
            found = probe.get(lab_key(record["lab"])) if record else None
            runs.append({"label": label, "lines": lines, "record": record, "probe": found})
    runs.sort(key=lambda run: sort_key(run["label"]))
    return runs


def sort_key(label):
    if label in LABEL_ORDER:
        return (0, LABEL_ORDER.index(label), label)
    return (1, 0, label)


def build_of(run):
    record = run["record"]
    return record["build"] if record else "not recorded"


# --- Numbers ---------------------------------------------------------------------------------------------------------


def metric_of(line, name):
    return line["metrics"][name]


def seconds_between(first, last):
    """The seconds between two lines (their `t` is in milliseconds since the Unix epoch), or None."""
    seconds = (last["t"] - first["t"]) / 1000.0
    return seconds if seconds > 0 else None


def per_second(before, after, seconds):
    """How fast a cumulative counter grew, or None when it cannot be told (one line only, or the counter went down:
    the app's "Reset stats" button zeroes the counters)."""
    if seconds is None or after < before:
        return None
    return (after - before) / seconds


def feed_rate(run):
    first, last = run["lines"][0], run["lines"][-1]
    return per_second(
        metric_of(first, "tickToApp")["count"], metric_of(last, "tickToApp")["count"], seconds_between(first, last)
    )


def display_rate(run):
    first, last = run["lines"][0], run["lines"][-1]
    return per_second(first["frames"], last["frames"], seconds_between(first, last))


def nominal_ticks_per_second(run):
    """What the lab asks the market for, from the settings the server confirmed; None without a run record."""
    record = run["record"]
    if not record:
        return None
    lab = record["lab"]
    per_symbol = STRESS_RATE if lab["stress"] else NORMAL_RATE * lab["rateMultiplier"]
    return record["symbols"] * per_symbol


# --- Formatting ------------------------------------------------------------------------------------------------------


def ms(nanos):
    return DASH if nanos is None else "%.2f" % (nanos / NS_PER_MS)


def whole(number):
    return "{:,}".format(int(round(number)))


def one_decimal(number):
    return DASH if number is None else "%.1f" % number


def share(part, whole_count):
    return "%.2f %%" % (100.0 * part / whole_count)


def percentiles(summary):
    """p50 / p95 / p99 in milliseconds; an em dash for each one that is missing."""
    return " / ".join(ms(summary[key]) for key in ("p50Ns", "p95Ns", "p99Ns"))


def clamped_cell(summary):
    """The clamped count and its share of the samples. `count` already includes the clamped samples: the app records a
    negative one as 0 and one above 10 s as 10 s, and counts it in both."""
    clamped = summary["clamped"]
    if clamped == 0:
        return "0"
    return "%s (%s)" % (whole(clamped), share(clamped, summary["count"]))


def hitches_cell(line):
    frames, hitches = line["frames"], line["hitches"]
    if frames == 0:
        return DASH
    return "%s / %s (%s)" % (whole(hitches), whole(frames), share(hitches, frames))


def lab_cell(run):
    record = run["record"]
    if not record:
        return DASH
    lab = record["lab"]
    if lab["stress"]:
        # Stress mode ticks at a fixed rate whatever the multiplier is.
        parts = ["stress"]
        if lab["rateMultiplier"] != 1:
            parts.append("rate %gx (unused)" % lab["rateMultiplier"])
    else:
        parts = ["rate %gx" % lab["rateMultiplier"]]
    if lab["extraLatencyMs"]:
        parts.append("+%d ms" % lab["extraLatencyMs"])
    if lab["jitterMs"]:
        parts.append("jitter %d ms" % lab["jitterMs"])
    if lab["dropUpdates"]:
        parts.append("drop updates")
    return ", ".join(parts)


def p99_in_frames(run):
    """The p99 of tickToRender in display frames at the run's own frame rate."""
    p99 = metric_of(run["lines"][-1], "tickToRender")["p99Ns"]
    fps = display_rate(run)
    if p99 is None or not fps:
        return DASH
    return "%.1f" % ((p99 / NS_PER_MS) / (1000.0 / fps))


def order_cell(summary):
    if summary["count"] == 0:
        return DASH
    text = "%s samples: %s ms" % (whole(summary["count"]), percentiles(summary))
    if summary["clamped"]:
        text += ", clamped %s" % clamped_cell(summary)
    return text


def table(header, rows, text_columns=1):
    """A markdown table; the first `text_columns` columns are left aligned and the others are right aligned."""
    marks = [" --- "] * text_columns + [" ---: "] * (len(header) - text_columns)
    lines = ["| " + " | ".join(header) + " |", "|" + "|".join(marks) + "|"]
    for row in rows:
        lines.append("| " + " | ".join(row) + " |")
    return lines


# --- The tables ------------------------------------------------------------------------------------------------------


def tick_table(runs):
    header = [
        "Run", "Lab setting", "Ticks/s set", "Updates/s sent", "Feed frames/s", "Display fps", "Samples",
        "p50 / p95 / p99 (ms)", "p99 in frames", "Clamped", "Hitches / frames",
    ]
    rows = []
    for run in runs:
        last = run["lines"][-1]
        render = metric_of(last, "tickToRender")
        nominal = nominal_ticks_per_second(run)
        rows.append([
            run["label"],
            lab_cell(run),
            DASH if nominal is None else whole(nominal),
            DASH if run["probe"] is None else whole(run["probe"]["updatesPerSecond"]),
            one_decimal(feed_rate(run)),
            one_decimal(display_rate(run)),
            DASH if render["count"] == 0 else whole(render["count"]),
            percentiles(render) if render["count"] else DASH,
            p99_in_frames(run),
            clamped_cell(render) if render["count"] else DASH,
            hitches_cell(last),
        ])
    return table(header, rows, text_columns=2)


def order_table(runs):
    header = ["Run", "Build"] + [title for _, title in ORDER_METRICS]
    rows = []
    for run in runs:
        last = run["lines"][-1]
        rows.append([run["label"], build_of(run)] + [order_cell(metric_of(last, name)) for name, _ in ORDER_METRICS])
    return table(header, rows, text_columns=len(header))


def build_groups(runs):
    """The builds that have runs, Release first, then Debug, then anything else."""
    present = []
    for run in runs:
        if build_of(run) not in present:
            present.append(build_of(run))
    known = [build for build in BUILDS if build in present]
    return known + sorted(build for build in present if build not in BUILDS)


def tables_text(runs):
    """The block that goes between <!-- tables:begin --> and <!-- tables:end -->."""
    out = []
    for build in build_groups(runs):
        chosen = [run for run in runs if build_of(run) == build]
        if build == "Release":
            title = "Tick to render, Release build (`make app-release`)"
        elif build == "Debug":
            title = "Tick to render, Debug build (`make app`, `make demo`)"
        else:
            title = "Tick to render, build: %s" % build
        out += ["### " + title, ""] + tick_table(chosen) + [""]
    out += ["### Order path, every run", "", "Each cell: the number of samples, then p50 / p95 / p99 in milliseconds.", ""]
    out += order_table(runs)
    return "\n".join(out) + "\n"


def clamped_text(runs):
    """The block that goes between <!-- clamped:begin --> and <!-- clamped:end -->."""
    header = [
        "Run", "Metric", "Lines", "First line: samples / clamped", "Middle line: samples / clamped",
        "Last line: samples / clamped", "Clamped share at the last line", "Clamped per second after the first line",
    ]
    rows = []
    for run in runs:
        lines = run["lines"]
        first, middle, last = lines[0], lines[len(lines) // 2], lines[-1]
        seconds = seconds_between(first, last)
        for name in METRICS:
            if name not in TICK_METRICS and metric_of(last, name)["count"] == 0:
                continue
            growth = per_second(metric_of(first, name)["clamped"], metric_of(last, name)["clamped"], seconds)
            rows.append([
                run["label"],
                name,
                str(len(lines)),
                "%s / %s" % (whole(metric_of(first, name)["count"]), whole(metric_of(first, name)["clamped"])),
                "%s / %s" % (whole(metric_of(middle, name)["count"]), whole(metric_of(middle, name)["clamped"])),
                "%s / %s" % (whole(metric_of(last, name)["count"]), whole(metric_of(last, name)["clamped"])),
                clamped_share_cell(metric_of(last, name)),
                one_decimal(growth) if metric_of(last, name)["count"] else DASH,
            ])
    return "\n".join(table(header, rows, text_columns=2)) + "\n"


def clamped_share_cell(summary):
    if summary["count"] == 0:
        return DASH
    return share(summary["clamped"], summary["count"])


def idle_cell(record, key):
    """The machine's idle CPU in percent, as measure.sh read it from `top`; an em dash when it could not be read."""
    if not record or record.get(key) is None:
        return DASH
    return "%.1f" % record[key]


def runs_text(runs):
    """The block that goes between <!-- runs:begin --> and <!-- runs:end -->."""
    header = [
        "Run", "Build", "Seconds", "JSON lines", "Started (UTC)", "CPU idle before the run (%)",
        "CPU idle after the run (%)",
    ]
    rows = []
    for run in runs:
        record = run["record"]
        rows.append([
            run["label"],
            build_of(run),
            DASH if not record else str(record["seconds"]),
            str(len(run["lines"])),
            DASH if not record else record["startedAt"],
            idle_cell(record, "cpuIdlePercentBeforeRun"),
            idle_cell(record, "cpuIdlePercentAfterRun"),
        ])
    return "\n".join(table(header, rows, text_columns=2)) + "\n"


# --- Checking a file ---------------------------------------------------------------------------------------------------


def block_between(text, begin, end):
    """The lines strictly between the begin and end marker lines, or None when either marker is missing."""
    lines = text.split("\n")
    if begin not in lines or end not in lines:
        return None
    start, stop = lines.index(begin) + 1, lines.index(end)
    if stop < start:
        return None
    return "\n".join(lines[start:stop]) + "\n"


def check_files(runs, paths):
    """Compares the blocks in each file with what is generated now. Returns the exit code."""
    wanted = [
        (TABLES_BEGIN, TABLES_END, tables_text(runs), True),
        (CLAMPED_BEGIN, CLAMPED_END, clamped_text(runs), False),
        (RUNS_BEGIN, RUNS_END, runs_text(runs), False),
    ]
    status = 0
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        for begin, end, generated, required in wanted:
            found = block_between(text, begin, end)
            if found is None:
                if required:
                    emit("%s: the lines %s and %s are missing\n" % (path, begin, end))
                    status = 1
                continue
            if found != generated:
                status = 1
                diff = difflib.unified_diff(
                    found.splitlines(True), generated.splitlines(True), fromfile=path, tofile="generated", n=1
                )
                emit("".join(diff))
    return status


# --- Main --------------------------------------------------------------------------------------------------------------


def emit(text):
    """Writes UTF-8 whatever the locale is."""
    sys.stdout.flush()
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.stdout.buffer.flush()


def usage():
    sys.stderr.write(
        "usage: python3 -I Scripts/summarize.py [--clamped | --runs] <results folder>\n"
        "       python3 -I Scripts/summarize.py --check <results folder> <file> [<file> ...]\n"
    )
    return 2


def main(argv):
    args = argv[1:]
    mode = "tables"
    if args and args[0] in ("--clamped", "--runs", "--check"):
        mode = args[0][2:]
        args = args[1:]
    if not args or (mode != "check" and len(args) != 1) or (mode == "check" and len(args) < 2):
        return usage()
    folder = args[0]
    if not os.path.isdir(folder):
        sys.stderr.write("not a folder: %s\n" % folder)
        return 2
    runs = load_runs(folder)
    if not runs:
        sys.stderr.write("no .jsonl results in %s\n" % folder)
        return 1
    if mode == "check":
        return check_files(runs, args[1:])
    if mode == "clamped":
        emit(clamped_text(runs))
    elif mode == "runs":
        emit(runs_text(runs))
    else:
        emit(tables_text(runs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
