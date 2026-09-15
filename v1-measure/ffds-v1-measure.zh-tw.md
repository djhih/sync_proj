# ffds-v1-measure — 用 bench 的口徑量現行 v1(`sync_ffds.sh`)

目的:在**不改 bench** 的前提下,讓現行 v1 跑出和 v3/v4 campaign 同名、同定義的數字
(`duration_s`、`files_transferred`、cgroup CPU/記憶體、cifs 操作數……),可以並排比較。

```
ffds-v1-measure.sh -p <subpath> [-r reps=3] [-o outdir] [-s v1-script]
                   [--scenarios cold,warm,incr] [--incr-files N=100]
                   [--no-drop-caches] [--keep-dst] [--force]
                   [--run-timeout seconds=7200]
```

## 步驟 0 — 佔位符替換(必做)

本 repo 是公開的,站點值都是佔位符(規則同 [`../DEPLOY.zh-tw.md`](../DEPLOY.zh-tw.md) 步驟 0)。
在目標機的 clone 上替換這些**功能行**:

| 檔案 | 行(key) | 佔位符 |
| --- | --- | --- |
| `v1-measure/ffds-v1-measure.sh` | `srcRoot=`、`scratchBase=`、`expectMount=` | `/mnt/src-share/DataSet`、`/mnt/dst-fs/…` |
| `v1-measure/ffds_v1_measure.py` | `V1_SRC_ROOT =`、`V1_DST_ROOT =` | v1 腳本裡**原樣出現**的來源 / 目的端根目錄(改寫錨點,必須逐字相同) |
| 同上 | `DATASET =` | `"DataSet"`(須與 `bench/ffds_bench_data.py` 的 `DATASET` 一致) |

```bash
sed -i "s|/mnt/src-share|<來源掛載點>|g; s|/mnt/dst-fs|<目的掛載點>|g; \
        s|DataSet|<資料集目錄名>|g" \
    v1-measure/ffds-v1-measure.sh v1-measure/ffds_v1_measure.py
git diff        # 逐行確認只改到預期的 key
```

`V1_*_ROOT` 對不上目標機的 v1 時,腳本會在產生副本那一步拒絕(錨點數量不符),不會誤跑。
`bench/ffds-bench.sh` 以 v1 為引擎時用的也是這支 instrumenter,所以這裡沒替換,bench 的 v1 引擎也會拒絕。

## 跟 bench 的關係

**v1 現在也是 bench 的引擎之一**(`ffds-bench.sh --engines v1,v3,v4-mount,v4-smb`),
用的是這裡的 `instrument --events-log`。兩者的分工:

| | bench 的 v1 引擎 | 這支獨立工具 |
| --- | --- | --- |
| 何時用 | 要和 v3/v4 並排比較(同一份來源、同一個 campaign、引擎順序輪轉) | 只想量 v1,不想開整個 campaign |
| 結果去處 | bench 的結果目錄 → :9760 exporter → Grafana | 自己的 outdir(`results.csv`) |
| 額外欄位 | 無 | `time -v` 的 `time_*` |


- bench 的 [`ffds_bench_data.py`](../bench/ffds_bench_data.py) 只被**呼叫**
  (`manifest`、`select-incr`、`verify-dst`、`scope-worker`)和**唯讀 import**,一行都沒改。
  所以 manifest sha、目的端驗證、scope 資源帳的定義和 bench 完全相同。
- incr 情境用和 bench 相同的選檔規則(同 manifest、同 N、seed = rep):
  v1 的 rep N 刪的檔,和 bench campaign 的 rep N 是同一批。
- 目錄結構需要 `v1-measure/` 和 `bench/` 並排(`benchData=` 可以改)。

## 跑的是 v1 的「改寫副本」,不是 v1 本身

改寫只動這些(`<outdir>/v1-instrument.diff` 可以逐行核對):

| 動了什麼 | 為什麼 |
| --- | --- |
| 目的端變數(值為 `/mnt/dst-fs/DataSet` 的那一行,依值定位、不依變數名)→ `/mnt/dst-fs/ffds-v1-measure/<id>/DataSet` | 不寫 production 目的端 |
| log `/var/log/rsync-smb*.log` → `<outdir>/v1log/` | v1 用 `>` 寫 log,會蓋掉 production 的 |
| rsync 加 `--stats` | 只多印結尾摘要,才拿得到 `files_transferred` |
| 3 行 `V1MEASURE` 標記(rsync 前、rsync 後含 rc、find 掃完) | 切出 rsync / fixup 兩段時間 |
| 結尾 `exit ${v1mRc:-93}` | v1 自己永遠 exit 0(rsync 的 rc 被吞掉);93 = v1 的 pgrep 檢查跳過了工作 |

其餘一律原樣:`rsync -avzhP --no-owner --no-group --delete`、4 次 find(含寫反的 chown 判斷)、
pgrep 互斥檢查、log 導向。v1 的形狀對不上(錨點數量不符、第 1 行不是 `#!/bin/bash`)
就拒絕產生副本,不猜。從終端機複製貼上的擷取(第 1 行是 prompt)會被拒絕——請直接用目標機上的檔案。

## 每輪的量測層次

```
systemd-run --scope
  └─ bench scope-worker   → resource.json:elapsed_s、cpu_usec、io_*、mem_peak_bytes
      └─ /usr/bin/time -v → time.txt(沒裝就 null;apt install time)
          └─ 改寫副本 <subpath>
```

## 輸出

`<outdir>/`(預設 `/root/ffds-v1-measure-<id>/`):`results.csv`、`SUMMARY.txt`、`meta.json`、
`run.log`、`interference.log`、`preflight-*.txt`、`source-manifest.json`、`incr-repN.json`、
`v1-instrument.diff`,以及每輪的 `runs/<run>/`
(`result.json`、`job.log`〔v1 自己的 log〕、`time.txt`、`resource.json`、`verify.json`、`cifs.pre/post`)。

`result.json` 欄位(和 bench 同名者定義相同):

| 分類 | 欄位 |
| --- | --- |
| 時間 | `duration_s`、`engine_s`(= rsync 段)、`fixup_s`(= 4 次 find)、`started_ts`/`finished_ts` |
| 傳輸 | `files_transferred`、`files_deleted`、`files_created`、`rsync_files`、`rsync_total_size`、`rsync_transferred_size`、`rsync_listgen_s`、`rsync_speedup` |
| 來源 | `source_files_total`、`source_dirs_total`、`source_size_bytes`、`source_manifest_sha256` |
| 資源(scope) | `cpu_usec`、`io_rbytes`、`io_wbytes`、`mem_peak_bytes`、`resource_complete`/`missing` |
| `time -v` | `time_elapsed_s`、`time_user_s`、`time_sys_s`、`time_max_rss_kb`、`time_fs_inputs/outputs`、`time_vol_cs`/`invol_cs`、`time_exit` |
| CIFS | `cifs_create/queryinfo/close/reads/reconnects_delta` |
| 正確性 | `valid`、`invalid_reasons`、`job_ran`、`rsync_exit`、`script_exit`、`worker_exit`、`destination_verified`、`source_unchanged` |
| 環境 | `cache_policy`、`drop_caches_ok`、`other_sync_running`、`interference_observation_ok`、`v1_script_sha256` |

`valid=1` 條件:job 真的有跑(3 個標記都在)、`rsync_exit=0`、script/worker exit 為 0 且一致、
duration>0、來源前後 manifest 相同、目的端驗證通過(size + mode 775)、沒有其他 sync、
drop policy 時 drop_caches 成功、傳輸數符合情境(cold = 來源檔數、warm = 0、incr = N)且刪除數 0。
rsync 失敗或 job 沒跑 → 保存該輪後停止。

## sync-host runbook

```bash
# 0. 窗口:v1 由 cron 觸發——先看 crontab -l,避開 sync_all.sh 的時間;
#    無人用 /mnt/src-share;drop_caches 是全主機生效
# 1. 煙霧:小 subpath、只跑 cold
./ffds-v1-measure.sh -p <小subpath> -r 1 --scenarios cold
cat /root/ffds-v1-measure-*/v1-instrument.diff      # 確認只改了上表那幾處
# 2. 正式:和 bench campaign 同一個 subpath、同 cache policy、同 --incr-files
./ffds-v1-measure.sh -p <subpath> -r 3
```

## 判讀注意

- **權限來回改**:`-a` 含 `-p`,每輪 rsync 把 mode 改回 cifs 來源端的值,find 再改回 775。
  若 `/mnt/src-share` 的 `file_mode` 不是 0775,warm 的 `fixup_s` 會吃掉大部分時間——這是 v1 的真實成本。
- **chown 判斷寫反**(`-eq 0`):chown 實際上從不作用;verify-dst 不查 owner,不影響 valid。
- **subpath 深度**:production 的上層目錄一定存在,所以每輪前(不計時)先 `mkdir -p` 上層;
  rsync 只建最後一層,和 production 相同。
- `mem_peak_bytes` 是 cgroup `memory.peak`,含 page cache;`time_max_rss_kb` 是單一行程 RSS,兩者不能互比。
- `cifs_*_delta` 是全主機計數器,非零可能來自別的程序。

## 驗證狀態(2026-09-14,本機 sandbox)

[`../test/ffds-v1-measure-local-test.sh`](../test/ffds-v1-measure-local-test.sh) **65/65**:
v1 原文放在 [`../test/fixtures/v1/sync_ffds.sh`](../test/fixtures/v1/sync_ffds.sh)(站點值已換成佔位符,邏輯逐行保留),
搭配真的會同步的 rsync shim + GNU time / systemd shim。
涵蓋完整 cold/warm/incr × 2 reps 全 valid、diff 只動預期行、深度 3 的 subpath、
rsync 回 23 → 副本傳出 23、invalid 並停止、v1 的 pgrep 檢查跳過 job → exit 93 且 invalid、干擾預檢拒絕、
拒絕貼上的非腳本檔。**真 rsync、真 systemd scope、真 cifs 尚未驗證**(本機沒有 rsync)——
sync-host 煙霧測試時確認 `--stats` 摘要解析與 `resource.json` 數值。
