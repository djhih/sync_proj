#!/bin/bash
#
# ffds-bench.sh -- v3(rsync) vs v4(rclone mount/smb) sync benchmark campaign
# Run manually as root on sync-host, OUTSIDE sync hours, in a quiet window
# (see ffds-bench.zh-tw.md, side-effect inventory B7 of the spec):
#   * cold copies put real read load on the SMB server and real write
#     load on WEKA; warm scans are a metadata storm on the server
#   * mount-backend traffic shares the kernel cifs session with every
#     /mnt/src-share and /mnt/other-share user -- "quiet" must include THEM
#   * drop_caches (default policy) is HOST-WIDE on sync-host
#   * v4-smb opens its own SMB sessions to the server
#
#   ffds-bench.sh -p <subpath> [-r reps] [-o outdir]
#                 [--engines v3,v4-mount,v4-smb] [--scenarios cold,warm,incr]
#                 [--incr-files N] [--no-drop-caches] [--keep-dst] [--force]
#                 [--run-timeout seconds]
#
# This script only orchestrates; everything with teeth lives in
# ffds_bench_data.py: path guards (component containment, campaign
# marker, expected mount -- the runner never composes an rm path),
# manifests, scenario verification, the in-scope measurement worker
# (internal mode: --scope-worker), result assembly/validation/publishing.
# Results: one immutable JSON per run under $resultsRoot (the :9760
# exporter reads those), a byte-identical copy + CSV/SUMMARY in <outdir>.
#
# Test hook: FFDS_BENCH_TEST_NONROOT=1 skips the root requirement and
# forces cache_policy=retain -- for the sandbox harness only.

set -u

# ── Fixed configuration -- edit in place (line-anchored for the harness) ─────
scratchBase=/mnt/dst-fs/ffds-bench
expectMount=/mnt/dst-fs
resultsRoot=/var/log/ffds-bench/results
liveLogRoot=/var/log/ffds-bench
benchLockFile=/run/lock/ffds-bench.lock
copyLockDir=/run/lock
copyMountpoints=(/mnt/src-share /mnt/dst-fs)
copyFileOwner=root:datasetgrp
srcRoot=/mnt/src-share/DataSet
smbRemote=nas:share1/DataSet
rcloneConfig=/etc/ffds-rclone.conf
cifsStats=/proc/fs/cifs/Stats
timerUnit=ffds-sync.timer
# ─────────────────────────────────────────────────────────────────────────────

here=$(cd "$(dirname "$0")" && pwd)
self=$(readlink -f "$0")
data=$here/ffds_bench_data.py
v3src=$here/../ffds-sync-v3.sh
v4src=$here/../ffds-sync-v4.sh

die() { echo "ffds-bench: $*" >&2; exit 1; }
log() { echo "[$(date '+%F %T')] $*" | tee -a "${outdir:-/dev/null}/run.log" >&2; }

# other sync work we must not overlap with; our own runs are excluded by
# the campaign id in their paths and the --scope-worker marker
syncPattern='sync_all\.sh|sync_ffds|ffds_sync(_v4)?\.sh (all|one)|rsync .*DataSet|rclone sync '

# internal mode: measured execution inside the transient scope
if [ "${1-}" = --scope-worker ]; then
    exec python3 "$data" scope-worker --manifest "${2-}"
fi

# ── argument parsing ─────────────────────────────────────────────────────────
subpath= reps=3 outdir=
engines=(v3 v4-mount v4-smb)
scenarios=(cold warm incr)
incrFiles=100
cachePolicy=drop
keepDst=0 force=0 runTimeout=7200
while [ $# -gt 0 ]; do
    case $1 in
        -p) subpath=${2-}; shift 2 ;;
        -r) reps=${2-}; shift 2 ;;
        -o) outdir=${2-}; shift 2 ;;
        --engines)   IFS=, read -r -a engines   <<< "${2-}"; shift 2 ;;
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
for e in "${engines[@]}"; do
    case $e in v3|v4-mount|v4-smb) ;; *) die "bad engine: $e" ;; esac
done
for s in "${scenarios[@]}"; do
    case $s in cold|warm|incr) ;; *) die "bad scenario: $s" ;; esac
done
[ "$(printf '%s\n' "${engines[@]}" | sort -u | wc -l)" = "${#engines[@]}" ] \
    || die "duplicate engines"
[ "$(printf '%s\n' "${scenarios[@]}" | sort -u | wc -l)" = "${#scenarios[@]}" ] \
    || die "duplicate scenarios"

testMode=${FFDS_BENCH_TEST_NONROOT:-0}
if [ "$testMode" != 1 ] && [ "$(id -u)" -ne 0 ]; then
    die "must run as root (or FFDS_BENCH_TEST_NONROOT=1 in the sandbox harness)"
fi
[ "$testMode" = 1 ] && cachePolicy=retain

# the runner's own -p validation, BEFORE anything is created
python3 -c '
import sys; sys.path.insert(0, "'"$here"'")
from ffds_bench_data import valid_subpath
sys.exit(0 if valid_subpath(sys.argv[1]) else 1)' "$subpath" \
    || die "bad subpath: '$subpath'"

for dep in python3 flock awk df stat; do
    command -v "$dep" >/dev/null || die "missing dependency: $dep"
done
for e in "${engines[@]}"; do
    case $e in
        v4-*) command -v rclone >/dev/null || die "rclone missing" ;;
        v3)   command -v rsync  >/dev/null || die "rsync missing (needed for v3)" ;;
    esac
done

# ── campaign identity, lock, quiet-window preflight ──────────────────────────
campaign="c$(date +%Y%m%d-%H%M%S)-$$"
outdir=${outdir:-/root/ffds-bench-$campaign}
mkdir -p "$outdir/scripts" "$outdir/runs" "$outdir/completed-results" \
    || die "cannot create outdir $outdir"
: > "$outdir/run.log"

exec {blfd}>>"$benchLockFile" || die "cannot open $benchLockFile"
flock -n "$blfd" || die "another campaign holds $benchLockFile"

timerState=$(systemctl is-active "$timerUnit" 2>/dev/null || true)
if [ "$timerState" = active ] && [ "$force" != 1 ]; then
    die "$timerUnit is active -- stop it for the campaign (or --force, results forced/invalid)"
fi
if pgrep -af "$syncPattern" | grep -vF "$campaign" | grep -v -- --scope-worker \
        > "$outdir/preflight-sync.txt"; then
    [ "$force" = 1 ] || die "other sync processes running (see $outdir/preflight-sync.txt)"
fi

# ── campaign root + per-engine script copies ─────────────────────────────────
mkdir -p "$scratchBase" || die "cannot create $scratchBase"
python3 "$data" init-campaign --scratch-base "$scratchBase" \
    --expect-mount "$expectMount" --campaign "$campaign" >/dev/null \
    || die "init-campaign refused"

make_engine_copy() {  # <engine>
    local engine=$1 src dstRootE logDirE out key
    case $engine in
        v3) src=$v3src ;;
        v4-mount|v4-smb) src=$v4src ;;
    esac
    [ -f "$src" ] || die "engine source missing: $src"
    dstRootE=$scratchBase/$campaign/$engine/DataSet
    logDirE=$liveLogRoot/$engine
    out=$outdir/scripts/$engine.sh
    sed -e "s|^srcRoot=.*|srcRoot=$srcRoot|" \
        -e "s|^dstRoot=.*|dstRoot=$dstRootE|" \
        -e "s|^mountpoints=.*|mountpoints=(${copyMountpoints[*]})|" \
        -e "s|^logDir=.*|logDir=$logDirE|" \
        -e "s|^lockDir=.*|lockDir=$copyLockDir|" \
        -e "s|^fileOwner=.*|fileOwner=$copyFileOwner|" \
        -e "s|^rcloneConfig=.*|rcloneConfig=$rcloneConfig|" \
        -e "s|^smbRemote=.*|smbRemote=$smbRemote|" \
        "$src" > "$out"
    chmod +x "$out"
    for key in srcRoot dstRoot logDir lockDir; do
        [ "$(grep -c "^$key=" "$out")" = 1 ] || die "$engine copy: $key not unique"
    done
    [ "$(grep "^dstRoot=" "$out")" = "dstRoot=$dstRootE" ] \
        || die "$engine copy: dstRoot mismatch"
    mkdir -p "$logDirE" || die "cannot create $logDirE"
    # production dstRoot pre-exists on WEKA; the per-engine scratch root
    # must too (the sync scripts refuse a missing dataset root)
    mkdir -p "$dstRootE" || die "cannot create $dstRootE"
}
for e in "${engines[@]}"; do make_engine_copy "$e"; done

# ── source manifest + capacity ───────────────────────────────────────────────
log "campaign $campaign  subpath=$subpath reps=$reps engines=${engines[*]} scenarios=${scenarios[*]} cache=$cachePolicy"
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
need=$((srcBytes * ${#engines[@]} * 12 / 10))
[ "$avail" -gt "$need" ] || die "not enough space on $scratchBase: need $need, have $avail"

{
    echo "{"
    echo " \"campaign\": \"$campaign\", \"subpath\": \"$subpath\","
    echo " \"reps\": $reps, \"engines\": \"${engines[*]}\","
    echo " \"scenarios\": \"${scenarios[*]}\", \"cache_policy\": \"$cachePolicy\","
    echo " \"incr_files\": $incrFiles, \"force\": $force,"
    echo " \"source_files\": $srcFiles, \"source_bytes\": $srcBytes,"
    echo " \"manifest_sha256\": \"$manifestSha\","
    echo " \"rclone_version\": \"$( { rclone version 2>/dev/null || echo none; } | head -n 1)\","
    echo " \"rsync_version\": \"$( { rsync --version 2>/dev/null || echo none; } | head -n 1)\","
    echo " \"kernel\": \"$(uname -r)\", \"host\": \"$(hostname)\""
    echo "}"
} > "$outdir/meta.json"

# ── interference watcher (1s cadence for the whole campaign) ─────────────────
interferenceLog=$outdir/interference.log
: > "$interferenceLog"
(
    exec {blfd}>&-   # children must not inherit (and outlive) the campaign lock
    while :; do
        pgrep -af "$syncPattern" 2>/dev/null \
            | grep -vF "$campaign" | grep -v -- --scope-worker \
            >> "$interferenceLog" || true
        sleep 1
    done
) & watcherPid=$!
trap 'kill "$watcherPid" 2>/dev/null; wait "$watcherPid" 2>/dev/null' EXIT

halt() {  # preserve everything, stop the campaign
    log "HALT: $*"
    log "scratch preserved under $scratchBase/$campaign; results so far under $resultsRoot/$campaign"
    exit 1
}

# ── helpers ──────────────────────────────────────────────────────────────────
guarded() {  # <subcommand> <engine> [extra args...]
    local cmd=$1 engine=$2; shift 2
    python3 "$data" "$cmd" --scratch-base "$scratchBase" \
        --expect-mount "$expectMount" --campaign "$campaign" \
        --engine "$engine" --subpath "$subpath" "$@"
}

scope_stopped() {  # <unit>
    local st
    st=$(systemctl is-active "$1" 2>/dev/null || true)
    [ "$st" != active ] && [ "$st" != activating ] && [ "$st" != deactivating ]
}

events_offset() {  # <engine>
    local f=$liveLogRoot/$1/events.log
    if [ -f "$f" ]; then wc -l < "$f"; else echo 0; fi
}

verify_dst() {  # <engine> [--missing-list F]
    local engine=$1; shift
    local target
    target=$(guarded guard-target "$engine") || return 2
    python3 "$data" verify-dst --manifest "$manifest" --root "$target" \
        --mode 775 "$@"
}

# run_scoped <engine> <action> <runId>: execute `<copy> one <subpath>`
# inside a transient scope via the scope-worker; sets scopedRc.  The
# parent stays free to watch the deadline; a scope that will not empty
# (D-state) halts the whole campaign with the scratch preserved.
run_scoped() {
    local engine=$1 action=$2 runId=$3
    runDir=$outdir/runs/$runId
    mkdir -p "$runDir"
    local unit="ffds-bench-$campaign-$runId"
    local rm=$runDir/run-manifest.json
    local backendEnv=""
    case $engine in
        v4-mount) backendEnv=mount ;;
        v4-smb)   backendEnv=smb ;;
    esac
    python3 -c '
import json, os, sys
rm, script, sub, run_dir, backend = sys.argv[1:6]
env = {"FFDS_V4_BACKEND": backend} if backend else {}
with open(rm, "w") as f:
    json.dump({"argv": [script, "one", sub], "env": env, "run_dir": run_dir}, f)
os.chmod(rm, 0o600)' \
        "$rm" "$outdir/scripts/$engine.sh" "$subpath" "$runDir" "$backendEnv"

    systemd-run --scope --collect --quiet --unit="$unit" \
        "$self" --scope-worker "$rm" \
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
    if ! scope_stopped "$unit"; then
        halt "scope $unit still populated (D-state?) -- no cleanup, no further runs"
    fi
    echo "$action rc=$scopedRc" >> "$runDir/actions.log"
}

# ensure the destination is complete and verified (prep, untimed)
ensure_ready() {  # <engine> <rep>
    local engine=$1 rep=$2
    if verify_dst "$engine" > /dev/null 2>&1; then
        return 0
    fi
    log "prep: seeding $engine destination (untimed)"
    guarded safe-remove "$engine" >/dev/null || halt "safe-remove refused"
    run_scoped "$engine" prep "r${rep}-${engine}-prep-seed"
    [ "$scopedRc" -eq 0 ] || halt "prep seed for $engine failed rc=$scopedRc"
    local off; off=$(events_offset "$engine")
    run_scoped "$engine" verify "r${rep}-${engine}-prep-verify"
    [ "$scopedRc" -eq 0 ] || halt "prep no-change check for $engine failed rc=$scopedRc"
    local xfr
    xfr=$(python3 "$data" extract-events --events "$liveLogRoot/$engine/events.log" \
              --offset "$off" --subpath "$subpath" \
          | python3 -c 'import json,sys
s = json.load(sys.stdin).get("stats") or {}
print(s.get("transferred", "?"))') || halt "prep events unreadable"
    [ "$xfr" = 0 ] || halt "prep no-change check transferred=$xfr (want 0) for $engine"
    verify_dst "$engine" >/dev/null || halt "prep verify-dst failed for $engine"
}

# ── measured run: snapshots -> scoped run -> verify -> assemble -> record ────
measured_run() {  # <engine> <scenario> <rep> <expect_transferred>
    local engine=$1 scenario=$2 rep=$3 expect=$4
    local runId="r${rep}-${engine}-${scenario}"
    log "run $runId (expect transferred=$expect)"

    sync
    local dropOk=null
    if [ "$cachePolicy" = drop ]; then
        if echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; then dropOk=1
        else log "drop_caches failed"; dropOk=0; fi
    fi
    mkdir -p "$outdir/runs/$runId"
    local cifsPre=$outdir/runs/$runId/cifs.pre cifsPost=$outdir/runs/$runId/cifs.post
    cat "$cifsStats" > "$cifsPre" 2>/dev/null || : > "$cifsPre"
    local off; off=$(events_offset "$engine")
    local intPre; intPre=$(wc -l < "$interferenceLog")
    local startEpoch; startEpoch=$(date +%s.%N)

    run_scoped "$engine" measure "$runId"

    local endEpoch; endEpoch=$(date +%s.%N)
    cat "$cifsStats" > "$cifsPost" 2>/dev/null || : > "$cifsPost"
    local intPost; intPost=$(wc -l < "$interferenceLog")
    local watcherOk=1
    kill -0 "$watcherPid" 2>/dev/null || watcherOk=0

    # untimed: events, destination + source verification
    python3 "$data" extract-events --events "$liveLogRoot/$engine/events.log" \
        --offset "$off" --subpath "$subpath" > "$runDir/events.json" \
        2>>"$outdir/run.log" || echo '{}' > "$runDir/events.json"
    local dstOk=0 srcOk=0
    if verify_dst "$engine" > "$runDir/verify.json" 2>&1; then dstOk=1; fi
    local postSha
    postSha=$(python3 "$data" manifest --root "$srcRoot/$subpath" \
                  --out "$runDir/source-post.json" 2>/dev/null \
              | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])' \
              || echo none)
    [ "$postSha" = "$manifestSha" ] && srcOk=1

    python3 "$data" assemble --run-dir "$runDir" --manifest "$manifest" \
        --out "$runDir/result-input.json" \
        --campaign "$campaign" --run-id "$runId" --engine "$engine" \
        --scenario "$scenario" --rep "$rep" --subpath "$subpath" \
        --script-exit "$scopedRc" --started "$startEpoch" --finished "$endEpoch" \
        --dst-ok "$dstOk" --src-ok "$srcOk" --drop-ok "$dropOk" \
        --cache-policy "$cachePolicy" --watcher-ok "$watcherOk" \
        --interference-delta $((intPost - intPre)) --forced "$force" \
        --cifs-pre "$cifsPre" --cifs-post "$cifsPost" \
        || halt "assemble failed for $runId"

    local recOut
    if ! recOut=$(python3 "$data" record \
            --input "$runDir/result-input.json" \
            --results-root "$resultsRoot" \
            --outdir-copy "$outdir/completed-results" \
            --expect-transferred "$expect" 2>&1); then
        halt "record refused for $runId: $recOut"
    fi
    log "recorded $runId: $recOut"
    runValid=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["valid"])' "$recOut")
    if [ "$scopedRc" -ne 0 ]; then
        halt "run $runId exited $scopedRc -- stopping after saving the failure"
    fi
}

# ── campaign loop ────────────────────────────────────────────────────────────
anyInvalid=0
runValid=1
for rep in $(seq 1 "$reps"); do
    incrList=
    for s in "${scenarios[@]}"; do
        if [ "$s" = incr ]; then
            incrList=$outdir/incr-rep$rep.json
            python3 "$data" select-incr --manifest "$manifest" \
                --n "$incrFiles" --seed "$rep" --out "$incrList" >/dev/null \
                || die "select-incr failed (N out of range?)"
        fi
    done
    mapfile -t order < <(python3 -c '
import random, sys
e = sys.argv[2:]
random.Random(int(sys.argv[1])).shuffle(e)
print("\n".join(e))' "$rep" "${engines[@]}")
    log "rep $rep engine order (seed=$rep): ${order[*]}"
    for engine in "${order[@]}"; do
        for scenario in "${scenarios[@]}"; do
            case $scenario in
                cold)
                    guarded safe-remove "$engine" >/dev/null \
                        || halt "safe-remove refused (cold)"
                    measured_run "$engine" cold "$rep" "$srcFiles"
                    ;;
                warm)
                    ensure_ready "$engine" "$rep"
                    measured_run "$engine" warm "$rep" 0
                    ;;
                incr)
                    ensure_ready "$engine" "$rep"
                    guarded remove-files "$engine" --list "$incrList" >/dev/null \
                        || halt "remove-files refused"
                    verify_dst "$engine" --missing-list "$incrList" >/dev/null \
                        || halt "incr precondition check failed for $engine"
                    measured_run "$engine" incr "$rep" "$incrFiles"
                    ;;
            esac
            [ "$runValid" = 1 ] || anyInvalid=1
        done
    done
done

# ── wrap-up ──────────────────────────────────────────────────────────────────
python3 "$data" csv --results-root "$resultsRoot" --campaign "$campaign" \
    --out "$outdir/results.csv" >/dev/null || log "csv rebuild failed"
python3 "$data" summary --results-root "$resultsRoot" --campaign "$campaign" \
    --out "$outdir/SUMMARY.txt" || log "summary failed"
cat "$outdir/SUMMARY.txt"

if [ "$keepDst" = 0 ] && [ "$anyInvalid" = 0 ]; then
    for engine in "${engines[@]}"; do
        guarded safe-remove "$engine" >/dev/null \
            || log "cleanup: safe-remove refused for $engine (left in place)"
    done
    log "scratch datasets removed (campaign root + marker kept for the record)"
else
    log "scratch kept: keep-dst=$keepDst anyInvalid=$anyInvalid"
fi
log "done: results $resultsRoot/$campaign, portable copy + CSV/SUMMARY in $outdir"
[ "$anyInvalid" = 0 ]
