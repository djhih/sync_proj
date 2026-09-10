#!/usr/bin/env python3
"""FFDS sync monitor -- Prometheus exporter fed by the event log only.

Reads /var/log/ffds-sync/events.log written by ffds_sync.sh (v3) and
serves /metrics and /status. That file is the whole contract: no /proc
walking, no pgrep, no mount checks, no rsync log parsing -- the sync
script already knows what it is doing and writes it down as it happens
(event format documented in the script header and in README.md).

Reading is incremental (inode + offset, restarts on rotation or
truncation) and happens on scrape under a lock; there is no sampler
thread. On start the last FFDS_SYNC_REPLAY_BYTES of history are
replayed, so results and batch timestamps survive a restart.

What "running" means here: a job is open from job_start until its
job_end, until the batch it belongs to ends, or until a newer job_start
for the same subpath supersedes it. A job whose last activity (start or
progress) is older than a few minutes is stuck -- that is the alert.

Metrics are emitted only when measured -- absent means "not running /
not reported", never zero.

Env knobs:
  FFDS_SYNC_LISTEN         default 127.0.0.1:9755
  FFDS_SYNC_EVENT_LOG      default /var/log/ffds-sync/events.log
  FFDS_SYNC_REPLAY_BYTES   history replayed on start, default 16 MiB
"""
import collections
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = os.environ.get("FFDS_SYNC_LISTEN", "127.0.0.1:9755")
EVENT_LOG = os.environ.get("FFDS_SYNC_EVENT_LOG", "/var/log/ffds-sync/events.log")
REPLAY_BYTES = int(os.environ.get("FFDS_SYNC_REPLAY_BYTES", str(16 * 1024 * 1024)))

KNOWN_EVENTS = {"batch_start", "batch_end", "batch_abort",
                "job_start", "job_progress", "job_stats", "job_end"}


def log(msg):
    print(f"[ffds-sync-monitor] {msg}", file=sys.stderr, flush=True)


# ── Parsers (pure functions) ─────────────────────────────────────────────────

# rsync -h uses decimal units (powers of 1000).
_UNITS = {"K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15}


def parse_human_size(s):
    """'1.23G', '12.34MB', '12.34MB/s', '1,234' -> float, or None."""
    s = s.strip().replace(",", "")
    if s.endswith("/s"):
        s = s[:-2]
    if s.endswith(("B", "b")):
        s = s[:-1]
    mult = 1.0
    if s and s[-1].upper() in _UNITS:
        mult = _UNITS[s[-1].upper()]
        s = s[:-1]
    try:
        return float(s) * mult
    except ValueError:
        return None


def parse_eta(s):
    """'0:12:34' -> 754; '?:??:??' -> None."""
    if "?" in s:
        return None
    try:
        secs = 0
        for part in s.split(":"):
            secs = secs * 60 + int(part)
        return secs
    except ValueError:
        return None


def parse_event(line):
    """logfmt event line -> (ts, event, fields) ; None for blank lines;
    False for lines that are not well-formed events."""
    line = line.strip()
    if not line:
        return None
    fields = {}
    for tok in line.split():
        k, sep, v = tok.partition("=")
        if not sep or not k:
            return False
        fields[k] = v
    try:
        ts = float(fields["ts"])
    except (KeyError, ValueError):
        return False
    event = fields.get("event")
    if event not in KNOWN_EVENTS:
        return False
    return ts, event, fields


def progress_from_fields(f):
    out = {}
    v = parse_human_size(f.get("bytes", ""))
    if v is not None:
        out["transferred_bytes"] = v
    try:
        out["ratio"] = int(f["pct"]) / 100.0
    except (KeyError, ValueError):
        pass
    v = parse_human_size(f.get("speed", ""))
    if v is not None:
        out["speed_bps"] = v
    v = parse_eta(f.get("eta", "?"))
    if v is not None:
        out["eta_seconds"] = v
    try:
        out["files_transferred"] = int(f["xfr"])
    except (KeyError, ValueError):
        pass
    try:
        rem, tot = f["chk"].split("/")
        out["files_remaining"] = int(rem)
        out["files_total"] = int(tot)
    except (KeyError, ValueError):
        pass
    return out


_STATS_KEYS = {"files": "files_total", "created": "files_created",
               "deleted": "files_deleted", "transferred": "files_transferred",
               "size": "total_size_bytes", "listgen": "list_generation_seconds",
               "speedup": "speedup"}


def stats_from_fields(f):
    out = {}
    for k, name in _STATS_KEYS.items():
        if k in f:
            v = parse_human_size(f[k])
            if v is not None:
                out[name] = v
    return out


# ── Incremental log follower ─────────────────────────────────────────────────

class Follower:
    """Remembers (inode, offset); starts over on rotation/truncation."""

    def __init__(self, path):
        self.path = path
        self.inode = None
        self.offset = 0

    def read_new_lines(self):
        try:
            st = os.stat(self.path)
        except OSError:
            self.inode, self.offset = None, 0
            return []
        if st.st_ino != self.inode or st.st_size < self.offset:
            self.inode, self.offset = st.st_ino, 0
            if st.st_size > REPLAY_BYTES:
                self.offset = st.st_size - REPLAY_BYTES
        try:
            with open(self.path, "rb") as f:
                f.seek(self.offset)
                chunk = f.read()
        except OSError:
            return []
        end = chunk.rfind(b"\n")   # a partially written last line waits
        if end < 0:
            return []
        self.offset += end + 1
        return chunk[:end].decode("utf-8", errors="replace").splitlines()


# ── State ────────────────────────────────────────────────────────────────────

def new_result():
    return {"runs": collections.Counter(), "last_exit": None,
            "last_end_ts": None, "last_success_ts": None,
            "last_duration": None, "stats": None}


class State:
    def __init__(self):
        self.follower = Follower(EVENT_LOG)
        self.batch = None           # dict while a batch is open
        self.last_batch_end_ts = None
        self.batch_config_total = None
        self.aborts = collections.Counter()      # reason -> n
        self.jobs = {}              # subpath -> open job dict
        self.results = {}           # subpath -> result dict
        self.pending_stats = {}     # (subpath, run) -> stats dict
        self.events = collections.Counter()
        self.parse_errors = collections.Counter()
        self.last_event_ts = None
        self.last_read_ts = None

    def consume(self):
        for line in self.follower.read_new_lines():
            parsed = parse_event(line)
            if parsed is None:
                continue
            if parsed is False:
                self.parse_errors["event"] += 1
                continue
            ts, event, f = parsed
            self.events[event] += 1
            self.last_event_ts = ts
            try:
                getattr(self, "on_" + event)(ts, f)
            except (KeyError, ValueError):
                self.parse_errors["fields"] += 1
        self.last_read_ts = time.time()

    # -- batch ---------------------------------------------------------------

    def on_batch_start(self, ts, f):
        self.batch = {"pid": f["pid"], "started": ts,
                      "total": int(f["total"]), "completed": set()}
        self.batch_config_total = int(f["total"])
        # a previous batch that never logged its end is over now
        self.jobs = {s: j for s, j in self.jobs.items()
                     if j.get("batch") in (None, f["pid"])}

    def _close_batch(self, ts, pid):
        if self.batch and self.batch["pid"] == pid:
            self.jobs = {s: j for s, j in self.jobs.items()
                         if j.get("batch") != pid}
            self.batch = None
        if self.last_batch_end_ts is None or ts > self.last_batch_end_ts:
            self.last_batch_end_ts = ts

    def on_batch_end(self, ts, f):
        self._close_batch(ts, f["pid"])

    def on_batch_abort(self, ts, f):
        self.aborts[f.get("reason", "unknown")] += 1
        # lock-busy is the *second* batch giving up; the running one
        # is unaffected
        if f.get("reason") != "lock-busy":
            self._close_batch(ts, f["pid"])

    # -- jobs ----------------------------------------------------------------

    def on_job_start(self, ts, f):
        self.jobs[f["subpath"]] = {"run": f["run"], "batch": f.get("batch"),
                                   "started": ts, "last_activity": ts,
                                   "progress": None}

    def _job_for(self, f):
        j = self.jobs.get(f["subpath"])
        return j if j and j["run"] == f["run"] else None

    def on_job_progress(self, ts, f):
        j = self._job_for(f)
        if j is None:
            return
        j["last_activity"] = ts
        j["progress"] = progress_from_fields(f)

    def on_job_stats(self, ts, f):
        self.pending_stats[(f["subpath"], f["run"])] = stats_from_fields(f)

    def on_job_end(self, ts, f):
        sub = f["subpath"]
        code = f["exit"]
        r = self.results.setdefault(sub, new_result())
        r["runs"][code] += 1
        r["last_exit"] = code
        r["last_end_ts"] = ts
        r["last_duration"] = float(f["duration"])
        if code == "0":
            r["last_success_ts"] = ts
        stats = self.pending_stats.pop((sub, f["run"]), None)
        if stats:
            r["stats"] = stats
        j = self._job_for(f)
        if j is not None:
            del self.jobs[sub]
        if self.batch and f.get("batch") == self.batch["pid"]:
            self.batch["completed"].add(sub)


STATE = State()
LOCK = threading.Lock()


# ── Rendering ────────────────────────────────────────────────────────────────

def esc(v):
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def render_metrics():
    with LOCK:
        STATE.consume()
        s = STATE
        now = time.time()
        out = []
        add = out.append

        def family(name, mtype, help_text, rows):
            rows = [r for r in rows if r[1] is not None]
            if not rows:
                return
            add(f"# HELP {name} {help_text}")
            add(f"# TYPE {name} {mtype}")
            for labels, value in rows:
                lbl = ("{" + ",".join(f'{k}="{esc(str(v))}"'
                                      for k, v in labels.items()) + "}"
                       if labels else "")
                if isinstance(value, float):
                    add(f"{name}{lbl} {value:.6f}".rstrip("0").rstrip("."))
                else:
                    add(f"{name}{lbl} {value}")

        jobs, results = s.jobs, s.results

        # A. running jobs
        family("ffds_sync_all_running", "gauge",
               "1 while a batch (ffds_sync.sh all) is open in the event log.",
               [({}, int(s.batch is not None))])
        family("ffds_sync_jobs_running", "gauge",
               "Jobs with job_start but no job_end yet.",
               [({}, len(jobs))])
        family("ffds_sync_job_active", "gauge",
               "1 while a job runs; phase=scan until the first progress "
               "event, transfer afterwards.",
               [({"subpath": sub,
                  "phase": "transfer" if j["progress"] else "scan"}, 1)
                for sub, j in jobs.items()])
        family("ffds_sync_job_runtime_seconds", "gauge",
               "Seconds since the job's job_start event.",
               [({"subpath": sub}, max(0.0, now - j["started"]))
                for sub, j in jobs.items()])
        family("ffds_sync_job_last_activity_timestamp_seconds", "gauge",
               "Unix time of the job's last event (start or progress). "
               "time() minus this is how long the job has been silent -- "
               "the stuck signal.",
               [({"subpath": sub}, j["last_activity"]) for sub, j in jobs.items()])

        def progress_rows(key):
            return [({"subpath": sub}, j["progress"].get(key))
                    for sub, j in jobs.items() if j["progress"]]

        family("ffds_sync_job_progress_ratio", "gauge",
               "Whole-transfer completion 0-1 from the last progress event. "
               "With incremental recursion the total grows during the scan.",
               progress_rows("ratio"))
        family("ffds_sync_job_transferred_bytes", "gauge",
               "Bytes transferred so far in the running job.",
               progress_rows("transferred_bytes"))
        family("ffds_sync_job_speed_bytes_per_second", "gauge",
               "Transfer speed as reported by rsync.",
               progress_rows("speed_bps"))
        family("ffds_sync_job_eta_seconds", "gauge",
               "rsync's own remaining-time estimate.",
               progress_rows("eta_seconds"))
        family("ffds_sync_job_files_remaining", "gauge",
               "Files left to check (to-chk / ir-chk numerator).",
               progress_rows("files_remaining"))
        family("ffds_sync_job_files_total", "gauge",
               "Files in the transfer list so far (to-chk / ir-chk denominator).",
               progress_rows("files_total"))
        family("ffds_sync_job_files_transferred", "gauge",
               "Files transferred so far (xfr# counter).",
               progress_rows("files_transferred"))

        # B. results
        family("ffds_sync_runs_total", "counter",
               "Finished runs per subpath by exit code (0 = success; 90-94 "
               "are the script's own preflight/lock codes). Resets when the "
               "monitor restarts beyond its replay window or the log rotates.",
               [({"subpath": sub, "exit_code": code}, n)
                for sub, r in results.items() for code, n in r["runs"].items()])
        family("ffds_sync_last_result", "gauge",
               "Whether the last finished run for this subpath succeeded.",
               [({"subpath": sub}, int(r["last_exit"] == "0"))
                for sub, r in results.items() if r["last_exit"] is not None])
        family("ffds_sync_last_run_exit_code", "gauge",
               "Exit code of the last finished run.",
               [({"subpath": sub}, int(r["last_exit"]))
                for sub, r in results.items() if r["last_exit"] is not None])
        family("ffds_sync_last_success_timestamp_seconds", "gauge",
               "Unix time of the last successful run.",
               [({"subpath": sub}, r["last_success_ts"]) for sub, r in results.items()])
        family("ffds_sync_last_run_duration_seconds", "gauge",
               "Wall time of the last finished run.",
               [({"subpath": sub}, r["last_duration"]) for sub, r in results.items()])

        def stats_rows(key):
            return [({"subpath": sub}, r["stats"].get(key))
                    for sub, r in results.items() if r["stats"]]

        family("ffds_sync_last_run_files_transferred", "gauge",
               "Regular files transferred in the last finished run (stats2).",
               stats_rows("files_transferred"))
        family("ffds_sync_last_run_files_deleted", "gauge",
               "Files deleted in the last finished run. --delete propagates "
               "source-side deletions; the deleted names are in the job log.",
               stats_rows("files_deleted"))
        family("ffds_sync_last_run_files_total", "gauge",
               "Total files enumerated in the last finished run.",
               stats_rows("files_total"))
        family("ffds_sync_last_run_total_size_bytes", "gauge",
               "Total size of the subpath as of the last finished run.",
               stats_rows("total_size_bytes"))
        family("ffds_sync_last_run_list_generation_seconds", "gauge",
               "rsync file list generation time of the last run (small "
               "under incremental recursion).",
               stats_rows("list_generation_seconds"))
        family("ffds_sync_last_run_speedup_ratio", "gauge",
               "rsync speedup of the last run.",
               stats_rows("speedup"))

        # C. batch
        b = s.batch
        family("ffds_sync_batch_subpaths_completed", "gauge",
               "Subpaths finished (any exit code) in the open batch. "
               "Absent while no batch runs.",
               [({}, len(b["completed"]) if b else None)])
        family("ffds_sync_config_subpaths", "gauge",
               "Subpaths the last batch was started with (total= of "
               "batch_start).",
               [({}, s.batch_config_total)])
        family("ffds_sync_batch_runtime_seconds", "gauge",
               "Seconds since the open batch started.",
               [({}, max(0.0, now - b["started"]) if b else None)])
        family("ffds_sync_batch_last_completed_timestamp_seconds", "gauge",
               "Unix time of the last batch_end / batch_abort event.",
               [({}, s.last_batch_end_ts)])
        family("ffds_sync_batch_aborts_total", "counter",
               "Batches that refused to run, by reason (lock-busy, "
               "config-missing, config-empty, mount-missing, tmp-failed, "
               "signal).",
               [({"reason": k}, n) for k, n in s.aborts.items()])

        # D. monitor self
        family("ffds_sync_events_total", "counter",
               "Event lines consumed, by event.",
               [({"event": k}, n) for k, n in s.events.items()])
        family("ffds_sync_parse_errors_total", "counter",
               "Event lines the monitor could not parse, by kind. First "
               "thing to light up on a log format change.",
               [({"kind": k}, n) for k, n in s.parse_errors.items()])
        family("ffds_sync_log_last_event_timestamp_seconds", "gauge",
               "ts= of the newest event seen.",
               [({}, s.last_event_ts)])
        family("ffds_sync_monitor_last_read_timestamp_seconds", "gauge",
               "Unix time the monitor last read the event log (on scrape).",
               [({}, s.last_read_ts)])

        return "\n".join(out) + "\n"


def fmt_dur(seconds):
    if seconds is None:
        return "?"
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}h{m:02d}m" if h else (f"{m}m{sec:02d}s" if m else f"{sec}s")


def fmt_bytes(n):
    if n is None:
        return "?"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1000:
            return f"{n:.1f}{unit}"
        n /= 1000
    return f"{n:.1f}PB"


def render_status():
    with LOCK:
        STATE.consume()
        s = STATE
        now = time.time()
        lines = ["ffds-sync monitor status", f"event log: {EVENT_LOG}"]
        if s.last_event_ts:
            lines.append(f"last event {fmt_dur(now - s.last_event_ts)} ago")
        else:
            lines.append("no events seen yet")
        if s.batch:
            b = s.batch
            lines.append(f"batch pid={b['pid']}: {len(b['completed'])}/"
                         f"{b['total']} done, up {fmt_dur(now - b['started'])}")
        else:
            lines.append("batch: not running")
        lines.append(f"jobs: {len(s.jobs)} running")
        for sub, j in sorted(s.jobs.items()):
            p = j["progress"] or {}
            lines.append(
                f"  {sub}  run={j['run']}  up={fmt_dur(now - j['started'])}  "
                f"silent={fmt_dur(now - j['last_activity'])}  "
                f"phase={'transfer' if p else 'scan'}"
                + (f"  {p.get('ratio', 0) * 100:.0f}% "
                   f"{fmt_bytes(p.get('transferred_bytes'))} "
                   f"@ {fmt_bytes(p.get('speed_bps'))}/s "
                   f"eta {fmt_dur(p.get('eta_seconds'))}" if p else ""))
        lines.append("last results:")
        for sub, r in sorted(s.results.items()):
            when = (time.strftime("%F %T", time.localtime(r["last_end_ts"]))
                    if r["last_end_ts"] else "?")
            extra = ""
            if r["stats"]:
                parts = [f"{k.replace('files_', '')}={v:.0f}"
                         for k, v in sorted(r["stats"].items())
                         if k in ("files_total", "files_transferred",
                                  "files_deleted")]
                if parts:
                    extra = "  (" + " ".join(parts) + ")"
            lines.append(f"  {sub}: exit {r['last_exit']} at {when}, "
                         f"took {fmt_dur(r['last_duration'])}{extra}")
        if s.aborts:
            lines.append("batch aborts: " + ", ".join(
                f"{k}={n}" for k, n in sorted(s.aborts.items())))
        return "\n".join(lines) + "\n"


# ── HTTP ─────────────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            if self.path in ("/", "/metrics"):
                body = render_metrics().encode()
            elif self.path == "/status":
                body = render_status().encode()
            else:
                self.send_error(404)
                return
        except Exception as e:  # a bad log line must not turn into a 500
            log(f"render failed: {type(e).__name__}: {e}")
            body = f"# ffds-sync monitor: render failed: {type(e).__name__}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # per-scrape access logs are noise


def main():
    host, _, port = LISTEN.rpartition(":")
    try:
        port = int(port)
    except ValueError:
        raise SystemExit(f"invalid FFDS_SYNC_LISTEN={LISTEN!r}, expected host:port")
    server = ThreadingHTTPServer((host, port), Handler)
    log(f"listening on {LISTEN}, event log {EVENT_LOG}")
    server.serve_forever()


if __name__ == "__main__":
    main()
