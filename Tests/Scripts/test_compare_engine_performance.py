"""Independent standard-library tests; no real CLI benchmarks or user index access."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "compare-engine-performance.py"
SPEC = importlib.util.spec_from_file_location("compare_engine_performance", SCRIPT)
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)


def table(p95=3.0, count=12):
    return benchmark.HEADER + "\n" + "".join(
        f"{query}\t{count}\t0.001\t0.002\t{p95:.3f}\n" for query in benchmark.QUERIES)


class ParsingTests(unittest.TestCase):
    def test_existing_bench25_plus_typing_contract(self):
        rows = benchmark.parse_bench(table())
        self.assertEqual(len(rows), 26)
        self.assertEqual(rows[-1]["query"], "typing readme")
        self.assertEqual(rows[-2]["query"], "(empty)")

    def test_rejects_missing_extra_reordered_and_filename_output(self):
        original = table()
        bad_outputs = [
            original.rsplit("\n", 2)[0] + "\n",
            original + "/Users/private/secret-result.pdf\n",
            original.replace("a\t12", "e\t12", 1),
            original.replace("0.001\t0.002", "9.0\t0.002", 1),
        ]
        for output in bad_outputs:
            with self.subTest(output=output[:60]), self.assertRaises(benchmark.BenchmarkError):
                benchmark.parse_bench(output)

    def test_rejects_nonfinite_negative_and_invalid_values(self):
        for value in ("nan", "inf", "-1", "text"):
            with self.subTest(value=value), self.assertRaises(benchmark.BenchmarkError):
                benchmark.parse_bench(table().replace("3.000", value, 1))
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.parse_bench(table(count=-1))

    def test_darwin_rss_is_bytes(self):
        self.assertEqual(benchmark.parse_rss("  123456 maximum resident set size\n"), 123456)
        for stderr in ("", "123 maximum resident set size\n456 maximum resident set size\n"):
            with self.assertRaises(benchmark.BenchmarkError):
                benchmark.parse_rss(stderr)

    def test_abba_order_and_minimum_rounds(self):
        self.assertEqual([role for _, role in benchmark.schedule(4)],
                         ["baseline", "candidate", "candidate", "baseline"] * 2)
        for rounds in (0, 2, 3, 5):
            with self.assertRaises(benchmark.BenchmarkError):
                benchmark.schedule(rounds)

    def test_round_p95_median_and_range_not_pooled_p95(self):
        runs = []
        for round_number, role in benchmark.schedule(4):
            p95 = [1, 2, 100, 101][round_number - 1] + (1 if role == "candidate" else 0)
            runs.append(dict(round=round_number, role=role, rows=benchmark.parse_bench(table(p95))))
        summary = benchmark.aggregate(runs, 4)[0]
        self.assertEqual(summary["baseline_median_round_p95_ms"], 51)
        self.assertEqual(summary["baseline_min_round_p95_ms"], 1)
        self.assertEqual(summary["baseline_max_round_p95_ms"], 101)
        self.assertEqual(summary["candidate_median_round_p95_ms"], 52)
        self.assertAlmostEqual(summary["candidate_over_baseline"], 52 / 51)
        self.assertFalse(any("pooled" in key for key in summary))
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.aggregate(runs[:-1], 4)
        runs[1]["rows"][0]["count"] += 1
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.aggregate(runs, 4)

    def test_zero_denominator_reports_null_ratio(self):
        rows = benchmark.parse_bench(table().replace("0.001\t0.002\t3.000", "0\t0\t0"))
        runs = [dict(round=number, role=role, rows=rows) for number, role in benchmark.schedule(4)]
        result = benchmark.aggregate(runs, 4)[0]
        self.assertIsNone(result["candidate_over_baseline"])
        self.assertIsNone(result["delta_percent"])


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="oilfind-compare-test-")
        self.root = Path(self.temporary.name)
        self.source = self.root / "private-source-index.oilfind"
        self.source.write_bytes(b"Synthetic index fixture, never read by a real engine")
        self.original_mode = stat.S_IMODE(self.source.stat().st_mode)
        self.baseline = self.root / "baseline-cli"
        self.candidate = self.root / "candidate-cli"
        for cli in (self.baseline, self.candidate):
            cli.write_text("fixture executable; subprocess is mocked\n", encoding="utf-8")
            cli.chmod(0o700)
        self.output = self.root / "benchmark-results"
        self.argv = ["--baseline-cli", str(self.baseline), "--candidate-cli", str(self.candidate),
                     "--db", str(self.source), "--output", str(self.output)]
        self.commands = []

    def tearDown(self):
        for directory in sorted(self.root.glob("**/index")):
            directory.chmod(0o700)
        self.temporary.cleanup()

    def fake_run(self, command, **kwargs):
        self.commands.append(command)
        self.assertIn("bench", command)
        self.assertNotIn("scan", command)
        snapshot = Path(command[-1])
        self.assertNotEqual(snapshot, self.source)
        self.assertEqual(snapshot.read_bytes(), self.source.read_bytes())
        self.assertEqual(stat.S_IMODE(snapshot.stat().st_mode), 0o400)
        self.assertEqual(stat.S_IMODE(snapshot.parent.stat().st_mode), 0o500)
        self.assertTrue(kwargs["capture_output"])
        self.assertEqual(kwargs["timeout"], 300)
        return subprocess.CompletedProcess(command, 0, table(), "123456 maximum resident set size\n")

    def run_main(self, argv=None, side_effect=None):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(benchmark.subprocess, "run", side_effect=side_effect or self.fake_run), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            result = benchmark.main(argv or self.argv)
        return result, out.getvalue(), err.getvalue()

    def test_complete_workflow_uses_one_readonly_copy_and_preserves_source(self):
        before = benchmark.checksum(self.source)
        result, _, err = self.run_main()
        self.assertEqual((result, err), (0, ""))
        self.assertEqual(len(self.commands), 8)
        self.assertEqual(len({command[-1] for command in self.commands}), 1)
        self.assertEqual([Path(command[0]).name for command in self.commands],
                         ["baseline-cli", "candidate-cli", "candidate-cli", "baseline-cli"] * 2)
        self.assertEqual(benchmark.checksum(self.source), before)
        self.assertEqual(stat.S_IMODE(self.source.stat().st_mode), self.original_mode)
        report = json.loads((self.output / "comparison.json").read_text())
        self.assertEqual(report["metadata"]["status"], "complete")
        self.assertEqual(report["metadata"]["index_sha256"], before)
        self.assertEqual(report["metadata"]["index_sha256_after"], before)
        self.assertEqual(report["metadata"]["samples_per_query_per_round"], 20)
        self.assertEqual(len(report["runs"]), 8)
        self.assertEqual(len((self.output / "rounds.tsv").read_text().splitlines()), 8 * 26 + 1)
        raw_files = sorted((self.output / "roundlog").glob("*.tsv"))
        self.assertEqual(len(raw_files), 8)
        self.assertEqual(raw_files[0].read_text(), table())
        self.assertEqual(len((self.output / "roundlog.jsonl").read_text().splitlines()), 8)
        self.assertNotIn(self.source.name, (self.output / "comparison.json").read_text())
        self.assertFalse((self.output / "index").exists())

    def test_optional_rss_uses_time_and_only_persists_rss_line(self):
        with mock.patch.object(benchmark.sys, "platform", "darwin"):
            result, _, _ = self.run_main(self.argv + ["--time-rss"])
        self.assertEqual(result, 0)
        self.assertTrue(all(command[:2] == ["/usr/bin/time", "-l"] for command in self.commands))
        metadata = json.loads((self.output / "metadata.json").read_text())
        self.assertEqual(metadata["peak_rss_summary_bytes"]["baseline"],
                         {"median": 123456, "min": 123456, "max": 123456})
        self.assertEqual(len(list((self.output / "roundlog").glob("*.rss.txt"))), 8)

    def test_count_mismatch_fails_without_publishing_summary(self):
        def changing_counts(command, **kwargs):
            self.commands.append(command)
            return subprocess.CompletedProcess(command, 0, table(count=len(self.commands)), "")
        result, _, _ = self.run_main(side_effect=changing_counts)
        self.assertEqual(result, 1)
        self.assertEqual(len(self.commands), 2)
        self.assertFalse((self.output / "summary.tsv").exists())
        metadata = json.loads((self.output / "metadata.json").read_text())
        self.assertEqual(metadata["status"], "failed")
        self.assertFalse((self.output / "index").exists())

    def test_unexpected_output_never_leaks_or_is_written_to_roundlog(self):
        secret = "/Users/private/secret-result.pdf"
        def unexpected(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, table() + secret + "\n", secret)
        result, out, err = self.run_main(side_effect=unexpected)
        self.assertEqual(result, 1)
        self.assertNotIn(secret, out + err)
        for path in sorted(self.output.glob("**/*.json")):
            self.assertNotIn(secret, path.read_text())
        self.assertEqual(list((self.output / "roundlog").glob("*")), [])

    def test_failed_cli_suppresses_private_stderr_and_stdout(self):
        secret = "/Users/private/secret-result.pdf"
        def failed(command, **kwargs):
            return subprocess.CompletedProcess(command, 1, secret, secret)
        result, out, err = self.run_main(side_effect=failed)
        self.assertEqual(result, 1)
        self.assertNotIn(secret, out + err + (self.output / "metadata.json").read_text())

    def test_timeout_reports_failure(self):
        def timeout(command, **kwargs):
            raise subprocess.TimeoutExpired(command, 300, output="private filename")
        result, _, err = self.run_main(side_effect=timeout)
        self.assertEqual(result, 1)
        self.assertIn("timed out", err)
        self.assertNotIn("private filename", err)

    def test_rejects_existing_output_without_overwriting(self):
        self.output.mkdir()
        sentinel = self.output / "sentinel.txt"
        sentinel.write_text("preserve me")
        result, _, _ = self.run_main()
        self.assertEqual(result, 1)
        self.assertEqual(sentinel.read_text(), "preserve me")
        self.assertEqual(self.commands, [])

    def test_detects_changed_binary(self):
        def replace_binary(command, **kwargs):
            result = self.fake_run(command, **kwargs)
            self.baseline.write_text("replaced during run")
            return result
        result, _, err = self.run_main(side_effect=replace_binary)
        self.assertEqual(result, 1)
        self.assertIn("binary changed", err)
        self.assertFalse((self.output / "summary.tsv").exists())


if __name__ == "__main__":
    unittest.main()
