#!/usr/bin/env python3
"""ffds_v1_measure.py -- helper for ffds-v1-measure.sh

Measures the production v1 sync script (sync_ffds.sh) with the bench's run
definitions.  The bench is never modified: ffds_bench_data.py is imported
read-only (path-guard building blocks, cifs parsing, JSON writing) so a v1
number means the same thing as the bench number with the same field name.

Subcommands:
  instrument     --src F --out F --diff F --src-root D --dst-root D
                 --log-dir D --tag T
                 make the instrumented copy of v1; refuses when v1 does
                 not have the known shape (anchor counts)
  init-scratch   --scratch-base D --expect-mount M --id ID
  remove-target  --scratch-base D --expect-mount M --id ID --subpath S
  remove-files   --scratch-base D --expect-mount M --id ID --subpath S --list F
  assemble       --run-dir D --manifest F --out F ... --expect-transferred N
                 merge one run's evidence into result.json, compute valid
  csv            --outdir D
  summary        --outdir D

Exit codes: 0 ok; 2 refused (guard/validation); 1 unexpected error.
"""
import argparse
import difflib
import hashlib
import json
import os
import re
import shutil
import stat
import sys

sys.dont_write_bytecode = True   # never drop a __pycache__ into the bench dir
sys.path.insert(0, os.environ.get("FFDS_BENCH_DIR") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "bench"))
from ffds_bench_data import (  # noqa: E402
    Refused, assert_no_symlink_walk, atomic_json, cifs_delta, median,
    mount_point_of, mounts_under, valid_subpath)

SCHEMA = "ffds-v1-measure/1"
DATASET = "DataSet"
MARKER = ".ffds-v1-measure"
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

# site literals of sync-host:/usr/local/ffds/sync_ffds.sh that this helper
# rewrites; the destination variable is found by its value, not its name
V1_SRC_ROOT = "/mnt/src-share/DataSet"
V1_DST_ROOT = "/mnt/dst-fs/DataSet"
V1_SRC = V1_SRC_ROOT + "/$1"
V1_LOG = "/var/log/rsync-smb"
V1_FIND = "find $targetPath"
V1_FIND_COUNT = 4   # owner count, chown, chmod files, chmod dirs


def die(msg, code=2):
    print(f"ffds-v1-measure: {msg}", file=sys.stderr)
    sys.exit(code)


def out_json(obj):
    json.dump(obj, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")


# ── instrumented copy ────────────────────────────────────────────────────────

def marker(event, extra=""):
    return f'echo "V1MEASURE event={event}{extra} t=$(date +%s.%N)"'


def instrument(text, src_root, dst_root, log_dir, header):
    """Return the instrumented script text.  Only these lines change:
    the destination variable, the rsync line (source root + --stats),
    the log path; added: header comments and three marker lines."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "#!/bin/bash":
        raise Refused("line 1 is not '#!/bin/bash' -- a pasted terminal "
                      "capture? copy the file itself from sync-host")

    def only(pred, what):
        idx = [i for i, l in enumerate(lines) if pred(l)]
        if len(idx) != 1:
            raise Refused(f"anchor {what!r} matched {len(idx)} lines, want 1 "
                          "-- this is not the known v1; review before measuring")
        return idx[0]

    dst_rx = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=" + re.escape(V1_DST_ROOT))
    i_dst = only(dst_rx.fullmatch, "<var>=" + V1_DST_ROOT)
    dst_var = dst_rx.fullmatch(lines[i_dst]).group(1)
    i_rsync = only(lambda l: l.lstrip().startswith("rsync ") and V1_SRC in l,
                   "rsync ... " + V1_SRC)
    finds = [i for i, l in enumerate(lines) if V1_FIND in l]
    if len(finds) != V1_FIND_COUNT:
        raise Refused(f"{V1_FIND!r} on {len(finds)} lines, want {V1_FIND_COUNT}")
    if not i_dst < i_rsync < finds[0]:
        raise Refused("unexpected order: destination, rsync, find sweeps")
    if not any(V1_LOG in l for l in lines):
        raise Refused(f"log path {V1_LOG!r} not found")

    def indent(l):
        return re.match(r"\s*", l).group(0)

    out = []
    for i, line in enumerate(lines):
        line = line.replace(V1_LOG, log_dir + "/rsync-smb")
        if i == i_dst:
            line = f"{dst_var}={dst_root}"
        if i == i_rsync:
            ind = indent(line)
            out.append(ind + marker("rsync_start"))
            out.append(line.replace(V1_SRC, src_root + "/$1")
                           .replace("rsync ", "rsync --stats ", 1))
            out.append(ind + "v1mRc=$?; " + marker("rsync_end", " rc=$v1mRc"))
            continue
        out.append(line)
        if i == 0:
            out.extend(header)
        if i == finds[-1]:
            out.append(indent(line) + marker("fixup_end"))
    result = "\n".join(out)
    for bad in (V1_DST_ROOT, V1_LOG):
        if bad in result:
            raise Refused(f"production path {bad!r} survived instrumenting")
    return result


def cmd_instrument(a):
    if os.path.normpath(a.dst_root) == V1_DST_ROOT:
        raise Refused("destination is the production dataset root")
    with open(a.src) as f:
        text = f.read()
    sha = hashlib.sha256(text.encode()).hexdigest()
    header = [f"# INSTRUMENTED COPY for ffds-v1-measure {a.tag} -- never deploy.",
              f"# original: {a.src} sha256={sha}"]
    new = instrument(text, a.src_root, a.dst_root, a.log_dir, header)
    with open(a.out, "w") as f:
        f.write(new)
    os.chmod(a.out, 0o700)
    diff = difflib.unified_diff(text.split("\n"), new.split("\n"),
                                a.src, a.out, lineterm="")
    with open(a.diff, "w") as f:
        f.write("\n".join(diff) + "\n")
    out_json({"src": a.src, "src_sha256": sha, "copy": a.out})


# ── scratch destination guards ───────────────────────────────────────────────

def guard(a, need_exist=False):
    """Validate the write/delete target <base>/<id>/DataSet/<sub>
    and return it.  Same rules as the bench's guard: component-wise
    containment, symlink-free ancestors, expected mount, private id root
    carrying our marker, no nested mounts."""
    base = a.scratch_base
    if not os.path.isabs(base) or base != os.path.normpath(base):
        raise Refused(f"scratch base must be absolute+normalized: {base}")
    if os.path.islink(base) or not os.path.isdir(base):
        raise Refused(f"scratch base missing or not a plain directory: {base}")
    mp = mount_point_of(base)
    if mp != a.expect_mount:
        raise Refused(f"scratch base on mount {mp!r}, expected {a.expect_mount!r}")
    if not ID_RE.match(a.id):
        raise Refused(f"bad id {a.id!r}")
    if not valid_subpath(a.subpath):
        raise Refused(f"bad subpath {a.subpath!r}")
    root = os.path.join(base, a.id)
    if os.path.islink(root) or not os.path.isdir(root):
        raise Refused(f"id root missing or not a plain directory: {root}")
    st = os.lstat(root)
    if st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o700:
        raise Refused(f"id root not private to uid {os.geteuid()}: {root}")
    try:
        with open(os.path.join(root, MARKER)) as f:
            if f.read().strip() != a.id:
                raise Refused("id marker mismatch")
    except OSError:
        raise Refused(f"id marker missing: {root}/{MARKER}")
    rel = [DATASET] + a.subpath.split("/")
    assert_no_symlink_walk(root, rel)
    target = os.path.join(root, *rel)
    if os.path.normpath(target) in (os.path.normpath(root),
                                    os.path.normpath(os.path.join(root, DATASET))):
        raise Refused(f"target equals a protected root: {target}")
    nested = mounts_under(root)
    if nested:
        raise Refused(f"unexpected nested mounts under {root}: {nested}")
    if need_exist and not os.path.lexists(target):
        raise Refused(f"target missing: {target}")
    return target


def cmd_init_scratch(a):
    base = a.scratch_base
    if os.path.islink(base) or not os.path.isdir(base):
        raise Refused(f"scratch base missing or a symlink: {base}")
    mp = mount_point_of(base)
    if mp != a.expect_mount:
        raise Refused(f"scratch base on mount {mp!r}, expected {a.expect_mount!r}")
    if not ID_RE.match(a.id):
        raise Refused(f"bad id {a.id!r}")
    root = os.path.join(base, a.id)
    try:
        os.mkdir(root, 0o700)
    except FileExistsError:
        raise Refused(f"id root already exists (never reused): {root}")
    os.chmod(root, 0o700)
    with open(os.path.join(root, MARKER), "w") as f:
        f.write(a.id + "\n")
    # production's dataset root pre-exists on WEKA; so must ours
    os.mkdir(os.path.join(root, DATASET))
    out_json({"dst_root": os.path.join(root, DATASET)})


def cmd_remove_target(a):
    target = guard(a)
    if not os.path.lexists(target):
        out_json({"removed": False, "reason": "absent"})
        return
    if os.path.islink(target):
        raise Refused(f"target itself is a symlink: {target}")
    if os.path.isdir(target):
        if not shutil.rmtree.avoids_symlink_attacks:
            raise Refused("shutil.rmtree cannot avoid symlink attacks here")
        shutil.rmtree(target)
    else:
        os.unlink(target)
    out_json({"removed": True, "target": target})


def cmd_remove_files(a):
    target = guard(a, need_exist=True)
    with open(a.list) as f:
        rels = json.load(f)
    if not isinstance(rels, list) or not rels:
        raise Refused("removal list empty or not a list")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    for rel in rels:
        if not valid_subpath(rel):
            raise Refused(f"bad relative path in list: {rel!r}")
        parts = rel.split("/")
        fd = os.open(target, flags)
        try:
            for part in parts[:-1]:
                nfd = os.open(part, flags, dir_fd=fd)
                os.close(fd)
                fd = nfd
            if not stat.S_ISREG(os.lstat(parts[-1], dir_fd=fd).st_mode):
                raise Refused(f"not a regular file: {rel}")
            os.unlink(parts[-1], dir_fd=fd)
        finally:
            os.close(fd)
    out_json({"removed": len(rels)})


# ── run evidence parsing ─────────────────────────────────────────────────────

def _count(s):
    """rsync --stats file counts are comma-grouped ("2,084")."""
    return int(s.replace(",", "")) if re.fullmatch(r"[0-9][0-9,]*", s) else None


STATS = [  # (regex on one stripped line, key, converter); last match wins
    (r"^Number of files: (\S+)", "rsync_files", _count),
    (r"^Number of created files: (\S+)", "files_created", _count),
    (r"^Number of deleted files: (\S+)", "files_deleted", _count),
    (r"^Number of regular files transferred: (\S+)", "files_transferred", _count),
    (r"^Total file size: (\S+) bytes", "rsync_total_size", str),
    (r"^Total transferred file size: (\S+) bytes", "rsync_transferred_size", str),
    (r"^File list generation time: ([0-9.]+) seconds", "rsync_listgen_s", float),
    (r"speedup is (\S+)", "rsync_speedup", str),
]


def parse_job_log(path):
    """v1's own log for the run: marker events + rsync --stats block."""
    markers, stats = {}, {k: None for _, k, _ in STATS}
    try:
        with open(path, errors="replace") as f:
            text = f.read()
    except OSError:
        return markers, stats
    for raw in text.replace("\r", "\n").split("\n"):
        line = raw.strip()
        if line.startswith("V1MEASURE "):
            fields = dict(t.partition("=")[::2] for t in line.split()[1:])
            markers[fields.get("event")] = fields
            continue
        for rx, key, conv in STATS:
            m = re.search(rx, line)
            if m:
                try:
                    stats[key] = conv(m.group(1))
                except ValueError:
                    stats[key] = None
    return markers, stats


TIME_FIELDS = {  # GNU time -v label -> (key, converter)
    "User time (seconds)": ("time_user_s", float),
    "System time (seconds)": ("time_sys_s", float),
    "Maximum resident set size (kbytes)": ("time_max_rss_kb", int),
    "File system inputs": ("time_fs_inputs", int),
    "File system outputs": ("time_fs_outputs", int),
    "Voluntary context switches": ("time_vol_cs", int),
    "Involuntary context switches": ("time_invol_cs", int),
    "Exit status": ("time_exit", int),
}


def parse_time(path):
    out = {k: None for k, _ in TIME_FIELDS.values()}
    out["time_elapsed_s"] = None
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        return out
    for line in lines:
        label, _, value = line.strip().rpartition(": ")
        if label.startswith("Elapsed (wall clock) time"):
            try:  # h:mm:ss or m:ss.ss
                secs = 0.0
                for part in value.split(":"):
                    secs = secs * 60 + float(part)
                out["time_elapsed_s"] = round(secs, 3)
            except ValueError:
                pass
        elif label in TIME_FIELDS:
            key, conv = TIME_FIELDS[label]
            try:
                out[key] = conv(value)
            except ValueError:
                pass
    return out


def _ts(markers, event):
    try:
        return float(markers[event]["t"])
    except (KeyError, TypeError, ValueError):
        return None


FIELDS = [
    "schema", "id", "run_id", "engine", "scenario", "rep", "subpath",
    "started_ts", "finished_ts", "duration_s", "engine_s", "fixup_s",
    "valid", "invalid_reasons", "job_ran", "script_exit", "worker_exit",
    "rsync_exit", "forced",
    "source_manifest_sha256", "source_files_total", "source_dirs_total",
    "source_size_bytes", "source_unchanged", "destination_verified",
    "files_transferred", "files_deleted", "files_created", "rsync_files",
    "rsync_total_size", "rsync_transferred_size", "rsync_listgen_s",
    "rsync_speedup",
    "cpu_usec", "io_rbytes", "io_wbytes", "mem_peak_bytes",
    "resource_complete", "resource_missing",
    "time_elapsed_s", "time_user_s", "time_sys_s", "time_max_rss_kb",
    "time_fs_inputs", "time_fs_outputs", "time_vol_cs", "time_invol_cs",
    "time_exit",
    "cifs_create_delta", "cifs_queryinfo_delta", "cifs_close_delta",
    "cifs_reads_delta", "cifs_reconnects_delta",
    "other_sync_running", "interference_observation_ok",
    "cache_policy", "drop_caches_ok", "v1_script_sha256",
]


def cmd_assemble(a):
    def load(name):
        try:
            with open(os.path.join(a.run_dir, name)) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    res = load("resource.json")
    with open(a.manifest) as f:
        man = json.load(f)
    markers, stats = parse_job_log(os.path.join(a.run_dir, "job.log"))
    t_start, t_rsync = _ts(markers, "rsync_start"), _ts(markers, "rsync_end")
    t_fixup = _ts(markers, "fixup_end")
    try:
        rsync_exit = int(markers["rsync_end"]["rc"])
    except (KeyError, ValueError):
        rsync_exit = None
    job_ran = int(None not in (t_start, t_rsync, t_fixup))
    cifs = os.path.join(a.run_dir, "cifs.pre"), os.path.join(a.run_dir, "cifs.post")

    rec = {
        "schema": SCHEMA, "id": a.id, "run_id": a.run_id, "engine": "v1",
        "scenario": a.scenario, "rep": a.rep, "subpath": a.subpath,
        "started_ts": a.started, "finished_ts": a.finished,
        "duration_s": res.get("elapsed_s"),
        "engine_s": round(t_rsync - t_start, 3) if job_ran else None,
        "fixup_s": round(t_fixup - t_rsync, 3) if job_ran else None,
        "job_ran": job_ran, "script_exit": a.script_exit,
        "worker_exit": res.get("child_exit"), "rsync_exit": rsync_exit,
        "forced": a.forced,
        "source_manifest_sha256": man["sha256"],
        "source_files_total": man["source_files_total"],
        "source_dirs_total": man["source_dirs_total"],
        "source_size_bytes": man["source_size_bytes"],
        "source_unchanged": a.src_ok, "destination_verified": a.dst_ok,
        **stats,
        "cpu_usec": res.get("cpu_usec"),
        "io_rbytes": res.get("io_rbytes"), "io_wbytes": res.get("io_wbytes"),
        "mem_peak_bytes": res.get("mem_peak_bytes"),
        "resource_complete": 0 if res.get("resource_missing", ["no-file"]) else 1,
        "resource_missing": res.get("resource_missing", ["resource.json"]),
        **parse_time(os.path.join(a.run_dir, "time.txt")),
        "cifs_create_delta": cifs_delta(*cifs, "Creates"),
        "cifs_queryinfo_delta": cifs_delta(*cifs, "QueryInfos"),
        "cifs_close_delta": cifs_delta(*cifs, "Closes"),
        "cifs_reads_delta": cifs_delta(*cifs, "Reads"),
        "cifs_reconnects_delta": cifs_delta(*cifs, "Reconnects"),
        "other_sync_running": (None if a.watcher_ok != 1
                               else int(a.interference_delta > 0)),
        "interference_observation_ok": a.watcher_ok,
        "cache_policy": a.cache_policy,
        "drop_caches_ok": None if a.drop_ok == "null" else int(a.drop_ok),
        "v1_script_sha256": a.v1_sha,
    }

    reasons = []

    def req(cond, why):
        if not cond:
            reasons.append(why)
    req(job_ran, "job did not run (no rsync markers: v1 pgrep guard skipped "
                 "it, or it died early)")
    req(rsync_exit == 0, "rsync exit nonzero or missing (v1 itself exits 0 anyway)")
    req(a.script_exit == 0, "script exit nonzero")
    req(rec["worker_exit"] == a.script_exit, "worker/script exit mismatch")
    req(not a.forced, "forced run")
    req(isinstance(rec["duration_s"], (int, float)) and rec["duration_s"] > 0,
        "duration missing or zero")
    req(a.src_ok == 1, "source changed or unchecked")
    req(a.dst_ok == 1, "destination not verified")
    req(rec["other_sync_running"] == 0, "other sync running or unknown")
    req(a.watcher_ok == 1, "interference watch failed")
    if a.cache_policy == "drop":
        req(rec["drop_caches_ok"] == 1, "drop_caches not confirmed")
    req(rec["files_transferred"] == a.expect_transferred,
        f"transferred != expected {a.expect_transferred}")
    req((rec["files_deleted"] or 0) == 0, "files deleted nonzero")
    rec["invalid_reasons"] = reasons
    rec["valid"] = 0 if reasons else 1

    assert set(rec) == set(FIELDS), sorted(set(rec) ^ set(FIELDS))
    atomic_json(a.out, rec, must_create=True)
    out_json({"valid": rec["valid"], "invalid_reasons": reasons,
              "engine_failed": int(not job_ran or rsync_exit != 0
                                   or a.script_exit != 0),
              "duration_s": rec["duration_s"],
              "files_transferred": rec["files_transferred"]})


# ── campaign outputs ─────────────────────────────────────────────────────────

def load_runs(outdir):
    runs = []
    rdir = os.path.join(outdir, "runs")
    for name in sorted(os.listdir(rdir)) if os.path.isdir(rdir) else []:
        path = os.path.join(rdir, name, "result.json")
        if os.path.isfile(path):
            with open(path) as f:
                runs.append(json.load(f))
    runs.sort(key=lambda r: r["started_ts"])
    return runs


def csv_cell(v):
    if v is None:
        return ""
    if isinstance(v, (list, dict)):
        v = json.dumps(v, sort_keys=True)
    s = str(v)
    return '"' + s.replace('"', '""') + '"' if any(c in s for c in ',"\n') else s


def cmd_csv(a):
    runs = load_runs(a.outdir)
    lines = [",".join(FIELDS)]
    lines += [",".join(csv_cell(r.get(k)) for k in FIELDS) for r in runs]
    path = os.path.join(a.outdir, "results.csv")
    with open(path + ".tmp", "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(path + ".tmp", path)
    out_json({"rows": len(runs)})


def cmd_summary(a):
    runs = load_runs(a.outdir)

    def med(rs, key, fn=None):
        vals = [fn(r) if fn else r[key] for r in rs]
        vals = [v for v in vals if isinstance(v, (int, float))]
        m = median(vals)
        return None if m is None else round(m, 3)

    lines = [f"ffds-v1-measure summary  runs={len(runs)}", ""]
    for scenario in ("cold", "warm", "incr"):
        rs = [r for r in runs if r["scenario"] == scenario]
        if not rs:
            continue
        valid = [r for r in rs if r["valid"] == 1]
        line = (f"v1 {scenario:5s} runs={len(rs)} valid={len(valid)}"
                f" median_duration_s={med(valid, 'duration_s')}"
                f" median_rsync_s={med(valid, 'engine_s')}"
                f" median_fixup_s={med(valid, 'fixup_s')}"
                f" median_cpu_s={med(valid, None, lambda r: r['cpu_usec'] / 1e6 if r['cpu_usec'] is not None else None)}")
        if scenario == "cold":
            line += " median_MB_per_s=" + str(med(valid, None, lambda r: (
                r["source_size_bytes"] / r["duration_s"] / 1e6)))
        if scenario == "warm":
            line += " warm_files_per_s=" + str(med(valid, None, lambda r: (
                r["source_files_total"] / r["duration_s"])))
        lines.append(line)
        for r in rs:
            lines.append(
                f"    rep={r['rep']} duration_s={r['duration_s']}"
                f" rsync_s={r['engine_s']} fixup_s={r['fixup_s']}"
                f" transferred={r['files_transferred']} rsync_exit={r['rsync_exit']}"
                f" valid={r['valid']}"
                + (f" invalid={';'.join(r['invalid_reasons'])}"
                   if r["invalid_reasons"] else ""))
    path = os.path.join(a.outdir, "SUMMARY.txt")
    with open(path + ".tmp", "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(path + ".tmp", path)


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(prog="ffds_v1_measure.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("instrument")
    for k in ("--src", "--out", "--diff", "--src-root", "--dst-root",
              "--log-dir", "--tag"):
        sp.add_argument(k, required=True)
    sp.set_defaults(fn=cmd_instrument)

    def guard_parser(name, fn):
        sp = sub.add_parser(name)
        sp.add_argument("--scratch-base", required=True)
        sp.add_argument("--expect-mount", required=True)
        sp.add_argument("--id", required=True)
        sp.set_defaults(fn=fn)
        return sp

    guard_parser("init-scratch", cmd_init_scratch)
    guard_parser("remove-target", cmd_remove_target).add_argument(
        "--subpath", required=True)
    sp = guard_parser("remove-files", cmd_remove_files)
    sp.add_argument("--subpath", required=True)
    sp.add_argument("--list", required=True)

    sp = sub.add_parser("assemble")
    for k in ("--run-dir", "--manifest", "--out", "--id", "--run-id",
              "--scenario", "--subpath", "--cache-policy", "--drop-ok",
              "--v1-sha"):
        sp.add_argument(k, required=True)
    for k in ("--rep", "--script-exit", "--dst-ok", "--src-ok", "--watcher-ok",
              "--interference-delta", "--forced", "--expect-transferred"):
        sp.add_argument(k, type=int, required=True)
    for k in ("--started", "--finished"):
        sp.add_argument(k, type=float, required=True)
    sp.set_defaults(fn=cmd_assemble)

    for name, fn in (("csv", cmd_csv), ("summary", cmd_summary)):
        sp = sub.add_parser(name)
        sp.add_argument("--outdir", required=True)
        sp.set_defaults(fn=fn)

    a = p.parse_args()
    try:
        a.fn(a)
    except Refused as e:
        die(str(e))


if __name__ == "__main__":
    main()
