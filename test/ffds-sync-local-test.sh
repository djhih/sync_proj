#!/bin/bash
#
# ffds-sync-local-test.sh -- end-to-end harness for ffds-sync-v3.sh
#
# Runs entirely under one scratch directory: no real mount, host, /var/log
# or /run/lock is touched. The script under test is a copy whose fixed
# config block is rewritten to point into the scratch tree.
#
# rsync is replaced by a shim that prints a canned --info=progress2,stats2
# transcript (real \r rewrites, all line shapes the awk filter must
# handle), sleeps FFDS_SHIM_SLEEP seconds and exits FFDS_SHIM_RC. That
# exercises the full  rsync | stdbuf tr | filter_rsync  pipeline, the
# throttle, the field extraction and PIPESTATUS propagation
# deterministically. A final layer uses the real rsync when one is
# installed and skips otherwise.
#
# Usage:  bash sendout/test/ffds-sync-local-test.sh
#         FFDS_TEST_KEEP=1 ... keeps the scratch dir (e.g. to point the
#         monitor at its events.log: FFDS_SYNC_EVENT_LOG=<scratch>/log/events.log)
# Exit:   0 when every assertion passed.
#
# Not covered here (target-host checklist in ffds-sync-v3-test-plan.zh-tw.md):
# mawk pipe buffering, hung mounts, systemd sandbox/timer behaviour. T19
# probes the bash 5.2 'wait -n' quirk but can only confirm it on bash 5.2.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
script=$repo/ffds-sync-v3.sh
monitorDir=$repo/sync_monitor

SCRATCH=$(mktemp -d)
if [ -z "${FFDS_TEST_KEEP:-}" ]; then
    trap 'rm -rf "$SCRATCH"' EXIT
fi

SRC=$SCRATCH/src/FFDS
DST=$SCRATCH/dst/FFDS
LOG=$SCRATCH/log
EV=$LOG/events.log
CONF=$SCRATCH/sync_paths.conf
LOCK=$SCRATCH/lock
S=$SCRATCH/ffds_sync.sh          # mounts present
S_NOMNT=$SCRATCH/ffds_sync_nomount.sh
export TMPDIR=$SCRATCH/tmp        # where the script's mktemp -d lands
export FFDS_SHIM_ARGV=$SCRATCH/shim.argv
export FFDS_SHIM_PIDS=$SCRATCH/shim.pids
mkdir -p "$SRC" "$DST" "$LOCK" "$TMPDIR" "$SCRATCH/bin"

# ── helpers ──────────────────────────────────────────────────────────────────
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }
assert_eq() {  # <desc> <got> <want>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', want '$3'"; fi
}
assert_match() {  # <desc> <text> <ERE>
    if grep -qE -- "$3" <<< "$2"; then ok "$1"; else bad "$1: no match for /$3/"; fi
}
assert_nomatch() {
    if grep -qE -- "$3" <<< "$2"; then bad "$1: unexpected match for /$3/"; else ok "$1"; fi
}
mark()  { if [ -f "$EV" ]; then wc -l < "$EV"; else echo 0; fi; }
since() { tail -n +"$(( $1 + 1 ))" "$EV"; }
names() { sed -n 's/^.* event=\([a-z_]*\).*$/\1/p'; }
conf()  { printf '%s\n' "$@" > "$CONF"; }
# run <VAR=val ...> <cmd...>: clean env (desktop shells leak
# JOURNAL_STREAM), shim first in PATH
run()   { env -u JOURNAL_STREAM PATH="$SCRATCH/bin:$PATH" "$@"; }
# hold_lock <file>: external holder, pid in $holder. flock(1) forks the
# command, which inherits the locked fd -- release() must kill the child
# too or the lock outlives the holder (and every later test sees 92).
hold_lock() { flock "$1" sleep 30 & holder=$!; sleep 0.2; }
release()   { pkill -P "$holder" 2>/dev/null; kill "$holder" 2>/dev/null
              wait "$holder" 2>/dev/null; }
# wait_until <tenths of a second> <cmd...>: poll until cmd succeeds
wait_until() { local n=$1; shift
               until "$@" 2>/dev/null; do n=$((n - 1)); [ "$n" -gt 0 ] || return 1; sleep 0.1; done; }
lock_free() { flock -n "$1" true; }
dead()      { # exited, or zombie not yet reaped by this shell
              ! kill -0 "$1" 2>/dev/null ||
              [ "$(awk '/^State:/ {print $2}' /proc/"$1"/status 2>/dev/null)" = Z ]; }

make_copy() {  # <dest> <mountpoints array literal>
    sed -e "s|^srcRoot=.*|srcRoot=$SRC|" \
        -e "s|^dstRoot=.*|dstRoot=$DST|" \
        -e "s|^mountpoints=.*|mountpoints=$2|" \
        -e "s|^logDir=.*|logDir=$LOG|" \
        -e "s|^config=.*|config=$CONF|" \
        -e "s|^lockDir=.*|lockDir=$LOCK|" \
        -e "s|^fileOwner=.*|fileOwner=$(id -un):$(id -gn)|" \
        "$script" > "$1"
    chmod +x "$1"
}

# ── fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$SRC/A" "$SRC/B/C" "$SRC/dup"
head -c 1048576 /dev/urandom > "$SRC/A/one.bin"
head -c 2097152 /dev/urandom > "$SRC/A/two.bin"
echo small > "$SRC/A/small.txt"
echo c > "$SRC/B/C/c.txt"
echo d > "$SRC/dup/d.txt"

# rsync shim. Six progress lines so FFDS_PROGRESS_EVERY=2 yields exactly
# three events (2nd, 4th, 6th): with xfr suffix, without any suffix, and
# with the to-chk variant.
cat > "$SCRATCH/bin/rsync" <<'EOF'
#!/bin/bash
echo "$$" >> "${FFDS_SHIM_PIDS:-/dev/null}"
printf '%s\n' "$*" >> "${FFDS_SHIM_ARGV:-/dev/null}"
printf 'file-a.bin\n'
printf '\r        512.00K   1%%    1.00MB/s    0:20:00 (xfr#0, ir-chk=1027/1084)'
printf '\r          1.23G  45%%   12.34MB/s    0:12:34 (xfr#123, ir-chk=456/789)'
printf '\r          1.50G  55%%   10.00MB/s    0:10:00 (xfr#130, ir-chk=400/800)'
printf '\r          1.80G  66%%    9.00MB/s    0:08:00'
printf '\rdeleting old/stale.bin\n'
printf '\r          2.10G  77%%    8.00MB/s    0:05:00 (xfr#140, ir-chk=100/810)'
printf '\r          2.72G 100%%    7.50MB/s    0:00:00 (xfr#150, to-chk=0/812)\n'
sleep "${FFDS_SHIM_SLEEP:-0}"
dry=""
case " $* " in *" --dry-run "*) dry=" (DRY RUN)" ;; esac   # as rsync -n prints it
cat <<'STATS'

Number of files: 1,234 (reg: 1,200, dir: 34)
Number of created files: 5 (reg: 5)
Number of deleted files: 2
Number of regular files transferred: 7
Total file size: 1.23G bytes
Total transferred file size: 12.34M bytes
Literal data: 12.34M bytes
Matched data: 0 bytes
File list size: 65.53K
File list generation time: 0.001 seconds
File list transfer time: 0.000 seconds
Total bytes sent: 12.35M
Total bytes received: 1.23K

STATS
printf 'sent 12.35M bytes  received 1.23K bytes  8.23M bytes/sec%s\n' "$dry"
printf 'total size is 1.23G  speedup is 2,345.67%s\n' "$dry"
exit "${FFDS_SHIM_RC:-0}"
EOF
chmod +x "$SCRATCH/bin/rsync"

make_copy "$S" "(/ /proc)"
make_copy "$S_NOMNT" "(/ /nonexistent-mnt-xyz)"

echo "scratch: $SCRATCH"
echo "bash $BASH_VERSION, $(awk -W version 2>&1 | head -n 1)"

# ── T0 static ────────────────────────────────────────────────────────────────
echo "T0 static"
if bash -n "$S"; then ok "bash -n"; else bad "bash -n"; fi
for key in "srcRoot=$SRC" "dstRoot=$DST" "mountpoints=(/ /proc)" \
           "logDir=$LOG" "config=$CONF" "lockDir=$LOCK"; do
    assert_eq "config rewritten: ${key%%=*}" "$(grep -c "^$key\$" "$S")" 1
done

# ── T1 one A (shim) ──────────────────────────────────────────────────────────
echo "T1 one A"
m=$(mark)
out=$(run FFDS_PROGRESS_EVERY=2 "$S" one A 2>"$SCRATCH/t1.err"); rc=$?
assert_eq "rc" "$rc" 0
assert_eq "stdout empty without JOURNAL_STREAM" "$out" ""
ev=$(since "$m")
assert_eq "event sequence" "$(names <<< "$ev" | tr '\n' ' ')" \
          "job_start job_progress job_progress job_progress job_stats job_end "
assert_eq "one run id" "$(grep -o 'run=[0-9]*' <<< "$ev" | sort -u | wc -l)" 1
assert_nomatch "no batch= on manual run" "$ev" 'batch='
assert_match "progress w/ xfr" "$ev" \
    'job_progress subpath=A run=[0-9]+ bytes=1.23G pct=45 speed=12.34MB/s eta=0:12:34 xfr=123 chk=456/789$'
assert_match "progress w/o suffix" "$ev" \
    'job_progress subpath=A run=[0-9]+ bytes=1.80G pct=66 speed=9.00MB/s eta=0:08:00$'
assert_match "progress to-chk" "$ev" \
    'bytes=2.72G pct=100 speed=7.50MB/s eta=0:00:00 xfr=150 chk=0/812$'
assert_match "stats" "$ev" \
    'job_stats subpath=A run=[0-9]+ files=1,234 created=5 deleted=2 transferred=7 size=1.23G listgen=0.001 speedup=2,345.67$'
assert_match "job_end" "$ev" 'job_end subpath=A run=[0-9]+ exit=0 duration=[0-9]+$'
assert_match "ts/time stamp" "$ev" '^ts=[0-9]+ time=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{4} event='
jl=$LOG/jobs/A.log
assert_match "job log RUN marker" "$(cat "$jl")" '^=== RUN .* subpath=A ===$'
assert_match "job log END marker" "$(cat "$jl")" '^=== END .* exit=0 duration=[0-9]+s subpath=A ===$'
assert_eq "job log keeps 3 of 6 progress lines" \
          "$(grep -cE '^ +[0-9.]+[KMG]? +[0-9]+%' "$jl")" 3
assert_match "job log keeps name1/del1 lines" "$(cat "$jl")" '^deleting old/stale.bin$'
argv=$(tail -n 1 "$FFDS_SHIM_ARGV")
assert_match "rsync flags" "$argv" \
    "^-ah --delete --chown=$(id -un):$(id -gn) --chmod=D775,F775 --info=progress2,stats2,name1,del1 --outbuf=N --timeout=1800 $SRC/A $DST/\$"
assert_eq "stderr quiet" "$(cat "$SCRATCH/t1.err")" ""

# ── T2 bad subpaths ──────────────────────────────────────────────────────────
echo "T2 bad subpaths"
argvLines=$(wc -l < "$FFDS_SHIM_ARGV")
m=$(mark); run "$S" one "" 2>/dev/null; assert_eq "empty -> 90" $? 90
assert_eq "empty: events" "$(since "$m" | sed 's/^.*event=//; s/run=[0-9]*/run=N/' | tr '\n' '|')" \
          "job_start subpath=? run=N|job_end subpath=? run=N exit=90 duration=0|"
m=$(mark); run "$S" one "a b" 2>/dev/null; assert_eq "space -> 90" $? 90
assert_eq "space: events" "$(since "$m" | sed 's/^.*event=//; s/run=[0-9]*/run=N/' | tr '\n' '|')" \
          "job_start subpath=a_b run=N|job_end subpath=a_b run=N exit=90 duration=0|"
for bad in /abs ../x 'a/../b' 'trail/' . './x' 'x/.' 'a\tb'; do
    run "$S" one "$bad" 2>/dev/null; assert_eq "'$bad' -> 90" $? 90
done
run "$S" bogus 2>/dev/null; assert_eq "unknown subcommand -> 90" $? 90
assert_eq "rsync never invoked" "$(wc -l < "$FFDS_SHIM_ARGV")" "$argvLines"
run "$S" one 'a..b' >/dev/null 2>&1; assert_eq "'a..b' is a legal name (0)" $? 0

# ── T3 missing mount ─────────────────────────────────────────────────────────
echo "T3 missing mount"
conf A
m=$(mark); run "$S_NOMNT" one A 2>/dev/null; assert_eq "one -> 91" $? 91
assert_eq "one: events" "$(since "$m" | names | tr '\n' ' ')" "job_start job_end "
assert_match "one: exit=91" "$(since "$m")" 'job_end subpath=A run=[0-9]+ exit=91 duration=0$'
m=$(mark); run "$S_NOMNT" all 2>/dev/null; assert_eq "all -> 91" $? 91
assert_match "all: abort event" "$(since "$m")" \
    'event=batch_abort pid=[0-9]+ reason=mount-missing mountpoint=/nonexistent-mnt-xyz$'

# ── T4 job lock ──────────────────────────────────────────────────────────────
echo "T4 job lock busy"
hold_lock "$LOCK/ffds-sync-job-A.lock"
m=$(mark); run "$S" one A 2>/dev/null; assert_eq "one A -> 92" $? 92
assert_match "job_end exit=92" "$(since "$m")" 'job_end subpath=A run=[0-9]+ exit=92 duration=0$'
release
run "$S" one A >/dev/null 2>&1; assert_eq "lock released -> 0" $? 0

# ── T5 batch lock ────────────────────────────────────────────────────────────
echo "T5 batch lock busy"
conf A
hold_lock "$LOCK/ffds-sync-all.lock"
m=$(mark); run "$S" all 2>/dev/null; assert_eq "all -> 92" $? 92
assert_match "batch_abort lock-busy" "$(since "$m")" 'event=batch_abort pid=[0-9]+ reason=lock-busy$'
release
run "$S" all >/dev/null 2>&1; assert_eq "lock released -> 0" $? 0

# ── T6 config parsing ────────────────────────────────────────────────────────
echo "T6 config"
rm -f "$CONF"
m=$(mark); run "$S" all 2>/dev/null; assert_eq "missing -> 93" $? 93
assert_match "config-missing" "$(since "$m")" 'reason=config-missing$'
printf '# only comments\r\n\r\n   \r\n' > "$CONF"
m=$(mark); run "$S" all 2>/dev/null; assert_eq "empty -> 93" $? 93
assert_match "config-empty" "$(since "$m")" 'reason=config-empty$'
printf '# comment\r\n  A  \r\n' > "$CONF"
m=$(mark); run "$S" all 2>/dev/null; assert_eq "CRLF + padded line -> 0" $? 0
assert_match "padded line parsed as A" "$(since "$m")" 'job_start subpath=A run=[0-9]+ batch=[0-9]+$'
assert_match "batch_end ok=1" "$(since "$m")" 'batch_end pid=[0-9]+ ok=1 fail=0 total=1 duration=[0-9]+$'

# ── T7 all, jobs=1 ───────────────────────────────────────────────────────────
echo "T7 all jobs=1 (A, B/C, /bad)"
conf A B/C /bad
m=$(mark); run "$S" all 2>/dev/null; assert_eq "batch rc=1 (one job failed)" $? 1
ev=$(since "$m")
assert_match "batch_start" "$ev" 'event=batch_start pid=[0-9]+ total=3 jobs=1$'
bpid=$(sed -n 's/.*event=batch_start pid=\([0-9]*\).*/\1/p' <<< "$ev")
assert_eq "3 job_start with batch=$bpid" "$(grep -c "event=job_start .* batch=$bpid\$" <<< "$ev")" 3
assert_eq "3 job_end with batch=$bpid" "$(grep -c "event=job_end .* batch=$bpid\$" <<< "$ev")" 3
assert_match "B/C ok" "$ev" 'job_end subpath=B/C run=[0-9]+ exit=0'
assert_match "/bad -> 90" "$ev" 'job_end subpath=/bad run=[0-9]+ exit=90'
assert_match "batch_end ok=2 fail=1" "$ev" 'event=batch_end pid=[0-9]+ ok=2 fail=1 total=3 duration=[0-9]+$'
assert_eq "sequential: no interleaving (A ends before B/C starts)" \
    "$(names <<< "$ev" | grep -vE 'job_progress|job_stats' | tr '\n' ' ')" \
    "batch_start job_start job_end job_start job_end job_start job_end batch_end "
[ -d "$DST/B" ] && ok "destParent \$DST/B created" || bad "destParent \$DST/B missing"
[ -f "$LOG/jobs/B_C.log" ] && ok "job log B_C.log" || bad "job log B_C.log missing"
assert_match "B/C rsync dest is parent" "$(tail -n 2 "$FFDS_SHIM_ARGV")" " $SRC/B/C $DST/B/\$"
assert_eq "rc dir cleaned" "$(ls -A "$TMPDIR" | wc -l)" 0

# ── T8 all, jobs=2, duplicated subpath ───────────────────────────────────────
echo "T8 all jobs=2 (dup, dup, A) with overlap"
conf dup dup A
m=$(mark); run FFDS_SYNC_JOBS=2 FFDS_SHIM_SLEEP=2 "$S" all 2>/dev/null; assert_eq "batch rc=1" $? 1
ev=$(since "$m")
assert_match "batch_start jobs=2" "$ev" 'event=batch_start pid=[0-9]+ total=3 jobs=2$'
assert_eq "dup: one success" "$(grep -c 'job_end subpath=dup run=[0-9]* exit=0 ' <<< "$ev")" 1
assert_eq "dup: one lock refusal" "$(grep -c 'job_end subpath=dup run=[0-9]* exit=92 ' <<< "$ev")" 1
assert_match "ok+fail == total" "$ev" 'event=batch_end pid=[0-9]+ ok=2 fail=1 total=3 '
assert_eq "rc dir cleaned" "$(ls -A "$TMPDIR" | wc -l)" 0

# ── T9 signal abort ──────────────────────────────────────────────────────────
echo "T9 SIGTERM during batch"
conf A
: > "$FFDS_SHIM_PIDS"
m=$(mark)
# Own process group (set -m), then signal the whole group: that is what
# systemd's KillMode=control-group does on TimeoutStartSec -- batch,
# worker, rsync and the filter all get SIGTERM at once. Not via run():
# a function in the background adds a subshell, and wait would return
# that subshell's 143 before the batch has finished its trap.
set -m
env -u JOURNAL_STREAM PATH="$SCRATCH/bin:$PATH" FFDS_SHIM_SLEEP=10 \
    "$S" all 2>/dev/null & bpid=$!
set +m
sleep 1
kill -TERM -- "-$bpid"; wait "$bpid" 2>/dev/null; assert_eq "batch rc=94" $? 94
ev=$(since "$m")
assert_match "job_start before the kill" "$ev" 'event=job_start subpath=A '
assert_match "batch_abort signal" "$ev" 'event=batch_abort pid=[0-9]+ reason=signal$'
assert_nomatch "no batch_end" "$ev" 'event=batch_end'
assert_nomatch "no job_end (worker killed, contract: 94 is batch-level)" "$ev" 'event=job_end'
assert_eq "rc dir cleaned by EXIT trap" "$(ls -A "$TMPDIR" | wc -l)" 0
sleep 0.3
alive=0
while read -r p; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done < "$FFDS_SHIM_PIDS"
assert_eq "no rsync (shim) survived the group kill" "$alive" 0

# ── T10 rsync exit code propagation ──────────────────────────────────────────
echo "T10 exit code propagation"
for code in 23 30; do
    m=$(mark); run FFDS_SHIM_RC=$code "$S" one A 2>/dev/null; assert_eq "rsync $code -> rc $code" $? $code
    assert_match "job_end exit=$code" "$(since "$m")" "job_end subpath=A run=[0-9]+ exit=$code "
done

# ── T11 journal mirror ───────────────────────────────────────────────────────
echo "T11 JOURNAL_STREAM mirror"
m=$(mark)
out=$(env JOURNAL_STREAM=1:2 PATH="$SCRATCH/bin:$PATH" "$S" one A 2>/dev/null); rc=$?
assert_eq "rc" "$rc" 0
assert_eq "stdout == lifecycle lines of events.log" "$out" \
          "$(since "$m" | grep -E 'event=(job_start|job_end) ')"
assert_eq "progress/stats not mirrored" "$(grep -cE 'job_progress|job_stats' <<< "$out")" 0
conf A
run "$S" all >/dev/null 2>&1; assert_eq "all without JOURNAL_STREAM still exits 0" $? 0

# ── T13 status ───────────────────────────────────────────────────────────────
echo "T13 status"
out=$(run "$S" status 2>&1); rc=$?
assert_eq "rc" "$rc" 0
assert_match "recent events section" "$out" 'recent events'
assert_match "lists job logs" "$out" 'jobs/A.log'

# ── T14 bad knobs ────────────────────────────────────────────────────────────
echo "T14 knob sanitation"
conf A
m=$(mark); run FFDS_SYNC_JOBS=abc "$S" all >/dev/null 2>&1; assert_eq "JOBS=abc rc 0" $? 0
assert_match "JOBS=abc -> jobs=1" "$(since "$m")" 'event=batch_start pid=[0-9]+ total=1 jobs=1$'
m=$(mark); run FFDS_PROGRESS_EVERY=0 "$S" one A 2>"$SCRATCH/t14.err"; assert_eq "PROGRESS_EVERY=0 rc 0" $? 0
assert_match "PROGRESS_EVERY=0 -> filter survives (job_stats present)" "$(since "$m")" 'event=job_stats '
assert_eq "no awk error" "$(cat "$SCRATCH/t14.err")" ""
m=$(mark); run FFDS_RSYNC_TIMEOUT=0 "$S" one A >/dev/null 2>&1
assert_nomatch "TIMEOUT=0 drops --timeout" "$(tail -n 1 "$FFDS_SHIM_ARGV")" '--timeout'
m=$(mark); run FFDS_RSYNC_EXTRA="--bwlimit=50m --dry-run" "$S" one A >/dev/null 2>&1
assert_match "EXTRA flags appended" "$(tail -n 1 "$FFDS_SHIM_ARGV")" ' --bwlimit=50m --dry-run '
assert_match "dry-run: '(DRY RUN)' suffix does not poison speedup" "$(since "$m")" \
    'event=job_stats .* speedup=2,345.67$'

# ── T16 rc directory unavailable (what ProtectSystem=strict without
#        PrivateTmp does to mktemp -d) ───────────────────────────────────────
echo "T16 mktemp failure"
conf A
argvLines=$(wc -l < "$FFDS_SHIM_ARGV")
m=$(mark); run TMPDIR=$SCRATCH/nonexistent "$S" all 2>/dev/null; assert_eq "TMPDIR unusable -> 90" $? 90
assert_eq "only a batch_abort" "$(since "$m" | names | tr '\n' ' ')" "batch_abort "
assert_match "reason=tmp-failed" "$(since "$m")" 'event=batch_abort pid=[0-9]+ reason=tmp-failed$'
assert_eq "no worker spawned" "$(wc -l < "$FFDS_SHIM_ARGV")" "$argvLines"

# ── T17 log dir / lock dir unavailable ───────────────────────────────────────
echo "T17 log and lock dir failures"
S_ROLOG=$SCRATCH/ffds_sync_rolog.sh; S_NOLOCK=$SCRATCH/ffds_sync_nolock.sh
make_copy "$S_ROLOG" "(/ /proc)"
sed -i "s|^logDir=.*|logDir=$SCRATCH/ro/log|" "$S_ROLOG"
make_copy "$S_NOLOCK" "(/ /proc)"
sed -i "s|^lockDir=.*|lockDir=$SCRATCH/nonexistent-lock|" "$S_NOLOCK"
argvLines=$(wc -l < "$FFDS_SHIM_ARGV")
if [ "$(id -u)" -eq 0 ]; then
    echo "  skip read-only log dir (root ignores directory modes)"
else
    mkdir -p "$SCRATCH/ro"; chmod 555 "$SCRATCH/ro"
    run "$S_ROLOG" one A 2>"$SCRATCH/t17.err"; assert_eq "one: log dir unwritable -> 90" $? 90
    assert_match "one: mkdir error on stderr" "$(cat "$SCRATCH/t17.err")" 'cannot create directory'
    run "$S_ROLOG" all 2>/dev/null; assert_eq "all: log dir unwritable -> 90" $? 90
    chmod 755 "$SCRATCH/ro"
fi
m=$(mark); run "$S_NOLOCK" one A 2>"$SCRATCH/t17.err"; assert_eq "one: lock dir missing -> 90" $? 90
assert_match "one: job_end exit=90" "$(since "$m")" 'job_end subpath=A run=[0-9]+ exit=90 duration=0$'
assert_match "one: lock error on stderr" "$(cat "$SCRATCH/t17.err")" 'cannot open lock file'
m=$(mark); run "$S_NOLOCK" all 2>/dev/null; assert_eq "all: lock dir missing -> 90" $? 90
assert_eq "all: no event (fails before the batch lock)" "$(since "$m" | wc -l)" 0
assert_eq "rsync never invoked" "$(wc -l < "$FFDS_SHIM_ARGV")" "$argvLines"

# ── T18 manual 'kill -TERM <batch>': documented limit -- the worker dies,
#        rsync (and the filter) live on as orphans holding the job lock ──────
echo "T18 batch-only SIGTERM leaves an rsync orphan holding the lock"
conf A
: > "$FFDS_SHIM_PIDS"
m=$(mark)
# no set -m: the batch stays in our process group and only it is signalled
env -u JOURNAL_STREAM PATH="$SCRATCH/bin:$PATH" FFDS_SHIM_SLEEP=4 \
    "$S" all 2>/dev/null & bpid=$!
wait_until 50 test -s "$FFDS_SHIM_PIDS" || bad "shim did not start"
kill -TERM "$bpid"; wait "$bpid" 2>/dev/null; assert_eq "batch rc=94" $? 94
sleep 0.2
ev=$(since "$m")
assert_match "batch_abort signal" "$ev" 'event=batch_abort pid=[0-9]+ reason=signal$'
wrun=$(sed -n 's/.*event=job_start subpath=A run=\([0-9]*\).*/\1/p' <<< "$ev" | head -n 1)
shim=$(tail -n 1 "$FFDS_SHIM_PIDS")
if kill -0 "$wrun" 2>/dev/null; then bad "worker $wrun survived the batch trap"; else ok "worker killed by the batch trap"; fi
if kill -0 "$shim" 2>/dev/null; then ok "rsync (shim) orphaned, still running"; else bad "shim died with the batch"; fi
run "$S" one A 2>/dev/null; assert_eq "same subpath meanwhile -> 92 (orphan holds the lock)" $? 92
wait_until 100 lock_free "$LOCK/ffds-sync-job-A.lock" || bad "lock never released"
assert_match "orphaned filter still logged job_stats for the dead run" "$(since "$m")" \
    "event=job_stats subpath=A run=$wrun "
assert_nomatch "no job_end for the dead run" "$(since "$m")" "event=job_end subpath=A run=$wrun "
run "$S" one A >/dev/null 2>&1; assert_eq "after the orphan exits -> 0" $? 0

# ── T19 a worker dies by SIGKILL while the batch waits (U1 probe) ────────────
# bash 5.3 here: wait -n reaps it and the batch carries on. On bash 5.2
# (Ubuntu 24.04) wait -n may miss a signalled child; then this case
# reports a stall instead of hanging -- TimeoutStartSec is the backstop.
echo "T19 SIGKILL a worker: batch must carry on (bash $BASH_VERSION)"
conf A B/C
: > "$FFDS_SHIM_PIDS"
m=$(mark)
set -m
env -u JOURNAL_STREAM PATH="$SCRATCH/bin:$PATH" FFDS_SHIM_SLEEP=3 \
    "$S" all 2>/dev/null & bpid=$!
set +m
wait_until 50 test -s "$FFDS_SHIM_PIDS" || bad "shim did not start"
wrun=$(since "$m" | sed -n 's/.*event=job_start subpath=A run=\([0-9]*\).*/\1/p' | head -n 1)
kill -KILL "$wrun"
t19Stalled=0
if wait_until 200 dead "$bpid"; then
    wait "$bpid" 2>/dev/null; assert_eq "batch rc=1 (A never reported)" $? 1
else
    bad "batch still waiting 20 s after the worker died: wait -n missed it (U1, bash $BASH_VERSION)"
    t19Stalled=1   # the group kill below adds one more batch_abort signal (T12 allows for it)
    kill -TERM -- "-$bpid"; wait "$bpid" 2>/dev/null
fi
ev=$(since "$m")
assert_match "B/C still ran" "$ev" 'event=job_end subpath=B/C run=[0-9]+ exit=0 '
assert_nomatch "no job_end for the killed A" "$ev" 'event=job_end subpath=A '
assert_match "batch_end ok=1 fail=0 total=2" "$ev" 'event=batch_end pid=[0-9]+ ok=1 fail=0 total=2 '
wait_until 100 lock_free "$LOCK/ffds-sync-job-A.lock" || bad "A lock never released"

# ── real rsync layer (skips when rsync is absent) ────────────────────────────
echo "T15 real rsync"
if command -v rsync >/dev/null 2>&1; then
    realRun() { env -u JOURNAL_STREAM "$@"; }   # shim not in PATH
    rm -rf "$DST"; mkdir -p "$DST/A"; echo stale > "$DST/A/stale.bin"
    m=$(mark); realRun "$S" one A 2>/dev/null; assert_eq "first run rc 0" $? 0
    assert_match "stats transferred=3" "$(since "$m")" 'event=job_stats .* transferred=3 '
    [ ! -e "$DST/A/stale.bin" ] && ok "--delete removed stale file" || bad "stale file survived --delete"
    if diff -r "$SRC/A" "$DST/A" >/dev/null; then ok "tree equal"; else bad "tree differs"; fi
    m=$(mark); realRun "$S" one A 2>/dev/null; assert_eq "second run rc 0" $? 0
    assert_match "idempotent: transferred=0" "$(since "$m")" 'event=job_stats .* transferred=0 '
    assert_eq "mode 775 on synced file" "$(stat -c %a "$DST/A/one.bin")" 775
else
    echo "  skip real rsync layer: rsync not installed on this machine"
fi

# ── T12 monitor gate (last: consumes the whole log) ──────────────────────────
echo "T12 monitor parses everything"
if [ ! -f "$monitorDir/ffds_sync_monitor.py" ]; then
    echo "  skip monitor gate: sync_monitor is not part of this repo"
elif FFDS_SYNC_EVENT_LOG=$EV FFDS_T19_STALLED=$t19Stalled python3 - "$monitorDir" <<'EOF'
import os, sys
sys.path.insert(0, sys.argv[1])
import ffds_sync_monitor as m
s = m.STATE
s.consume()
errs = dict(s.parse_errors)
assert errs == {}, f"parse errors: {errs}"
assert s.batch is None, "batch left open"
assert s.jobs == {}, f"jobs left open: {list(s.jobs)}"
r = s.results
assert r["A"]["runs"]["0"] >= 5, r["A"]["runs"]
assert r["A"]["runs"]["23"] == 1 and r["A"]["runs"]["30"] == 1, r["A"]["runs"]
assert r["A"]["runs"]["91"] == 1 and r["A"]["runs"]["92"] == 2, r["A"]["runs"]   # T4, T18
assert r["A"]["runs"]["90"] == 1, r["A"]["runs"]                                  # T17 lock dir
assert r["?"]["runs"]["90"] == 1 and r["a_b"]["runs"]["90"] == 1
assert r["/bad"]["runs"]["90"] == 1
assert r["B/C"]["runs"]["0"] == 2                                                 # T7, T19
assert r["dup"]["runs"]["0"] == 1 and r["dup"]["runs"]["92"] == 1
assert r["A"]["stats"]["files_total"] == 1234, r["A"]["stats"]
assert r["A"]["stats"]["speedup"] == 2345.67, r["A"]["stats"]
ab = dict(s.aborts)
want = {"mount-missing": 1, "lock-busy": 1, "config-missing": 1, "config-empty": 1,
        "tmp-failed": 1, "signal": 2 + int(os.environ["FFDS_T19_STALLED"])}     # T9, T18 (+T19 on bash 5.2)
assert ab == want, ab
out = m.render_metrics()
for needle in ('ffds_sync_runs_total{subpath="A",exit_code="0"}',
               'ffds_sync_batch_aborts_total{reason="lock-busy"} 1',
               'ffds_sync_last_run_exit_code{subpath="/bad"} 90',
               "ffds_sync_events_total", "ffds_sync_log_last_event_timestamp_seconds"):
    assert needle in out, f"missing in /metrics: {needle}"
print(f"  ok   monitor: {sum(s.events.values())} events, {len(r)} subpaths, "
      f"{len(out.splitlines())} metric lines, parse_errors={{}}")
EOF
then pass=$((pass + 1)); else bad "monitor gate"; fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
