#!/usr/bin/env python3
"""FFDS bench Results exporter -- per-run gauges from completed JSON only.

Reads immutable per-run result files written by bench/ffds-bench.sh
(one JSON per finished run under <results root>/<campaign>/runs/) and
serves them as Prometheus gauges on :9760.  Restarting rebuilds everything
from disk; the monitor's last_run metrics and the CSV are NOT inputs.

Every metric row carries labels (campaign, engine, scenario, rep,
subpath), so a run that finished between two scrapes is still exposed
forever -- Results never depend on scrape frequency.  Values are emitted
only when measured: absent means "not observed", never zero.

A bad or duplicate result file makes the exporter NOT ready
(ffds_bench_exporter_ready 0, ffds_bench_result_parse_errors > 0) and
that run's metrics are withheld entirely -- no half-emitted runs.

Env knobs:
  FFDS_BENCH_LISTEN        default 127.0.0.1:9760
  FFDS_BENCH_RESULTS_DIR   default /var/log/ffds-bench/results
"""
import json
import math
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = os.environ.get("FFDS_BENCH_LISTEN", "127.0.0.1:9760")
RESULTS_DIR = os.environ.get("FFDS_BENCH_RESULTS_DIR",
                             "/var/log/ffds-bench/results")

ENGINES = ("v1", "v3", "v4-mount", "v4-smb")
SCENARIOS = ("cold", "warm", "incr")

# metric name -> result field (plain copy-through gauges)
PLAIN = {
    "ffds_bench_run_valid": "valid",
    "ffds_bench_run_exit_code": "script_exit",
    "ffds_bench_run_started_timestamp_seconds": "started_ts",
    "ffds_bench_run_finished_timestamp_seconds": "finished_ts",
    "ffds_bench_run_duration_seconds": "duration_s",
    "ffds_bench_run_source_files": "source_files_total",
    "ffds_bench_run_source_size_bytes": "source_size_bytes",
    "ffds_bench_run_files_transferred": "files_transferred",
    "ffds_bench_run_files_deleted": "files_deleted",
    "ffds_bench_run_fixup_seconds": "fixup_s",
    "ffds_bench_run_engine_seconds": "engine_s",
    "ffds_bench_run_other_sync_running": "other_sync_running",
    "ffds_bench_run_resource_complete": "resource_complete",
}
HELP = {
    "ffds_bench_run_valid": "1 when the run passed every gate; failures and "
                            "polluted samples stay visible at 0.",
    "ffds_bench_run_exit_code": "Final exit code of the sync script.",
    "ffds_bench_run_started_timestamp_seconds": "Run start (unix time).",
    "ffds_bench_run_finished_timestamp_seconds": "Run end (unix time).",
    "ffds_bench_run_duration_seconds":
        "Full script elapsed as measured by the scope worker (preflight + "
        "engine + fixup + logging).",
    "ffds_bench_run_source_files": "Regular files in the shared source manifest.",
    "ffds_bench_run_source_size_bytes": "Bytes in the shared source manifest.",
    "ffds_bench_run_files_transferred": "Files the engine reported transferred.",
    "ffds_bench_run_files_deleted": "Files the engine reported deleted.",
    "ffds_bench_run_fixup_seconds":
        "Ownership/mode fixup phase: v4's fixup pass, v1's find sweeps "
        "(absent for v3, which folds both into the rsync pass).",
    "ffds_bench_run_engine_seconds":
        "Transfer phase: v4's rclone pipeline, v1's rsync (absent for v3).",
    "ffds_bench_run_other_sync_running":
        "1 when the interference watcher saw another sync during the run; "
        "absent when the watcher could not observe.",
    "ffds_bench_run_resource_complete": "1 when every cgroup counter was readable.",
    "ffds_bench_run_warm_files_per_second":
        "source_files_total / duration_s for VALID warm runs only -- the "
        "throughput of a full no-change verification pass, not a raw SMB "
        "scan rate.",
    "ffds_bench_results_loaded": "Completed run results currently loaded.",
    "ffds_bench_exporter_ready":
        "1 when every result file parsed and label sets are unique.",
    "ffds_bench_result_parse_errors":
        "Bad or duplicate result files currently on disk (a gauge, not a "
        "per-scrape counter).",
}
LABELS = ("campaign", "engine", "scenario", "rep", "subpath")

REQUIRED = {"campaign": str, "run_id": str, "engine": str, "scenario": str,
            "rep": int, "subpath": str, "valid": int}


def log(msg):
    print(f"[ffds-bench-exporter] {msg}", file=sys.stderr, flush=True)


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def num_ok(v):
    return (isinstance(v, (int, float)) and not isinstance(v, bool)
            and math.isfinite(v))


def load_result(path, errors):
    """One result file -> validated record, or None (+ an errors entry).
    Results are few and immutable, so a full re-read per scrape is fine."""
    try:
        with open(path) as f:
            obj = json.load(f)
        if not isinstance(obj, dict):
            raise ValueError("not an object")
        for key, typ in REQUIRED.items():
            v = obj.get(key)
            if not isinstance(v, typ) or isinstance(v, bool):
                raise ValueError(f"bad field {key}: {v!r}")
        if obj["engine"] not in ENGINES:
            raise ValueError(f"unknown engine {obj['engine']!r}")
        if obj["scenario"] not in SCENARIOS:
            raise ValueError(f"unknown scenario {obj['scenario']!r}")
        return obj
    except (OSError, ValueError) as e:
        errors[path] = str(e)
        return None


def scan_results():
    """All completed runs keyed by their label set, plus per-file errors."""
    runs, errors = {}, {}
    if os.path.isdir(RESULTS_DIR):
        for c in sorted(os.listdir(RESULTS_DIR)):
            run_dir = os.path.join(RESULTS_DIR, c, "runs")
            if not os.path.isdir(run_dir):
                continue
            for name in sorted(n for n in os.listdir(run_dir)
                               if n.endswith(".json")):
                path = os.path.join(run_dir, name)
                rec = load_result(path, errors)
                if rec is None:
                    continue
                key = tuple(str(rec.get(k)) for k in LABELS)
                if key in runs:
                    errors[path] = f"duplicate label set {key}"
                    continue
                runs[key] = rec
    return runs, errors


LOCK = threading.Lock()


def render():
    with LOCK:
        runs, errors = scan_results()
    out = []
    add = out.append

    def family(name, rows):
        rows = [r for r in rows if r[1] is not None]
        if not rows and name.startswith("ffds_bench_run_"):
            return
        add(f"# HELP {name} {HELP[name]}")
        add(f"# TYPE {name} gauge")
        for labels, value in rows:
            lbl = ",".join(f'{k}="{esc(v)}"' for k, v in labels)
            if isinstance(value, float):
                add(f"{name}{{{lbl}}} {value:.6f}".rstrip("0").rstrip("."))
            else:
                add(f"{name}{{{lbl}}} {value}")

    def label_pairs(rec):
        return tuple(zip(LABELS, (str(rec.get(k)) for k in LABELS)))

    for metric, field in PLAIN.items():
        rows = []
        for rec in runs.values():
            v = rec.get(field)
            rows.append((label_pairs(rec), v if num_ok(v) else None))
        family(metric, rows)

    rows = []
    for rec in runs.values():
        if (rec.get("valid") == 1 and rec.get("scenario") == "warm"
                and num_ok(rec.get("duration_s")) and rec["duration_s"] > 0
                and num_ok(rec.get("source_files_total"))):
            rows.append((label_pairs(rec),
                         rec["source_files_total"] / rec["duration_s"]))
    family("ffds_bench_run_warm_files_per_second", rows)

    add(f"# HELP ffds_bench_results_loaded {HELP['ffds_bench_results_loaded']}")
    add("# TYPE ffds_bench_results_loaded gauge")
    add(f"ffds_bench_results_loaded {len(runs)}")
    add(f"# HELP ffds_bench_result_parse_errors {HELP['ffds_bench_result_parse_errors']}")
    add("# TYPE ffds_bench_result_parse_errors gauge")
    add(f"ffds_bench_result_parse_errors {len(errors)}")
    ready = int(not errors)
    add(f"# HELP ffds_bench_exporter_ready {HELP['ffds_bench_exporter_ready']}")
    add("# TYPE ffds_bench_exporter_ready gauge")
    add(f"ffds_bench_exporter_ready {ready}")
    if errors:
        for path, why in sorted(errors.items())[:5]:
            log(f"bad result {path}: {why}")
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            if self.path in ("/", "/metrics"):
                body = render().encode()
            else:
                self.send_error(404)
                return
        except Exception as e:   # a bad file must not turn into a 500
            log(f"render failed: {type(e).__name__}: {e}")
            body = f"# ffds-bench-exporter: render failed: {type(e).__name__}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type",
                         "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


def main():
    host, _, port = LISTEN.rpartition(":")
    try:
        port = int(port)
    except ValueError:
        raise SystemExit(f"invalid FFDS_BENCH_LISTEN={LISTEN!r}, expected host:port")
    server = ThreadingHTTPServer((host, port), Handler)
    log(f"listening on {LISTEN}, results dir {RESULTS_DIR}")
    server.serve_forever()


if __name__ == "__main__":
    main()
