#!/bin/bash
#
# ffds_sync_v4.sh -- sync [SMB] source NAS share to [WEKA] DataSet
#                    with rclone instead of rsync (experimental sibling of v3)
# Deploy target: sync-host:/usr/local/ffds/ffds_sync_v4.sh  (NOT a replacement for
#                v3 until the bench campaign says so -- see ffds-sync-v4.zh-tw.md)
# Requires: bash >= 4.4, rclone (version pinned by fixtures, see test/fixtures/
#           rclone/), python3 >= 3.7, GNU coreutils, GNU findutils, util-linux
#           flock, /proc (uptime, mounts)
#
#   ffds_sync_v4.sh all              sync every subpath in /etc/sync_paths.conf
#   ffds_sync_v4.sh one <subpath>    sync a single subpath
#   ffds_sync_v4.sh [status]         show running jobs and last progress
#
# Same CLI and the same events.log contract as v3 (one logfmt event per
# line, O_APPEND, values never contain spaces). The monitor
# (sync_monitor/ffds_sync_monitor.py) consumes it unchanged. The SEVEN
# event names are the same; v4 differs only in fields:
#
#   job_progress  bytes= (plain integer)  pct= (integer, omitted when the
#                 total is unknown)  speed= (plain integer B/s)
#                 eta=H:MM:SS (omitted when rclone reports null)
#                 xfr= (files transferred so far).  chk= is NOT emitted:
#                 rclone's totalChecks counts work items, not the file
#                 enumeration total rsync reports, and a wrong total is
#                 worse than none.
#   job_stats     transferred= (files copied)  plus rclone-native extras
#                 checks= total_checks= transfers_total= transfer_bytes=
#                 transfer_bytes_total= deletes= deleted_dirs= errors=
#                 (the monitor ignores unknown keys).  files= size=
#                 created= listgen= speedup= are NOT emitted -- rclone has
#                 no equivalent numbers and absent is honest.
#   job_end       exit= duration= (fractional seconds, monotonic) plus
#                 dry_run= rclone_exit= filter_exit= fixup_exit=
#                 preflight_s= engine_s= fixup= ; on a handled signal also
#                 aborted=1 termination_signal=<n>.
#
# Backends (FFDS_V4_BACKEND):
#   mount  read /mnt/src-share via the kernel cifs mount (engine-only A/B vs v3)
#   smb    rclone's native SMB backend: its own connections to the server,
#          bypassing the kernel mount entirely.  Credentials live in
#          $rcloneConfig (root:root 0600); every rclone invocation goes
#          through rclone_cmd, which scrubs inherited RCLONE_* variables
#          and pins RCLONE_CONFIG, so ambient environment cannot silently
#          change what a sync does.
#
# Ownership/mode: rclone cannot enforce --chown/--chmod, so after the
# engine a single find pass (GNU find ',' operator: one tree walk, two
# actions) fixes ONLY entries whose owner/group or mode is wrong.  Its
# duration is reported as fixup= on job_end; until fixup completes, newly
# written files are NOT guaranteed to carry the final owner/mode.
#
# Deletion: 'rclone sync --delete-during' matches rsync --delete (>= 3.0
# default).  FFDS_V4_MAX_DELETE adds --max-delete; its exit code is
# whatever the pinned rclone version uses -- do not hardcode one.
#
# Exit codes:
#   0      sync + fixup + telemetry all succeeded (dry_run=1 on a dry run)
#   1..    rclone's own exit code, verbatim (do not assume it stops at 9;
#          see https://rclone.org/docs/#exit-code for the pinned version)
#   90     bad usage/subpath/knobs, unsafe destination ancestor,
#          log, lock or state dir unwritable
#   91     source or destination unavailable (mount missing, smb source
#          preflight failed, destination on an unexpected device)
#   92     lock busy (same subpath already syncing / batch already running)
#   93     config missing, empty, or invalid (duplicates, mangle
#          collisions, parent/child overlaps -- rejected before spawning)
#   94     batch aborted by signal
#   95     rclone succeeded but the required fixup pass failed
#   96     rclone succeeded but telemetry failed (filter error, missing or
#          invalid final stats, or an event/log write failure)
#   130/143  'one' interrupted by INT/TERM (128+signal); job_end carries
#          aborted=1 termination_signal=
#
# Process model ('one'): the public process is only a coordinator; the
# rclone|filter pipeline and the fixup run inside an internal __worker
# started with setsid, i.e. in its OWN process group.  The coordinator
# saves the worker's PGID (read back from ps, not assumed), waits
# interruptibly, and on INT/TERM kills the whole group, waits for it, and
# only then emits the single job_end.  The worker never uses its own $$
# for event identity: the coordinator's PID is the one run= id.
#
# Watch one job live:
#   tail -f /var/log/ffds-sync-v4/jobs/<subpath, / replaced by _>.log
#   tail -f /var/log/ffds-sync-v4/events.log
# Raw rclone JSON per run: /var/log/ffds-sync-v4/raw/<mangled>.<run>.jsonl

set -u

# ── Fixed configuration -- edit in place ─────────────────────────────────────
srcRoot=/mnt/src-share/DataSet
dstRoot=/mnt/dst-fs/DataSet
mountpoints=(/mnt/src-share /mnt/dst-fs)
logDir=/var/log/ffds-sync-v4
config=/etc/sync_paths.conf
lockDir=/run/lock
fileOwner=root:datasetgrp
fileMode=775
rcloneConfig=/etc/ffds-rclone.conf
smbRemote=nas:share1/DataSet
# ─────────────────────────────────────────────────────────────────────────────

# ── Env knobs ────────────────────────────────────────────────────────────────
backend=${FFDS_V4_BACKEND:-mount}
transfers=${FFDS_V4_TRANSFERS:-4}
checkers=${FFDS_V4_CHECKERS:-8}
mtStreams=${FFDS_V4_MULTI_THREAD_STREAMS:-4}
rcloneTimeout=${FFDS_V4_TIMEOUT:-1800}
jobs=${FFDS_SYNC_JOBS:-1}
statsEvery=${FFDS_PROGRESS_EVERY:-15}

# Numeric knobs: non-numeric (or a zero that would break the knob) falls
# back to the default; then normalize through base-10 so "08"/"00012" can
# never be read as octal downstream.
case $transfers     in ''|*[!0-9]*|0) transfers=4 ;;     esac
case $checkers      in ''|*[!0-9]*|0) checkers=8 ;;      esac
case $mtStreams     in ''|*[!0-9]*)   mtStreams=4 ;;     esac
case $rcloneTimeout in ''|*[!0-9]*)   rcloneTimeout=1800 ;; esac
case $jobs          in ''|*[!0-9]*|0) jobs=1 ;;          esac
case $statsEvery    in ''|*[!0-9]*|0) statsEvery=15 ;;   esac
transfers=$((10#$transfers)); checkers=$((10#$checkers))
mtStreams=$((10#$mtStreams)); rcloneTimeout=$((10#$rcloneTimeout))
jobs=$((10#$jobs)); statsEvery=$((10#$statsEvery))

eventLog=$logDir/events.log
jobLogDir=$logDir/jobs
rawLogDir=$logDir/raw
self=$(readlink -f "$0")
ownerName=${fileOwner%%:*}
groupName=${fileOwner##*:}

usage_die() { echo "$*" >&2; exit 90; }

# Operation-changing knobs are rejected loudly, never silently defaulted.
dryRunFlag=${FFDS_V4_DRY_RUN:-0}
bwLimit=${FFDS_V4_BWLIMIT:-}
maxDelete=${FFDS_V4_MAX_DELETE:-}
case $backend in mount|smb) ;; *)
    usage_die "FFDS_V4_BACKEND='$backend' (want mount|smb)" ;; esac
case $dryRunFlag in 0|1) ;; *)
    usage_die "FFDS_V4_DRY_RUN='$dryRunFlag' (want 0|1)" ;; esac
case $bwLimit in *[!A-Za-z0-9.,:]*)
    usage_die "FFDS_V4_BWLIMIT='$bwLimit' (bad character)" ;; esac
case $maxDelete in *[!0-9]*)
    usage_die "FFDS_V4_MAX_DELETE='$maxDelete' (want an integer)" ;; esac
dryRunBool=false; [ "$dryRunFlag" = 1 ] && dryRunBool=true
optionFlags=()
[ -n "$bwLimit" ]   && optionFlags+=(--bwlimit "$bwLimit")
[ -n "$maxDelete" ] && optionFlags+=(--max-delete "$maxDelete")

# smb mode: the source is not a mountpoint -- drop the first (source)
# entry from the preflight list; the destination mount(s) stay checked
# and the source gets an rclone lsd preflight instead.
if [ "$backend" = smb ]; then
    mountpoints=("${mountpoints[@]:1}")
fi

# ── Shared helpers (emit/valid_subpath/mounts_ok follow v3, emit checked) ────

now_mono() { local up _; read -r up _ < /proc/uptime; echo "$up"; }
mono_diff() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", a - b }'; }

emit() {  # emit <event> [key=value ...] ; returns 1 when the write failed
    local line
    line="$(date '+ts=%s time=%FT%T%z') event=$*"
    if ! echo "$line" >> "$eventLog"; then
        echo "cannot append to $eventLog" >&2
        return 1
    fi
    if [ -n "${JOURNAL_STREAM:-}" ]; then
        echo "$line"
    fi
    return 0
}

valid_subpath() {
    case "${1-}" in
        ''|/*|*/) return 1 ;;             # empty, absolute, trailing slash
        ..|../*|*/..|*/../*) return 1 ;;  # path traversal
        .|./*|*/.|*/./*) return 1 ;;      # '.' would sync the whole root
        *//*) return 1 ;;                 # doubled slash / empty component
        *[[:space:]]*) return 1 ;;        # event log values are space-free
        *\\*) return 1 ;;                 # backslash
    esac
    return 0
}

mounts_ok() {
    local mp present
    missingMount=
    for mp in "${mountpoints[@]}"; do
        present=0
        while read -r _ mnt _; do
            [ "$mnt" = "$mp" ] && { present=1; break; }
        done < /proc/mounts
        if [ "$present" -eq 0 ]; then
            echo "mount $mp is missing" >&2
            missingMount=$mp
            return 1
        fi
    done
    return 0
}

# Every rclone invocation goes through here: inherited RCLONE_* is
# scrubbed, the pinned config is the only rclone environment that
# survives.  Never put credentials on the command line.
rclone_cmd() {
    local scrub=() name
    while IFS= read -r name; do
        scrub+=(-u "$name")
    done < <(env | sed -n 's/^\(RCLONE_[A-Za-z0-9_]*\)=.*/\1/p')
    env ${scrub[@]+"${scrub[@]}"} RCLONE_CONFIG="$rcloneConfig" rclone "$@"
}

# atomic_write <file>: stdin -> <file> via tmp+rename in the same dir
atomic_write() {
    local tmp
    tmp=$1.tmp.$BASHPID
    cat > "$tmp" && mv -f "$tmp" "$1"
}

# ── Destination safety (B1.4 #3) ─────────────────────────────────────────────
# Walk every existing component from dstRoot down to the target: no
# symlinks, and everything stays on dstRoot's device (a nested mount under
# the dataset would silently swallow the sync).  May touch the filesystem
# -- a hung WEKA can block here; the scope/timeout above us is the backstop.
dst_safe() {
    local sub=$1 base dev cur part rc=0
    if [ ! -d "$dstRoot" ] || [ -L "$dstRoot" ]; then
        echo "dstRoot $dstRoot missing or a symlink" >&2
        return 91
    fi
    dev=$(stat -c %d "$dstRoot") || return 91
    cur=$dstRoot
    local IFS=/
    for part in $sub; do
        cur=$cur/$part
        [ -e "$cur" ] || break
        if [ -L "$cur" ]; then
            echo "refusing to sync through symlink $cur" >&2
            return 90
        fi
        if [ "$(stat -c %d "$cur" 2>/dev/null)" != "$dev" ]; then
            echo "unexpected mount boundary at $cur" >&2
            return 91
        fi
    done
    return $rc
}

# ── The rclone JSON -> events filter ─────────────────────────────────────────
# argv: <subpath> <runId> <eventLog> <rawJsonl> <stateDir>
# stdin:  rclone --use-json-log output (one JSON object per line)
# stdout: the human job log (INFO operations, errors, readable progress)
# side effects: job_progress events appended to the event log; the final
#   stats payload written to <stateDir>/stats_payload -- job_stats
#   itself is emitted by the worker only after PIPESTATUS is known.
# exit: 0 all input handled; 3 telemetry errors (bad JSON / bad stats
#   schema, originals preserved); 4 write failure.  Never stops draining.
filterSrc='
import json, math, os, sys, time

sub, run_id, event_log, raw_path, state_dir = sys.argv[1:6]

REQUIRED = ("bytes", "totalBytes", "speed", "transfers", "totalTransfers",
            "checks", "totalChecks", "deletes", "errors")

def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) \
        and math.isfinite(v) and v >= 0

def stamp():
    t = time.localtime()
    off = time.strftime("%z", t)
    return "ts=%d time=%s%s" % (int(time.time()),
                                time.strftime("%Y-%m-%dT%H:%M:%S", t), off)

def human_bytes(n):
    for unit in ("B", "KB", "MB", "GB", "TB", "PB"):
        if abs(n) < 1000:
            return "%.2f%s" % (n, unit)
        n /= 1000.0
    return "%.2fEB" % n

def eta_hms(secs):
    secs = int(secs)
    return "%d:%02d:%02d" % (secs // 3600, (secs % 3600) // 60, secs % 60)

errors = 0
write_failed = False
candidate = None            # last stats object seen, verbatim

def out(line):
    global write_failed
    try:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()
    except OSError:
        write_failed = True

def event(payload):
    global write_failed
    line = stamp() + " event=" + payload + "\n"
    try:
        with open(event_log, "a") as f:
            f.write(line)
    except OSError:
        write_failed = True

raw = None
try:
    raw = open(raw_path, "a")
except OSError:
    write_failed = True

for line in sys.stdin:
    line = line.rstrip("\n")
    if raw:
        try:
            raw.write(line + "\n"); raw.flush()
        except OSError:
            write_failed = True
    try:
        obj = json.loads(line)
        if not isinstance(obj, dict):
            raise ValueError("not an object")
    except ValueError:
        # with --use-json-log everything should be JSON; keep the original
        # visible and count it -- passthrough is not telemetry success
        out(line)
        errors += 1
        continue
    stats = obj.get("stats")
    if not isinstance(stats, dict):
        msg = str(obj.get("msg", "")).replace("\n", " ")
        objname = obj.get("object")
        out("%s: %s" % (msg, objname) if objname else msg)
        continue
    # periodic (or final) stats object
    candidate = stats
    fields = []
    ok_line = True
    b = stats.get("bytes")
    if is_num(b):
        fields.append("bytes=%d" % int(b))
    else:
        ok_line = False
    tb = stats.get("totalBytes")
    pct = None
    if is_num(b) and is_num(tb) and tb > 0:
        p = 100.0 * b / tb
        if 0 <= p <= 100:
            pct = int(p)          # transient estimate out of range: omit
    if pct is not None:
        fields.append("pct=%d" % pct)
    sp = stats.get("speed")
    if is_num(sp):
        fields.append("speed=%d" % int(sp))
    eta = stats.get("eta")
    if is_num(eta):
        fields.append("eta=" + eta_hms(eta))
    xfr = stats.get("transfers")
    if is_num(xfr):
        fields.append("xfr=%d" % int(xfr))
    if not ok_line:
        errors += 1
    if fields:
        event("job_progress subpath=%s run=%s %s" % (sub, run_id, " ".join(fields)))
        human = "%12s %4s %12s/s eta %s (xfr#%s)" % (
            human_bytes(b) if is_num(b) else "?",
            ("%d%%" % pct) if pct is not None else "?",
            human_bytes(sp) if is_num(sp) else "?",
            eta_hms(eta) if is_num(eta) else "-:--:--",
            int(xfr) if is_num(xfr) else "?")
        out(human.strip() and "  " + " ".join(human.split()) or human)

if raw:
    try:
        raw.close()
    except OSError:
        write_failed = True

# Validate ONLY the last candidate: a corrupted final must not fall back
# to an earlier periodic snapshot.  The result is one job_stats payload
# line in <state_dir>/stats_payload -- empty when there is no acceptable
# final -- which the worker turns into the event once PIPESTATUS is known.
payload = ""
if candidate is None:
    out("final stats rejected: no stats object seen")
else:
    missing = [k for k in REQUIRED if not is_num(candidate.get(k))]
    if missing:
        out("final stats rejected: bad/missing " + ",".join(missing))
    else:
        kv = [("transferred", "transfers"), ("checks", "checks"),
              ("total_checks", "totalChecks"), ("transfers_total", "totalTransfers"),
              ("transfer_bytes", "bytes"), ("transfer_bytes_total", "totalBytes"),
              ("deletes", "deletes"), ("errors", "errors")]
        parts = ["%s=%d" % (name, int(candidate[key])) for name, key in kv]
        dd = candidate.get("deletedDirs")
        if is_num(dd):
            parts.insert(len(parts) - 1, "deleted_dirs=%d" % int(dd))
        payload = " ".join(parts)
try:
    tmp = os.path.join(state_dir, "stats_payload.tmp")
    with open(tmp, "w") as f:
        f.write(payload)
    os.replace(tmp, os.path.join(state_dir, "stats_payload"))
except OSError:
    write_failed = True

sys.exit(4 if write_failed else (3 if errors else 0))
'

filter_rclone() {  # <subpath> <runId> <rawJsonl> <stateDir>
    python3 -u -c "$filterSrc" "$1" "$2" "$eventLog" "$3" "$4"
}

# ── Internal worker (own process group; started via setsid) ──────────────────
# argv: __worker <stateDir>.  Everything else comes from files inside the
# state dir, written by the coordinator: no arbitrary argv reaches the
# part of the program that runs the engine and the fixup.
cmd_worker() {
    local stateDir=$1
    # The state dir must be ours and private (a fresh mktemp -d from the
    # coordinator) -- a wrong or planted directory is refused.
    if [ ! -d "$stateDir" ] || [ ! -O "$stateDir" ]; then
        echo "__worker: state dir invalid" >&2; exit 90
    fi
    local mode; mode=$(stat -c %a "$stateDir") || exit 90
    [ "$mode" = 700 ] || { echo "__worker: state dir mode $mode != 700" >&2; exit 90; }
    [ -f "$stateDir/params" ] || { echo "__worker: params missing" >&2; exit 90; }

    # v3 contract: job_progress/job_stats are log-only -- never mirrored
    # to the journal even when systemd set the variable.
    unset JOURNAL_STREAM

    # own PGID first thing, read back from ps rather than assumed -- the
    # coordinator kills this group, so it must learn the id from us, not
    # from guessing what setsid did.
    ps -o pgid= -p $$ | tr -d ' ' | atomic_write "$stateDir/pgid"

    # shellcheck disable=SC1091
    . "$stateDir/params"   # sub runId logFile rawLog dstTarget doFixup
    local args=()
    mapfile -d '' args < "$stateDir/argv"

    # One consolidated, shell-sourceable state file for the coordinator;
    # written after the pipeline and again after the fixup so a worker
    # killed mid-fixup still leaves the engine phase behind.
    local rcloneExit filterExit engineS fixupExit=skipped fixupS=0 finalRc=
    save_state() {
        printf 'rcloneExit=%s\nfilterExit=%s\nengineS=%s\nfixupExit=%s\nfixupS=%s\nfinalRc=%s\n' \
            "$rcloneExit" "$filterExit" "$engineS" "$fixupExit" "$fixupS" "$finalRc" \
            | atomic_write "$stateDir/state"
    }

    local t0 t1
    t0=$(now_mono)
    rclone_cmd "${args[@]}" 2>&1 \
        | filter_rclone "$sub" "$runId" "$rawLog" "$stateDir" >> "$logFile"
    local pipelineStatus=("${PIPESTATUS[@]}")
    t1=$(now_mono)
    rcloneExit=${pipelineStatus[0]}
    filterExit=${pipelineStatus[1]}
    engineS=$(mono_diff "$t1" "$t0")
    save_state

    # job_stats: only once the engine's fate is known, only from the
    # filter's validated payload, and only for a normal rclone exit.
    local statsOk=0 payload=""
    [ -f "$stateDir/stats_payload" ] && payload=$(cat "$stateDir/stats_payload")
    if [ "$rcloneExit" = 0 ] && [ "$filterExit" = 0 ] && [ -n "$payload" ]; then
        if emit "job_stats subpath=$sub run=$runId $payload"; then
            statsOk=1
        fi
    fi

    # fixup: never on dry-run; runs even after a failed engine when the
    # target exists (a partial sync still wrote files that need the final
    # owner/mode); a successful engine with no destination is a failure.
    if [ "$doFixup" = 1 ]; then
        if [ -d "$dstTarget" ] && [ ! -L "$dstTarget" ]; then
            t0=$(now_mono)
            find -P "$dstTarget" \
                '(' ! -user "$ownerName" -o ! -group "$groupName" ')' \
                    -exec chown -hc "$fileOwner" -- {} + , \
                ! -type l ! -perm "$fileMode" -exec chmod -c "$fileMode" -- {} + \
                >> "$logFile" 2>&1
            fixupExit=$?
            t1=$(now_mono)
            fixupS=$(mono_diff "$t1" "$t0")
        elif [ "$rcloneExit" = 0 ]; then
            echo "fixup: destination $dstTarget missing after successful sync" \
                >> "$logFile"
            fixupExit=missing
        else
            echo "fixup: skipped (engine failed, destination absent)" >> "$logFile"
        fi
    fi
    # final rc: rclone native beats 96 beats 95 beats 0
    finalRc=0
    if [ "$rcloneExit" != 0 ]; then
        finalRc=$rcloneExit
    elif [ "$filterExit" != 0 ] || [ "$statsOk" != 1 ]; then
        finalRc=96
    elif [ "$fixupExit" = missing ] || { [ "$fixupExit" != skipped ] && [ "$fixupExit" != 0 ]; }; then
        finalRc=95
    fi
    save_state
    exit "$finalRc"
}

# ── run_one: coordinator side of a single job ────────────────────────────────
run_one() {
    local sub=$1 runId=$2
    local mangled=${sub//\//_}
    local logFile=$jobLogDir/$mangled.log
    local lk

    if ! exec {lk}>>"$lockDir/ffds-sync-job-$mangled.lock"; then
        echo "cannot open lock file under $lockDir" >&2
        return 90
    fi
    if ! flock -n "$lk"; then
        echo "a sync job for '$sub' is already running (lock busy)" >&2
        return 92
    fi

    local tPre0 tPre1
    tPre0=$(now_mono)

    if ! mounts_ok; then
        return 91
    fi
    local src
    if [ "$backend" = smb ]; then
        src=$smbRemote/$sub
        if ! rclone_cmd lsd "$src" --contimeout 10s --timeout 20s --retries 1 \
                >> "$logFile" 2>&1; then
            echo "smb source preflight failed for $src (see $logFile)" >&2
            missingMount=$smbRemote
            return 91
        fi
    else
        src=$srcRoot/$sub
    fi
    local rc
    dst_safe "$sub"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    local dstTarget=$dstRoot/$sub

    # private state dir for this run; the worker re-verifies it
    local stateDir
    if ! stateDir=$(mktemp -d); then
        echo "mktemp -d failed (TMPDIR not writable?)" >&2
        return 90
    fi
    runStateDir=$stateDir     # for finish() to read phase rcs
    mkdir -p "$rawLogDir" || return 90
    local rawLog=$rawLogDir/$mangled.$runId.jsonl
    local doFixup=1; [ "$dryRunBool" = true ] && doFixup=0
    {
        echo "sub=$(printf '%q' "$sub")"
        echo "runId=$runId"
        echo "logFile=$(printf '%q' "$logFile")"
        echo "rawLog=$(printf '%q' "$rawLog")"
        echo "dstTarget=$(printf '%q' "$dstTarget")"
        echo "doFixup=$doFixup"
    } | atomic_write "$stateDir/params"
    local args=(sync "$src" "$dstTarget"
        --delete-during --create-empty-src-dirs --links
        --transfers "$transfers" --checkers "$checkers"
        --multi-thread-streams "$mtStreams"
        --timeout "${rcloneTimeout}s" --contimeout 30s
        --retries 1 --low-level-retries 10
        --use-json-log --log-level INFO
        --stats "${statsEvery}s" --stats-log-level NOTICE
        "--dry-run=$dryRunBool")
    args+=(${optionFlags[@]+"${optionFlags[@]}"})
    printf '%s\0' "${args[@]}" | atomic_write "$stateDir/argv"

    tPre1=$(now_mono)
    preflightS=$(mono_diff "$tPre1" "$tPre0")

    {
        echo "=== RUN $(date '+%F %T') pid=$runId backend=$backend dry_run=$dryRunFlag subpath=$sub ==="
        echo "rclone ${args[*]}"
    } >> "$logFile"

    # Worker in its own session/process group.  A backgrounded job in a
    # non-interactive shell is not a group leader, so setsid(1) execs the
    # worker directly (no fork) and $! is the worker's pid; the PGID is
    # still learned from the worker's own pgid file, never assumed.
    setsid "$self" __worker "$stateDir" &
    local workerPid=$!
    workerPgid=
    local i
    for i in $(seq 1 40); do
        if [ -f "$stateDir/pgid" ]; then
            workerPgid=$(cat "$stateDir/pgid")
            break
        fi
        kill -0 "$workerPid" 2>/dev/null || break
        sleep 0.05
    done
    if [ -z "$workerPgid" ]; then
        workerPgid=$(ps -o pgid= -p "$workerPid" 2>/dev/null | tr -d ' ')
    fi

    # Interruptible wait: a trapped INT/TERM interrupts wait (>128); the
    # group is TERMed once and then we keep waiting -- the engine/filter
    # must be gone before anyone reports or reuses this subpath.  While
    # the worker is a zombie kill -0 still succeeds, so the loop reaps it
    # and the final wait status is the worker's real one.
    local killedGroup=
    while :; do
        if [ -n "$gotSignal" ] && [ -z "$killedGroup" ]; then
            killedGroup=1
            if [ -n "$workerPgid" ]; then
                kill -TERM -- "-$workerPgid" 2>/dev/null
            else
                kill -TERM "$workerPid" 2>/dev/null
            fi
        fi
        wait "$workerPid" 2>/dev/null; rc=$?
        kill -0 "$workerPid" 2>/dev/null || break
    done

    echo "=== END $(date '+%F %T') exit=$rc subpath=$sub ===" >> "$logFile"

    # coordinator-side validation: the worker's state file must exist and
    # agree with its exit status; a worker that vanished without state is
    # a telemetry failure, not a success.
    if [ -z "$gotSignal" ]; then
        local finalRc=
        [ -f "$stateDir/state" ] && . "$stateDir/state"
        if [ "$finalRc" != "$rc" ]; then
            echo "worker state disagrees with exit status (killed?)" >&2
            [ "$rc" -eq 0 ] && rc=96
        fi
    fi
    return "$rc"
}

# ── cmd_one: v3's shape plus phase keys, dry-run and signal handling ─────────
cmd_one() {
    local sub=${1-}
    local batchTag=${FFDS_BATCH_PID:+ batch=$FFDS_BATCH_PID}
    mkdir -p "$jobLogDir" || exit 90

    jobStart=$(now_mono)
    preflightS=0
    gotSignal=
    workerPgid=
    runStateDir=
    finished=

    finish() {  # <exit code>: single job_end, batch bookkeeping, exit
        local rc=$1
        [ -n "$finished" ] && exit "$rc"
        finished=1
        local dur extras
        dur=$(mono_diff "$(now_mono)" "$jobStart")
        # phase values from the worker's state file; anything it never
        # reached stays at these defaults ("skipped", 0)
        local rcloneExit=skipped filterExit=skipped engineS=0 \
              fixupExit=skipped fixupS=0 finalRc=
        if [ -n "$runStateDir" ] && [ -f "$runStateDir/state" ]; then
            . "$runStateDir/state"
        fi
        extras=" dry_run=$dryRunFlag rclone_exit=$rcloneExit"
        extras+=" filter_exit=$filterExit fixup_exit=$fixupExit"
        extras+=" engine_s=$engineS preflight_s=$preflightS fixup=$fixupS"
        if [ -n "$gotSignal" ]; then
            extras+=" aborted=1 termination_signal=$gotSignal"
        fi
        if ! emit "job_end subpath=$sub run=$$ exit=$rc" \
                  "duration=$dur$extras$batchTag"; then
            [ "$rc" -eq 0 ] && rc=96
        fi
        if [ -n "${FFDS_BATCH_TMP:-}" ] && [ -d "$FFDS_BATCH_TMP" ]; then
            echo "$rc" > "$FFDS_BATCH_TMP/$$.rc"
        fi
        [ -n "$runStateDir" ] && rm -rf "$runStateDir"
        exit "$rc"
    }

    trap 'gotSignal=15' TERM
    trap 'gotSignal=2'  INT

    if ! valid_subpath "$sub"; then
        echo "bad subpath '${sub-}' (must be relative, no '..', no doubled" \
             "slash, no trailing slash, no whitespace)" >&2
        sub=${sub//[[:space:]]/_}
        emit "job_start subpath=${sub:-?} run=$$$batchTag" || exit 90
        sub=${sub:-?}
        finish 90
    fi
    emit "job_start subpath=$sub run=$$$batchTag" || exit 90

    local rc
    run_one "$sub" "$$"
    rc=$?
    if [ -n "$gotSignal" ]; then
        finish $((128 + gotSignal))
    fi
    finish "$rc"
}

# ── cmd_all: v3's batch with spawn-time config validation ────────────────────
cmd_all() {
    local blk
    mkdir -p "$jobLogDir" || exit 90
    if ! exec {blk}>>"$lockDir/ffds-sync-v4-all.lock"; then
        echo "cannot open lock file under $lockDir" >&2
        exit 90
    fi
    if ! flock -n "$blk"; then
        echo "another v4 batch is already running (ffds-sync-v4-all.lock busy)" >&2
        emit "batch_abort pid=$$ reason=lock-busy"
        exit 92
    fi
    if [ ! -r "$config" ]; then
        echo "config $config missing or unreadable" >&2
        emit "batch_abort pid=$$ reason=config-missing"
        exit 93
    fi
    local subs=()
    mapfile -t subs < <(grep -vE '^[[:space:]]*(#|$)' "$config" \
                        | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    if [ "${#subs[@]}" -eq 0 ]; then
        echo "config $config has no subpaths" >&2
        emit "batch_abort pid=$$ reason=config-empty"
        exit 93
    fi
    # Reject duplicates, mangle collisions ('a/b' vs 'a_b' share a lock
    # and a log) and parent/child overlaps ('a' and 'a/b' would race on
    # the same tree) BEFORE spawning anything.
    local i j
    for i in "${!subs[@]}"; do
        for j in "${!subs[@]}"; do
            [ "$i" -lt "$j" ] || continue
            local a=${subs[$i]} b=${subs[$j]}
            if [ "$a" = "$b" ] || [ "${a//\//_}" = "${b//\//_}" ] \
               || [[ "$b" = "$a"/* ]] || [[ "$a" = "$b"/* ]]; then
                echo "config: '$a' and '$b' overlap (duplicate, mangle" \
                     "collision, or parent/child)" >&2
                emit "batch_abort pid=$$ reason=config-invalid"
                exit 93
            fi
        done
    done
    if ! mounts_ok; then
        emit "batch_abort pid=$$ reason=mount-missing mountpoint=$missingMount"
        exit 91
    fi

    local tmp
    if ! tmp=$(mktemp -d); then
        echo "mktemp -d failed (TMPDIR not writable?)" >&2
        emit "batch_abort pid=$$ reason=tmp-failed"
        exit 90
    fi
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    trap 'emit "batch_abort pid=$$ reason=signal"; kill $(jobs -p) 2>/dev/null; exit 94' \
        INT TERM

    local batchStart=$SECONDS
    emit "batch_start pid=$$ total=${#subs[@]} jobs=$jobs"

    local sub running=0 rc
    for sub in "${subs[@]}"; do
        FFDS_BATCH_PID=$$ FFDS_BATCH_TMP="$tmp" "$self" one "$sub" &
        running=$((running + 1))
        while [ "$running" -ge "$jobs" ]; do
            wait -n; rc=$?
            [ "$rc" -eq 127 ] && { running=0; break; }
            running=$((running - 1))
        done
    done
    wait

    local ok=0 fail=0 f
    for f in "$tmp"/*.rc; do
        [ -e "$f" ] || continue
        rc=$(<"$f")
        if [ "$rc" = 0 ]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    done
    emit "batch_end pid=$$ ok=$ok fail=$fail total=${#subs[@]}" \
         "duration=$((SECONDS - batchStart))"
    [ "$ok" -eq "${#subs[@]}" ]
}

cmd_status() {
    echo "== sync processes (v4, backend knob currently '$backend') =="
    # both the repo name and the deployed name; NOT every rclone on the box
    pgrep -af 'ffds[-_]sync[-_]v4(\.sh)? (all|one|__worker)' || echo "(none)"
    echo ""
    echo "== rclone sync/lsd processes (any: the config is env, not argv) =="
    pgrep -af "rclone (sync|lsd) " || echo "(none)"
    echo ""
    echo "== last progress per job log =="
    shopt -s nullglob
    local found=0 now log age mark line
    now=$(date +%s)
    for log in "$jobLogDir"/*.log; do
        found=1
        age=$(( now - $(stat -c %Y "$log" 2>/dev/null || echo "$now") ))
        if [ "$age" -lt $(( statsEvery * 8 )) ]; then
            mark="ACTIVE"
        else
            mark="idle"
        fi
        line=$(grep -E '^[[:space:]]*[0-9.,]+[KMGT]?B?[[:space:]]+[0-9]+%' "$log" \
               | tail -n 1)
        printf '%-6s %s\n' "$mark" "$log"
        if [ -n "$line" ]; then
            printf '       %s\n' "$line"
        else
            printf '       (no progress line yet)\n'
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "(no job logs under $jobLogDir/)"
    fi
    echo ""
    echo "== recent events (tail of $eventLog) =="
    tail -n 15 "$eventLog" 2>/dev/null || echo "(no event log yet)"
}

case "${1-}" in
    all)        cmd_all ;;
    one)        cmd_one "${2-}" ;;
    __worker)   cmd_worker "${2-}" ;;
    status|"")  cmd_status ;;
    *)
        echo "usage: $0 all | one <subpath> | status" >&2
        exit 90
        ;;
esac
