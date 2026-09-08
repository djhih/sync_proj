# ffds_sync.sh v3 測試項目

受測物:[`ffds-sync-v3.sh`](../ffds-sync-v3.sh)(部署名 `ffds_sync.sh`)、
[`ffds-sync.service`](../ffds-sync.service) / [`ffds-sync.timer`](../ffds-sync.timer)、
`events.log` 契約、與 [`ffds_sync_monitor.py`](../../sync_monitor/ffds_sync_monitor.py)
的整合。設計與取捨見 [`ffds-sync-v3.zh-tw.md`](../ffds-sync-v3.zh-tw.md)。

**不在範圍**:2×2 SMB stall 實驗、SMB 端吞吐與 stall 行為、monitor 側的
alert 規則與 dashboard(另案收尾)。

## 測試層級

| 層級 | 在哪 | 怎麼跑 | 碰真實資料 | 狀態 |
| --- | --- | --- | --- | --- |
| **L1 本機自動** | 開發機 | [`ffds-sync-local-test.sh`](ffds-sync-local-test.sh),rsync 換成 shim | 否 | 2026-09-03 **127/127**(bash 5.3、gawk 5.4;真 rsync 層略過) |
| **L2 目標機自動** | sync-host | 同一支 harness(真 rsync 層會跑;mawk、bash 5.2) | 否,全在 scratch | 待跑,**隨時可跑** |
| **L3 目標機手動** | sync-host | 真掛載 + systemd | 是 | 待跑,需要窗口 |
| **L4 上線觀察** | sync-host | 手動 `systemctl start` 幾輪 → timer | 是 | 待跑 |

L3 / L4 的窗口條件:

1. **舊 cron 鏈停掉或避開它的時段**。v3 的 flock 只認 v3 自己;舊
   `sync_ffds.sh` 的 rsync 同時跑同一個 subpath 就是真的重疊。
2. **2×2 實驗把「sync 有沒有在跑」當變因**,L3 / L4 都是真的 sync 流量,
   要排在實驗結束後,或排進協調好的窗口。
3. 先過 A5、B5(部署檔內的固定路徑與 `/etc/sync_paths.conf`)。

## 怎麼跑 harness

```bash
bash sendout/test/ffds-sync-local-test.sh                  # exit 0 = 全過
FFDS_TEST_KEEP=1 bash sendout/test/ffds-sync-local-test.sh # 保留 scratch,可拿 events.log 餵 monitor
```

- 目錄結構是硬的:`<root>/sendout/ffds-sync-v3.sh`、`<root>/sendout/test/`、
  `<root>/sync_monitor/ffds_sync_monitor.py`。搬到 sync-host 時 `sendout/` 與
  `sync_monitor/` 一起搬。
- 需要 bash ≥ 4.4、flock、stdbuf、awk、python3。**以一般使用者跑**
  (T17 的唯讀目錄案例 root 會略過;真 rsync 層 `--chown` 會改成自己)。
  沒有 tty 時(`ssh host bash …`)T9 / T19 用到 `set -m`,異常就改 `ssh -t`。
- 有 rsync 時 T15 多 7 項 → 預期 **134**;沒有時 127。
- 開頭會印 `bash X, awk Y`,把這行抄進紀錄表。

## 測試項目

狀態欄:✅ L1 已過(括號內是 harness 案例)、⏳ 待目標機、◇ 選作、👁 只能觀察。

### A. 靜態與參數

| # | 項目 | 操作 | 預期 | 狀態 |
| --- | --- | --- | --- | --- |
| A1 | 語法 | `bash -n ffds_sync.sh` | 無輸出 | ✅ T0 |
| A2 | unit 檔語法 | `systemd-analyze verify ffds-sync.service ffds-sync.timer` | 安裝前只抱怨 ExecStart 的檔不存在;sync-host 安裝後無輸出 | ✅ 本機手動 / ⏳ G1 |
| A3 | 用法 | `ffds_sync.sh bogus`;`ffds_sync.sh` | usage 到 stderr、exit 90;無參數 = `status` | ✅ T2, T13 |
| A4 | 旋鈕清洗 | `FFDS_SYNC_JOBS=abc all`;`FFDS_PROGRESS_EVERY=0 one A`;`FFDS_RSYNC_TIMEOUT=0`;`FFDS_RSYNC_EXTRA="--bwlimit=50m --dry-run"` | `batch_start … jobs=1`;filter 存活、有 `job_stats`、stderr 無 awk 錯誤;argv 無 `--timeout`;flags 接在 `--outbuf=N --timeout=…` 之後 | ✅ T14 |
| A5 | 部署檔的 fixed config | `sed -n '/Fixed configuration/,/^# ─/p' /usr/local/ffds/ffds_sync.sh` | `srcRoot` `dstRoot` `mountpoints` `logDir` `config` `lockDir` `fileOwner` 與 sync-host 實際一致(harness 只證明改寫機制,不證明正式值) | ⏳ |

### B. subpath 驗證與 config

| # | 項目 | 操作 | 預期 | 狀態 |
| --- | --- | --- | --- | --- |
| B1 | 空字串 / 含空白 | `one ""`;`one "a b"` | 90;事件成對 `subpath=?` / `subpath=a_b`,`duration=0`;rsync 未被呼叫 | ✅ T2 |
| B2 | 拒絕清單 | `/abs` `../x` `a/../b` `trail/` `.` `./x` `x/.` `'a\tb'`(反斜線) | 全部 90,rsync 未被呼叫;`a..b` 是合法名稱 → 0 | ✅ T2 |
| B3 | config 缺 / 空 | 檔案不存在;只有註解、空行、CRLF | 93 + `batch_abort reason=config-missing` / `config-empty`,無 `batch_start` | ✅ T6 |
| B4 | config 容錯 | 內容 `"# c\r\n  A  \r\n"` | 解析為 `A`,`batch_end ok=1 fail=0 total=1`,exit 0 | ✅ T6 |
| B5 | 正式 config 檢查 | `grep -vE '^\s*(#\|$)' /etc/sync_paths.conf \| sed 's/\r$//' \| while read -r s; do printf '%s -> ' "$s"; test -d "/mnt/src-share/DataSet/$s" && echo ok \|\| echo MISSING; done` | 每行 ok;沒有會被 B2 拒絕的行(每個壞行每晚燒一個 90) | ⏳ |

### C. 前置檢查(每一種失敗都有自己的碼與事件)

| # | 項目 | 操作 | 預期 | 狀態 |
| --- | --- | --- | --- | --- |
| C1 | 掛載缺 | 複本 `mountpoints=(/ /nonexistent)`;`one A`、`all` | `one`:`job_start` + `job_end exit=91 duration=0`,無 rsync;`all`:91 + `batch_abort reason=mount-missing mountpoint=…` | ✅ T3 |
| C2 | job lock 忙 | 外部 `flock` 持鎖 → `one A`;放掉再跑 | 92 + `job_end exit=92 duration=0`;放掉 → 0 | ✅ T4 |
| C3 | batch lock 忙 | 外部持 `ffds-sync-all.lock` → `all` | 92 + `batch_abort reason=lock-busy`,無 `batch_start`;放掉 → 0 | ✅ T5 |
| C4 | rc 目錄建不出來 | `TMPDIR=/nonexistent all` | 90 + `batch_abort reason=tmp-failed`,無 worker 被 spawn | ✅ T16 |
| C5 | log 目錄唯讀 | 複本 `logDir=<唯讀>/log` | `one`、`all` 都 90,stderr `cannot create directory`,無事件、無 rsync | ✅ T17(root 略過) |
| C6 | lock 目錄不存在 | 複本 `lockDir=/nonexistent` | `one`:`job_start` + `job_end exit=90`,stderr `cannot open lock file`;`all`:90、無事件 | ✅ T17 |
| C7 | C4–C6 在 systemd 下 | 見 G3 | strict sandbox 由 `PrivateTmp` / `LogsDirectory` / `ReadWritePaths` 補齊,不該看到 C4–C6 任一種 | ⏳ G3 |

### D. 單一 job

| # | 項目 | 操作 | 預期 | 狀態 |
| --- | --- | --- | --- | --- |
| D1 | 事件序列 | `FFDS_PROGRESS_EVERY=2 one A`(shim 印 6 行 progress) | `job_start → job_progress×3 → job_stats → job_end exit=0 duration=N`;四種事件同一個 `run=`;手動跑無 `batch=`;stdout、stderr 都空 | ✅ T1 |
| D2 | progress 三種行型 | 有 `(xfr#…, ir-chk=…)`、無尾巴、`to-chk=` | `bytes= pct= speed= eta=` 皆對;`xfr=123 chk=456/789`;無尾巴時沒有 xfr / chk;`chk=0/812` | ✅ T1 |
| D3 | stats 欄位 | stats2 區塊 | `files=1,234 created=5 deleted=2 transferred=7 size=1.23G listgen=0.001 speedup=2,345.67` | ✅ T1 |
| D4 | dry-run 尾碼 | `FFDS_RSYNC_EXTRA=--dry-run`(rsync -n 在最後兩行加 ` (DRY RUN)`) | `speedup=2,345.67`,不是 `RUN)` | ✅ T14 |
| D5 | 節流與 job log | 同 D1 | job log 留 3/6 行 progress、留 name1 / del1 行(`deleting old/stale.bin`)、`=== RUN … subpath=A ===` 與 `=== END … exit=0 duration=Ns subpath=A ===`;`B/C` 寫到 `jobs/B_C.log` | ✅ T1, T7 |
| D6 | rsync 參數 | 看 shim 記下的 argv | 恰為 `-ah --delete --chown=<owner> --chmod=D775,F775 --info=progress2,stats2,name1,del1 --outbuf=N --timeout=1800 <src>/A <dst>/`;`B/C` 的目的地是父層 `<dst>/B/`,父層被建立 | ✅ T1, T7 |
| D7 | 結束碼傳遞 | shim exit 23 / 30 | `one` 以 23 / 30 結束,`job_end exit=23` / `exit=30` | ✅ T10 |
| D8 | journal 鏡射 | `JOURNAL_STREAM=1:2 one A`;未設時跑 `all` | stdout 與 events.log 新增的 `job_start` / `job_end` 行逐位元相同,progress / stats 不鏡射;未設 → stdout 空,且 `all` 成功仍 exit 0 | ✅ T11 |
| D9 | status | `ffds_sync.sh status` | 0;有 `recent events` 段、列出 `jobs/A.log`;sync-host 上跑中的 job 標 `ACTIVE`、pgrep 段列出 rsync | ✅ T13 / ⏳ |

### E. 批次

| # | 項目 | 操作 | 預期 | 狀態 |
| --- | --- | --- | --- | --- |
| E1 | jobs=1 順序 | config `A` `B/C` `/bad` | `batch_start total=3 jobs=1`;三對 job 事件都帶 `batch=<pid>`;無交錯(A 結束才 B/C 開始);`/bad` → 90;`batch_end ok=2 fail=1 total=3`;exit 1;rc 暫存目錄已清 | ✅ T7 |
| E2 | jobs=2 + 重複行 | config `dup` `dup` `A`,shim 睡 2 s | `jobs=2`;dup 一個 0 一個 92;`ok=2 fail=1 total=3`(ok+fail == total);exit 1 | ✅ T8 |
| E3 | 批次結束碼 | 全成功 / 有失敗 / worker 沒回報 rc | 0 / 1 / 1 | ✅ T6, T7, T19 |

### F. 訊號

| # | 項目 | 操作 | 預期 | 狀態 |
| --- | --- | --- | --- | --- |
| F1 | 整個 process group 收 SIGTERM(= systemd 的 control-group kill) | `set -m` 起 `all`,`kill -TERM -- -<pid>` | exit 94;`batch_abort reason=signal`;無 `batch_end`、無 `job_end`;rc 目錄已刪;rsync 無存活 | ✅ T9 |
| F2 | 只殺 batch(手動 `kill -TERM <batch pid>`) | shim 睡 4 s;殺 batch 主程序 | 94 + abort;worker 被 trap 殺掉;rsync / filter 變孤兒繼續跑並持有 job lock → 期間同 subpath `one A` 得 92;孤兒結束時 filter 仍寫出該 run 的 `job_stats`,但永遠沒有 `job_end`;之後 `one A` → 0。這是文件寫的已知限制,測的是「行為如文件所述」 | ✅ T18 |
| F3 | worker 被 SIGKILL(U1 探針) | jobs=1、config `A` `B/C`,對 A 的 worker `kill -KILL` | **bash 5.3**:batch 繼續、B/C 跑完、`batch_end ok=1 fail=0 total=2`、exit 1、A 沒有 `job_end`。**bash 5.2**:若 `wait -n` 漏接,harness 等 20 s 後判 FAIL 並 group-kill(T19 會有 4 項 FAIL;T12 已把多出來的 signal abort 算進去)。那就是 U1 成立的證據,對策維持 `TimeoutStartSec` 當 backstop,不改碼 | ✅ T19(5.3)/ ⏳ 5.2 |

### G. systemd 整合(L3)

| # | 項目 | 操作 | 預期 | 狀態 |
| --- | --- | --- | --- | --- |
| G1 | 安裝與驗證 | 照設計文件安裝(**timer 不 enable**);`systemctl daemon-reload`;`systemd-analyze verify ffds-sync.service ffds-sync.timer`;`systemctl is-enabled ffds-sync.timer` | verify 無輸出;timer 是 `disabled`;`systemctl cat ffds-sync` 內容正確 | ⏳ |
| G2 | 手動整批 | `systemctl start ffds-sync; journalctl -u ffds-sync -f` | journal 有 batch_start / job_start / job_end / batch_end,與 events.log 同一行;`systemctl status` 的 main process `status=0`(全成功)或 `status=1`;跑中 `ffds_sync.sh status` 標 ACTIVE | ⏳ |
| G3 | sandbox | G2 之後 `ls -ld /var/log/ffds-sync /var/log/ffds-sync/jobs`、`ls /run/lock/ffds-sync-*`、`journalctl -u ffds-sync -p warning` | log 目錄由 `LogsDirectory` 建、root 擁有;lock 檔存在;沒有 `tmp-failed`、沒有 `Read-only file system`;rsync 寫 `/mnt/dst-fs` 正常 | ⏳ |
| G4 | 重疊防護 | 批次跑中:再 `systemctl start ffds-sync`;shell 直接跑 `ffds_sync.sh all`;`ffds_sync.sh one <跑中的 sub>` | 第二次 start 不會起第二個批次(同一個 job);shell 的 `all` → 92 + `batch_abort lock-busy`;`one` → 92;跑中的批次不受影響(monitor 的 running 不變) | ⏳ |
| G5 | 中止 | 批次跑中 `systemctl stop ffds-sync` | journal / events.log 有 `batch_abort reason=signal`;`pgrep rsync` 無;`systemctl status` 顯示 `status=94`;下一次 start 正常(lock 已釋放) | ⏳ ◇ |
| G6 | TimeoutStartSec | drop-in:`mkdir -p /etc/systemd/system/ffds-sync.service.d; printf '[Service]\nTimeoutStartSec=90s\n' > /etc/systemd/system/ffds-sync.service.d/override.conf; systemctl daemon-reload`;start;事後刪 drop-in 再 daemon-reload | 90 s 後與 G5 同結果,journal 有 `start operation timed out`;rsync 收 SIGTERM 會自己清掉暫存檔(`.<name>.XXXXXX`) | ⏳ ◇(會中斷一次真同步) |
| G7 | RequiresMountsFor | 不主動 umount 來測;掛載真的掉的時候觀察 | unit 根本不啟動(`Dependency failed`),events.log 無紀錄,只有 journal 與 `batch_last_completed_timestamp_seconds` 老化 | 👁 |
| G8 | cgroup 帳 | 跑中 `systemd-cgls -u ffds-sync.service`;`systemctl show -p CPUUsageNSec -p IOReadBytes -p IOWriteBytes ffds-sync` | cgroup 內有 batch / worker / rsync / awk;計數在長;cgroup-exporter 看得到 `ffds-sync.service` | ⏳ |
| G9 | timer(填好 `OnCalendar` 後) | `systemd-analyze calendar "<OnCalendar>"`;`systemctl enable --now ffds-sync.timer`;`systemctl list-timers ffds-sync.timer` | 下次觸發時間正確(加 `RandomizedDelaySec` 5 分內);隔天 events.log 有 `batch_start`、job 事件帶 `batch=`;開機不補跑(`Persistent=false`,只能觀察) | ⏳ L4 |
| G10 | logrotate | `logrotate -d /etc/logrotate.d/ffds-sync`(乾跑);閒置時 `logrotate -f /etc/logrotate.d/ffds-sync`;再跑一個 `one` | 乾跑無錯;rotate 後 events.log 被截斷、`events.log.1` 存在;monitor **不重啟**仍讀到新事件(`parse_errors_total` 不變、`events_total` 續增) | ⏳ ◇ |

### H. 真 rsync 與資料正確性

| # | 項目 | 操作 | 預期 | 狀態 |
| --- | --- | --- | --- | --- |
| H1 | harness 真 rsync 層 | sync-host 上跑 harness(有 rsync 才會跑 T15) | 第一次 `transferred=3`、預埋的 stale 檔被 `--delete` 清掉、`diff -r` 相等;第二次 `transferred=0`;檔案 mode 775 | ⏳ L2 |
| H2 | **上線前乾跑,每個 subpath** | `FFDS_RSYNC_EXTRA=--dry-run /usr/local/ffds/ffds_sync.sh one <sub>`(root);看 `jobs/<sub>.log` 的 `deleting` 行與 `job_stats deleted=` | 刪除數量與清單合理——這是 `--delete` 的保險絲:srcRoot 打錯或 share 半掛時,真跑會一次把 dst 清空。順便得到每個 subpath 的 `files=` / `size=` 基準。乾跑也會寫 `job_end exit=0`,monitor 會當一次成功,上線前無妨 | ⏳ **必做** |
| H3 | 第一次真跑(小 subpath) | `one <小 sub>`;`tail -f jobs/<sub>.log` | exit 0;`find /mnt/dst-fs/DataSet/<sub> \( ! -user root -o ! -group datasetgrp -o ! -perm 775 \) \| head` 為空(舊三趟 find 的工作已由 `--chown/--chmod` 在同一趟做完);job log 有逐檔 name1 | ⏳ |
| H4 | 穩態(立刻再跑一次) | 跑前後對幾個檔 `stat -c '%n %Z'` | `transferred=0 created=0 deleted=0`;ctime 不變(v2 每晚翻兩次權限,ctime 天天變)——設計文件「穩態零 metadata 寫入」的實證 | ⏳ |
| H5 | 偽 exit 30 | 上線前幾夜看 `ffds_sync_runs_total{exit_code="30"}`,對照 job log 最後一筆 progress 的時間 | 零筆;掃描期長、無 progress 而出現 30 → 調大 `FFDS_RSYNC_TIMEOUT`,不要關掉 | 👁 L4 |
| H6 | rsync 原生失敗碼 | 觀察 23(部分)/ 24(來源檔消失) | `job_end exit=` 帶碼、批次繼續、`batch_end fail=` 計入、unit exit 1 | 👁 L4 |
| H7 | 耗時對照 | 舊 `/var/log/sync_all.log` 的 START→SUCCESS 間隔 vs `job_end duration=` | 每個 subpath 記一組數字;預期 ≤ v2(少三趟樹遍歷),但 SMB stall 支配的 subpath 不會變快——這是預期,不是缺陷 | 👁 L4 |

### I. monitor 整合

| # | 項目 | 操作 | 預期 | 狀態 |
| --- | --- | --- | --- | --- |
| I1 | 整份 harness log | T12:餵 `State`、`render_metrics()` | `parse_errors == {}`;batch / jobs 全關;各 subpath 的 `runs`(A:0×≥5、23、30、91、90、92×2;`?` / `a_b` / `/bad`:90;`B/C`:0×2;`dup`:0 與 92);六種 abort 原因計數;`/metrics` 含 runs_total、aborts、last_run_exit_code、events_total、log_last_event_timestamp | ✅ T12 |
| I2 | HTTP scrape | `FFDS_TEST_KEEP=1` 跑 harness,另起 `FFDS_SYNC_EVENT_LOG=<scratch>/log/events.log FFDS_SYNC_LISTEN=127.0.0.1:19756 ffds_sync_monitor.py`,`curl /metrics` | 19 個 family;值與 I1 一致 | ✅ 2026-09-03 |
| I3 | sync-host 跑中 | `curl -s localhost:9755/metrics \| grep -E 'all_running\|jobs_running\|job_active\|job_last_activity'`;`/status` | `all_running 1`、`jobs_running 1`、`job_active{subpath,phase}` 正確,`job_last_activity_timestamp_seconds` 隨 progress 前進;結束後 `last_result`、`last_run_exit_code`、`batch_last_completed_timestamp_seconds` 更新,`batch_subpaths_completed == config_subpaths` | ⏳ |
| I4 | monitor 重啟 | 批次跑中 `systemctl restart ffds-sync-monitor` | replay 後跑中的 job 仍在(job_start 無 job_end)、歷史結果仍在;`parse_errors_total 0`;counter 重建 Prometheus 視為 reset,`rate()` 可容忍 | ⏳ |
| I5 | 中止後的狀態 | G5 / G6 之後 | `all_running 0`、`jobs_running 0`、`batch_aborts_total{reason="signal"}` +1;lock-busy 的第二個批次不會把跑中的批次關掉 | ✅ T12(彙總)/ ⏳ |
| I6 | rotation 後 | G10 之後 | 同 G10 的 monitor 預期 | ⏳ ◇ |

### J. 回滾

| # | 項目 | 操作 | 預期 | 狀態 |
| --- | --- | --- | --- | --- |
| J1 | 回滾推演 | 停 timer、cron 復原、舊腳本搬回、`ffds-sync-exporter` 換回 | 步驟在設計文件;確認舊 exporter 的 unit 檔還在、cron 行只是註解掉沒刪 | ⏳ ◇ |

## 目標機執行順序

1. 環境:`rsync --version | head -1; bash --version | head -1; awk -W version 2>&1 | head -1; flock --version; python3 --version`,記下。
2. **L2**:搬 `sendout/` + `sync_monitor/`,一般使用者跑 harness → 預期 134 全過(bash 5.2 的例外見 F3)。
3. 安裝(G1),timer 不 enable;monitor `systemctl enable --now ffds-sync-monitor`。
4. A5、B5:檢查部署檔的固定路徑與 config。
5. **H2 乾跑每個 subpath**,看刪除清單。
6. H3 小 subpath 真跑;I3 看 monitor。
7. G2 手動整批(cron 先停);同一輪順便做 G3、G4、G8、I3,再跑一次做 H4。
8. 選作破壞性:G5 → G6 → G10 / I6 → I4。
9. 幾輪正常後填 `OnCalendar`、enable timer(G9);之後 L4 觀察 H5–H7。

## 驗收準則(enable timer 之前)

- 連續 ≥ 3 個手動整批 `batch_end ok=total`、unit `status=0`。
- 沒有未解釋的 exit 23 / 30;H2 的刪除清單與真跑實際刪除一致。
- H3 的 `find` 為空;H4 的 `transferred=0` 且 ctime 不變。
- journal 有生命週期事件、無 sandbox 錯誤(G3)。
- monitor `parse_errors_total 0`,`batch_last_completed_timestamp_seconds` 每輪更新。
- 每個 subpath 的 duration 有記錄(H7 的基準)。

## 紀錄表

| 日期 | 主機 | bash / awk / rsync | 項目 | 結果 | 備註 |
| --- | --- | --- | --- | --- | --- |
| 2026-09-03 | 開發機 | 5.3.15 / gawk 5.4.1 / 無 | L1 全部 | 127/127 | T15 略過;monitor 19 family 抓取 OK(port 19756) |
