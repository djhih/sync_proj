"""Turn the log of one sync or relocate run (real or --dry-run) into a TSV: what happened and why.

Standard library only and independent of the package, so it can be copied anywhere on its own.
It parses the lines written by Executor (see Action.describe and cli.LOG_FORMAT); tests/test_report.py
keeps the two in step.
"""
import csv
import re
import sys
from collections import Counter

LINE = re.compile(r"^(\S+ \S+) \| [A-Z]+ \| "
                  r"(?:(START|REPLACING|DONE|FAILED|DUPLICATE LOT|PLAN FAILED|DRY-RUN REPLACE|DRY-RUN) \| )?(.*)$")
ACTION = re.compile(r"^(\S+) +(.*?)(?: -> (.*?))?(?:  \((.*)\))?$")   # Action.describe()
FAILURE = re.compile(r"^(\S+) +(.*?) -> (.*?): (.*)$")                # describe(): error
NOTE = re.compile(r"^(.*): (\d+ B @ .* -> \d+ B @ .*)$")              # path: old -> new
RESULT = {"DONE": "updated", "DRY-RUN": "would-update", "DUPLICATE LOT": "duplicate",
          "PLAN FAILED": "error", None: "skipped"}


def parse(log_path):
    rows, started, current_src = [], {}, ""
    with open(log_path, errors="replace") as log:
        for line in log:
            match = LINE.match(line.rstrip("\n"))
            if not match:
                continue
            time, tag, body = match.groups()
            if tag is None and not body.startswith("SKIP "):
                continue  # PASS, LRF FALLBACK DIRS, ...
            if tag in ("REPLACING", "DRY-RUN REPLACE"):
                note = NOTE.match(body)
                path, change = note.groups() if note else (body, "")
                result = "overwrote" if tag == "REPLACING" else "would-overwrite"
                rows.append([time, result, "FILE", current_src, path, change])
                continue
            if tag == "FAILED":
                failure = FAILURE.match(body)
                kind, src, dst, reason = failure.groups() if failure else ("?", body, "", "")
                started.pop((src, dst), None)
                rows.append([time, "failed", kind, src, dst, reason])
                continue
            kind, src, dst, reason = ACTION.match(body).groups()
            dst, reason = dst or "", reason or ""
            if tag in ("START", "DRY-RUN"):
                current_src = src
            if tag == "START":
                started[(src, dst)] = (time, kind)
                continue
            if tag == "DONE":
                started.pop((src, dst), None)
            rows.append([time, RESULT[tag], kind, src, dst, reason])
    for (src, dst), (time, kind) in started.items():
        rows.append([time, "unfinished", kind, src, dst, "START logged, no DONE or FAILED"])
    return rows


def main(log_path, out_path):
    rows = parse(log_path)
    with open(out_path, "w", newline="") as out:
        writer = csv.writer(out, delimiter="\t")
        writer.writerow(["time", "result", "kind", "src", "dst", "reason"])
        writer.writerows([field or "-" for field in row] for row in rows)  # '-' keeps columns aligned
    for result, count in sorted(Counter(row[1] for row in rows).items()):
        print("{:<16} {}".format(result, count))
    print("written to", out_path)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: report.py <log of one run> <output.tsv>")
    main(sys.argv[1], sys.argv[2])
