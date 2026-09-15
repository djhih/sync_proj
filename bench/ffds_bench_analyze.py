#!/usr/bin/env python3
"""ffds_bench_analyze.py -- offline analysis of one ffds-bench campaign.

Reads the campaign's results.csv (the portable copy ffds-bench.sh writes
next to SUMMARY.txt) and prints markdown tables:

  1. integrity    every run valid, one cache policy, no interference,
                  one source manifest, v4-smb never touched kernel cifs
  2. cells        every rep per engine x scenario, median, min, max, spread
  3. headline     Q1 cold duration/throughput, Q2 warm files/s, incr
  4. separation   do the engines' rep ranges overlap, per scenario
  5. axes         script axis (v1 vs v3: same rsync, rewritten script)
                  engine axis (v3 vs v4-mount: same kernel cifs session)
                  connection axis (v4-mount vs v4-smb: whole client stack)
  6. order        duration / cell median by the engine's position in its rep
  7. resources    CPU seconds, peak memory, cifs QueryInfo/s

n is 3 per cell, so there are no p-values here.  "separated" means every
rep of one engine beat every rep of the other -- with three reps that is
the strongest statement the data supports.

Usage:  python3 ffds_bench_analyze.py <results.csv>
"""
import csv
import statistics
import sys

ENGINES = ("v1", "v3", "v4-mount", "v4-smb")
SCENARIOS = ("cold", "warm", "incr")
CIFS = ("cifs_create_delta", "cifs_queryinfo_delta", "cifs_close_delta",
        "cifs_reads_delta")
INTS = ("rep", "valid", "source_files_total", "source_size_bytes",
        "cpu_usec", "mem_peak_bytes", "other_sync_running") + CIFS
FLOATS = ("duration_s", "started_ts")


def load(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            for k in INTS:
                r[k] = int(r[k]) if r.get(k) not in (None, "") else None
            for k in FLOATS:
                r[k] = float(r[k]) if r.get(k) not in (None, "") else None
            rows.append(r)
    return rows


def fmt(v, nd=1):
    return "-" if v is None else f"{v:.{nd}f}"


def pct(a, b):
    """a relative to b, signed percent."""
    return None if not a or not b else (a / b - 1) * 100


def table(header, body):
    out = ["| " + " | ".join(header) + " |",
           "| " + " | ".join("---" for _ in header) + " |"]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in body]
    return "\n".join(out)


def main(path):
    rows = load(path)
    valid = [r for r in rows if r["valid"] == 1]
    cells = {}
    for r in valid:
        cells.setdefault((r["engine"], r["scenario"]), []).append(r)
    for rs in cells.values():
        rs.sort(key=lambda r: r["rep"])
    engines = [e for e in ENGINES if any(k[0] == e for k in cells)]
    scenarios = [s for s in SCENARIOS if any(k[1] == s for k in cells)]

    def med(e, s, key="duration_s"):
        vals = [r[key] for r in cells.get((e, s), []) if r[key] is not None]
        return statistics.median(vals) if vals else None

    # ── 1. integrity ────────────────────────────────────────────────────────
    print("## 1. Integrity\n")
    reps = sorted({r["rep"] for r in rows})
    expected = len(reps) * len(engines) * len(scenarios)
    checks = [
        ("runs recorded / expected", f"{len(rows)} / {expected}",
         len(rows) == expected),
        ("valid runs", f"{len(valid)} / {len(rows)}", len(valid) == len(rows)),
        ("cache policy", ", ".join(sorted({r["cache_policy"] for r in rows})),
         len({r["cache_policy"] for r in rows}) == 1),
        ("source manifest", f"{len({r['source_manifest_sha256'] for r in rows})} distinct",
         len({r["source_manifest_sha256"] for r in rows}) == 1),
        ("other sync observed", str(sum(1 for r in rows if r["other_sync_running"])),
         not any(r["other_sync_running"] for r in rows)),
    ]
    smb = [r for r in rows if r["engine"] == "v4-smb"]
    smb_cifs = sum(r[c] or 0 for r in smb for c in CIFS)
    checks.append(("v4-smb kernel cifs ops", str(smb_cifs), smb_cifs == 0))
    print(table(["check", "value", "ok"],
                [(n, v, "yes" if ok else "**NO**") for n, v, ok in checks]))
    bad = [r for r in rows if r["valid"] != 1]
    if bad:
        print("\nInvalid runs (excluded from everything below):")
        for r in bad:
            print(f"- {r['run_id']}: {r['invalid_reasons']}")
    if not all(ok for *_, ok in checks):
        print("\n**Integrity failed -- read the rest as exploratory, not as results.**")

    # ── 2. cells ────────────────────────────────────────────────────────────
    print("\n## 2. Every rep (duration, s)\n")
    body = []
    for s in scenarios:
        for e in engines:
            rs = cells.get((e, s), [])
            d = [r["duration_s"] for r in rs]
            if not d:
                continue
            m = statistics.median(d)
            body.append((s, e, len(d), " / ".join(fmt(x) for x in d),
                         fmt(m), fmt(min(d)), fmt(max(d)),
                         fmt((max(d) - min(d)) / m * 100 if m else None, 0) + "%"))
    print(table(["scenario", "engine", "n", "rep 1 / 2 / 3", "median", "min",
                 "max", "spread"], body))

    # ── 3. headline ─────────────────────────────────────────────────────────
    print("\n## 3. Headline\n")
    any_row = valid[0] if valid else rows[0]
    files, size = any_row["source_files_total"], any_row["source_size_bytes"]
    print(f"Source: {files} files, {size / 1e9:.2f} GB "
          f"(mean {size / files / 1e3:.0f} KB/file)\n")
    body = []
    for e in engines:
        c, w, i = med(e, "cold"), med(e, "warm"), med(e, "incr")
        body.append((e, fmt(c), fmt(size / c / 1e6 if c else None),
                     fmt(files / c if c else None, 0),
                     fmt(files / w if w else None, 0), fmt(i)))
    print(table(["engine", "Q1 cold median (s)", "cold MB/s", "cold files/s",
                 "Q2 warm files/s", "incr median (s)"], body))

    # ── 4. separation ───────────────────────────────────────────────────────
    print("\n## 4. Separation (all reps of one engine beat all reps of the other?)\n")
    body = []
    for s in scenarios:
        for a in range(len(engines)):
            for b in range(a + 1, len(engines)):
                ea, eb = engines[a], engines[b]
                da = [r["duration_s"] for r in cells.get((ea, s), [])]
                db = [r["duration_s"] for r in cells.get((eb, s), [])]
                if not da or not db:
                    continue
                if max(da) < min(db):
                    verdict = f"{ea} faster, separated"
                elif max(db) < min(da):
                    verdict = f"{eb} faster, separated"
                else:
                    verdict = "ranges overlap"
                body.append((s, f"{ea} vs {eb}",
                             fmt(pct(statistics.median(db), statistics.median(da))) + "%",
                             verdict))
    print(table(["scenario", "pair", "2nd vs 1st median (+ = 2nd slower)", "verdict"], body))

    # ── 5. axes ─────────────────────────────────────────────────────────────
    print("\n## 5. Axes (positive = slower)\n")
    body = []
    for s in scenarios:
        body.append((s, fmt(pct(med("v3", s), med("v1", s))) + "%",
                     fmt(pct(med("v4-mount", s), med("v3", s))) + "%",
                     fmt(pct(med("v4-smb", s), med("v4-mount", s))) + "%"))
    print(table(["scenario", "script axis: v3 vs v1",
                 "engine axis: v4-mount vs v3",
                 "connection axis: v4-smb vs v4-mount"], body))
    policy = {r["cache_policy"] for r in rows}
    print("\n- Script axis is the legacy baseline: both are rsync over the "
          "same kernel cifs session, so it prices the v3 rewrite itself "
          "(one tree walk with --chown/--chmod vs v1's rsync + four find "
          "sweeps, and -z dropped).")
    print("- Engine axis is the clean single-factor comparison: same kernel "
          "cifs session, only rsync vs rclone changes.")
    print("- Connection axis swaps the whole client stack (kernel cifs vs "
          "go-smb2): corroborates the shared-session direction, cannot "
          "attribute to a single factor.")
    if policy == {"retain"}:
        print("- cache_policy=retain: mount engines re-read source content from "
              "the local page cache, v4-smb always fetches it over the network. "
              "The connection axis is biased AGAINST v4-smb -- a v4-smb win is a "
              "lower bound on its advantage.")

    # ── 6. order ────────────────────────────────────────────────────────────
    print("\n## 6. Order effect (duration / cell median, by engine position in rep)\n")
    pos = {}
    for rep in reps:
        firsts = {}
        for r in valid:
            if r["rep"] == rep:
                firsts[r["engine"]] = min(firsts.get(r["engine"], r["started_ts"]),
                                          r["started_ts"])
        for i, e in enumerate(sorted(firsts, key=firsts.get), 1):
            pos[(rep, e)] = i
    body = []
    for s in scenarios:
        by = {}
        for r in valid:
            m = med(r["engine"], s)
            if r["scenario"] == s and m:
                by.setdefault(pos[(r["rep"], r["engine"])], []).append(r["duration_s"] / m)
        body.append((s, *(fmt(statistics.mean(by[p]), 3) if p in by else "-"
                          for p in range(1, len(engines) + 1))))
    print(table(["scenario", *(f"{p}." for p in range(1, len(engines) + 1))],
                body))
    print("\n1.000 = typical. A position consistently above 1 (e.g. 1st in cold) "
          "is an order effect; the Latin-square rotation balances it across "
          "engines, but report it.")

    # ── 7. resources ────────────────────────────────────────────────────────
    print("\n## 7. Resources (medians of valid runs)\n")
    body = []
    for s in scenarios:
        for e in engines:
            rs = cells.get((e, s), [])
            if not rs:
                continue
            cpu = [r["cpu_usec"] / 1e6 for r in rs if r["cpu_usec"] is not None]
            mem = [r["mem_peak_bytes"] / 2**20 for r in rs if r["mem_peak_bytes"] is not None]
            qi = [r["cifs_queryinfo_delta"] / r["duration_s"] for r in rs
                  if r["cifs_queryinfo_delta"] is not None and r["duration_s"]]
            body.append((s, e,
                         fmt(statistics.median(cpu) if cpu else None),
                         fmt(statistics.median(mem) if mem else None, 0),
                         fmt(statistics.median(qi) if qi else None, 0)))
    print(table(["scenario", "engine", "CPU (s)", "peak mem (MiB)",
                 "cifs QueryInfo/s"], body))
    print("\ncifs counters are host-wide: non-zero on v4-smb would mean another "
          "process used the mount during that run.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
