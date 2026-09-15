#!/usr/bin/env python3
"""ffds-bench data layer: path guards, manifests, per-run results.

Used by ffds-bench.sh as a subprocess toolbox; stdlib only.  Everything
that writes or deletes inside the scratch tree goes through the guard in
this file -- the shell runner never builds an rm -rf path by hand.

Subcommands (all print JSON on stdout unless noted):

  init-campaign  --scratch-base B --expect-mount M --campaign C
                 create <B>/<C> 0700 + owner marker (refuses to reuse)
  guard-target   --scratch-base B --expect-mount M --campaign C
                 --engine E --subpath S
                 validate and print the absolute dataset target path
  safe-remove    (guard-target args)   remove the target tree
  remove-files   (guard-target args) --list FILE
                 delete exactly the listed relative regular files
  manifest       --root DIR --out FILE      local tree -> manifest JSON
  select-incr    --manifest F --n N --seed S --out FILE
  verify-dst     --manifest F --root DIR [--missing-list FILE]
                 [--owner-uid U --owner-gid G --mode 775]
  extract-events --events F --offset N --subpath S
                 the unique job_start/job_stats/job_end after offset
  scope-worker   --manifest FILE
                 runs INSIDE the transient scope: measures the child and
                 its cgroup, saves resource.json, exits with the child rc
  assemble       (many options) build one run's result-input.json from
                 the run dir, events, resource and cifs snapshots
  record         --input FILE --results-root D --outdir-copy DIR
                 [--expect-transferred N] [--no-expectations]
                 validate schema, compute valid, publish atomically
  csv            --results-root D --campaign C --out FILE
  summary        --results-root D --campaign C --out FILE

Exit codes: 0 ok; 2 refused (guard/validation); 1 unexpected error.
"""
import argparse
import hashlib
import json
import os
import random
import re
import shutil
import stat
import sys

SCHEMA_VERSION = 1
DATASET = "DataSet"
MARKER = ".ffds-bench-campaign"
ENGINES = ("v1", "v3", "v4-mount", "v4-smb")
SCENARIOS = ("cold", "warm", "incr")

CAMPAIGN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class Refused(Exception):
    pass


def die(msg, code=2):
    print(f"ffds-bench-data: {msg}", file=sys.stderr)
    sys.exit(code)


def out_json(obj):
    json.dump(obj, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")


# ── subpath / path validation ────────────────────────────────────────────────

def valid_subpath(sub):
    """Same rules as the sync scripts, enforced independently here."""
    if not sub or sub.startswith("/") or sub.endswith("/"):
        return False
    if "\\" in sub or re.search(r"\s", sub):
        return False
    parts = sub.split("/")
    if any(p in ("", ".", "..") for p in parts):
        return False
    return True


def mount_point_of(path):
    """Longest mountinfo mount point that is a prefix of *path* (which
    must be absolute with no symlinks -- the caller checks that)."""
    best = "/"
    with open("/proc/self/mountinfo") as f:
        for line in f:
            fields = line.split()
            mp = re.sub(r"\\([0-7]{3})",
                        lambda m: chr(int(m.group(1), 8)), fields[4])
            if path == mp or path.startswith(mp.rstrip("/") + "/"):
                if len(mp) > len(best):
                    best = mp
    return best


def mounts_under(path):
    """Mount points strictly below *path* (nested mounts)."""
    found = []
    prefix = path.rstrip("/") + "/"
    with open("/proc/self/mountinfo") as f:
        for line in f:
            fields = line.split()
            mp = re.sub(r"\\([0-7]{3})",
                        lambda m: chr(int(m.group(1), 8)), fields[4])
            if mp.startswith(prefix):
                found.append(mp)
    return found


def assert_no_symlink_walk(base, rel_parts):
    """Every existing component from *base* down must be a real directory
    (final component may be any non-symlink).  Raises Refused."""
    cur = base
    for i, part in enumerate(rel_parts):
        cur = os.path.join(cur, part)
        try:
            st = os.lstat(cur)
        except FileNotFoundError:
            return
        if stat.S_ISLNK(st.st_mode):
            raise Refused(f"symlink in path: {cur}")
        if i < len(rel_parts) - 1 and not stat.S_ISDIR(st.st_mode):
            raise Refused(f"non-directory in path: {cur}")


def guard(args, need_exist=False):
    """Validate the full write/delete target and return its path.

    Containment is component-wise construction, never startswith on
    strings; ancestors are re-checked for symlinks; the scratch base must
    sit on the expected mount; the campaign root must carry our marker
    and be private to us.
    """
    base = args.scratch_base
    if not os.path.isabs(base) or base != os.path.normpath(base):
        raise Refused(f"scratch base must be absolute+normalized: {base}")
    st = os.lstat(base) if os.path.lexists(base) else None
    if st is None:
        raise Refused(f"scratch base missing: {base}")
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        raise Refused(f"scratch base not a plain directory: {base}")
    mp = mount_point_of(base)
    if mp != args.expect_mount:
        raise Refused(f"scratch base on mount {mp!r}, expected {args.expect_mount!r}")

    if not CAMPAIGN_RE.match(args.campaign):
        raise Refused(f"bad campaign id {args.campaign!r}")
    if args.engine not in ENGINES:
        raise Refused(f"bad engine {args.engine!r}")
    if not valid_subpath(args.subpath):
        raise Refused(f"bad subpath {args.subpath!r}")

    croot = os.path.join(base, args.campaign)
    cst = os.lstat(croot) if os.path.lexists(croot) else None
    if cst is None:
        raise Refused(f"campaign root missing: {croot}")
    if stat.S_ISLNK(cst.st_mode) or not stat.S_ISDIR(cst.st_mode):
        raise Refused(f"campaign root not a plain directory: {croot}")
    if cst.st_uid != os.geteuid():
        raise Refused(f"campaign root not owned by uid {os.geteuid()}")
    if stat.S_IMODE(cst.st_mode) != 0o700:
        raise Refused(f"campaign root mode {oct(stat.S_IMODE(cst.st_mode))} != 0700")
    marker = os.path.join(croot, MARKER)
    try:
        with open(marker) as f:
            content = f.read().strip()
    except OSError:
        raise Refused(f"campaign marker missing/unreadable: {marker}")
    if content != args.campaign:
        raise Refused(f"campaign marker mismatch: {content!r}")

    rel = [args.engine, DATASET] + args.subpath.split("/")
    assert_no_symlink_walk(croot, rel)
    target = os.path.join(croot, *rel)
    for root in (base, croot, os.path.join(croot, args.engine),
                 os.path.join(croot, args.engine, DATASET)):
        if os.path.normpath(target) == os.path.normpath(root):
            raise Refused(f"target equals a protected root: {target}")
    nested = mounts_under(croot)
    if nested:
        raise Refused(f"unexpected nested mounts under campaign root: {nested}")
    if need_exist and not os.path.lexists(target):
        raise Refused(f"target missing: {target}")
    return target


# ── campaign / removal ───────────────────────────────────────────────────────

def cmd_init_campaign(args):
    base = args.scratch_base
    if not os.path.isdir(base) or os.path.islink(base):
        raise Refused(f"scratch base missing or a symlink: {base}")
    mp = mount_point_of(base)
    if mp != args.expect_mount:
        raise Refused(f"scratch base on mount {mp!r}, expected {args.expect_mount!r}")
    if not CAMPAIGN_RE.match(args.campaign):
        raise Refused(f"bad campaign id {args.campaign!r}")
    croot = os.path.join(base, args.campaign)
    try:
        os.mkdir(croot, 0o700)
    except FileExistsError:
        raise Refused(f"campaign root already exists (campaigns are never reused): {croot}")
    os.chmod(croot, 0o700)
    with open(os.path.join(croot, MARKER), "w") as f:
        f.write(args.campaign + "\n")
    out_json({"campaign_root": croot})


def cmd_guard_target(args):
    print(guard(args))


def cmd_safe_remove(args):
    target = guard(args)
    if not os.path.lexists(target):
        out_json({"removed": False, "reason": "absent"})
        return
    st = os.lstat(target)
    if stat.S_ISLNK(st.st_mode):
        raise Refused(f"target itself is a symlink: {target}")
    if stat.S_ISDIR(st.st_mode):
        if not shutil.rmtree.avoids_symlink_attacks:
            raise Refused("shutil.rmtree cannot avoid symlink attacks here")
        shutil.rmtree(target)
    else:
        os.unlink(target)
    out_json({"removed": True, "target": target})


def _open_beneath(root, rel_parts):
    """Walk *rel_parts* under *root* with O_NOFOLLOW dir_fds; return
    (dir_fd, leaf_name).  Caller closes dir_fd."""
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in rel_parts[:-1]:
            nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                          dir_fd=fd)
            os.close(fd)
            fd = nfd
        return fd, rel_parts[-1]
    except BaseException:
        os.close(fd)
        raise


def cmd_remove_files(args):
    target = guard(args, need_exist=True)
    with open(args.list) as f:
        rels = json.load(f)
    if not isinstance(rels, list) or not rels:
        raise Refused("removal list empty or not a list")
    removed = []
    for rel in rels:
        if not valid_subpath(rel):
            raise Refused(f"bad relative path in list: {rel!r}")
        parts = rel.split("/")
        fd, leaf = _open_beneath(target, parts)
        try:
            st = os.lstat(leaf, dir_fd=fd)
            if not stat.S_ISREG(st.st_mode):
                raise Refused(f"not a regular file: {rel}")
            os.unlink(leaf, dir_fd=fd)
        finally:
            os.close(fd)
        removed.append(rel)
    out_json({"removed": len(removed)})


# ── manifest / scenario support ──────────────────────────────────────────────

def build_manifest(root):
    if not os.path.isdir(root):
        raise Refused(f"manifest root missing: {root}")
    files, dirs, specials = {}, [], []
    for cur, dnames, fnames in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(cur, root)
        if rel_dir != ".":
            dirs.append(rel_dir)
        for name in fnames:
            p = os.path.join(cur, name)
            rel = os.path.relpath(p, root)
            st = os.lstat(p)
            if stat.S_ISREG(st.st_mode):
                files[rel] = {"size": st.st_size, "mtime_ns": st.st_mtime_ns}
            else:
                specials.append(rel)
        for name in list(dnames):
            if os.path.islink(os.path.join(cur, name)):
                specials.append(os.path.relpath(os.path.join(cur, name), root))
                dnames.remove(name)
    dirs.sort(); specials.sort()
    canon = json.dumps({"files": files, "dirs": dirs}, sort_keys=True)
    return {
        "root": root,
        "files": files,
        "dirs": dirs,
        "specials": specials,
        "source_files_total": len(files),
        "source_dirs_total": len(dirs),
        "source_size_bytes": sum(v["size"] for v in files.values()),
        "sha256": hashlib.sha256(canon.encode()).hexdigest(),
    }


def cmd_manifest(args):
    man = build_manifest(args.root)
    atomic_json(args.out, man)
    out_json({k: man[k] for k in ("source_files_total", "source_dirs_total",
                                  "source_size_bytes", "sha256")}
             | {"specials": len(man["specials"])})


def cmd_select_incr(args):
    with open(args.manifest) as f:
        man = json.load(f)
    rels = sorted(man["files"])
    n = args.n
    if not 1 <= n <= len(rels):
        raise Refused(f"incr N={n} out of range 1..{len(rels)}")
    rng = random.Random(args.seed)
    rng.shuffle(rels)
    atomic_json(args.out, sorted(rels[:n]))
    out_json({"n": n})


def cmd_verify_dst(args):
    with open(args.manifest) as f:
        man = json.load(f)
    missing_expected = set()
    if args.missing_list:
        with open(args.missing_list) as f:
            missing_expected = set(json.load(f))
    problems = []
    root = args.root
    if not os.path.isdir(root):
        out_json({"ok": False, "problems": [f"destination missing: {root}"]})
        sys.exit(2)
    seen = set()
    for cur, dnames, fnames in os.walk(root, followlinks=False):
        for name in fnames:
            rel = os.path.relpath(os.path.join(cur, name), root)
            seen.add(rel)
    for rel, meta in man["files"].items():
        if rel in missing_expected:
            if rel in seen:
                problems.append(f"expected-missing file present: {rel}")
            continue
        if rel not in seen:
            problems.append(f"missing: {rel}")
            continue
        st = os.lstat(os.path.join(root, rel))
        if not stat.S_ISREG(st.st_mode):
            problems.append(f"not a regular file: {rel}")
        elif st.st_size != meta["size"]:
            problems.append(f"size mismatch: {rel}")
        elif args.mode is not None and stat.S_IMODE(st.st_mode) != int(args.mode, 8):
            problems.append(f"mode mismatch: {rel}")
    extras = seen - set(man["files"]) - set(man["specials"])
    for rel in sorted(extras)[:20]:
        problems.append(f"extra file: {rel}")
    ok = not problems
    out_json({"ok": ok, "problems": problems[:50], "checked": len(man["files"])})
    if not ok:
        sys.exit(2)


# ── events extraction ────────────────────────────────────────────────────────

def parse_logfmt(line):
    fields = {}
    for tok in line.split():
        k, sep, v = tok.partition("=")
        if not sep:
            return None
        fields[k] = v
    return fields


def cmd_extract_events(args):
    starts, stats, ends = [], [], []
    try:
        with open(args.events) as f:
            lines = f.read().splitlines()
    except OSError:
        die(f"events log unreadable: {args.events}")
    for line in lines[args.offset:]:
        f = parse_logfmt(line)
        if not f or f.get("subpath") != args.subpath:
            continue
        ev = f.get("event")
        if ev == "job_start":
            starts.append(f)
        elif ev == "job_stats":
            stats.append(f)
        elif ev == "job_end":
            ends.append(f)
    if len(starts) != 1 or len(ends) != 1:
        die(f"expected exactly one job_start/job_end for {args.subpath!r} "
            f"after offset {args.offset}: got {len(starts)}/{len(ends)}")
    if starts[0].get("run") != ends[0].get("run"):
        die("job_start/job_end run ids differ")
    run = starts[0]["run"]
    st = [s for s in stats if s.get("run") == run]
    if len(st) > 1:
        die("more than one job_stats for the run")
    out_json({"start": starts[0], "end": ends[0],
              "stats": st[0] if st else None})


# ── result schema, record, csv, summary ──────────────────────────────────────

# (type, nullable); "num" accepts int or float, stored as given
_S, _I, _F, _N, _L = "str", "int", "num", "nullable", "list"
FIELDS = {
    "schema_version": (_I, False), "campaign": (_S, False),
    "run_id": (_S, False), "engine": (_S, False), "backend": (_S, True),
    "scenario": (_S, False), "rep": (_I, False), "subpath": (_S, False),
    "started_ts": (_F, False), "finished_ts": (_F, False),
    "duration_s": (_F, True),
    "script_exit": (_I, True), "event_exit": (_I, True),
    "worker_exit": (_I, True),
    "valid": (_I, False), "invalid_reasons": (_L, False),
    "forced": (_I, False), "dry_run": (_I, False), "aborted": (_I, False),
    "termination_signal": (_I, True),
    "source_manifest_sha256": (_S, True),
    "source_files_total": (_I, True), "source_dirs_total": (_I, True),
    "source_size_bytes": (_I, True), "source_unchanged": (_I, True),
    "destination_verified": (_I, True),
    "files_transferred": (_I, True), "files_deleted": (_I, True),
    "rclone_checks": (_I, True), "rclone_total_checks": (_I, True),
    "rclone_transfer_bytes": (_I, True),
    "rclone_transfer_bytes_total": (_I, True),
    "rclone_deletes": (_I, True), "rclone_deleted_dirs": (_I, True),
    "rclone_errors": (_I, True), "rclone_exit": (_I, True),
    "filter_exit": (_I, True), "fixup_exit": (_S, True),
    "engine_s": (_F, True), "fixup_s": (_F, True),
    "cifs_create_delta": (_I, True), "cifs_queryinfo_delta": (_I, True),
    "cifs_close_delta": (_I, True), "cifs_reads_delta": (_I, True),
    "cifs_reconnects_delta": (_I, True),
    "cpu_usec": (_I, True), "io_rbytes": (_I, True), "io_wbytes": (_I, True),
    "mem_peak_bytes": (_I, True),
    "resource_complete": (_I, False), "resource_missing": (_L, False),
    "other_sync_running": (_I, True),
    "interference_observation_ok": (_I, False),
    "cache_policy": (_S, False), "drop_caches_ok": (_I, True),
    "notes": (_S, False),
}
CSV_COLUMNS = list(FIELDS)


def check_schema(rec):
    problems = []
    unknown = set(rec) - set(FIELDS)
    missing = set(FIELDS) - set(rec)
    if unknown:
        problems.append(f"unknown fields: {sorted(unknown)}")
    if missing:
        problems.append(f"missing fields: {sorted(missing)}")
    for key, (typ, nullable) in FIELDS.items():
        if key not in rec:
            continue
        v = rec[key]
        if v is None:
            if not nullable:
                problems.append(f"{key} must not be null")
            continue
        if isinstance(v, bool):
            problems.append(f"{key} is bool")
        elif typ == _I and not isinstance(v, int):
            problems.append(f"{key} not int: {v!r}")
        elif typ == _F and not isinstance(v, (int, float)):
            problems.append(f"{key} not numeric: {v!r}")
        elif typ == _S and not isinstance(v, str):
            problems.append(f"{key} not str: {v!r}")
        elif typ == _L and not isinstance(v, list):
            problems.append(f"{key} not list: {v!r}")
    if rec.get("engine") not in ENGINES:
        problems.append(f"bad engine {rec.get('engine')!r}")
    if rec.get("scenario") not in SCENARIOS:
        problems.append(f"bad scenario {rec.get('scenario')!r}")
    if rec.get("schema_version") != SCHEMA_VERSION:
        problems.append("bad schema_version")
    for key in ("duration_s", "engine_s", "fixup_s"):
        v = rec.get(key)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            if v != v or v in (float("inf"), float("-inf")) or v < 0:
                problems.append(f"{key} not a finite non-negative number")
    rid = rec.get("run_id")
    if not (isinstance(rid, str) and RUN_ID_RE.match(rid)):
        problems.append(f"bad run_id {rid!r}")
    return problems


def compute_valid(rec, expect_transferred, no_expectations):
    reasons = list(rec.get("invalid_reasons") or [])
    def req(cond, why):
        if not cond:
            reasons.append(why)
    req(rec.get("script_exit") == 0, "script exit nonzero")
    req(rec.get("event_exit") == rec.get("script_exit"), "event/script exit mismatch")
    req(rec.get("worker_exit") == rec.get("script_exit"), "worker/script exit mismatch")
    req(not rec.get("forced"), "forced run")
    req(not rec.get("dry_run"), "dry run")
    req(not rec.get("aborted"), "aborted")
    req(isinstance(rec.get("duration_s"), (int, float))
        and rec["duration_s"] > 0, "duration missing or zero")
    req(rec.get("source_unchanged") == 1, "source changed or unchecked")
    req(rec.get("destination_verified") == 1, "destination not verified")
    req(rec.get("other_sync_running") == 0, "other sync running or unknown")
    req(rec.get("interference_observation_ok") == 1, "interference watch failed")
    if rec.get("cache_policy") == "drop":
        req(rec.get("drop_caches_ok") == 1, "drop_caches not confirmed")
    if not no_expectations:
        req(rec.get("files_transferred") == expect_transferred,
            f"transferred != expected {expect_transferred}")
        req((rec.get("files_deleted") or 0) == 0, "files deleted nonzero")
        if str(rec.get("engine")).startswith("v4"):
            req((rec.get("rclone_deletes") or 0) == 0, "rclone deletes nonzero")
            req((rec.get("rclone_deleted_dirs") or 0) == 0,
                "rclone deleted dirs nonzero")
    rec["invalid_reasons"] = reasons
    rec["valid"] = 0 if reasons else 1
    return rec


def atomic_json(path, obj, must_create=False):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, sort_keys=True, indent=1)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    if must_create and os.path.exists(path):
        os.unlink(tmp)
        raise Refused(f"result already exists (never overwritten): {path}")
    os.replace(tmp, path)
    dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def cmd_record(args):
    with open(args.input) as f:
        rec = json.load(f)
    problems = check_schema(rec)
    if problems:
        die("schema: " + "; ".join(problems))
    rec = compute_valid(rec, args.expect_transferred, args.no_expectations)
    run_dir = os.path.join(args.results_root, rec["campaign"], "runs")
    path = os.path.join(run_dir, rec["run_id"] + ".json")
    atomic_json(path, rec, must_create=True)
    # byte-identical portable copy for offline analysis
    os.makedirs(args.outdir_copy, exist_ok=True)
    shutil.copyfile(path, os.path.join(args.outdir_copy, rec["run_id"] + ".json"))
    out_json({"path": path, "valid": rec["valid"],
              "invalid_reasons": rec["invalid_reasons"]})


def load_campaign(results_root, campaign):
    run_dir = os.path.join(results_root, campaign, "runs")
    recs = []
    if not os.path.isdir(run_dir):
        return recs
    for name in sorted(os.listdir(run_dir)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(run_dir, name)) as f:
            rec = json.load(f)
        if check_schema(rec):
            die(f"stored result fails schema: {name}")
        recs.append(rec)
    return recs


def csv_quote(v):
    if v is None:
        return ""
    if isinstance(v, (list, dict)):
        v = json.dumps(v, sort_keys=True)
    s = str(v)
    if any(c in s for c in ',"\n'):
        s = '"' + s.replace('"', '""') + '"'
    return s


def cmd_csv(args):
    recs = load_campaign(args.results_root, args.campaign)
    lines = [",".join(CSV_COLUMNS)]
    for rec in recs:
        lines.append(",".join(csv_quote(rec.get(c)) for c in CSV_COLUMNS))
    tmp = args.out + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, args.out)
    out_json({"rows": len(recs)})


def median(vals):
    vals = sorted(vals)
    n = len(vals)
    if not n:
        return None
    mid = n // 2
    return vals[mid] if n % 2 else (vals[mid - 1] + vals[mid]) / 2


def cmd_summary(args):
    recs = load_campaign(args.results_root, args.campaign)
    groups = {}
    for rec in recs:
        groups.setdefault((rec["engine"], rec["scenario"]), []).append(rec)
    lines = [f"ffds-bench summary  campaign={args.campaign}",
             f"runs={len(recs)}", ""]
    for (engine, scenario) in sorted(groups):
        rs = groups[(engine, scenario)]
        valid = [r for r in rs if r["valid"] == 1]
        durs = [r["duration_s"] for r in valid
                if isinstance(r["duration_s"], (int, float))]
        line = (f"{engine:9s} {scenario:5s} runs={len(rs)} valid={len(valid)}"
                f" median_duration_s={median(durs)}")
        if scenario == "warm" and valid:
            fps = [r["source_files_total"] / r["duration_s"] for r in valid
                   if r.get("source_files_total") and r["duration_s"]]
            line += f" warm_files_per_s={median(fps)}"
        lines.append(line)
        for r in rs:
            lines.append(f"    rep={r['rep']} duration_s={r['duration_s']}"
                         f" exit={r['script_exit']} valid={r['valid']}"
                         + (f" invalid={';'.join(r['invalid_reasons'])}"
                            if r["invalid_reasons"] else ""))
    text = "\n".join(lines) + "\n"
    if args.out:
        tmp = args.out + ".tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, args.out)
    else:
        sys.stdout.write(text)


# ── scope worker + result assembly (run by ffds-bench.sh) ────────────────────

def read_cgroup_counters(missing):
    """Absolute counters of the current cgroup; unreadable ones become
    None + an entry in *missing* (never a fabricated 0)."""
    cg = None
    with open("/proc/self/cgroup") as f:
        for line in f:
            parts = line.strip().split(":", 2)
            if parts[0] == "0":
                cg = "/sys/fs/cgroup" + parts[2]
    out = {}

    def grab(fname, key, parse):
        try:
            with open(os.path.join(cg, fname)) as f:
                out[key] = parse(f.read())
        except (TypeError, OSError, ValueError, IndexError):
            missing.append(key)
            out[key] = None

    def kv(text, want):
        for line in text.splitlines():
            k, _, v = line.partition(" ")
            if k == want:
                return int(v)
        raise ValueError(want)

    def iosum(text, field):
        total, seen = 0, False
        for line in text.splitlines():
            for tok in line.split()[1:]:
                k, _, v = tok.partition("=")
                if k == field:
                    total += int(v)
                    seen = True
        if not seen:
            raise ValueError(field)
        return total

    if cg is None:
        missing.append("cgroup")
    grab("cpu.stat", "cpu_usec", lambda t: kv(t, "usage_usec"))
    grab("io.stat", "io_rbytes", lambda t: iosum(t, "rbytes"))
    grab("io.stat", "io_wbytes", lambda t: iosum(t, "wbytes"))
    grab("memory.peak", "mem_peak_bytes", lambda t: int(t.strip()))
    return out


def cmd_scope_worker(args):
    """Inside the transient scope: baseline counters -> run the child ->
    counters again while we are still alive (the scope would be GC'd the
    moment its last process exits) -> save resource.json -> exit with the
    child's rc, or 97 when saving the telemetry failed."""
    import subprocess
    import time
    m_path = args.manifest
    st = os.lstat(m_path)
    if st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o600:
        die("run manifest not private to this user")
    with open(m_path) as f:
        m = json.load(f)
    argv, run_dir = m["argv"], m["run_dir"]
    if not (isinstance(argv, list) and argv
            and all(isinstance(a, str) for a in argv)):
        die("run manifest argv invalid")
    if not (os.path.isdir(run_dir) and os.lstat(run_dir).st_uid == os.geteuid()):
        die("run dir invalid")

    missing = []
    before = read_cgroup_counters(missing)
    env = dict(os.environ)
    env.update(m.get("env", {}))
    t0 = time.monotonic()
    try:
        rc = subprocess.call(argv, env=env)
    except OSError as e:
        print(f"scope-worker: launch failed: {e}", file=sys.stderr)
        rc = 127
    elapsed = time.monotonic() - t0
    after = read_cgroup_counters(missing)

    res = {"child_exit": rc, "elapsed_s": round(elapsed, 3),
           "resource_missing": sorted(set(missing))}
    for key in ("cpu_usec", "io_rbytes", "io_wbytes"):
        b, a = before.get(key), after.get(key)
        res[key] = (a - b) if (a is not None and b is not None) else None
    res["mem_peak_bytes"] = after.get("mem_peak_bytes")
    try:
        atomic_json(os.path.join(run_dir, "resource.json"), res)
    except OSError as e:
        print(f"scope-worker: cannot save resource.json: {e}", file=sys.stderr)
        sys.exit(97)
    sys.exit(rc)


def cifs_delta(pre, post, word):
    """Sum of '<word>: N' counters across both snapshots' sessions."""
    pat = re.compile(r"\b" + word + r":?\s+(\d+)", re.IGNORECASE)
    def total(path):
        try:
            hits = pat.findall(open(path).read())
        except OSError:
            return None
        return sum(int(h) for h in hits) if hits else None
    a, b = total(pre), total(post)
    return (b - a) if (a is not None and b is not None) else None


def cmd_assemble(args):
    """Merge the run dir's evidence (resource.json, events.json, cifs
    snapshots) with the runner-provided facts into one schema-complete
    result-input.json.  valid stays 0 here; `record` computes it."""
    def load(name):
        try:
            with open(os.path.join(args.run_dir, name)) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    res = load("resource.json")
    ev = load("events.json")
    end = ev.get("end") or {}
    stats = ev.get("stats") or {}
    with open(args.manifest) as f:
        man = json.load(f)

    def num(d, k):
        # rsync's stats2 summary groups thousands ("2,084"); the monitor
        # strips them the same way (parse_human_size).  v4 emits plain
        # integers, so this is a no-op there.
        try:
            return int(str(d[k]).replace(",", ""))
        except (KeyError, TypeError, ValueError):
            return None

    def fnum(d, k):
        try:
            return float(str(d[k]).replace(",", ""))
        except (KeyError, TypeError, ValueError):
            return None

    engine = args.engine
    rec = {
        "schema_version": SCHEMA_VERSION,
        "campaign": args.campaign, "run_id": args.run_id, "engine": engine,
        "backend": {"v1": None, "v3": None,
                    "v4-mount": "mount", "v4-smb": "smb"}[engine],
        "scenario": args.scenario, "rep": args.rep, "subpath": args.subpath,
        "started_ts": args.started, "finished_ts": args.finished,
        "duration_s": res.get("elapsed_s"),
        "script_exit": args.script_exit,
        "event_exit": num(end, "exit"),
        "worker_exit": res.get("child_exit"),
        "valid": 0, "invalid_reasons": [],
        "forced": args.forced, "dry_run": num(end, "dry_run") or 0,
        "aborted": num(end, "aborted") or 0,
        "termination_signal": num(end, "termination_signal"),
        "source_manifest_sha256": man["sha256"],
        "source_files_total": man["source_files_total"],
        "source_dirs_total": man["source_dirs_total"],
        "source_size_bytes": man["source_size_bytes"],
        "source_unchanged": args.src_ok,
        "destination_verified": args.dst_ok,
        "files_transferred": num(stats, "transferred"),
        # v1 and v3 are rsync: its summary says "deleted"; rclone "deletes"
        "files_deleted": num(stats, "deletes" if engine.startswith("v4")
                             else "deleted"),
        "rclone_checks": num(stats, "checks"),
        "rclone_total_checks": num(stats, "total_checks"),
        "rclone_transfer_bytes": num(stats, "transfer_bytes"),
        "rclone_transfer_bytes_total": num(stats, "transfer_bytes_total"),
        "rclone_deletes": num(stats, "deletes"),
        "rclone_deleted_dirs": num(stats, "deleted_dirs"),
        "rclone_errors": num(stats, "errors"),
        "rclone_exit": num(end, "rclone_exit"),
        "filter_exit": num(end, "filter_exit"),
        "fixup_exit": end.get("fixup_exit"),
        "engine_s": fnum(end, "engine_s"), "fixup_s": fnum(end, "fixup"),
        "cifs_create_delta": cifs_delta(args.cifs_pre, args.cifs_post, "Creates"),
        "cifs_queryinfo_delta": cifs_delta(args.cifs_pre, args.cifs_post, "QueryInfos"),
        "cifs_close_delta": cifs_delta(args.cifs_pre, args.cifs_post, "Closes"),
        "cifs_reads_delta": cifs_delta(args.cifs_pre, args.cifs_post, "Reads"),
        "cifs_reconnects_delta": cifs_delta(args.cifs_pre, args.cifs_post, "Reconnects"),
        "cpu_usec": res.get("cpu_usec"),
        "io_rbytes": res.get("io_rbytes"), "io_wbytes": res.get("io_wbytes"),
        "mem_peak_bytes": res.get("mem_peak_bytes"),
        "resource_complete": 0 if res.get("resource_missing", ["no-file"]) else 1,
        "resource_missing": res.get("resource_missing", ["resource.json"]),
        "other_sync_running": (None if args.watcher_ok != 1
                               else (1 if args.interference_delta > 0 else 0)),
        "interference_observation_ok": args.watcher_ok,
        "cache_policy": args.cache_policy,
        "drop_caches_ok": None if args.drop_ok == "null" else int(args.drop_ok),
        "notes": "",
    }
    atomic_json(args.out, rec)


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(prog="ffds_bench_data.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    def guard_args(sp):
        sp.add_argument("--scratch-base", required=True)
        sp.add_argument("--expect-mount", required=True)
        sp.add_argument("--campaign", required=True)
        sp.add_argument("--engine", required=True)
        sp.add_argument("--subpath", required=True)

    sp = sub.add_parser("init-campaign")
    sp.add_argument("--scratch-base", required=True)
    sp.add_argument("--expect-mount", required=True)
    sp.add_argument("--campaign", required=True)
    sp.set_defaults(fn=cmd_init_campaign)

    sp = sub.add_parser("guard-target"); guard_args(sp)
    sp.set_defaults(fn=cmd_guard_target)

    sp = sub.add_parser("safe-remove"); guard_args(sp)
    sp.set_defaults(fn=cmd_safe_remove)

    sp = sub.add_parser("remove-files"); guard_args(sp)
    sp.add_argument("--list", required=True)
    sp.set_defaults(fn=cmd_remove_files)

    sp = sub.add_parser("manifest")
    sp.add_argument("--root", required=True)
    sp.add_argument("--out", required=True)
    sp.set_defaults(fn=cmd_manifest)

    sp = sub.add_parser("select-incr")
    sp.add_argument("--manifest", required=True)
    sp.add_argument("--n", type=int, required=True)
    sp.add_argument("--seed", type=int, required=True)
    sp.add_argument("--out", required=True)
    sp.set_defaults(fn=cmd_select_incr)

    sp = sub.add_parser("verify-dst")
    sp.add_argument("--manifest", required=True)
    sp.add_argument("--root", required=True)
    sp.add_argument("--missing-list")
    sp.add_argument("--mode")
    sp.set_defaults(fn=cmd_verify_dst)

    sp = sub.add_parser("extract-events")
    sp.add_argument("--events", required=True)
    sp.add_argument("--offset", type=int, required=True)
    sp.add_argument("--subpath", required=True)
    sp.set_defaults(fn=cmd_extract_events)

    sp = sub.add_parser("scope-worker")
    sp.add_argument("--manifest", required=True)
    sp.set_defaults(fn=cmd_scope_worker)

    sp = sub.add_parser("assemble")
    sp.add_argument("--run-dir", required=True)
    sp.add_argument("--manifest", required=True)
    sp.add_argument("--out", required=True)
    sp.add_argument("--campaign", required=True)
    sp.add_argument("--run-id", required=True)
    sp.add_argument("--engine", required=True)
    sp.add_argument("--scenario", required=True)
    sp.add_argument("--rep", type=int, required=True)
    sp.add_argument("--subpath", required=True)
    sp.add_argument("--script-exit", type=int, required=True)
    sp.add_argument("--started", type=float, required=True)
    sp.add_argument("--finished", type=float, required=True)
    sp.add_argument("--dst-ok", type=int, required=True)
    sp.add_argument("--src-ok", type=int, required=True)
    sp.add_argument("--drop-ok", required=True)      # null | 0 | 1
    sp.add_argument("--cache-policy", required=True)
    sp.add_argument("--watcher-ok", type=int, required=True)
    sp.add_argument("--interference-delta", type=int, required=True)
    sp.add_argument("--forced", type=int, required=True)
    sp.add_argument("--cifs-pre", required=True)
    sp.add_argument("--cifs-post", required=True)
    sp.set_defaults(fn=cmd_assemble)

    sp = sub.add_parser("record")
    sp.add_argument("--input", required=True)
    sp.add_argument("--results-root", required=True)
    sp.add_argument("--outdir-copy", required=True)
    sp.add_argument("--expect-transferred", type=int)
    sp.add_argument("--no-expectations", action="store_true")
    sp.set_defaults(fn=cmd_record)

    sp = sub.add_parser("csv")
    sp.add_argument("--results-root", required=True)
    sp.add_argument("--campaign", required=True)
    sp.add_argument("--out", required=True)
    sp.set_defaults(fn=cmd_csv)

    sp = sub.add_parser("summary")
    sp.add_argument("--results-root", required=True)
    sp.add_argument("--campaign", required=True)
    sp.add_argument("--out")
    sp.set_defaults(fn=cmd_summary)

    args = p.parse_args()
    try:
        args.fn(args)
    except Refused as e:
        die(str(e))


if __name__ == "__main__":
    main()
