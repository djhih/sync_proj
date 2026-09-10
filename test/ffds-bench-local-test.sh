#!/bin/bash
#
# ffds-bench-local-test.sh -- sandbox harness for ffds-bench.sh +
# ffds_bench_data.py
#
# Everything under one mktemp -d.  The bench script and the v4 engine are
# copies with rewritten fixed-config blocks; systemd-run/systemctl are
# PATH shims (the transient scope itself is sync-host-smoke territory), and
# rclone is a shim that REALLY syncs (cp + delete-extras) and prints a
# valid --use-json-log final stats object, so scenario gates
# (cold=all files, warm=0, incr=N) are exercised against real trees.
#
# Usage:  bash test/ffds-bench-local-test.sh
# Exit:   0 when every assertion passed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

SCRATCH=$(mktemp -d)
if [ -z "${FFDS_TEST_KEEP:-}" ]; then
    trap 'rm -rf "$SCRATCH"' EXIT
fi

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', want '$3'"; fi; }
assert_match() { if grep -qE -- "$3" <<< "$2"; then ok "$1"; else bad "$1: no match for /$3/"; fi; }
assert_refused() {  # <desc> <cmd...>: expect rc 2 (guard refusal)
    local desc=$1; shift
    "$@" >/dev/null 2>&1
    assert_eq "$desc" $? 2
}

# ── layout: bench + data helper + engine sources in scratch ──────────────────
mkdir -p "$SCRATCH/bench" "$SCRATCH/shims" "$SCRATCH/weka/ffds-bench" \
         "$SCRATCH/src/FFDS/A/sub" "$SCRATCH/results" "$SCRATCH/livelog" \
         "$SCRATCH/lock" "$SCRATCH/out" "$SCRATCH/fake"
cp "$repo/bench/ffds_bench_data.py" "$SCRATCH/bench/"
cp "$repo/ffds-sync-v3.sh" "$SCRATCH/ffds-sync-v3.sh"
cp "$repo/ffds-sync-v4.sh" "$SCRATCH/ffds-sync-v4.sh"

data=$SCRATCH/bench/ffds_bench_data.py
expectMount=$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
from ffds_bench_data import mount_point_of
print(mount_point_of(sys.argv[2]))' "$SCRATCH/bench" "$SCRATCH")
echo "scratch: $SCRATCH (mount: $expectMount)"

BENCH=$SCRATCH/bench/ffds-bench.sh
sed -e "s|^scratchBase=.*|scratchBase=$SCRATCH/weka/ffds-bench|" \
    -e "s|^expectMount=.*|expectMount=$expectMount|" \
    -e "s|^resultsRoot=.*|resultsRoot=$SCRATCH/results|" \
    -e "s|^liveLogRoot=.*|liveLogRoot=$SCRATCH/livelog|" \
    -e "s|^benchLockFile=.*|benchLockFile=$SCRATCH/lock/ffds-bench.lock|" \
    -e "s|^copyLockDir=.*|copyLockDir=$SCRATCH/lock|" \
    -e "s|^copyMountpoints=.*|copyMountpoints=(/ /proc)|" \
    -e "s|^copyFileOwner=.*|copyFileOwner=$(id -un):$(id -gn)|" \
    -e "s|^srcRoot=.*|srcRoot=$SCRATCH/src/FFDS|" \
    -e "s|^smbRemote=.*|smbRemote=shimremote:share/FFDS|" \
    -e "s|^rcloneConfig=.*|rcloneConfig=$SCRATCH/rclone.conf|" \
    -e "s|^cifsStats=.*|cifsStats=$SCRATCH/fake-cifs|" \
    "$repo/bench/ffds-bench.sh" > "$BENCH"
chmod +x "$BENCH"
touch "$SCRATCH/rclone.conf"
printf 'Creates: 10\nCloses: 8\nQueryInfos: 100\nReads: 50\nReconnects: 0\n' \
    > "$SCRATCH/fake-cifs"

# source fixture: 5 regular files
echo one > "$SCRATCH/src/FFDS/A/f1.txt"
echo two > "$SCRATCH/src/FFDS/A/f2.txt"
head -c 4096 /dev/urandom > "$SCRATCH/src/FFDS/A/big.bin"
echo s1 > "$SCRATCH/src/FFDS/A/sub/s1.txt"
echo s2 > "$SCRATCH/src/FFDS/A/sub/s2.txt"

# ── shims ────────────────────────────────────────────────────────────────────
# rclone: a real mini-sync (size-compare copy + delete-extras) that
# prints one valid final stats JSON; FFDS_BENCH_SHIM_RC forces a failure.
cat > "$SCRATCH/shims/rclone" <<'EOF'
#!/bin/bash
if [ "$1" = lsd ]; then exit 0; fi
src=$2; dst=$3
if [ "${FFDS_BENCH_SHIM_RC:-0}" != 0 ]; then
    echo '{"level":"error","msg":"forced failure","time":"T"}'
    exit "$FFDS_BENCH_SHIM_RC"
fi
mkdir -p "$dst"
transfers=0; checks=0; deletes=0; bytes=0; totalBytes=0
while IFS= read -r -d '' f; do
    rel=${f#"$src"/}
    checks=$((checks + 1))
    sz=$(stat -c %s "$f"); totalBytes=$((totalBytes + sz))
    if [ ! -f "$dst/$rel" ] || [ "$(stat -c %s "$dst/$rel")" != "$sz" ]; then
        mkdir -p "$(dirname "$dst/$rel")"
        cp -p "$f" "$dst/$rel"
        transfers=$((transfers + 1)); bytes=$((bytes + sz))
    fi
done < <(find "$src" -type f -print0)
while IFS= read -r -d '' f; do
    rel=${f#"$dst"/}
    if [ ! -f "$src/$rel" ]; then rm -f "$f"; deletes=$((deletes + 1)); fi
done < <(find "$dst" -type f -print0)
while IFS= read -r -d '' d; do
    mkdir -p "$dst/${d#"$src"/}"
done < <(find "$src" -mindepth 1 -type d -print0)
printf '{"level":"notice","msg":"stats","stats":{"bytes":%d,"totalBytes":%d,"speed":1000,"eta":0,"transfers":%d,"totalTransfers":%d,"checks":%d,"totalChecks":%d,"deletes":%d,"deletedDirs":0,"errors":0},"time":"T"}\n' \
    "$bytes" "$totalBytes" "$transfers" "$transfers" "$checks" "$checks" "$deletes"
exit 0
EOF
# systemd-run: strip --scope/--collect/--quiet/--unit=... and exec
cat > "$SCRATCH/shims/systemd-run" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
    case $1 in
        --scope|--collect|--quiet) shift ;;
        --unit=*) shift ;;
        --unit) shift 2 ;;
        *) break ;;
    esac
done
exec "$@"
EOF
cat > "$SCRATCH/shims/systemctl" <<'EOF'
#!/bin/bash
case $1 in
    is-active) echo inactive; exit 3 ;;
    kill|stop) exit 0 ;;
esac
exit 0
EOF
chmod +x "$SCRATCH/shims/"*
cat > "$SCRATCH/fake/ffds_sync.sh" <<'EOF'
#!/bin/bash
sleep "${1:-30}" 2>/dev/null || sleep 30
EOF
chmod +x "$SCRATCH/fake/ffds_sync.sh"

runbench() { env PATH="$SCRATCH/shims:$PATH" FFDS_BENCH_TEST_NONROOT=1 "$@"; }

# ── G1: data-layer guards ────────────────────────────────────────────────────
echo "G1 path guards"
gbase=$SCRATCH/weka/ffds-bench
G=(python3 "$data")
"${G[@]}" init-campaign --scratch-base "$gbase" --expect-mount "$expectMount" \
    --campaign guardtest >/dev/null
assert_eq "init-campaign" $? 0
assert_refused "campaign id reuse refused" \
    "${G[@]}" init-campaign --scratch-base "$gbase" --expect-mount "$expectMount" \
        --campaign guardtest
target=$("${G[@]}" guard-target --scratch-base "$gbase" --expect-mount "$expectMount" \
    --campaign guardtest --engine v4-mount --subpath A)
assert_eq "guard-target ok" $? 0
assert_eq "guard-target path" "$target" \
    "$gbase/guardtest/v4-mount/DataSet/A"
for badsub in "../../../DataSet" "/abs" "a//b" "a/../b" ".." "trail/"; do
    assert_refused "traversal subpath '$badsub' refused" \
        "${G[@]}" guard-target --scratch-base "$gbase" --expect-mount "$expectMount" \
            --campaign guardtest --engine v4-mount --subpath "$badsub"
done
assert_refused "wrong mount refused" \
    "${G[@]}" guard-target --scratch-base "$gbase" --expect-mount /nonexistent-mount \
        --campaign guardtest --engine v4-mount --subpath A
assert_refused "unknown engine refused" \
    "${G[@]}" guard-target --scratch-base "$gbase" --expect-mount "$expectMount" \
        --campaign guardtest --engine evil --subpath A
echo tampered > "$gbase/guardtest/.ffds-bench-campaign"
assert_refused "fake marker refused" \
    "${G[@]}" guard-target --scratch-base "$gbase" --expect-mount "$expectMount" \
        --campaign guardtest --engine v4-mount --subpath A
echo guardtest > "$gbase/guardtest/.ffds-bench-campaign"
chmod 755 "$gbase/guardtest"
assert_refused "campaign root mode != 0700 refused" \
    "${G[@]}" guard-target --scratch-base "$gbase" --expect-mount "$expectMount" \
        --campaign guardtest --engine v4-mount --subpath A
chmod 700 "$gbase/guardtest"

# symlink ancestor + sentinel: a refused safe-remove must not touch data
mkdir -p "$SCRATCH/elsewhere/DataSet/A"
echo precious > "$SCRATCH/elsewhere/DataSet/A/sentinel.txt"
ln -s "$SCRATCH/elsewhere" "$gbase/guardtest/v4-mount"
assert_refused "symlink engine ancestor refused" \
    "${G[@]}" safe-remove --scratch-base "$gbase" --expect-mount "$expectMount" \
        --campaign guardtest --engine v4-mount --subpath A
[ -f "$SCRATCH/elsewhere/DataSet/A/sentinel.txt" ] \
    && ok "sentinel untouched after refusal" || bad "sentinel destroyed!"
rm "$gbase/guardtest/v4-mount"
mkdir -p "$gbase/guardtest/v4-mount/DataSet"
ln -s "$SCRATCH/elsewhere/DataSet/A" \
      "$gbase/guardtest/v4-mount/DataSet/A"
assert_refused "symlink target itself refused" \
    "${G[@]}" safe-remove --scratch-base "$gbase" --expect-mount "$expectMount" \
        --campaign guardtest --engine v4-mount --subpath A
[ -f "$SCRATCH/elsewhere/DataSet/A/sentinel.txt" ] \
    && ok "sentinel untouched (symlink target)" || bad "sentinel destroyed via symlink!"

# remove-files hygiene
mkdir -p "$gbase/guardtest/v4-mount/DataSet/B/d"
echo keep > "$gbase/guardtest/v4-mount/DataSet/B/keep.txt"
echo '["../escape"]' > "$SCRATCH/badlist.json"
assert_refused "remove-files traversal in list refused" \
    "${G[@]}" remove-files --scratch-base "$gbase" --expect-mount "$expectMount" \
        --campaign guardtest --engine v4-mount --subpath B --list "$SCRATCH/badlist.json"
echo '["d"]' > "$SCRATCH/badlist2.json"
assert_refused "remove-files non-regular refused" \
    "${G[@]}" remove-files --scratch-base "$gbase" --expect-mount "$expectMount" \
        --campaign guardtest --engine v4-mount --subpath B --list "$SCRATCH/badlist2.json"
[ -f "$gbase/guardtest/v4-mount/DataSet/B/keep.txt" ] \
    && ok "unlisted file kept" || bad "unlisted file removed"

# ── G3: full mini campaign (v4-mount, cold+warm+incr, 2 reps) ────────────────
echo "G3 campaign"
out=$SCRATCH/out/c1
runbench "$BENCH" -p A -r 2 -o "$out" --engines v4-mount \
    --scenarios cold,warm,incr --incr-files 2 --no-drop-caches \
    > "$SCRATCH/c1.stdout" 2>&1
assert_eq "campaign rc" $? 0
camp=$(ls "$SCRATCH/results" | head -n 1)
[ -n "$camp" ] && ok "campaign results dir: $camp" || bad "no results dir"
nruns=$(ls "$SCRATCH/results/$camp/runs/"*.json 2>/dev/null | wc -l)
assert_eq "6 measured results (2 reps x 3 scenarios)" "$nruns" 6
allvalid=$(python3 - "$SCRATCH/results/$camp/runs" <<'EOF'
import json, os, sys
d = sys.argv[1]
recs = [json.load(open(os.path.join(d, f))) for f in sorted(os.listdir(d))]
print(all(r["valid"] == 1 for r in recs))
for r in recs:
    if r["valid"] != 1:
        print(r["run_id"], r["invalid_reasons"], file=sys.stderr)
EOF
)
assert_eq "all runs valid" "$allvalid" "True"
check_run() {  # <runid-suffix> <field> <want>
    python3 - "$SCRATCH/results/$camp/runs" "$@" <<'EOF'
import json, os, sys
d, suffix, field, want = sys.argv[1:5]
for f in os.listdir(d):
    if f.endswith(suffix + ".json"):
        print(json.load(open(os.path.join(d, f))).get(field))
        break
else:
    print("NORUN")
EOF
}
assert_eq "cold transferred = 5" "$(check_run r1-v4-mount-cold files_transferred 5)" 5
assert_eq "warm transferred = 0" "$(check_run r1-v4-mount-warm files_transferred 0)" 0
assert_eq "incr transferred = 2" "$(check_run r1-v4-mount-incr files_transferred 2)" 2
assert_eq "deletes zero"        "$(check_run r1-v4-mount-cold rclone_deletes 0)" 0
assert_eq "fixup ran (exit recorded)" "$(check_run r1-v4-mount-cold fixup_exit 0)" 0
assert_eq "cifs delta parsed (same snapshot -> 0)" \
          "$(check_run r1-v4-mount-cold cifs_queryinfo_delta 0)" 0
assert_eq "interference clean" "$(check_run r1-v4-mount-cold other_sync_running 0)" 0
dur=$(check_run r1-v4-mount-cold duration_s x)
assert_match "duration positive" "$dur" '^[0-9.]+$'
[ -f "$out/results.csv" ] && ok "results.csv" || bad "results.csv missing"
assert_eq "csv rows" "$(( $(wc -l < "$out/results.csv") - 1 ))" 6
[ -f "$out/SUMMARY.txt" ] && ok "SUMMARY.txt" || bad "SUMMARY missing"
assert_match "summary has warm files/s" "$(cat "$out/SUMMARY.txt")" 'warm_files_per_s='
ncopies=$(ls "$out/completed-results/"*.json | wc -l)
assert_eq "portable copies" "$ncopies" 6
cmp -s "$SCRATCH/results/$camp/runs/$(ls "$SCRATCH/results/$camp/runs" | head -1)" \
       "$out/completed-results/$(ls "$SCRATCH/results/$camp/runs" | head -1)" \
    && ok "portable copy byte-identical" || bad "portable copy differs"
[ ! -d "$SCRATCH/weka/ffds-bench/$camp/v4-mount/DataSet/A" ] \
    && ok "scratch dataset cleaned on success" || bad "scratch left behind"
assert_match "engine order logged with seed" "$(cat "$out/run.log")" \
    'engine order \(seed=1\)'
# no-overwrite: replaying the same record must be refused
firstInput=$(ls "$out"/runs/r1-v4-mount-cold/result-input.json)
python3 "$data" record --input "$firstInput" --results-root "$SCRATCH/results" \
    --outdir-copy "$out/completed-results" --expect-transferred 5 >/dev/null 2>&1
assert_eq "duplicate tuple record refused" $? 2
# rebuild csv from authoritative JSON is reproducible
python3 "$data" csv --results-root "$SCRATCH/results" --campaign "$camp" \
    --out "$SCRATCH/rebuild.csv" >/dev/null
cmp -s "$out/results.csv" "$SCRATCH/rebuild.csv" \
    && ok "csv reproducible from JSON" || bad "csv differs on rebuild"

# ── G4: failure stops the campaign, saves the invalid run, keeps scratch ─────
echo "G4 failure handling"
out2=$SCRATCH/out/c2
runbench env FFDS_BENCH_SHIM_RC=7 "$BENCH" -p A -r 2 -o "$out2" \
    --engines v4-mount --scenarios cold --no-drop-caches \
    > "$SCRATCH/c2.stdout" 2>&1
assert_eq "failed campaign rc nonzero" $? 1
camp2=$(ls -t "$SCRATCH/results" | head -n 1)
n2=$(ls "$SCRATCH/results/$camp2/runs/"*.json 2>/dev/null | wc -l)
assert_eq "exactly one (failed) result saved before halt" "$n2" 1
v=$(python3 -c 'import json,glob,sys
r=json.load(open(glob.glob(sys.argv[1])[0]))
print(r["valid"], r["script_exit"], ";".join(r["invalid_reasons"][:1]))' \
    "$SCRATCH/results/$camp2/runs/*.json")
assert_match "failed run recorded invalid with reason" "$v" \
    '^0 7 script exit nonzero'
[ -d "$SCRATCH/weka/ffds-bench/$camp2" ] \
    && ok "scratch preserved after halt" || bad "scratch removed after failure"
assert_match "halt logged" "$(cat "$out2/run.log")" 'HALT: run .* exited 7'

# ── G5: quiet-window preflight ───────────────────────────────────────────────
echo "G5 interference preflight"
bash "$SCRATCH/fake/ffds_sync.sh" all & fakePid=$!
sleep 0.2
out3=$SCRATCH/out/c3
runbench "$BENCH" -p A -r 1 -o "$out3" --engines v4-mount --scenarios cold \
    --no-drop-caches > "$SCRATCH/c3.stdout" 2>&1
rc=$?
kill "$fakePid" 2>/dev/null; wait "$fakePid" 2>/dev/null
assert_eq "refuses while another sync runs" "$rc" 1
assert_match "reason mentions other sync" "$(cat "$SCRATCH/c3.stdout")" \
    'other sync processes running'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
