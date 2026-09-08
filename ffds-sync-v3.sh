#!/bin/bash
#
# ffds_sync.sh (v3) -- sync [SMB] source NAS share to [WEKA] DataSet
# Deploy target: sync-host:/usr/local/ffds/ffds_sync.sh
# Requires: bash >= 4.4, rsync >= 3.1.0 (--info, --chown, --outbuf),
#           coreutils stdbuf, util-linux flock, awk (mawk >= 1.3.4 or gawk)
#
# One script replaces the v1/v2 pair (sync_all.sh + sync_ffds.sh):
#
#   ffds_sync.sh all              sync every subpath in /etc/sync_paths.conf
#   ffds_sync.sh one <subpath>    sync a single subpath
#   ffds_sync.sh [status]         show running jobs and last progress
#
# Logs: the contract between this script and its monitor 
#
# The monitor (sync_monitor/ffds_sync_monitor.py) is a separate program
# that reads ONLY the event log below -- no /proc, no pgrep, no mounts.
# Everything it needs to know is therefore written here, by the process
# that knows it, at the moment it happens.
#
#   /var/log/ffds-sync/events.log        machine contract, one event per line
#   /var/log/ffds-sync/jobs/<sub>.log    raw rsync output per subpath, for
#                                        humans (append, RUN/END markers;
#                                        '/' in subpath becomes '_')
#
# Event line format (logfmt; values never contain spaces -- subpaths are
# validated, rsync tokens are single words):
#
#   ts=<epoch> time=<ISO-8601 local> event=<name> key=value ...
#
#   batch_start   pid= total= jobs=
#   batch_end     pid= ok= fail= total= duration=
#   batch_abort   pid= reason=lock-busy|config-missing|config-empty|
#                              mount-missing|tmp-failed|signal  [mountpoint=]
#   job_start     subpath= run=<worker pid> [batch=<batch pid>]
#   job_progress  subpath= run= bytes= pct= speed= eta= [xfr= chk=]
#                 (raw rsync --info=progress2 tokens, one per N lines)
#   job_stats     subpath= run= [files= created= deleted= transferred=
#                 size= listgen= speedup=]   (rsync --info=stats2 summary)
#   job_end       subpath= run= exit= duration= [batch=]
#
# A job with job_start but no job_end is running; a job whose last
# job_progress is older than a few minutes is stuck. Manual 'one' runs
# are logged too (no batch= field). Single-line O_APPEND writes are
# atomic, so batch, workers and the awk filter share the file safely.
#
# Under systemd (JOURNAL_STREAM set) the lifecycle events -- batch_*,
# job_start, job_end -- are also printed to stdout, i.e. the journal.
# job_progress and job_stats are log-only: they come from the awk filter
# and would flood the journal on a long transfer.
#
# Two subpaths that mangle to the same name ('a/b' and 'a_b') share one
# job log and one job lock; the second would fail 92 while the first
# runs. Filenames printed by --info=name1,del1 that happen to look like
# a progress or stats line can poison one event's numbers (never its
# shape -- every token is still key=value).
#
# Differences from v2 (rationale: ffds-sync-v3.zh-tw.md) 
#   * One tree walk instead of four: --chown/--chmod make rsync enforce
#     root:datasetgrp and 775 on every file it examines, in the same
#     pass that syncs the data. The three post-rsync find sweeps are
#     gone, and so is the perms tug-of-war (-p used to reset perms to
#     the cifs source mode each run, then chmod flipped them back).
#   * -z dropped: sender and receiver are processes on the same host
#     talking over a socketpair; compression there is pure CPU waste.
#   * --no-inc-recursive dropped: incremental recursion overlaps the
#     scan with the transfer and bounds the in-memory file list.
#     Progress totals (ir-chk) grow while scanning; exact totals come
#     from the stats2 summary at the end.
#   * --partial dropped: local transfers default to --whole-file, so a
#     partial file cannot be resumed anyway -- keeping it only exposes
#     a truncated file at its final name to dataset consumers.
#   * --timeout (default 1800s): a hung SMB/WEKA mount fails the job
#     with rsync exit 30 instead of hanging it forever.
#   * flock instead of pgrep substring matching: per-subpath job locks
#     plus one batch lock.
#   * Mount preflight from /proc/mounts (kernel memory only -- never
#     stat a possibly-hung mount): exit 91 instead of rsync filling
#     the root filesystem when /mnt/dst-fs is absent.
#   * Optional parallelism: FFDS_SYNC_JOBS=N (default 1, sequential).
#
# Exit codes (job_end exit= / batch worker status):
#   0      success
#   1-35   rsync's own codes (23 partial, 24 vanished, 30 timeout, ...)
#   90     bad usage / bad subpath (absolute, '.', '..', trailing slash,
#          whitespace, backslash) / log, lock or temp dir unwritable
#   91     source or destination mount missing
#   92     lock busy (same subpath already syncing / batch already running)
#   93     config missing or empty
#   94     batch aborted by signal
#
# 'all' itself exits 0 only when every job succeeded, 1 otherwise (so a
# failed night shows as failed in 'systemctl status'); its own aborts
# use 90-94 as above.
#
# Watch one job live:
#   tail -f /var/log/ffds-sync/jobs/<subpath, / replaced by _>.log
#   tail -f /var/log/ffds-sync/events.log

set -u

# ── Fixed configuration -- edit in place ─────────────────────────────────────
srcRoot=/mnt/src-share/DataSet
dstRoot=/mnt/dst-fs/DataSet
mountpoints=(/mnt/src-share /mnt/dst-fs)
logDir=/var/log/ffds-sync
config=/etc/sync_paths.conf
lockDir=/run/lock
fileOwner=root:datasetgrp
fileMode=D775,F775
# ─────────────────────────────────────────────────────────────────────────────

# ── Env knobs (deployment tuning only -- WHAT to sync is fixed above) ────────
jobs=${FFDS_SYNC_JOBS:-1}                  # concurrent subpaths in 'all'
rsyncTimeout=${FFDS_RSYNC_TIMEOUT:-1800}   # rsync --timeout, 0 disables
progressEvery=${FFDS_PROGRESS_EVERY:-15}   # keep/emit every Nth progress line
read -r -a extraFlags <<< "${FFDS_RSYNC_EXTRA:-}"  # e.g. "--bwlimit=50m"
# Non-numeric knobs fall back to defaults: a bad FFDS_SYNC_JOBS would
# make the pool test fail open (unbounded parallelism), and a zero
# FFDS_PROGRESS_EVERY would divide by zero inside the awk filter.
case $jobs          in ''|*[!0-9]*|0) jobs=1 ;;          esac
case $rsyncTimeout  in ''|*[!0-9]*)   rsyncTimeout=1800 ;; esac
case $progressEvery in ''|*[!0-9]*|0) progressEvery=15 ;; esac

eventLog=$logDir/events.log
jobLogDir=$logDir/jobs
self=$(readlink -f "$0")

emit() {  # emit <event> [key=value ...]  -> one line into the event log
    local line
    line="$(date '+ts=%s time=%FT%T%z') event=$*"
    echo "$line" >> "$eventLog"
    # Under systemd, stdout is the journal: mirror lifecycle events there
    # too (batch_*, job_start, job_end -- workers inherit the fd). The
    # awk-emitted job_progress/job_stats stay log-only on purpose.
    # if/fi, not '[ ] &&': emit is the last command of cmd_all, so its
    # status must be 0 when JOURNAL_STREAM is unset.
    if [ -n "${JOURNAL_STREAM:-}" ]; then
        echo "$line"
    fi
}

mounts_ok() {
    # /proc/mounts is kernel memory; stat()ing a hung SMB mountpoint
    # would hang this script before rsync even starts. On failure the
    # missing mountpoint is left in $missingMount for the caller's event.
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

valid_subpath() {
    case "${1-}" in
        ''|/*|*/) return 1 ;;             # empty, absolute, trailing slash
        ..|../*|*/..|*/../*) return 1 ;;  # path traversal
        .|./*|*/.|*/./*) return 1 ;;      # '.' would sync the whole root
        *[[:space:]]*) return 1 ;;        # event log values are space-free
        *\\*) return 1 ;;                 # awk -v would escape-process '\t'
    esac
    return 0
}

filter_rsync() {
    # stdin: rsync output with \r already turned into \n.
    # stdout: the job log -- everything except progress lines, plus every
    #         Nth progress line (progress2 prints ~1/s; a multi-hour
    #         transfer would otherwise log tens of MB of noise).
    # side effect: job_progress (every Nth line) and job_stats (at EOF)
    #         events appended to the event log, already tokenized.
    local sp=$1 run=$2
    awk -v n="$progressEvery" -v ev="$eventLog" -v sp="$sp" -v run="$run" '
        function stamp(   cmd, s) {
            cmd = "date \"+ts=%s time=%FT%T%z\""
            cmd | getline s; close(cmd)
            return s
        }
        function kv(k, v) { return (v == "" ? "" : " " k "=" v) }
        function event(line) { print line >> ev; close(ev) }
        /^[[:space:]]*[0-9][0-9.,]*[KkMmGgTtPp]?B?[[:space:]]+[0-9]+%/ {
            if (++c % n) next
            pct = $2; sub(/%$/, "", pct)
            xfr = ""; chk = ""
            if ($5 ~ /^\(xfr#/) { xfr = substr($5, 6); sub(/,$/, "", xfr) }
            if ($6 ~ /chk=/)    { chk = $6; sub(/^.*chk=/, "", chk); sub(/\)$/, "", chk) }
            event(stamp() " event=job_progress subpath=" sp " run=" run \
                  " bytes=" $1 " pct=" pct " speed=" $3 " eta=" $4 \
                  kv("xfr", xfr) kv("chk", chk))
        }
        /^Number of files: /                  { files = $4 }
        /^Number of created files: /          { created = $5 }
        /^Number of deleted files: /          { deleted = $5 }
        /^Number of regular files transferred: / { transferred = $6 }
        /^Total file size: /                  { size = $4 }
        /^File list generation time: /        { listgen = $5 }
        /speedup is / {  # token after "speedup is": --dry-run appends "(DRY RUN)"
            speedup = $0; sub(/.*speedup is /, "", speedup); sub(/ .*$/, "", speedup)
        }
        { print; fflush() }
        END {
            if (files != "" || transferred != "")
                event(stamp() " event=job_stats subpath=" sp " run=" run \
                      kv("files", files) kv("created", created) \
                      kv("deleted", deleted) kv("transferred", transferred) \
                      kv("size", size) kv("listgen", listgen) \
                      kv("speedup", speedup))
        }'
}

run_one() {
    local sub=$1
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

    # rsync recreates the last path component, so the destination
    # argument is the PARENT of the subpath on the WEKA side.
    local destParent=$dstRoot
    case "$sub" in */*) destParent=$dstRoot/${sub%/*} ;; esac
    # Deliberately unchecked: on a present-but-hung WEKA this blocks in
    # D-state (mounts_ok only proves presence) -- the held lock and the
    # monitor's last-activity alarm are the backstops; on plain failure
    # rsync fails right after with its own code in the job log.
    mkdir -p "$destParent"

    local timeoutFlag=()
    if [ "$rsyncTimeout" != 0 ]; then
        timeoutFlag=(--timeout="$rsyncTimeout")
    fi

    local start=$SECONDS
    {
        echo "=== RUN $(date '+%F %T') pid=$$ subpath=$sub ==="
        echo "rsync -ah --delete --chown=$fileOwner --chmod=$fileMode" \
             "--info=progress2,stats2,name1,del1 ${timeoutFlag[*]-}" \
             "${extraFlags[*]-} $srcRoot/$sub -> $destParent/"
    } >> "$logFile"

    # --chown/--chmod: ownership and mode are enforced during the sync
    #   pass itself, for every file examined -- not just transferred
    #   ones -- which is what made the find sweeps redundant.
    # --info=name1,del1: transferred and deleted files logged by name
    #   (the deletion list is the only forensic record --delete leaves).
    # --outbuf=N | tr '\r' '\n': progress updates are \r rewrites of one
    #   line; make each update its own line, unbuffered.
    rsync -ah --delete \
          --chown="$fileOwner" --chmod="$fileMode" \
          --info=progress2,stats2,name1,del1 --outbuf=N \
          "${timeoutFlag[@]}" "${extraFlags[@]}" \
          "$srcRoot/$sub" "$destParent/" \
        2>&1 | stdbuf -o0 tr '\r' '\n' | filter_rsync "$sub" "$$" >> "$logFile"
    local rc=${PIPESTATUS[0]}

    echo "=== END $(date '+%F %T') exit=$rc duration=$((SECONDS - start))s" \
         "subpath=$sub ===" >> "$logFile"
    jobDuration=$((SECONDS - start))
    return "$rc"
}

cmd_one() {
    local sub=${1-}
    local batchTag=${FFDS_BATCH_PID:+ batch=$FFDS_BATCH_PID}
    # Checked: without the log dir the lock's exec redirection fails,
    # leaves $lk unset and set -u would kill the worker without job_end.
    mkdir -p "$jobLogDir" || exit 90

    finish() {  # <exit code>: job_end event, batch bookkeeping, exit
        local rc=$1
        emit "job_end subpath=$sub run=$$ exit=$rc" \
             "duration=${jobDuration:-0}$batchTag"
        # keyed by worker pid, not subpath: a duplicated config line (or
        # 'a/b' vs 'a_b') would otherwise overwrite another worker's rc
        if [ -n "${FFDS_BATCH_TMP:-}" ] && [ -d "$FFDS_BATCH_TMP" ]; then
            echo "$rc" > "$FFDS_BATCH_TMP/$$.rc"
        fi
        exit "$rc"
    }

    if ! valid_subpath "$sub"; then
        echo "bad subpath '${sub-}' (must be relative, no '..', no" \
             "trailing slash, no whitespace)" >&2
        sub=${sub//[[:space:]]/_}   # keep the event line well-formed
        emit "job_start subpath=${sub:-?} run=$$$batchTag"
        sub=${sub:-?}
        finish 90
    fi
    emit "job_start subpath=$sub run=$$$batchTag"
    if ! mounts_ok; then
        finish 91
    fi
    local rc
    run_one "$sub"
    rc=$?
    finish "$rc"
}

cmd_all() {
    local blk
    mkdir -p "$jobLogDir" || exit 90
    if ! exec {blk}>>"$lockDir/ffds-sync-all.lock"; then
        echo "cannot open lock file under $lockDir" >&2
        exit 90
    fi
    if ! flock -n "$blk"; then
        echo "another batch is already running (ffds-sync-all.lock busy)" >&2
        emit "batch_abort pid=$$ reason=lock-busy"
        exit 92
    fi
    if [ ! -r "$config" ]; then
        echo "config $config missing or unreadable" >&2
        emit "batch_abort pid=$$ reason=config-missing"
        exit 93
    fi
    local subs=()
    # CRLF and surrounding whitespace are tolerated (config files get
    # edited from Windows); comment and blank lines are skipped
    mapfile -t subs < <(grep -vE '^[[:space:]]*(#|$)' "$config" \
                        | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    if [ "${#subs[@]}" -eq 0 ]; then
        echo "config $config has no subpaths" >&2
        emit "batch_abort pid=$$ reason=config-empty"
        exit 93
    fi
    if ! mounts_ok; then
        emit "batch_abort pid=$$ reason=mount-missing mountpoint=$missingMount"
        exit 91
    fi

    # Workers report their exit code through files in this directory.
    # Guarded: under ProtectSystem=strict without PrivateTmp, mktemp
    # fails and an unguarded batch would end with a false ok=0 fail=0.
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

    # Workers are separate processes ("$self" one <sub>): each job has
    # its own pid (the run= id in the event log) and its own lock.
    local sub running=0 rc
    for sub in "${subs[@]}"; do
        FFDS_BATCH_PID=$$ FFDS_BATCH_TMP="$tmp" "$self" one "$sub" &
        running=$((running + 1))
        while [ "$running" -ge "$jobs" ]; do
            wait -n; rc=$?
            # 127 = nothing left to reap; decrementing on it would drift
            # the counter negative and let the pool overspawn
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
    # Batch status: 0 only if every job reported success (a worker that
    # died without writing its rc counts as failed), so 'systemctl status'
    # shows a failed night as failed. Timer triggers are unaffected.
    [ "$ok" -eq "${#subs[@]}" ]
}

cmd_status() {
    echo "== sync processes =="
    pgrep -af 'ffds_sync\.sh (all|one)' || echo "(none)"
    echo ""
    echo "== rsync processes =="
    pgrep -a rsync || echo "(none)"
    echo ""
    echo "== last progress per job log =="
    shopt -s nullglob
    local found=0 now log age mark line
    now=$(date +%s)
    for log in "$jobLogDir"/*.log; do
        found=1
        age=$(( now - $(stat -c %Y "$log" 2>/dev/null || echo "$now") ))
        # a running transfer appends progress every ~progressEvery
        # seconds, so a stale mtime means the job is done or stuck
        if [ "$age" -lt $(( progressEvery * 8 )) ]; then
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
    status|"")  cmd_status ;;
    *)
        echo "usage: $0 all | one <subpath> | status" >&2
        exit 90
        ;;
esac
