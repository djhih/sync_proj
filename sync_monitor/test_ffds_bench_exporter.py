#!/usr/bin/env python3
"""Unit tests for ffds_bench_exporter.py (stdlib unittest).

Run:  FFDS_BENCH_RESULTS_DIR is set per-test; the module is re-imported
against a temp results tree.  python3 sync_monitor/test_ffds_bench_exporter.py
"""
import importlib
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def make_record(campaign="c1", run_id="r1-v3-cold", engine="v3",
                scenario="cold", rep=1, subpath="A", valid=1, **kw):
    rec = {"campaign": campaign, "run_id": run_id, "engine": engine,
           "scenario": scenario, "rep": rep, "subpath": subpath,
           "valid": valid, "script_exit": 0, "started_ts": 1000.0,
           "finished_ts": 1010.0, "duration_s": 10.0,
           "source_files_total": 500, "source_size_bytes": 12345,
           "files_transferred": 500, "files_deleted": 0,
           "engine_s": None, "fixup_s": None,
           "other_sync_running": 0, "resource_complete": 1}
    rec.update(kw)
    return rec


class ExporterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["FFDS_BENCH_RESULTS_DIR"] = self.tmp.name
        import ffds_bench_exporter
        self.mod = importlib.reload(ffds_bench_exporter)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rec, campaign=None, name=None):
        c = campaign or rec["campaign"]
        d = os.path.join(self.tmp.name, c, "runs")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, (name or rec["run_id"]) + ".json"), "w") as f:
            json.dump(rec, f)

    def render(self):
        return self.mod.render()

    def test_two_runs_between_scrapes_both_exposed(self):
        self.write(make_record(run_id="r1-v3-cold"))
        self.write(make_record(run_id="r2-v3-cold", rep=2, duration_s=20.0))
        out = self.render()
        self.assertIn('rep="1"', out)
        self.assertIn('rep="2"', out)
        self.assertIn("ffds_bench_results_loaded 2", out)
        self.assertIn("ffds_bench_exporter_ready 1", out)

    def test_restart_rebuilds_from_disk(self):
        self.write(make_record())
        self.render()
        importlib.reload(self.mod)             # simulated restart
        out = self.render()
        self.assertIn("ffds_bench_results_loaded 1", out)
        self.assertIn("ffds_bench_run_duration_seconds", out)

    def test_bad_json_withholds_run_and_clears_ready(self):
        self.write(make_record())
        d = os.path.join(self.tmp.name, "c1", "runs")
        with open(os.path.join(d, "broken.json"), "w") as f:
            f.write("{not json")
        out = self.render()
        self.assertIn("ffds_bench_result_parse_errors 1", out)
        self.assertIn("ffds_bench_exporter_ready 0", out)
        self.assertIn("ffds_bench_results_loaded 1", out)   # good run stays

    def test_partial_record_rejected_entirely(self):
        rec = make_record()
        del rec["valid"]
        self.write(rec)
        out = self.render()
        self.assertIn("ffds_bench_exporter_ready 0", out)
        self.assertNotIn("ffds_bench_run_duration_seconds{", out)

    def test_duplicate_label_set_rejected(self):
        self.write(make_record(run_id="r1-v3-cold"))
        self.write(make_record(run_id="r1-v3-cold"), name="r1-v3-cold-copy")
        out = self.render()
        self.assertIn("ffds_bench_exporter_ready 0", out)
        self.assertIn("ffds_bench_results_loaded 1", out)

    def test_unknown_enum_rejected(self):
        self.write(make_record(engine="v5-quantum"))
        out = self.render()
        self.assertIn("ffds_bench_exporter_ready 0", out)
        self.assertIn("ffds_bench_results_loaded 0", out)

    def test_missing_value_absent_not_zero(self):
        self.write(make_record(files_deleted=None))
        out = self.render()
        self.assertNotIn("ffds_bench_run_files_deleted", out)
        self.assertIn("ffds_bench_run_files_transferred", out)

    def test_nonfinite_value_absent(self):
        self.write(make_record(duration_s=float("inf")))
        out = self.render()
        self.assertNotIn("ffds_bench_run_duration_seconds{", out)

    def test_label_escaping(self):
        self.write(make_record(subpath='A"quote\\slash'))
        out = self.render()
        self.assertIn('subpath="A\\"quote\\\\slash"', out)

    def test_warm_files_per_second_only_valid_warm(self):
        self.write(make_record(run_id="w1", scenario="warm", valid=1,
                               duration_s=10.0, files_transferred=0))
        self.write(make_record(run_id="w2", rep=2, scenario="warm", valid=0,
                               duration_s=10.0, files_transferred=0))
        self.write(make_record(run_id="c2", rep=3, scenario="cold"))
        out = self.render()
        lines = [l for l in out.splitlines()
                 if l.startswith("ffds_bench_run_warm_files_per_second{")]
        self.assertEqual(len(lines), 1)
        self.assertIn('rep="1"', lines[0])
        self.assertIn(" 50", lines[0])          # 500 files / 10 s

    def test_warm_zero_duration_excluded(self):
        self.write(make_record(run_id="w0", scenario="warm", duration_s=0))
        out = self.render()
        self.assertNotIn("ffds_bench_run_warm_files_per_second{", out)

    def test_v4_phase_metrics_present_v3_absent(self):
        self.write(make_record(run_id="m1", engine="v4-mount",
                               engine_s=7.5, fixup_s=1.25))
        self.write(make_record(run_id="v3a", rep=2))
        out = self.render()
        fixup_lines = [l for l in out.splitlines()
                       if l.startswith("ffds_bench_run_fixup_seconds{")]
        self.assertEqual(len(fixup_lines), 1)
        self.assertIn('engine="v4-mount"', fixup_lines[0])


if __name__ == "__main__":
    unittest.main(verbosity=1)
