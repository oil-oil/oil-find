#!/usr/bin/env python3
"""Compare two release oilfind-cli binaries without modifying the source index.

Run with uv run python. --rounds is the number of 20-sample rounds PER CLI;
paired rounds alternate AB, BA, yielding ABBAABBA for the default four rounds.
Only the CLI's existing bench command is used, never scan/search/watch.
"""

import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
from datetime import datetime, timezone


QUERIES = (
    "a", "e", "re", "log", "readme", "file:readme", "folder:src",
    "package.json", "*.pdf", "ext:png", "wd", "xm", "文档", "项目", "src/",
    "~/Library/", "/System/", "/private/", "kind:image", "~/Desktop/ png",
    "readme !node_modules", "jpg|png size:>1mb", "dm:7d ext:md",
    r"regex:^IMG_\d+", "(empty)", "typing readme",
)
HEADER = "query\tcount\tmin_ms\tmedian_ms\tp95_ms"
SAMPLES_PER_ROUND = 20
BASELINE_COMMIT = "a4f685405a014f80d1773f2bd0baa7f3321b77e8"


class BenchmarkError(Exception):
    """An invalid or incomplete comparison; never include subprocess output."""


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def schedule(rounds):
    if rounds < 4 or rounds % 2:
        raise BenchmarkError("--rounds must be an even number >= 4 (rounds per CLI)")
    return [
        (round_number, role)
        for round_number in range(1, rounds + 1)
        for role in (("baseline", "candidate") if round_number % 2
                     else ("candidate", "baseline"))
    ]


def parse_bench(stdout):
    lines = stdout.splitlines()
    if len(lines) != len(QUERIES) + 1 or lines[0] != HEADER:
        raise BenchmarkError("CLI bench output must contain exactly the bench25 + typing table")
    rows = []
    for expected_query, line in zip(QUERIES, lines[1:]):
        columns = line.split("\t")
        if len(columns) != 5 or columns[0] != expected_query:
            raise BenchmarkError("CLI bench query sequence or schema does not match")
        try:
            count = int(columns[1])
            timings = [float(value) for value in columns[2:]]
        except ValueError:
            raise BenchmarkError("CLI bench contains invalid numeric values") from None
        if count < 0 or any(not math.isfinite(value) or value < 0 for value in timings):
            raise BenchmarkError("CLI bench contains negative or non-finite values")
        if timings != sorted(timings):
            raise BenchmarkError("CLI bench timings must satisfy min <= median <= p95")
        rows.append(dict(query=expected_query, count=count, min_ms=timings[0],
                         median_ms=timings[1], p95_ms=timings[2]))
    return rows


def parse_rss(stderr):
    matches = re.findall(r"^\s*(\d+)\s+maximum resident set size\s*$", stderr, re.MULTILINE)
    if len(matches) != 1:
        raise BenchmarkError("/usr/bin/time -l did not report one peak RSS value")
    # Darwin time -l reports bytes, unlike Linux /usr/bin/time.
    return int(matches[0])


def aggregate(runs, rounds):
    expected = schedule(rounds)
    if [(run["round"], run["role"]) for run in runs] != expected:
        raise BenchmarkError("Comparison is incomplete or execution order is incorrect")
    counts = {}
    values = {role: {query: [] for query in QUERIES} for role in ("baseline", "candidate")}
    for run in runs:
        if [row["query"] for row in run["rows"]] != list(QUERIES):
            raise BenchmarkError("A round is missing queries")
        for row in run["rows"]:
            query, count = row["query"], row["count"]
            if query in counts and counts[query] != count:
                raise BenchmarkError(f"Result count changed across CLI versions or rounds: {query}")
            counts[query] = count
            values[run["role"]][query].append(row["p95_ms"])
    summaries = []
    for query in QUERIES:
        result = {"query": query, "count": counts[query]}
        for role in ("baseline", "candidate"):
            p95s = values[role][query]
            result[f"{role}_median_round_p95_ms"] = statistics.median(p95s)
            result[f"{role}_min_round_p95_ms"] = min(p95s)
            result[f"{role}_max_round_p95_ms"] = max(p95s)
        baseline = result["baseline_median_round_p95_ms"]
        candidate = result["candidate_median_round_p95_ms"]
        result["delta_median_round_p95_ms"] = candidate - baseline
        result["candidate_over_baseline"] = candidate / baseline if baseline else None
        result["delta_percent"] = (candidate / baseline - 1) * 100 if baseline else None
        summaries.append(result)
    return summaries


def write_json(path, payload):
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False) + "\n",
                    encoding="utf-8")


def write_tsv(path, rows):
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]), delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)


def compare(args):
    order = schedule(args.rounds)
    if args.time_rss and sys.platform != "darwin":
        raise BenchmarkError("--time-rss requires Darwin /usr/bin/time -l (RSS in bytes)")
    binaries = {"baseline": args.baseline_cli.resolve(), "candidate": args.candidate_cli.resolve()}
    for binary in binaries.values():
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise BenchmarkError("Both CLI paths must point to executable release binaries")
    if binaries["baseline"] == binaries["candidate"]:
        raise BenchmarkError("Use two distinct CLI paths")
    source = args.db.resolve()
    if not source.is_file():
        raise BenchmarkError("--db must point to an existing index")
    output = args.output.resolve()
    if output.exists():
        raise BenchmarkError("--output must be a new directory; existing artifacts are never overwritten")
    output.mkdir(parents=True, mode=0o700)
    metadata = {
        "status": "preparing", "started_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "release CLI file engine; not app or launcher end-to-end latency",
        "baseline_commit_expected": BASELINE_COMMIT,
        "binary_provenance": "Caller must use release builds; SHA256 identifies actual binaries. "
                             "Baseline commit is an expected input, not inferred from the binary.",
        "platform": {"system": platform.system(), "release": platform.release(), "machine": platform.machine()},
        "cli_sha256": {role: checksum(binary) for role, binary in binaries.items()},
        "rounds_per_cli": args.rounds, "samples_per_query_per_round": SAMPLES_PER_ROUND,
        "queries": list(QUERIES), "execution_order": [{"round": n, "role": role} for n, role in order],
        "metric": "Per-round CLI p95 = sorted samples[18] of 20 (nearest-rank 95th percentile). "
                  "CLI median = sorted samples[10]. Values printed to 0.001 ms precision. "
                  "Summary is median/min/max of round p95 values, never pooled-sample p95.",
        "typing_metric": "Each of 20 typing readme repetitions reports the maximum step latency "
                         "over forward typing and backspace with a fresh SearchCache; "
                         "p95 is over those 20 maxima, not over all keystrokes.",
        "cache_conditions": "Each bench invocation is a new process with pinyin warmed by CLI; "
                            "OS page cache is not flushed. Load/startup are outside search timings.",
        "peak_rss_metric": "Darwin /usr/bin/time -l whole CLI process peak RSS in bytes; "
                           "includes load/pinyin/bench, not per query or app RSS" if args.time_rss else None,
        "limitations": "CLI exposes aggregate samples and last repetition result counts only. "
                       "Count consistency checks compare reported counts across all runs; "
                       "individual sample latency and count cannot be reconstructed. "
                       "No automatic claim of regression or statistical significance.",
    }
    runs = []
    index_dir = output / "index"
    snapshot = index_dir / "readonly.oilfind"
    try:
        index_dir.mkdir(mode=0o700)
        shutil.copyfile(source, snapshot)
        snapshot.chmod(0o400)
        index_dir.chmod(0o500)
        digest = checksum(snapshot)
        if digest != checksum(source):
            raise BenchmarkError("Source index changed while copying; retry after indexing is idle")
        metadata.update(index_sha256=digest, index_bytes=snapshot.stat().st_size, status="running")
        write_json(output / "metadata.json", metadata)
        print(f"Index SHA256: {digest}", flush=True)
        raw_dir = output / "roundlog"
        raw_dir.mkdir(mode=0o700)
        for sequence, (round_number, role) in enumerate(order, 1):
            if checksum(snapshot) != digest:
                raise BenchmarkError("Read-only index checksum changed before a round")
            if checksum(binaries[role]) != metadata["cli_sha256"][role]:
                raise BenchmarkError("CLI binary changed during comparison; rebuild and rerun")
            command = [str(binaries[role]), "bench", "--db", str(snapshot)]
            if args.time_rss:
                command = ["/usr/bin/time", "-l"] + command
            print(f"Run {sequence}/{len(order)}: round {round_number} {role}", flush=True)
            try:
                process = subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                                         timeout=args.timeout, check=False)
            except subprocess.TimeoutExpired:
                raise BenchmarkError(f"CLI timed out in round {round_number} ({role})") from None
            if process.returncode:
                raise BenchmarkError(f"CLI failed in round {round_number} ({role}), exit {process.returncode}; "
                                     "output suppressed to protect file paths")
            rows = parse_bench(process.stdout)
            peak_rss = parse_rss(process.stderr) if args.time_rss else None
            if checksum(snapshot) != digest:
                raise BenchmarkError("Read-only index checksum changed during a round")
            if checksum(binaries[role]) != metadata["cli_sha256"][role]:
                raise BenchmarkError("CLI binary changed during a round")
            # Persist stdout verbatim only after validating a query/count/timing-only schema.
            # Never persist arbitrary stderr: load errors may expose source file paths.
            stem = f"{sequence:02d}-round-{round_number:02d}-{role}"
            (raw_dir / f"{stem}.tsv").write_text(process.stdout, encoding="utf-8")
            if peak_rss is not None:
                (raw_dir / f"{stem}.rss.txt").write_text(
                    f"{peak_rss} maximum resident set size\n", encoding="utf-8")
            run = {"sequence": sequence, "round": round_number, "role": role,
                   "samples_per_query": SAMPLES_PER_ROUND, "peak_rss_bytes": peak_rss, "rows": rows}
            runs.append(run)
            with (output / "roundlog.jsonl").open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(run, ensure_ascii=False, allow_nan=False) + "\n")
            if len(runs) > 1:
                expected_counts = [row["count"] for row in runs[0]["rows"]]
                if [row["count"] for row in rows] != expected_counts:
                    raise BenchmarkError("Result counts differ across CLI versions or rounds; "
                                         "comparison invalid, inspect query counts in roundlog")
        summaries = aggregate(runs, args.rounds)
        write_tsv(output / "summary.tsv", summaries)
        round_rows = [dict(sequence=run["sequence"], round=run["round"], role=run["role"],
                           samples_per_query=SAMPLES_PER_ROUND, **row)
                      for run in runs for row in run["rows"]]
        write_tsv(output / "rounds.tsv", round_rows)
        if args.time_rss:
            metadata["peak_rss_summary_bytes"] = {}
            for role in binaries:
                values = [run["peak_rss_bytes"] for run in runs if run["role"] == role]
                metadata["peak_rss_summary_bytes"][role] = {
                    "median": statistics.median(values), "min": min(values), "max": max(values)}
        metadata.update(status="complete", completed_utc=datetime.now(timezone.utc).isoformat(),
                        counts_consistent=True, index_sha256_after=checksum(snapshot))
        write_json(output / "metadata.json", metadata)
        write_json(output / "comparison.json", {"metadata": metadata, "summary": summaries, "runs": runs})
        print("Complete: summary.tsv, rounds.tsv, comparison.json, metadata.json, roundlog/ and roundlog.jsonl")
        return 0
    except (BenchmarkError, OSError, UnicodeError) as error:
        # Do not emit arbitrary OS/subprocess errors which can contain user paths.
        reason = str(error) if isinstance(error, BenchmarkError) else type(error).__name__
        metadata.update(status="failed", failure=reason, completed_runs=len(runs))
        write_json(output / "metadata.json", metadata)
        raise BenchmarkError(reason) from None
    finally:
        # The evidence needs checksums and timings, never another lasting index.
        # Restore only the permissions of this run's owned temporary directory.
        try:
            if index_dir.exists():
                index_dir.chmod(0o700)
                if snapshot.exists():
                    snapshot.chmod(0o600)
                    snapshot.unlink()
                index_dir.rmdir()
        except OSError:
            metadata.update(status="failed", cleanup_failure=True)
            write_json(output / "metadata.json", metadata)
            raise BenchmarkError("Owned temporary index cleanup failed") from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-cli", type=Path, required=True)
    parser.add_argument("--candidate-cli", type=Path, required=True)
    parser.add_argument("--db", type=Path, required=True, help="Source index; copied, never rewritten")
    parser.add_argument("--output", type=Path, required=True, help="New output directory (prefer ignored build/validation/benchmark-*)")
    parser.add_argument("--rounds", type=int, default=4, help="20-sample rounds per CLI; even and >= 4 (default: 4)")
    parser.add_argument("--time-rss", action="store_true", help="Capture whole CLI peak RSS with Darwin /usr/bin/time -l")
    parser.add_argument("--timeout", type=float, default=300, help="Maximum seconds per bench process (default: 300)")
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be positive and finite")
    previous_umask = os.umask(0o077)
    try:
        return compare(args)
    except BenchmarkError as error:
        print(f"Comparison failed: {error}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError) as error:
        print(f"Comparison failed: {type(error).__name__}; details suppressed to protect file paths", file=sys.stderr)
        return 1
    finally:
        os.umask(previous_umask)


if __name__ == "__main__":
    raise SystemExit(main())
