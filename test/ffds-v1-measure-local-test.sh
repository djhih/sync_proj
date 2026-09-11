#!/bin/bash
#
# ffds-v1-measure-local-test.sh -- sandbox harness for
# v1-measure/ffds-v1-measure.sh + ffds_v1_measure.py
#
# Everything under one mktemp -d.  The v1 script under test is
# fixtures/v1/sync_ffds.sh, a copy of sync-host:/usr/local/ffds/sync_ffds.sh
# (site values replaced by the repo placeholders),
# so the instrument anchors are checked against the real v1 text.
# rsync is a shim that REALLY syncs (-a/--delete
# semantics, -p resets modes on every run like the real thing) and prints
# the --stats block in rsync 3.x wording; /usr/bin/time, systemd-run and
# systemctl are shims too (the transient scope is sync-host-smoke territory).
#
# Usage:  bash test/ffds-v1-measure-local-test.sh
# Exit:   0 when every assertion passed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

SCRATCH=$(mktemp -d)
bgPids=()
cleanup() {
    for p in "${bgPids[@]}"; do kill "$p" 2>/dev/null; done
    [ -n "${FFDS_TEST_KEEP:-}" ] || rm -rf "$SCRATCH"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', want '$3'"; fi; }
assert_match() { if grep -qE -- "$3" <<< "$2"; then ok "$1"; else bad "$1: no match for /$3/"; fi; }
jget() {  # <json file> <python expr on d>
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

# ── layout ───────────────────────────────────────────────────────────────────
S=$SCRATCH
mkdir -p "$S/v1m" "$S/bench" "$S/shims" "$S/v1" "$S/src/FFDS/A/sub/deep" \
         "$S/weka/ffds-v1-measure" "$S/lock" "$S/fake"
cp "$repo/bench/ffds_bench_data.py" "$S/bench/"
cp "$repo/v1-measure/ffds_v1_measure.py" "$S/v1m/"
cp "$here/fixtures/v1/sync_ffds.sh" "$S/v1/sync_ffds.sh"
chmod +x "$S/v1/sync_ffds.sh"

expectMount=$(python3 -c '
import sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1])
from ffds_bench_data import mount_point_of
print(mount_point_of(sys.argv[2]))' "$S/bench" "$S")

M=$S/v1m/ffds-v1-measure.sh
sed -e "s|^v1Script=.*|v1Script=$S/v1/sync_ffds.sh|" \
    -e "s|^srcRoot=.*|srcRoot=$S/src/FFDS|" \
    -e "s|^scratchBase=.*|scratchBase=$S/weka/ffds-v1-measure|" \
    -e "s|^expectMount=.*|expectMount=$expectMount|" \
    -e "s|^lockFile=.*|lockFile=$S/lock/v1m.lock|" \
    -e "s|^cifsStats=.*|cifsStats=$S/fake/cifs-stats|" \
    -e "s|^timeBin=.*|timeBin=$S/shims/time|" \
    "$repo/v1-measure/ffds-v1-measure.sh" > "$M"
chmod +x "$M"
for key in v1Script srcRoot scratchBase expectMount lockFile cifsStats timeBin; do
    [ "$(grep -c "^$key=$S\|^$key=$expectMount" "$M")" = 1 ] || { echo "rewrite of $key failed"; exit 1; }
done
printf 'Creates: 10\nQueryInfos: 20\nCloses: 10\nReads: 5\nReconnects: 0\n' > "$S/fake/cifs-stats"

# source tree: 6 regular files, modes 0644 (v1 must chmod them to 775)
for f in a.txt b.bin c.txt sub/d.txt sub/e.txt sub/deep/f.txt; do
    head -c $((RANDOM % 4096 + 1)) /dev/urandom > "$S/src/FFDS/A/$f"
done
chmod 644 "$S"/src/FFDS/A/*.* "$S"/src/FFDS/A/sub/*.* "$S"/src/FFDS/A/sub/deep/*.*
srcFiles=6

# ── shims ────────────────────────────────────────────────────────────────────
cat > "$S/shims/rsync" <<'EOF'
#!/usr/bin/env python3
# rsync stand-in: really syncs SRC (no trailing slash) into DST/basename(SRC)
# with -a/--delete semantics, prints -v names and, with --stats, the summary
# block in rsync 3.x wording (comma-grouped counts).  FFDS_SHIM_RC = exit.
import os, shutil, stat, sys
argv = sys.argv[1:]
if "--version" in argv:
    print("rsync  version 3.2.7-shim  protocol version 31"); sys.exit(0)
pos = [a for a in argv if not a.startswith("-")]
src, dst = pos[-2].rstrip("/"), pos[-1]
if not os.path.isdir(dst):
    try:
        os.mkdir(dst)          # like rsync: the last component only
    except OSError as e:
        print(f'rsync: mkdir "{dst}" failed: {e.strerror}', file=sys.stderr)
        sys.exit(11)
name = os.path.basename(src)
root = os.path.join(dst, name)
nreg = ndir = created = deleted = xfr = 0
for cur, dirs, files in os.walk(src):
    rel = os.path.relpath(cur, src)
    tdir = os.path.normpath(os.path.join(root, rel))
    ndir += 1
    if not os.path.isdir(tdir):
        os.mkdir(tdir); created += 1
    shutil.copymode(cur, tdir)
    for f in sorted(files):
        s, t = os.path.join(cur, f), os.path.join(tdir, f)
        nreg += 1
        ss = os.lstat(s)
        ts = os.lstat(t) if os.path.lexists(t) else None
        if ts is None or ts.st_size != ss.st_size or int(ts.st_mtime) != int(ss.st_mtime):
            created += ts is None
            shutil.copy2(s, t); xfr += 1
            print(os.path.normpath(os.path.join(name, rel, f)))
        else:
            os.chmod(t, stat.S_IMODE(ss.st_mode))   # -p: source mode back every run
    if "--delete" in argv:
        for extra in sorted(set(os.listdir(tdir)) - set(dirs) - set(files)):
            p = os.path.join(tdir, extra)
            shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.unlink(p)
            deleted += 1
            print("deleting " + os.path.normpath(os.path.join(name, rel, extra)))
if "--stats" in argv:
    print()
    print(f"Number of files: {nreg + ndir:,} (reg: {nreg:,}, dir: {ndir:,})")
    print(f"Number of created files: {created:,}")
    print(f"Number of deleted files: {deleted:,}")
    print(f"Number of regular files transferred: {xfr:,}")
    print("Total file size: 12.34K bytes")
    print("Total transferred file size: 1.23K bytes")
    print("File list generation time: 0.001 seconds")
    print("File list transfer time: 0.000 seconds")
    print()
print("sent 1.30K bytes  received 35 bytes  2.67K bytes/sec")
print("total size is 12.34K  speedup is 9.25")
sys.exit(int(os.environ.get("FFDS_SHIM_RC", "0")))
EOF

cat > "$S/shims/time" <<'EOF'
#!/bin/bash
# GNU time -v -o FILE stand-in, same labels as the real output
[ "$1" = -v ] && [ "$2" = -o ] || exit 99
out=$3; shift 3
"$@"; rc=$?
{
    echo "	Command being timed: \"$*\""
    echo "	User time (seconds): 0.12"
    echo "	System time (seconds): 0.34"
    echo "	Percent of CPU this job got: 50%"
    echo "	Elapsed (wall clock) time (h:mm:ss or m:ss): 0:01.50"
    echo "	Maximum resident set size (kbytes): 4321"
    echo "	File system inputs: 8"
    echo "	File system outputs: 16"
    echo "	Voluntary context switches: 12"
    echo "	Involuntary context switches: 3"
    echo "	Exit status: $rc"
} > "$out"
exit $rc
EOF

cat > "$S/shims/systemd-run" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case $1 in --*) shift ;; *) break ;; esac; done
exec "$@"
EOF

cat > "$S/shims/systemctl" <<'EOF'
#!/bin/bash
case ${1-} in is-active) echo inactive; exit 3 ;; *) exit 0 ;; esac
EOF
chmod +x "$S"/shims/*

export PATH=$S/shims:$PATH FFDS_V1M_TEST_NONROOT=1
echo "scratch: $S (mount: $expectMount)"

# ── T1 a terminal capture (pasted prompt on line 1) is refused ───────────────
echo "T1 refuse a non-script v1"
{ echo 'root@host:/# cat /usr/local/ffds/sync_ffds.sh'; cat "$S/v1/sync_ffds.sh"; } \
    > "$S/fake/pasted.sh"
out=$("$M" -p A -r 1 -o "$S/out-t1" -s "$S/fake/pasted.sh" 2>&1); rc=$?
assert_eq "rc" "$rc" 1
assert_match "reason" "$out" "line 1 is not '#!/bin/bash'"
assert_eq "no scratch id root created" "$(find "$S/weka/ffds-v1-measure" -mindepth 1 | wc -l)" 0

# ── T2 parser units: comma counts, markers, GNU time durations ───────────────
echo "T2 parser units"
cat > "$S/fake/job.log" <<'EOF'
V1MEASURE event=rsync_start t=100.0
        1.23M 100%   10.00MB/s    0:00:00 (xfr#1, to-chk=0/3)
Number of deleted files: 0
Number of regular files transferred: 1,234
V1MEASURE event=rsync_end rc=23 t=160.5
V1MEASURE event=fixup_end t=190.75
EOF
printf '\tElapsed (wall clock) time (h:mm:ss or m:ss): 1:02:03\n\tExit status: 0\n' > "$S/fake/time1.txt"
printf '\tElapsed (wall clock) time (h:mm:ss or m:ss): 0:01.50\n' > "$S/fake/time2.txt"
units=$(cd "$S/v1m" && FFDS_BENCH_DIR=$S/bench python3 -c '
import sys; sys.dont_write_bytecode = True; sys.path.insert(0, ".")
from ffds_v1_measure import parse_job_log, parse_time
m, s = parse_job_log(sys.argv[1])
print(s["files_transferred"], s["files_deleted"], m["rsync_end"]["rc"], m["fixup_end"]["t"],
      parse_time(sys.argv[2])["time_elapsed_s"], parse_time(sys.argv[2])["time_exit"],
      parse_time(sys.argv[3])["time_elapsed_s"])' "$S/fake/job.log" "$S/fake/time1.txt" "$S/fake/time2.txt")
assert_eq "transferred deleted rc fixup_t elapsed exit elapsed" "$units" "1234 0 23 190.75 3723.0 0 1.5"

# ── T3 full measurement: cold/warm/incr x 2 reps, all valid ──────────────────
echo "T3 full measurement"
out3=$S/out-t3
"$M" -p A -r 2 -o "$out3" --incr-files 2 > "$S/t3.log" 2>&1; rc=$?
assert_eq "rc" "$rc" 0
[ "$rc" = 0 ] || sed 's/^/      /' "$S/t3.log"
assert_eq "six results" "$(ls "$out3"/runs/*/result.json 2>/dev/null | wc -l)" 6
for r in r1-cold r1-warm r1-incr r2-cold r2-warm r2-incr; do
    f=$out3/runs/$r/result.json
    [ -f "$f" ] || { bad "$r missing"; continue; }
    want=$srcFiles; case $r in *warm) want=0 ;; *incr) want=2 ;; esac
    assert_eq "$r valid" "$(jget "$f" 'd["valid"], d["invalid_reasons"]')" "(1, [])"
    assert_eq "$r transferred" "$(jget "$f" 'd["files_transferred"]')" "$want"
    assert_eq "$r rsync_exit/job_ran" "$(jget "$f" 'd["rsync_exit"], d["job_ran"]')" "(0, 1)"
    assert_eq "$r split present" \
        "$(jget "$f" 'd["engine_s"] is not None and d["fixup_s"] is not None and d["duration_s"] > 0')" True
    assert_eq "$r time -v parsed" "$(jget "$f" 'd["time_user_s"], d["time_max_rss_kb"], d["time_exit"]')" \
        "(0.12, 4321, 0)"
    assert_eq "$r cifs delta" "$(jget "$f" 'd["cifs_queryinfo_delta"]')" 0
done
f=$out3/runs/r1-cold/result.json
assert_eq "same manifest definition as the bench" \
    "$(jget "$f" 'd["source_manifest_sha256"]')" "$(jget "$out3/source-manifest.json" 'd["sha256"]')"
assert_match "job log filed with the run" "$(cat "$out3/runs/r1-cold/job.log")" "^Done\.$"
assert_eq "csv rows" "$(wc -l < "$out3/results.csv")" 7
assert_match "summary" "$(cat "$out3/SUMMARY.txt")" "^v1 warm  runs=2 valid=2 .*warm_files_per_s="
assert_eq "scratch dataset cleaned" "$(find "$S/weka/ffds-v1-measure" -path '*DataSet/*' | wc -l)" 0
assert_eq "no production log path in copy" "$(grep -c '/var/log/rsync-smb' "$out3"/sync_ffds-*.sh)" 0
assert_eq "no production dst in copy" "$(grep -c '/mnt/dst-fs/DataSet' "$out3"/sync_ffds-*.sh)" 0
assert_match "rsync flags verbatim + --stats" "$(cat "$out3"/sync_ffds-*.sh)" \
    "^    rsync --stats -avzhP --no-owner --no-group --delete $S/src/FFDS/\\\$1 "
diffMinus=$(grep -c '^-[^-]' "$out3/v1-instrument.diff")
diffPlus=$(grep -c '^+[^+]' "$out3/v1-instrument.diff")
assert_eq "diff: only 4 v1 lines changed (dst, rsync, 2x log)" "$diffMinus" 4
assert_eq "diff: 9 lines in (4 changed + 2 header + 3 markers)" "$diffPlus" 9

# ── T4 depth-3 subpath: parent pre-created, rsync makes the last level ───────
echo "T4 depth-3 subpath"
"$M" -p A/sub/deep -r 1 -o "$S/out-t4" --scenarios cold > "$S/t4.log" 2>&1
assert_eq "rc" "$?" 0
assert_eq "valid, 1 file" "$(jget "$S/out-t4/runs/r1-cold/result.json" 'd["valid"], d["files_transferred"]')" "(1, 1)"

# ── T5 rsync fails: v1 still exits 0, the run is invalid and the loop halts ──
echo "T5 rsync exit 23 behind v1's exit 0"
FFDS_SHIM_RC=23 "$M" -p A -r 1 -o "$S/out-t5" > "$S/t5.log" 2>&1
assert_eq "rc" "$?" 1
f=$S/out-t5/runs/r1-cold/result.json
assert_eq "script 0, rsync 23" "$(jget "$f" 'd["script_exit"], d["rsync_exit"], d["valid"]')" "(0, 23, 0)"
assert_match "halted" "$(cat "$S/t5.log")" "HALT: run r1-cold: v1 did not complete"
assert_eq "no warm run after the halt" "$(ls "$S/out-t5/runs" | grep -c warm)" 0

# ── T6 v1's own pgrep guard skips the job: no markers -> invalid + halt ──────
echo "T6 v1 pgrep guard skip"
printf '#!/bin/bash\nsleep 60\n' > "$S/fake/rsync"; chmod +x "$S/fake/rsync"
"$S/fake/rsync" A & bgPids+=($!)
sleep 0.3
"$M" -p A -r 1 -o "$S/out-t6" --scenarios cold > "$S/t6.log" 2>&1
assert_eq "rc" "$?" 1
assert_match "reason" "$(jget "$S/out-t6/runs/r1-cold/result.json" 'd["invalid_reasons"]')" "job did not run"
kill "${bgPids[-1]}" 2>/dev/null

# ── T7 another sync running -> preflight refuses ─────────────────────────────
echo "T7 interference preflight"
bash -c 'exec -a sync_all.sh sleep 60' & bgPids+=($!)
sleep 0.3
out=$("$M" -p A -r 1 -o "$S/out-t7" 2>&1); rc=$?
assert_eq "rc" "$rc" 1
assert_match "reason" "$out" "other sync processes running"
kill "${bgPids[-1]}" 2>/dev/null

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
