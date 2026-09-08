#!/bin/bash
#
# generate-fixtures.sh -- pin rclone --use-json-log output for the v4
# filter contract.  Run on a machine with the rclone version you intend
# to deploy (PATH decides); everything happens in a scratch dir, results
# land next to this script: <case>.jsonl + expected.json + version.txt.
#
# Cases: cold (2 files), warm (no change), incr (1 file restored),
# updated (1 file rewritten, same size -> mtime-driven), empty-dir,
# symlink (with --links), error-nosrc (missing source).
#
# Usage: bash generate-fixtures.sh

set -eu
here=$(cd "$(dirname "$0")" && pwd)
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT

RCLONE_FLAGS=(--use-json-log --log-level INFO --stats 1s
              --stats-log-level NOTICE --links --create-empty-src-dirs
              --transfers 4 --checkers 8 --retries 1)
export RCLONE_CONFIG=/dev/null

mkdir -p "$S/src/d" "$S/src/emptydir" "$S/dst"
head -c 1048576 /dev/urandom > "$S/src/one.bin"
echo hello > "$S/src/d/two.txt"
ln -s one.bin "$S/src/alink"

run_case() {  # <name> [extra rclone args...]
    local name=$1; shift
    rclone sync "$S/src" "$S/dst" "${RCLONE_FLAGS[@]}" "$@" \
        2> "$here/$name.jsonl" || echo "note: $name exited $?"
}

run_case cold
run_case warm
rm "$S/dst/d/two.txt"
run_case incr
sleep 1.1
echo HELLO > "$S/src/d/two.txt"   # same size, new mtime
run_case updated
rclone sync "$S/nonexistent-src" "$S/dst2" "${RCLONE_FLAGS[@]}" \
    2> "$here/error-nosrc.jsonl" && echo "note: error case exited 0?!"

rclone version > "$here/version.txt"

python3 - "$here" <<'EOF'
import json, os, sys
here = sys.argv[1]
out = {}
for name in ("cold", "warm", "incr", "updated", "error-nosrc"):
    path = os.path.join(here, name + ".jsonl")
    final = None
    for line in open(path):
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj.get("stats"), dict):
            final = obj["stats"]
    out[name] = None if final is None else {
        k: final.get(k) for k in
        ("bytes", "totalBytes", "speed", "transfers", "totalTransfers",
         "checks", "totalChecks", "deletes", "deletedDirs", "errors")}
with open(os.path.join(here, "expected.json"), "w") as f:
    json.dump(out, f, indent=1, sort_keys=True)
print(json.dumps(out, indent=1, sort_keys=True))
EOF
echo "fixtures written to $here"
