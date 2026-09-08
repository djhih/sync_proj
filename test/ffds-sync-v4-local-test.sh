#!/bin/bash
#
# ffds-sync-v4-local-test.sh -- end-to-end harness for ffds-sync-v4.sh
#
# Same sandbox model as the v3 harness: everything under one mktemp -d,
# the script under test is a copy whose fixed config block is rewritten
# into the scratch tree, and rclone is a shim first in PATH.  The shim
# prints canned --use-json-log output (selected by FFDS_SHIM_MODE),
# creates the destination like real rclone would (unless dry-run), sleeps
# FFDS_SHIM_SLEEP and exits FFDS_SHIM_RC; 'lsd' calls exit
# FFDS_SHIM_LSD_RC.  A final layer uses a real rclone when installed
# (local->local scratch only) and skips otherwise -- it MUST be run on a
# machine with the pinned rclone before any sync-host smoke.
#
# Usage:  bash sendout/test/ffds-sync-v4-local-test.sh
#         FFDS_TEST_KEEP=1 ...   keeps the scratch dir
# Exit:   0 when every assertion passed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
script=$repo/ffds-sync-v4.sh
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
RCONF=$SCRATCH/rclone.conf
S=$SCRATCH/ffds_sync_v4.sh
S_NOMNT=$SCRATCH/ffds_sync_v4_nomount.sh
export TMPDIR=$SCRATCH/tmp
export FFDS_SHIM_ARGV=$SCRATCH/shim.argv
export FFDS_SHIM_PIDS=$SCRATCH/shim.pids
export FFDS_SHIM_ENV=$SCRATCH/shim.env
mkdir -p "$SRC" "$DST" "$LOCK" "$TMPDIR" "$SCRATCH/bin"
touch "$RCONF"

# ── helpers (v3 harness idiom) ───────────────────────────────────────────────
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
run()   { env -u JOURNAL_STREAM PATH="$SCRATCH/bin:$PATH" "$@"; }
hold_lock() { flock "$1" sleep 30 & holder=$!; sleep 0.2; }
release()   { pkill -P "$holder" 2>/dev/null; kill "$holder" 2>/dev/null
              wait "$holder" 2>/dev/null; }
wait_until() { local n=$1; shift
               until "$@" 2>/dev/null; do n=$((n - 1)); [ "$n" -gt 0 ] || return 1; sleep 0.1; done; }
lock_free() { flock -n "$1" true; }
has_ev()  { since "$1" | grep -qE -- "$2"; }

make_copy() {  # <dest> <mountpoints array literal>
    sed -e "s|^srcRoot=.*|srcRoot=$SRC|" \
        -e "s|^dstRoot=.*|dstRoot=$DST|" \
        -e "s|^mountpoints=.*|mountpoints=$2|" \
        -e "s|^logDir=.*|logDir=$LOG|" \
        -e "s|^config=.*|config=$CONF|" \
        -e "s|^lockDir=.*|lockDir=$LOCK|" \
        -e "s|^fileOwner=.*|fileOwner=$(id -un):$(id -gn)|" \
        -e "s|^rcloneConfig=.*|rcloneConfig=$RCONF|" \
        -e "s|^smbRemote=.*|smbRemote=shimremote:share/FFDS|" \
        "$script" > "$1"
    chmod +x "$1"
}

# ── fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$SRC/A" "$SRC/B/C" "$SRC/L"
head -c 1048576 /dev/urandom > "$SRC/A/one.bin"
head -c 1048576 /dev/urandom > "$SRC/A/two.bin"
echo c > "$SRC/B/C/c.txt"

# rclone shim: canned --use-json-log output per FFDS_SHIM_MODE; creates
# the destination (and one 644 file for the fixup layer) like rclone
# would, except in nodst mode or when --dry-run=true is on the argv.
cat > "$SCRATCH/bin/rclone" <<'EOF'
#!/bin/bash
echo "$$" >> "${FFDS_SHIM_PIDS:-/dev/null}"
printf '%s\n' "$*" >> "${FFDS_SHIM_ARGV:-/dev/null}"
echo "RCLONE_CONFIG=${RCLONE_CONFIG:-unset} RCLONE_DRY_RUN=${RCLONE_DRY_RUN:-unset}" \
    >> "${FFDS_SHIM_ENV:-/dev/null}"
if [ "$1" = lsd ]; then
    if [ "${FFDS_SHIM_LSD_RC:-0}" != 0 ]; then
        echo '{"level":"error","msg":"directory not found","time":"T"}'
    fi
    exit "${FFDS_SHIM_LSD_RC:-0}"
fi
dst=$3
mode=${FFDS_SHIM_MODE:-happy}
dry=0; case " $* " in *" --dry-run=true "*) dry=1 ;; esac
if [ "$dry" = 0 ] && [ "$mode" != nodst ]; then
    mkdir -p "$dst"
    echo shim > "$dst/shimfile"
    chmod 644 "$dst/shimfile"
fi
info()  { printf '{"level":"info","msg":"%s","object":"%s","time":"T"}\n' "$1" "$2"; }
stats() { printf '{"level":"notice","msg":"stats","stats":%s,"time":"T"}\n' "$1"; }
FINAL='{"bytes":2097152,"totalBytes":2097152,"speed":349525.0,"eta":0,"transfers":2,"totalTransfers":2,"checks":98,"totalChecks":98,"deletes":1,"deletedDirs":0,"errors":0,"fatalError":false,"elapsedTime":4.2}'
case $mode in
    happy|nodst)
        info "Copied (new)" "A/one.bin"
        stats '{"bytes":1048576,"totalBytes":2097152,"speed":524288,"eta":2,"transfers":1}'
        stats '{"bytes":1572864,"totalBytes":2097152,"speed":524288.7,"eta":null,"transfers":1}'
        info "Deleted" "A/old.bin"
        stats "$FINAL"
        ;;
    overpct)
        stats '{"bytes":3000000,"totalBytes":2097152,"speed":1000,"eta":1,"transfers":1}'
        stats "$FINAL"
        ;;
    garbage)
        echo 'NOT-JSON garbage line from somewhere'
        stats "$FINAL"
        ;;
    badfinal)
        stats '{"bytes":1048576,"totalBytes":2097152,"speed":524288,"eta":2,"transfers":1}'
        stats '{"bytes":2097152,"speed":100}'
        ;;
    nostats)
        info "Copied (new)" "A/one.bin"
        ;;
    zerostats)
        stats '{"bytes":0,"totalBytes":0,"speed":0,"eta":null,"transfers":0,"totalTransfers":0,"checks":98,"totalChecks":98,"deletes":0,"deletedDirs":0,"errors":0}'
        ;;
esac
sleep "${FFDS_SHIM_SLEEP:-0}"
exit "${FFDS_SHIM_RC:-0}"
EOF
chmod +x "$SCRATCH/bin/rclone"

make_copy "$S" "(/ /proc)"
make_copy "$S_NOMNT" "(/ /nonexistent-mnt-xyz)"

echo "scratch: $SCRATCH"
echo "bash $BASH_VERSION, $(python3 --version 2>&1), find: $(find --version 2>/dev/null | head -n 1)"

# ── V0 static ────────────────────────────────────────────────────────────────
echo "V0 static"
if bash -n "$S"; then ok "bash -n"; else bad "bash -n"; fi
for key in "srcRoot=$SRC" "dstRoot=$DST" "mountpoints=(/ /proc)" \
           "logDir=$LOG" "config=$CONF" "lockDir=$LOCK" \
           "fileOwner=$(id -un):$(id -gn)" "rcloneConfig=$RCONF" \
           "smbRemote=shimremote:share/FFDS"; do
    assert_eq "config rewritten: ${key%%=*}" "$(grep -c "^$key\$" "$S")" 1
done
mkdir -p "$SCRATCH/findprobe"
if find "$SCRATCH/findprobe" -name x -print , -name y -print >/dev/null 2>&1; then
    ok "find supports the ',' operator"
else
    bad "find lacks the ',' operator (fixup depends on it)"
fi

# ── V1 happy path, mount backend ─────────────────────────────────────────────
echo "V1 one A (mount, shim)"
m=$(mark)
out=$(run RCLONE_DRY_RUN=true "$S" one A 2>"$SCRATCH/v1.err"); rc=$?
assert_eq "rc" "$rc" 0
assert_eq "stdout empty without JOURNAL_STREAM" "$out" ""
assert_eq "stderr quiet" "$(cat "$SCRATCH/v1.err")" ""
ev=$(since "$m")
assert_eq "event sequence" "$(names <<< "$ev" | tr '\n' ' ')" \
          "job_start job_progress job_progress job_progress job_stats job_end "
assert_eq "one run id" "$(grep -o ' run=[0-9]*' <<< "$ev" | sort -u | wc -l)" 1
assert_nomatch "no batch= on manual run" "$ev" 'batch='
assert_match "progress tick 1 (plain ints, H:MM:SS eta)" "$ev" \
    'job_progress subpath=A run=[0-9]+ bytes=1048576 pct=50 speed=524288 eta=0:00:02 xfr=1$'
assert_match "progress tick 2 (float speed -> int, null eta omitted)" "$ev" \
    'job_progress subpath=A run=[0-9]+ bytes=1572864 pct=75 speed=524288 xfr=1$'
assert_match "progress final tick" "$ev" \
    'job_progress subpath=A run=[0-9]+ bytes=2097152 pct=100 speed=349525 eta=0:00:00 xfr=2$'
assert_match "job_stats payload (rclone-native keys, no files=/size=)" "$ev" \
    'job_stats subpath=A run=[0-9]+ transferred=2 checks=98 total_checks=98 transfers_total=2 transfer_bytes=2097152 transfer_bytes_total=2097152 deletes=1 deleted_dirs=0 errors=0$'
assert_nomatch "no rsync-only stats keys" "$ev" ' (files|size|created|listgen|speedup)='
assert_nomatch "no chk= (totalChecks is not a file total)" "$ev" ' chk='
assert_match "job_end phases" "$ev" \
    'job_end subpath=A run=[0-9]+ exit=0 duration=[0-9.]+ dry_run=0 rclone_exit=0 filter_exit=0 fixup_exit=0 engine_s=[0-9.]+ preflight_s=[0-9.]+ fixup=[0-9.]+$'
jl=$LOG/jobs/A.log
assert_match "RUN marker with backend" "$(cat "$jl")" '^=== RUN .* backend=mount dry_run=0 subpath=A ===$'
assert_match "name1 equivalent (Copied)" "$(cat "$jl")" '^Copied \(new\): A/one.bin$'
assert_match "del1 equivalent (Deleted)" "$(cat "$jl")" '^Deleted: A/old.bin$'
assert_eq "human progress lines (status greppable)" \
          "$(grep -cE '^[[:space:]]*[0-9.,]+[KMGT]?B?[[:space:]]+[0-9]+%' "$jl")" 3
argv=$(tail -n 1 "$FFDS_SHIM_ARGV")
assert_match "rclone argv" "$argv" \
    "^sync $SRC/A $DST/A --delete-during --create-empty-src-dirs --links --transfers 4 --checkers 8 --multi-thread-streams 4 --timeout 1800s --contimeout 30s --retries 1 --low-level-retries 10 --use-json-log --log-level INFO --stats 15s --stats-log-level NOTICE --dry-run=false\$"
assert_match "launcher pins RCLONE_CONFIG, scrubs RCLONE_DRY_RUN" \
    "$(tail -n 1 "$FFDS_SHIM_ENV")" \
    "^RCLONE_CONFIG=$RCONF RCLONE_DRY_RUN=unset\$"
assert_eq "fixup: shim's 644 file forced to 775" "$(stat -c %a "$DST/A/shimfile")" 775
assert_eq "fixup: destination dir forced to 775" "$(stat -c %a "$DST/A")" 775
assert_match "fixup changes logged" "$(cat "$jl")" "mode of .*shimfile.* changed"
raws=("$LOG"/raw/A.*.jsonl)
[ -f "${raws[0]}" ] && ok "raw jsonl saved per run" || bad "raw jsonl missing"
assert_match "raw jsonl holds original lines" "$(cat "${raws[0]}")" '"totalChecks":98'

# ── V2 argv construction and knobs ───────────────────────────────────────────
echo "V2 backends and knobs"
m=$(mark)
run FFDS_V4_BACKEND=smb "$S" one A >/dev/null 2>&1; assert_eq "smb backend rc" $? 0
assert_match "lsd preflight argv" "$(tail -n 2 "$FFDS_SHIM_ARGV" | head -n 1)" \
    '^lsd shimremote:share/FFDS/A --contimeout 10s --timeout 20s --retries 1$'
assert_match "smb sync src is the remote" "$(tail -n 1 "$FFDS_SHIM_ARGV")" \
    "^sync shimremote:share/FFDS/A $DST/A "
run FFDS_V4_TRANSFERS=9 FFDS_V4_CHECKERS=3 FFDS_V4_MULTI_THREAD_STREAMS=0 \
    FFDS_V4_TIMEOUT=0 FFDS_PROGRESS_EVERY=5 "$S" one A >/dev/null 2>&1
assert_eq "override knobs rc" $? 0
argv=$(tail -n 1 "$FFDS_SHIM_ARGV")
assert_match "knob overrides in argv" "$argv" \
    ' --transfers 9 --checkers 3 --multi-thread-streams 0 --timeout 0s .* --stats 5s '
run FFDS_V4_TRANSFERS=abc "$S" one A >/dev/null 2>&1; assert_eq "bad numeric knob falls back, rc" $? 0
assert_match "TRANSFERS=abc -> 4" "$(tail -n 1 "$FFDS_SHIM_ARGV")" ' --transfers 4 '
run FFDS_V4_BWLIMIT=50M FFDS_V4_MAX_DELETE=1000 "$S" one A >/dev/null 2>&1
assert_eq "option knobs rc" $? 0
assert_match "option knobs appended after --dry-run" "$(tail -n 1 "$FFDS_SHIM_ARGV")" \
    ' --dry-run=false --bwlimit 50M --max-delete 1000$'
argvLines=$(wc -l < "$FFDS_SHIM_ARGV"); evLines=$(mark)
run FFDS_V4_BWLIMIT='50M;evil' "$S" one A 2>/dev/null
assert_eq "bad BWLIMIT character -> 90" $? 90
run FFDS_V4_MAX_DELETE=many "$S" one A 2>/dev/null
assert_eq "non-integer MAX_DELETE -> 90" $? 90
run FFDS_V4_BACKEND=weird "$S" one A 2>/dev/null
assert_eq "bad backend -> 90" $? 90
assert_eq "rejected runs: rclone never invoked" "$(wc -l < "$FFDS_SHIM_ARGV")" "$argvLines"
assert_eq "rejected runs: no events" "$(mark)" "$evLines"

# ── V3 dry-run ───────────────────────────────────────────────────────────────
echo "V3 dry-run"
rm -rf "$DST/B"
m=$(mark)
run FFDS_V4_DRY_RUN=1 "$S" one B/C >/dev/null 2>&1; assert_eq "env dry-run rc" $? 0
assert_match "argv has --dry-run=true once" "$(tail -n 1 "$FFDS_SHIM_ARGV")" ' --dry-run=true$'
assert_eq "only one --dry-run token" \
    "$(tail -n 1 "$FFDS_SHIM_ARGV" | grep -o -- '--dry-run' | wc -l)" 1
[ ! -e "$DST/B/C" ] && ok "dry-run: destination untouched" || bad "dry-run created $DST/B/C"
assert_match "job_end dry_run=1, fixup skipped" "$(since "$m")" \
    'job_end subpath=B/C run=[0-9]+ exit=0 duration=[0-9.]+ dry_run=1 rclone_exit=0 filter_exit=0 fixup_exit=skipped engine_s=[0-9.]+ preflight_s=[0-9.]+ fixup=0$'
run FFDS_V4_DRY_RUN=2 "$S" one B/C 2>/dev/null
assert_eq "FFDS_V4_DRY_RUN=2 -> 90" $? 90

# ── V4 fixup ─────────────────────────────────────────────────────────────────
echo "V4 fixup"
mkdir -p "$DST/A"; echo x > "$DST/A/badmode.txt"; chmod 600 "$DST/A/badmode.txt"
ln -sf /nonexistent-target "$DST/A/alink"
run "$S" one A >/dev/null 2>&1; assert_eq "rc with pre-broken modes" $? 0
assert_eq "wrong mode fixed to 775" "$(stat -c %a "$DST/A/badmode.txt")" 775
[ -L "$DST/A/alink" ] && ok "symlink left alone by chmod pass" || bad "symlink destroyed"
m=$(mark)
run FFDS_SHIM_RC=7 "$S" one A 2>/dev/null; assert_eq "engine failure propagates (7)" $? 7
assert_match "fixup still ran after engine failure" "$(since "$m")" \
    'job_end subpath=A run=[0-9]+ exit=7 duration=[0-9.]+ dry_run=0 rclone_exit=7 filter_exit=0 fixup_exit=0 '
mkdir -p "$DST/A/deny"; chmod 000 "$DST/A/deny"
if [ "$(id -u)" -eq 0 ]; then
    echo "  skip fixup-failure case (root ignores directory modes)"
    chmod 755 "$DST/A/deny"; rmdir "$DST/A/deny"
else
    m=$(mark)
    run "$S" one A 2>/dev/null; assert_eq "fixup failure -> 95" $? 95
    assert_match "job_end shows fixup_exit nonzero" "$(since "$m")" \
        'job_end subpath=A run=[0-9]+ exit=95 duration=[0-9.]+ dry_run=0 rclone_exit=0 filter_exit=0 fixup_exit=[1-9][0-9]* '
    chmod 755 "$DST/A/deny"; rmdir "$DST/A/deny"
fi
m=$(mark)
run FFDS_SHIM_MODE=nodst "$S" one NEWSUB 2>/dev/null
assert_eq "engine ok but dst missing -> 95" $? 95
assert_match "fixup_exit=missing" "$(since "$m")" \
    'job_end subpath=NEWSUB run=[0-9]+ exit=95 .* fixup_exit=missing '

# ── V5 telemetry contract ────────────────────────────────────────────────────
echo "V5 telemetry"
m=$(mark)
run FFDS_SHIM_MODE=garbage "$S" one A 2>/dev/null
assert_eq "non-JSON line -> 96" $? 96
assert_match "filter_exit=3 recorded" "$(since "$m")" \
    'job_end subpath=A run=[0-9]+ exit=96 .* rclone_exit=0 filter_exit=3 '
assert_nomatch "no job_stats on telemetry failure" "$(since "$m")" 'event=job_stats'
assert_match "original garbage preserved in job log" "$(cat "$LOG/jobs/A.log")" \
    '^NOT-JSON garbage line from somewhere$'
m=$(mark)
run FFDS_SHIM_MODE=badfinal "$S" one A 2>/dev/null
assert_eq "corrupt final stats -> 96 (no fallback to periodic)" $? 96
assert_nomatch "no job_stats from earlier periodic snapshot" "$(since "$m")" 'event=job_stats'
m=$(mark)
run FFDS_SHIM_MODE=nostats "$S" one A 2>/dev/null
assert_eq "no stats at all -> 96" $? 96
m=$(mark)
run FFDS_SHIM_MODE=zerostats "$S" one A >/dev/null 2>&1
assert_eq "zero-transfer success rc" $? 0
assert_match "job_stats transferred=0 still emitted" "$(since "$m")" \
    'job_stats subpath=A run=[0-9]+ transferred=0 checks=98 total_checks=98 transfers_total=0 transfer_bytes=0 transfer_bytes_total=0 deletes=0 deleted_dirs=0 errors=0$'
m=$(mark)
run FFDS_SHIM_MODE=overpct "$S" one A >/dev/null 2>&1
assert_eq "out-of-range pct is not fatal" $? 0
assert_match "over-100% tick keeps bytes, omits pct" "$(since "$m")" \
    'job_progress subpath=A run=[0-9]+ bytes=3000000 speed=1000 eta=0:00:01 xfr=1$'
if [ "$(id -u)" -eq 0 ]; then
    echo "  skip unwritable-log cases (root ignores file modes)"
else
    chmod 555 "$LOG/raw"
    m=$(mark)
    run "$S" one A 2>/dev/null
    assert_eq "raw jsonl unwritable -> 96" $? 96
    assert_match "filter_exit=4 (write failure)" "$(since "$m")" \
        'job_end subpath=A run=[0-9]+ exit=96 .* filter_exit=4 '
    chmod 755 "$LOG/raw"
    chmod 444 "$EV"
    run "$S" one A 2>"$SCRATCH/v5.err"
    assert_eq "event log unwritable -> 90" $? 90
    assert_match "error on stderr" "$(cat "$SCRATCH/v5.err")" 'cannot append'
    chmod 644 "$EV"
fi

# ── V6 lifecycle ─────────────────────────────────────────────────────────────
echo "V6 lifecycle"
argvLines=$(wc -l < "$FFDS_SHIM_ARGV")
for badsub in "" "a//b" "a b" "/abs" "trail/"; do
    run "$S" one "$badsub" 2>/dev/null
    assert_eq "'$badsub' -> 90" $? 90
done
run "$S" bogus 2>/dev/null; assert_eq "unknown subcommand -> 90" $? 90
assert_eq "bad subpaths: rclone never invoked" "$(wc -l < "$FFDS_SHIM_ARGV")" "$argvLines"

m=$(mark); run "$S_NOMNT" one A 2>/dev/null; assert_eq "missing mount -> 91" $? 91
assert_match "job_end exit=91" "$(since "$m")" 'job_end subpath=A run=[0-9]+ exit=91 '
conf A
m=$(mark); run "$S_NOMNT" all 2>/dev/null; assert_eq "all missing mount -> 91" $? 91
assert_match "batch_abort mount-missing" "$(since "$m")" \
    'event=batch_abort pid=[0-9]+ reason=mount-missing mountpoint=/nonexistent-mnt-xyz$'
m=$(mark)
run FFDS_V4_BACKEND=smb FFDS_SHIM_LSD_RC=1 "$S" one A 2>/dev/null
assert_eq "smb source preflight failure -> 91" $? 91
assert_match "job_end exit=91 (smb preflight)" "$(since "$m")" 'job_end subpath=A run=[0-9]+ exit=91 '

hold_lock "$LOCK/ffds-sync-job-A.lock"
m=$(mark); run "$S" one A 2>/dev/null; assert_eq "job lock busy -> 92" $? 92
assert_match "job_end exit=92" "$(since "$m")" 'job_end subpath=A run=[0-9]+ exit=92 '
release
run "$S" one A >/dev/null 2>&1; assert_eq "lock released -> 0" $? 0

conf A
hold_lock "$LOCK/ffds-sync-v4-all.lock"
m=$(mark); run "$S" all 2>/dev/null; assert_eq "batch lock busy -> 92" $? 92
assert_match "batch_abort lock-busy" "$(since "$m")" 'reason=lock-busy$'
release

rm -f "$CONF"
m=$(mark); run "$S" all 2>/dev/null; assert_eq "config missing -> 93" $? 93
assert_match "config-missing" "$(since "$m")" 'reason=config-missing$'
printf '# nothing\n' > "$CONF"
m=$(mark); run "$S" all 2>/dev/null; assert_eq "config empty -> 93" $? 93
assert_match "config-empty" "$(since "$m")" 'reason=config-empty$'
for badconf in "A|A" "a/b|a_b" "A|A/B"; do
    conf "${badconf%%|*}" "${badconf##*|}"
    m=$(mark); run "$S" all 2>/dev/null
    assert_eq "config '$badconf' -> 93" $? 93
    assert_match "config-invalid" "$(since "$m")" 'reason=config-invalid$'
done

conf A B/C
m=$(mark); run "$S" all 2>/dev/null; assert_eq "batch happy rc" $? 0
ev=$(since "$m")
assert_match "batch_start" "$ev" 'event=batch_start pid=[0-9]+ total=2 jobs=1$'
bpid=$(sed -n 's/.*event=batch_start pid=\([0-9]*\).*/\1/p' <<< "$ev")
assert_eq "2 job_start with batch tag" "$(grep -c "event=job_start .* batch=$bpid\$" <<< "$ev")" 2
assert_match "batch_end ok=2 fail=0" "$ev" 'event=batch_end pid=[0-9]+ ok=2 fail=0 total=2 duration=[0-9]+$'
assert_eq "rc dir cleaned" "$(find "$TMPDIR" -mindepth 1 | wc -l)" 0

m=$(mark); run FFDS_SHIM_RC=3 "$S" one A 2>/dev/null
assert_eq "rclone rc 3 propagates" $? 3
assert_match "job_end exit=3" "$(since "$m")" 'job_end subpath=A run=[0-9]+ exit=3 .* rclone_exit=3 '

echo "V6 signals"
: > "$FFDS_SHIM_PIDS"
m=$(mark)
# not via run(): a function in the background adds a subshell and the
# TERM would hit the subshell, not the script under test
env -u JOURNAL_STREAM PATH="$SCRATCH/bin:$PATH" FFDS_SHIM_SLEEP=10 \
    "$S" one A 2>/dev/null & onePid=$!
wait_until 50 test -s "$FFDS_SHIM_PIDS" || bad "shim did not start"
kill -TERM "$onePid"; wait "$onePid" 2>/dev/null
assert_eq "one TERM -> 143" $? 143
ev=$(since "$m")
assert_match "job_end 143 with abort keys" "$ev" \
    'job_end subpath=A run=[0-9]+ exit=143 duration=[0-9.]+ dry_run=0 .* aborted=1 termination_signal=15$'
shim=$(tail -n 1 "$FFDS_SHIM_PIDS")
wait_until 30 bash -c "! kill -0 $shim 2>/dev/null" \
    && ok "engine group killed with the coordinator" \
    || bad "shim survived the coordinator TERM"
wait_until 50 lock_free "$LOCK/ffds-sync-job-A.lock" || bad "job lock never released"

conf A
: > "$FFDS_SHIM_PIDS"
m=$(mark)
set -m
env -u JOURNAL_STREAM PATH="$SCRATCH/bin:$PATH" FFDS_SHIM_SLEEP=10 \
    "$S" all 2>/dev/null & bpid=$!
set +m
wait_until 50 test -s "$FFDS_SHIM_PIDS" || bad "shim did not start"
kill -TERM -- "-$bpid"; wait "$bpid" 2>/dev/null
assert_eq "batch group TERM -> 94" $? 94
wait_until 100 has_ev "$m" 'event=job_end subpath=A run=[0-9]+ exit=143 ' \
    && ok "worker still emitted job_end 143 after batch abort" \
    || bad "no job_end 143 after batch signal"
assert_match "batch_abort signal" "$(since "$m")" 'event=batch_abort pid=[0-9]+ reason=signal$'
wait_until 100 lock_free "$LOCK/ffds-sync-job-A.lock" || bad "job lock never released (batch)"

ln -s "$SCRATCH" "$DST/L"
run "$S" one L 2>/dev/null; assert_eq "symlink at dst target -> 90" $? 90
rm "$DST/L"

# ── V7 JOURNAL_STREAM mirror ─────────────────────────────────────────────────
echo "V7 journal mirror"
m=$(mark)
out=$(env JOURNAL_STREAM=1:2 PATH="$SCRATCH/bin:$PATH" "$S" one A 2>/dev/null); rc=$?
assert_eq "rc" "$rc" 0
assert_eq "stdout == lifecycle lines only" "$out" \
          "$(since "$m" | grep -E 'event=(job_start|job_end) ')"
assert_eq "progress/stats never mirrored" "$(grep -cE 'job_progress|job_stats' <<< "$out")" 0

# ── V8 status ────────────────────────────────────────────────────────────────
echo "V8 status"
out=$(run "$S" status 2>&1); rc=$?
assert_eq "rc" "$rc" 0
assert_match "events tail present" "$out" 'recent events'
assert_match "job log listed" "$out" 'jobs/A.log'
assert_match "human progress line surfaced" "$out" '[0-9.]+[KMGT]?B[[:space:]]+[0-9]+%'

# ── V9 real rclone layer (skips when absent; REQUIRED before sync-host smoke) ────
echo "V9 real rclone"
if command -v rclone >/dev/null 2>&1; then
    realRun() { env -u JOURNAL_STREAM "$@"; }   # shim not in PATH
    rm -rf "$DST/A"
    m=$(mark); realRun "$S" one A 2>/dev/null; assert_eq "first real run rc" $? 0
    assert_match "real stats: transferred=2" "$(since "$m")" \
        'job_stats subpath=A run=[0-9]+ transferred=2 '
    if diff -r "$SRC/A" "$DST/A" >/dev/null; then ok "tree equal"; else bad "tree differs"; fi
    assert_eq "mode 775 via fixup" "$(stat -c %a "$DST/A/one.bin")" 775
    m=$(mark); realRun "$S" one A 2>/dev/null; assert_eq "second real run rc" $? 0
    assert_match "idempotent: transferred=0" "$(since "$m")" \
        'job_stats subpath=A run=[0-9]+ transferred=0 '
    echo "  note: pin fixtures from $LOG/raw/*.jsonl (rclone $(rclone version 2>/dev/null | head -n 1))"
else
    echo "  skip real rclone layer: rclone not installed (MUST run before sync-host smoke)"
fi

# ── V10 monitor gate (last: consumes the whole log) ──────────────────────────
echo "V10 monitor parses everything"
if [ ! -f "$monitorDir/ffds_sync_monitor.py" ]; then
    echo "  skip monitor gate: sync_monitor is not part of this repo"
elif FFDS_SYNC_EVENT_LOG=$EV python3 - "$monitorDir" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import ffds_sync_monitor as m
s = m.STATE
s.consume()
errs = dict(s.parse_errors)
assert errs == {}, f"parse errors: {errs}"
assert s.batch is None, "batch left open"
assert s.jobs == {}, f"jobs left open: {list(s.jobs)}"
r = s.results
runs_A = dict(r["A"]["runs"])
for code in ("92", "3", "7"):
    assert runs_A.get(code) == 1, (code, runs_A)
assert runs_A.get("91") == 2, runs_A
assert runs_A.get("96") == 4, runs_A
assert runs_A.get("143") == 2, runs_A
assert runs_A.get("0", 0) >= 8, runs_A
assert r["B/C"]["runs"]["0"] >= 2
assert r["NEWSUB"]["runs"]["95"] == 1
assert r["L"]["runs"]["90"] == 1
assert r["?"]["runs"]["90"] == 1 and r["a_b"]["runs"]["90"] == 1
# v4 stats vocabulary: only transferred= maps into the monitor
assert r["A"]["stats"] == {"files_transferred": 0.0} or \
       r["A"]["stats"].get("files_transferred") is not None, r["A"]["stats"]
ab = dict(s.aborts)
want = {"mount-missing": 1, "lock-busy": 1, "config-missing": 1,
        "config-empty": 1, "config-invalid": 3, "signal": 1}
assert ab == want, ab
out = m.render_metrics()
for needle in ('ffds_sync_runs_total{subpath="A",exit_code="96"} 4',
               'ffds_sync_last_run_exit_code{subpath="L"} 90',
               'ffds_sync_batch_aborts_total{reason="config-invalid"} 3',
               "ffds_sync_log_last_event_timestamp_seconds"):
    assert needle in out, f"missing in /metrics: {needle}"
print(f"  ok   monitor: {sum(s.events.values())} events, {len(r)} subpaths, "
      f"parse_errors={{}}")
EOF
then pass=$((pass + 1)); else bad "monitor gate"; fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
