#!/bin/bash
#
# ffds-v1-measure.sh -- measure the production v1 sync script
# (sync-host:/usr/local/ffds/sync_ffds.sh) on one subpath, with the run
# definitions and result field names of ffds-bench.sh, so v1 numbers can
# sit next to a v3/v4 campaign.  The bench is NOT modified: its
# ffds_bench_data.py is only called (manifest, select-incr, verify-dst,
# scope-worker) and imported read-only by ffds_v1_measure.py.
#
#   ffds-v1-measure.sh -p <subpath> [-r reps] [-o outdir] [-s v1-script]
#                      [--scenarios cold,warm,incr] [--incr-files N]
#                      [--no-drop-caches] [--keep-dst] [--force]
#                      [--run-timeout seconds]
#
# What runs is an INSTRUMENTED COPY of v1, never v1 in place:
#   * destination -> scratch $scratchBase/<id>/DataSet
#   * its log     -> <outdir>/v1log/ (v1 truncates /var/log/rsync-smb*.log)
#   * rsync gets --stats (prints the summary block: files transferred)
#   * three marker lines: before rsync, after rsync (its exit code -- v1
#     itself always exits 0), after the find sweeps (rsync/fixup split)
# Everything else -- rsync -avzhP --no-owner --no-group --delete, the four
# find passes with their inverted chown test, the pgrep guard, the log
# redirection -- is v1 verbatim; <outdir>/v1-instrument.diff shows it.
# If the script does not have the known v1 shape, no copy is made.
#
# Per measured run:  systemd-run --scope
#                      -> bench scope-worker (cgroup CPU/IO/memory.peak,
#                         elapsed -- the bench's own definitions)
#                        -> /usr/bin/time -v (when installed)
#                          -> the copy
# Results: <outdir>/runs/<run>/result.json, results.csv, SUMMARY.txt.
#
# Run as root on sync-host in a quiet window: no sync running or scheduled
# (root's crontab entry for sync_all.sh is saved in preflight-cron.txt),
# nobody on /mnt/src-share; drop_caches (default) is host-wide.
#
# Test hook: FFDS_V1M_TEST_NONROOT=1 skips the root requirement and forces
# cache_policy=retain -- for the sandbox harness only.

set -u

# ── Fixed configuration -- edit in place (line-anchored for the harness) ─────
v1Script=/usr/local/ffds/sync_ffds.sh
srcRoot=/mnt/src-share/DataSet
scratchBase=/mnt/dst-fs/ffds-v1-measure
expectMount=/mnt/dst-fs
lockFile=/run/lock/ffds-v1-measure.lock
cifsStats=/proc/fs/cifs/Stats
timeBin=/usr/bin/time
benchData=
# ─────────────────────────────────────────────────────────────────────────────

here=$(cd "$(dirname "$0")" && pwd)
helper=$here/ffds_v1_measure.py
data=${benchData:-$here/../bench/ffds_bench_data.py}

die() { echo "ffds-v1-measure: $*" >&2; exit 1; }
log() { echo "[$(date '+%F %T')] $*" | tee -a "${outdir:-/dev/null}/run.log" >&2; }
h() { FFDS_BENCH_DIR=$(dirname "$data") python3 "$helper" "$@"; }

# same "other sync" pattern as the bench; our own processes are excluded
# by the id in their command lines
syncPattern='sync_all\.sh|sync_ffds|ffds_sync(_v4)?\.sh (all|one)|rsync .*DataSet|rclone sync '

# ── argument parsing ─────────────────────────────────────────────────────────
subpath= reps=3 outdir=
scenarios=(cold warm incr)
incrFiles=100
cachePolicy=drop
keepDst=0 force=0 runTimeout=7200
while [ $# -gt 0 ]; do
    case $1 in
        -p) subpath=${2-}; shift 2 ;;
        -r) reps=${2-}; shift 2 ;;
        -o) outdir=${2-}; shift 2 ;;
        -s) v1Script=${2-}; shift 2 ;;
        --scenarios) IFS=, read -r -a scenarios <<< "${2-}"; shift 2 ;;
        --incr-files) incrFiles=${2-}; shift 2 ;;
        --no-drop-caches) cachePolicy=retain; shift ;;
        --keep-dst) keepDst=1; shift ;;
        --force) force=1; shift ;;
        --run-timeout) runTimeout=${2-}; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$subpath" ] || die "-p <subpath> is required"
case $reps in ''|*[!0-9]*) die "bad -r" ;; esac
[ "$reps" -ge 1 ] && [ "$reps" -le 20 ] || die "-r must be 1..20"
case $incrFiles in ''|*[!0-9]*) die "bad --incr-files" ;; esac
case $runTimeout in ''|*[!0-9]*) die "bad --run-timeout" ;; esac
for s in "${scenarios[@]}"; do
    case $s in cold|warm|incr) ;; *) die "bad scenario: $s" ;; esac
done
[ "$(printf '%s\n' "${scenarios[@]}" | sort -u | wc -l)" = "${#scenarios[@]}" ] \
    || die "duplicate scenarios"

testMode=${FFDS_V1M_TEST_NONROOT:-0}
if [ "$testMode" != 1 ] && [ "$(id -u)" -ne 0 ]; then
    die "must run as root (or FFDS_V1M_TEST_NONROOT=1 in the sandbox harness)"
fi
[ "$testMode" = 1 ] && cachePolicy=retain

for dep in python3 rsync flock systemd-run systemctl df pgrep; do
    command -v "$dep" >/dev/null || die "missing dependency: $dep"
done
[ -f "$helper" ] || die "helper missing: $helper"
[ -f "$data" ] || die "bench data helper missing: $data"
[ -f "$v1Script" ] || die "v1 script missing: $v1Script"
[ -x "$timeBin" ] || echo "ffds-v1-measure: $timeBin not installed -- time_* fields will be null" >&2

FFDS_BENCH_DIR=$(dirname "$data") python3 -c '
import sys; sys.dont_write_bytecode = True
import os; sys.path.insert(0, os.environ["FFDS_BENCH_DIR"])
from ffds_bench_data import valid_subpath
sys.exit(0 if valid_subpath(sys.argv[1]) else 1)' "$subpath" \
    || die "bad subpath: '$subpath'"

# ── identity, lock, quiet-window preflight ───────────────────────────────────
id="v1m$(date +%Y%m%d-%H%M%S)-$$"
outdir=${outdir:-/root/ffds-v1-measure-$id}
mkdir -p "$outdir/runs" "$outdir/v1log" || die "cannot create outdir $outdir"
: > "$outdir/run.log"

exec {lfd}>>"$lockFile" || die "cannot open $lockFile"
flock -n "$lfd" || die "another measurement holds $lockFile"

if pgrep -af "$syncPattern" | grep -vF "$id" | grep -v -- scope-worker \
        > "$outdir/preflight-sync.txt"; then
    [ "$force" = 1 ] || die "other sync processes running (see $outdir/preflight-sync.txt)"
fi
# v1 is started by cron; a scheduled run inside the window is only caught
# by the watcher once it starts -- keep the schedule with the results
{ crontab -l 2>/dev/null || true; } | grep -E 'sync_all|sync_ffds' \
    > "$outdir/preflight-cron.txt" || true
[ -s "$outdir/preflight-cron.txt" ] \
    && echo "ffds-v1-measure: cron schedules v1 -- make sure the window avoids it:" \
    && cat "$outdir/preflight-cron.txt"

# ── instrumented copy + scratch destination ──────────────────────────────────
dstRoot=$scratchBase/$id/DataSet
target=$dstRoot/$subpath
parent=$dstRoot
case $subpath in */*) parent=$dstRoot/${subpath%/*} ;; esac

copy=$outdir/sync_ffds-$id.sh
h instrument --src "$v1Script" --out "$copy" --diff "$outdir/v1-instrument.diff" \
    --src-root "$srcRoot" --dst-root "$dstRoot" --log-dir "$outdir/v1log" \
    --tag "$id" > "$outdir/instrument.json" \
    || die "refused to instrument $v1Script"
bash -n "$copy" || die "instrumented copy fails bash -n"
v1Sha=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["src_sha256"])' \
            "$outdir/instrument.json")
v1Log=$outdir/v1log/rsync-smb${subpath//\//_}.log

mkdir -p "$scratchBase" || die "cannot create $scratchBase"
guardArgs=(--scratch-base "$scratchBase" --expect-mount "$expectMount" --id "$id")
h init-scratch "${guardArgs[@]}" >/dev/null || die "init-scratch refused"

# ── source manifest + capacity ───────────────────────────────────────────────
log "measurement $id  subpath=$subpath reps=$reps scenarios=${scenarios[*]} cache=$cachePolicy"
log "v1: $v1Script sha256=$v1Sha -> $copy"
manifest=$outdir/source-manifest.json
python3 "$data" manifest --root "$srcRoot/$subpath" --out "$manifest" \
    > "$outdir/manifest-summary.json" || die "source manifest failed"
manifest_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$manifest" "$1"; }
srcFiles=$(manifest_field source_files_total)
srcBytes=$(manifest_field source_size_bytes)
manifestSha=$(manifest_field sha256)
[ "$srcFiles" -ge 1 ] || die "source subpath has no regular files"
log "source: files=$srcFiles bytes=$srcBytes sha=$manifestSha"

avail=$(df -B1 --output=avail "$scratchBase" | tail -n 1 | tr -d ' ')
need=$((srcBytes * 12 / 10))
[ "$avail" -gt "$need" ] || die "not enough space on $scratchBase: need $need, have $avail"

{
    echo "{"
    echo " \"id\": \"$id\", \"subpath\": \"$subpath\", \"reps\": $reps,"
    echo " \"scenarios\": \"${scenarios[*]}\", \"cache_policy\": \"$cachePolicy\","
    echo " \"incr_files\": $incrFiles, \"force\": $force,"
    echo " \"source_files\": $srcFiles, \"source_bytes\": $srcBytes,"
    echo " \"manifest_sha256\": \"$manifestSha\","
    echo " \"v1_script\": \"$v1Script\", \"v1_script_sha256\": \"$v1Sha\","
    echo " \"rsync_version\": \"$( { rsync --version 2>/dev/null || echo none; } | head -n 1)\","
    echo " \"time_bin\": \"$( [ -x "$timeBin" ] && echo "$timeBin" || echo none)\","
    echo " \"kernel\": \"$(uname -r)\", \"host\": \"$(hostname)\""
    echo "}"
} > "$outdir/meta.json"

# ── interference watcher (1s cadence for the whole measurement) ──────────────
interferenceLog=$outdir/interference.log
: > "$interferenceLog"
(
    exec {lfd}>&-   # must not inherit (and outlive) the lock
    while :; do
        pgrep -af "$syncPattern" 2>/dev/null \
            | grep -vF "$id" | grep -v -- scope-worker \
            >> "$interferenceLog" || true
        sleep 1
    done
) & watcherPid=$!
trap 'kill "$watcherPid" 2>/dev/null; wait "$watcherPid" 2>/dev/null' EXIT

halt() {
    log "HALT: $*"
    log "scratch preserved under $scratchBase/$id; results so far in $outdir"
    h csv --outdir "$outdir" >/dev/null 2>&1
    h summary --outdir "$outdir" >/dev/null 2>&1
    exit 1
}

verify_dst() {  # [--missing-list F]
    python3 "$data" verify-dst --manifest "$manifest" --root "$target" --mode 775 "$@"
}

scope_stopped() {  # <unit>
    local st
    st=$(systemctl is-active "$1" 2>/dev/null || true)
    [ "$st" != active ] && [ "$st" != activating ] && [ "$st" != deactivating ]
}

# run_scoped <runId>: the copy inside a transient scope via the bench
# scope-worker; sets runDir and scopedRc.  v1 truncates its single log on
# every invocation, so the log is filed with the run right after.
run_scoped() {
    local runId=$1 unit="ffds-v1m-$id-$1"
    runDir=$outdir/runs/$runId
    mkdir -p "$runDir"
    local rm=$runDir/run-manifest.json
    local argv=("$copy" "$subpath")
    [ -x "$timeBin" ] && argv=("$timeBin" -v -o "$runDir/time.txt" "${argv[@]}")
    python3 -c '
import json, os, sys
path, run_dir, argv = sys.argv[1], sys.argv[2], sys.argv[3:]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"argv": argv, "env": {}, "run_dir": run_dir}, f)' \
        "$rm" "$runDir" "${argv[@]}" || halt "cannot write $rm"

    systemd-run --scope --collect --quiet --unit="$unit" \
        python3 "$data" scope-worker --manifest "$rm" \
        > "$runDir/stdout.log" 2> "$runDir/stderr.log" & local spid=$!
    local waited=0
    while kill -0 "$spid" 2>/dev/null; do
        if [ "$waited" -ge "$runTimeout" ]; then
            log "run $runId exceeded --run-timeout=$runTimeout, killing scope $unit"
            systemctl kill --signal=TERM "$unit" 2>/dev/null
            sleep 15
            systemctl kill --signal=KILL "$unit" 2>/dev/null
            sleep 5
            break
        fi
        sleep 1; waited=$((waited + 1))
    done
    wait "$spid" 2>/dev/null; scopedRc=$?
    scope_stopped "$unit" \
        || halt "scope $unit still populated (D-state?) -- no cleanup, no further runs"
    if [ -f "$v1Log" ]; then mv -f "$v1Log" "$runDir/job.log"; else : > "$runDir/job.log"; fi
}

# destination complete and verified before warm/incr (prep, untimed)
ensure_ready() {  # <rep> <scenario>
    verify_dst > /dev/null 2>&1 && return 0
    log "prep: seeding destination (untimed)"
    h remove-target "${guardArgs[@]}" --subpath "$subpath" >/dev/null \
        || halt "remove-target refused"
    mkdir -p "$parent" || halt "cannot create $parent"
    run_scoped "r$1-$2-prep-seed"
    [ "$scopedRc" -eq 0 ] || halt "prep seed failed rc=$scopedRc"
    verify_dst > "$runDir/verify.json" 2>&1 \
        || halt "prep seed left an unverified destination (see $runDir/job.log)"
}

# ── measured run: snapshots -> scoped run -> verify -> assemble ──────────────
measured_run() {  # <scenario> <rep> <expect_transferred>
    local scenario=$1 rep=$2 expect=$3
    local runId="r${rep}-${scenario}"
    log "run $runId (expect transferred=$expect)"
    # production's parent directories always exist; rsync creates only
    # the last component (untimed)
    mkdir -p "$parent" || halt "cannot create $parent"

    sync
    local dropOk=null
    if [ "$cachePolicy" = drop ]; then
        if echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; then dropOk=1
        else log "drop_caches failed"; dropOk=0; fi
    fi
    mkdir -p "$outdir/runs/$runId"
    cat "$cifsStats" > "$outdir/runs/$runId/cifs.pre" 2>/dev/null \
        || : > "$outdir/runs/$runId/cifs.pre"
    local intPre; intPre=$(wc -l < "$interferenceLog")
    local startEpoch; startEpoch=$(date +%s.%N)

    run_scoped "$runId"

    local endEpoch; endEpoch=$(date +%s.%N)
    cat "$cifsStats" > "$runDir/cifs.post" 2>/dev/null || : > "$runDir/cifs.post"
    local intPost; intPost=$(wc -l < "$interferenceLog")
    local watcherOk=1
    kill -0 "$watcherPid" 2>/dev/null || watcherOk=0

    # untimed: destination + source verification
    local dstOk=0 srcOk=0
    verify_dst > "$runDir/verify.json" 2>&1 && dstOk=1
    local postSha
    postSha=$(python3 "$data" manifest --root "$srcRoot/$subpath" \
                  --out "$runDir/source-post.json" 2>/dev/null \
              | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])' \
              || echo none)
    [ "$postSha" = "$manifestSha" ] && srcOk=1

    local recOut
    recOut=$(h assemble --run-dir "$runDir" --manifest "$manifest" \
        --out "$runDir/result.json" --id "$id" --run-id "$runId" \
        --scenario "$scenario" --rep "$rep" --subpath "$subpath" \
        --script-exit "$scopedRc" --started "$startEpoch" --finished "$endEpoch" \
        --dst-ok "$dstOk" --src-ok "$srcOk" --drop-ok "$dropOk" \
        --cache-policy "$cachePolicy" --watcher-ok "$watcherOk" \
        --interference-delta $((intPost - intPre)) --forced "$force" \
        --expect-transferred "$expect" --v1-sha "$v1Sha") \
        || halt "assemble failed for $runId"
    log "recorded $runId: $recOut"
    runValid=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["valid"])' "$recOut")
    local failed
    failed=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["engine_failed"])' "$recOut")
    [ "$failed" = 0 ] \
        || halt "run $runId: v1 did not complete (see $runDir/job.log) -- stopping after saving it"
}

# ── measurement loop ─────────────────────────────────────────────────────────
anyInvalid=0
runValid=1
for rep in $(seq 1 "$reps"); do
    for scenario in "${scenarios[@]}"; do
        case $scenario in
            cold)
                h remove-target "${guardArgs[@]}" --subpath "$subpath" >/dev/null \
                    || halt "remove-target refused (cold)"
                measured_run cold "$rep" "$srcFiles"
                ;;
            warm)
                ensure_ready "$rep" "$scenario"
                measured_run warm "$rep" 0
                ;;
            incr)
                ensure_ready "$rep" "$scenario"
                # same seed rule as the bench: rep N removes the same files
                # a bench campaign's rep N removed (same manifest, same N)
                incrList=$outdir/incr-rep$rep.json
                python3 "$data" select-incr --manifest "$manifest" \
                    --n "$incrFiles" --seed "$rep" --out "$incrList" >/dev/null \
                    || halt "select-incr failed (N out of range?)"
                h remove-files "${guardArgs[@]}" --subpath "$subpath" \
                    --list "$incrList" >/dev/null || halt "remove-files refused"
                verify_dst --missing-list "$incrList" >/dev/null \
                    || halt "incr precondition check failed"
                measured_run incr "$rep" "$incrFiles"
                ;;
        esac
        [ "$runValid" = 1 ] || anyInvalid=1
    done
done

# ── wrap-up ──────────────────────────────────────────────────────────────────
h csv --outdir "$outdir" >/dev/null || log "csv failed"
h summary --outdir "$outdir" || log "summary failed"
cat "$outdir/SUMMARY.txt"

if [ "$keepDst" = 0 ] && [ "$anyInvalid" = 0 ]; then
    h remove-target "${guardArgs[@]}" --subpath "$subpath" >/dev/null \
        || log "cleanup: remove-target refused (left in place)"
    log "scratch dataset removed (id root + marker kept for the record)"
else
    log "scratch kept: keep-dst=$keepDst anyInvalid=$anyInvalid"
fi
log "done: $outdir (results.csv, SUMMARY.txt, runs/*/result.json)"
[ "$anyInvalid" = 0 ]
