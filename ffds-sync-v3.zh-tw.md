# ffds_sync.sh v3 — 整合設計說明

把 sync-host 上的 `sync_all.sh` + `/usr/local/ffds/sync_ffds.sh` 兩支腳本
整合成一支 [`ffds-sync-v3.sh`](ffds-sync-v3.sh)(部署名 `ffds_sync.sh`),
目標:**效率更好**(砍掉重複的樹遍歷與無效功)、**紀錄更好**
(結構化事件 log 作為與監控之間的唯一契約)。

```
ffds_sync.sh all              跑完 /etc/sync_paths.conf 全部 subpath(原 sync_all.sh)
ffds_sync.sh one <subpath>    跑單一 subpath(原 sync_ffds.sh <subpath>)
ffds_sync.sh [status]         看執行中 job 與各 log 最後進度(原 v2 無參數模式)
```

## 架構總覽:三塊、兩個邊界

```
systemd timer ──(何時跑、資源、隔離)──▶ ffds_sync.sh
ffds_sync.sh ──(發生了什麼:events.log)──▶ ffds_sync_monitor.py ──▶ Prometheus
```

- **systemd → 腳本**:排程、cgroup 資源帳(CPU/IO/memory/PSI)、sandbox、
  重疊防護都交給 systemd;腳本只管把一批同步做完。
- **腳本 → monitor**:`../sync_monitor/ffds_sync_monitor.py`
  **只讀 `/var/log/ffds-sync/events.log`**——不碰 `/proc`、不 pgrep、
  不看掛載、不 parse rsync 原始輸出。知道事情的人(腳本)在事情發生的
  當下把它寫下來,監控只是轉述。

這取代了第一版設計(舊 exporter 從 `/proc` + log 尾端往回推狀態,
1068 行、38 個 metric family)。舊 exporter 的複雜度全部來自
「不能動 sync 腳本」的前提;腳本改成自己人之後,那個前提消失,
監控就縮成一支薄的轉述程式。舊檔 `ffds_sync_exporter.py` 保留在
`sync_monitor/` 當歷史紀錄,不再部署。

## 為什麼要改:v1/v2 的帳

每晚一輪,v1/v2 對**每個 subpath** 做了 **4 趟完整樹遍歷**:

| 趟 | 誰 | 做什麼 |
| --- | --- | --- |
| 1 | rsync | 掃描 + 傳輸(SMB 與 WEKA 兩端都要走一次 metadata) |
| 2 | `find` -not -user root … | 修 owner/group |
| 3 | `find` -type f ! -perm 775 | 修檔案權限 |
| 4 | `find` -type d ! -perm 775 | 修目錄權限 |

更糟的是 **permission 拔河**:`-a` 含 `-p`,rsync 每晚把 dst 權限改回
cifs 來源的 mode,接著 find/chmod 再翻回 775 —— 每個檔案每晚兩次
metadata 寫入,資料一個位元都沒變。

其他問題:`-z` 對本機 socketpair 純燒 CPU;`--partial` 在 whole-file
模式下無續傳價值、還把截斷檔暴露在最終檔名;`pgrep | grep` 子字串
誤判(`SubA` 擋掉 `SubA2`);sync_all 自己沒有防重跑;掛載沒預檢
(dst 沒掛上 rsync 會灌進本機根目錄);SMB 一卡 job 永遠吊死;
v2 每次 run 截斷 job log、沒 logrotate、沒 exit code 沒耗時;
`sync_all.sh` 結尾的 `wait` 是死碼。

## v3 設計決策

### 效率

| 決策 | 理由 |
| --- | --- |
| **`--chown=root:datasetgrp --chmod=D775,F775` 取代三趟 find** | rsync 在同一趟掃描裡對**每個檢查到的檔案**(不只有傳輸的)強制 owner 與 mode;跟 dst 現值一致就不動作。4 趟樹遍歷 → **1 趟**,permission 拔河消失(穩態下零 metadata 寫入)。既有錯誤第一輪修正,之後每輪維持。 |
| **拿掉 `-z`** | 本機 socketpair 上壓縮是純 CPU 浪費。 |
| **拿掉 `--no-inc-recursive`** | 增量遞迴讓掃描與傳輸重疊,file list 記憶體有界。代價:progress 總數(ir-chk)邊掃邊長,百分比是近似 —— 精確總數在 stats2 結尾摘要。 |
| **`--timeout=1800`(可調,0 關閉)** | 掛載卡死 → rsync 以 exit 30 收場而不是永遠吊著;批次繼續下一個 subpath。也是日後 soft → hard mount 的配套(見 stall report 一節)。 |
| **拿掉 `--partial`** | 無續傳價值 + 暴露截斷檔。 |
| **`FFDS_SYNC_JOBS=N` 選擇性平行** | 預設 1。stall report 證明 SMB 路徑 latency-bound、並行度近線性放大 —— 但**先等 2×2 實驗定罪再開**(若結論是 sync 壓垮 pool,正確動作是限速不是加併發)。 |

### 正確性 / 強健性

| 決策 | 理由 |
| --- | --- |
| **flock 取代 pgrep** | per-subpath lock + 批次 lock,子字串誤判消失。**附帶的正確行為**:lock fd 被 rsync 子程序繼承,若 rsync 卡死在 D-state、worker 已退出,lock 仍被持有 —— 隔晚同 subpath 拿到 FAIL(92) 而不是疊上去跑;卡死的 rsync 消失後自動解鎖。 |
| **掛載預檢只讀 `/proc/mounts`** | 對可能卡死的掛載做 stat 自己也會卡死(stall report 實測單一 read 可卡 5.5s)。 |
| **subpath 驗證** | 拒絕空值、絕對路徑、`..`、尾斜線、空白(事件 log 的值以空白分隔)。壞行記 `job_end exit=90`,看得見、不靜默跳過。 |
| **批次 worker 用 `"$self" one <sub> &` 起新 process** | 每個 job 有自己的 pid(= 事件的 `run=` id)與自己的 lock;不是 subshell fork。 |
| **exit code 版圖** | 0 成功;1–35 rsync 原生碼;**90 用法/subpath、91 掛載缺、92 lock 忙、93 config 缺/空、94 批次被訊號中止**。全部進 `job_end exit=` → `ffds_sync_runs_total{exit_code}`。 |

### 紀錄:events.log 是唯一契約

```
/var/log/ffds-sync/events.log        機器契約,一事件一行(logfmt)
/var/log/ffds-sync/jobs/<sub>.log    原始 rsync 輸出,給人看(append、RUN/END 標記)
```

事件行格式:`ts=<epoch> time=<ISO-8601> event=<name> key=value ...`
值永不含空白(subpath 有驗證、rsync token 是單詞),單行 O_APPEND
寫入是原子的,batch、worker、awk filter 可以安全共寫。

| 事件 | 欄位 | 誰寫 |
| --- | --- | --- |
| `batch_start` | `pid= total= jobs=` | batch 母程序 |
| `batch_end` | `pid= ok= fail= total= duration=` | batch 母程序 |
| `batch_abort` | `pid= reason=lock-busy\|config-missing\|config-empty\|mount-missing\|tmp-failed\|signal [mountpoint=]` | batch 母程序 |
| `job_start` | `subpath= run= [batch=]` | worker |
| `job_progress` | `subpath= run= bytes= pct= speed= eta= [xfr= chk=]` | awk filter(每 N 行 progress 取 1) |
| `job_stats` | `subpath= run= [files= created= deleted= transferred= size= listgen= speedup=]` | awk filter(stats2 結尾) |
| `job_end` | `subpath= run= exit= duration= [batch=]` | worker |

- 手動 `one` 也記錄(無 `batch=` 欄),以前手動跑是監控黑洞。
- systemd 底下跑(`JOURNAL_STREAM` 有設)時,生命週期事件
  `batch_*`/`job_start`/`job_end` 同時印到 stdout = journal,
  `journalctl -u ffds-sync` 直接看得到;`job_progress`/`job_stats`
  由 awk 發、只進 events.log(長傳輸會灌爆 journal)。
- `all` 的結束碼:每個 job 都成功才 0,否則 1(worker 沒寫回 rc 也算失敗),
  `systemctl status` 才會把失敗的一夜顯示成 failed;90–94 是它自己
  的 abort 碼。timer 不看上次結果,照常觸發。
- job log 同時保留:節流後的 progress、**傳輸檔逐檔記名(name1)、
  刪除逐檔記名(del1)**——`--delete` 誤刪傳染的唯一 forensic 紀錄。
- logrotate 隨附([`ffds-sync.logrotate`](ffds-sync.logrotate)):
  weekly + maxsize 64M、rotate 8、copytruncate;monitor 的 offset
  reader 偵測截斷自動重來,rotation 只損失 replay 歷史不損失活狀態。

### Monitor(取代舊 exporter)

`ffds_sync_monitor.py`:增量讀 events.log(inode+offset,scrape 時讀,
無 sampler thread),啟動時 replay 最後 16 MiB 歷史,結果與批次時間戳
在重啟後存活。「running」的定義:`job_start` 之後、`job_end` /
所屬 batch 結束 / 更新的同 subpath `job_start` 之前。

Metric 名稱盡量沿用,dashboard / alerts 改動最小:

- **沿用**:`all_running`、`jobs_running`、`job_active{subpath,phase}`
  (phase 只剩 scan/transfer;fixup 不存在了)、`job_runtime_seconds`、
  progress 系列 ×7、`runs_total{subpath,exit_code}`、`last_result`、
  `last_success_timestamp`、`last_run_duration`、`last_run_*` 統計 ×6、
  `batch_subpaths_completed`、`config_subpaths`、`batch_runtime`、
  `batch_last_completed_timestamp`、`parse_errors_total`。
- **新增**:`job_last_activity_timestamp_seconds`(stuck 訊號)、
  `last_run_exit_code`、`batch_aborts_total{reason}`、
  `events_total{event}`、`log_last_event_timestamp_seconds`、
  `monitor_last_read_timestamp_seconds`。
- **移除**:`job_io_active`、`job_io_read/write_bytes_per_second`、
  `job_dstate_processes`、`job_rss_bytes`、`job_phase_duration_seconds`、
  `job_log_mtime_seconds`、`log_bytes`、`mount_present`、`sampler_*`。
  資源面(CPU/IO/memory/PSI/D-state)由 **`ffds-sync.service` 自己的
  cgroup** 經 cgroup-exporter 補回 —— 量整個 sync tree,比舊 exporter
  逐 pid 加總更正確;掛載狀態的告警改由 `batch_aborts_total{reason=
  "mount-missing"}` 與 `last_run_exit_code == 91` 表達。

## 部署:systemd timer + oneshot(取代 cron)

三個 unit,都已寫好:

- [`ffds-sync.timer`](ffds-sync.timer) → 定時觸發;oneshot 還在 active 時
  timer 不會再觸發(重疊防護內建,flock 留給手動執行守門)。
  `OnCalendar` 目前是 placeholder(`02:30`),`Persistent=false`
  (停機補跑會落在上班時間)、`RandomizedDelaySec=5m`。
- [`ffds-sync.service`](ffds-sync.service)(`Type=oneshot`,跑 `ffds_sync.sh all`):
  `RequiresMountsFor=/mnt/src-share /mnt/dst-fs`、`TimeoutStartSec=12h`、
  `CPUWeight=30`/`IOWeight=30`(placeholder,低於預設 100 讓 GPU 工作優先)、
  `ProtectSystem=strict` + `ReadWritePaths=/mnt/dst-fs /run/lock` +
  `LogsDirectory=ffds-sync`(strict 下自動建 `/var/log/ffds-sync` 並開寫入)
  + `PrivateTmp=yes`(strict 把 `/tmp` 變唯讀,batch 的 `mktemp -d` 會失敗;
  腳本有 guard,失敗發 `batch_abort reason=tmp-failed` 退 90,但正解是
  PrivateTmp);env 旋鈕寫在 `Environment=`;**不設 `Restart=`**、無
  `[Install]`(由 timer 或手動拉起)。**batch 因此有自己的 cgroup**,
  PSI/資源觀測免費取得。
- `../sync_monitor/ffds-sync-monitor.service`:
  常駐,只讀 `/var/log/ffds-sync`,port 9755 沿用(Prometheus scrape
  job `ffds-sync` 不用改 target)。

手動執行與排程執行同一套環境:`systemctl start ffds-sync`;
`journalctl -u ffds-sync` 直接看到生命週期事件(見上節)。

兩個 systemd 邊角,寫在 unit 註解裡,這裡再講一次:

- `TimeoutStartSec` 到期 → SIGTERM 送整個 cgroup(`KillMode=control-group`
  預設)→ batch 的 trap 發 `batch_abort reason=signal`、殺 worker、退 94
  → `TimeoutStopSec` 後 SIGKILL。卡在 D-state 的 rsync 連 SIGKILL 都殺不掉,
  unit 會停在 deactivating、**擋住下一次 timer** —— 這是刻意的重疊保護,
  不是 bug;人工介入是重新掛載或重開。
- `RequiresMountsFor` 的掛載不在時 unit **根本不會啟動**:腳本的 91 路徑
  不會跑、events.log 沒有紀錄,只有 journal 與
  `ffds_sync_batch_last_completed_timestamp_seconds` 老化看得出來。

**上線順序(已定案:timer 先寫好、不啟用)**

```bash
# sync-host 上
install -m 0755 ffds-sync-v3.sh /usr/local/ffds/ffds_sync.sh
install -m 0644 ffds-sync.logrotate /etc/logrotate.d/ffds-sync
install -m 0644 ffds-sync.service ffds-sync.timer /etc/systemd/system/
install -m 0755 ../sync_monitor/ffds_sync_monitor.py /usr/local/bin/ffds-sync-monitor
install -m 0644 ../sync_monitor/ffds-sync-monitor.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now ffds-sync-monitor
# 煙霧測試(不動 timer)
/usr/local/ffds/ffds_sync.sh one <某個小subpath>
tail /var/log/ffds-sync/events.log
curl -s localhost:9755/status
# 手動跑幾輪整批,確認行為(cron 先停掉,避免兩套同時跑)
systemctl start ffds-sync; journalctl -u ffds-sync -f
# 幾輪正常後:填 OnCalendar = 原 cron 時段,再啟用
systemctl enable --now ffds-sync.timer
# 舊檔退役
mv sync_all.sh sync_all.sh.v1
systemctl disable --now ffds-sync-exporter   # 舊 exporter
```

**回滾**:舊腳本搬回、timer 停掉、cron 復原;新舊監控互不相容
(log 路徑不同),回滾時 exporter 也要換回舊版。

**第一輪注意**:`--chown/--chmod` 第一次會把全樹既有錯誤的 owner/mode
修正,metadata 寫入量一次性偏高;`name1` 讓第一輪 job log 較大,
rotation 頂得住。**另要驗證**:掃描重、零變更的夜晚有沒有偽 exit 30
(rsync `--timeout` 在長掃描期的 keepalive 行為),有就調大
`FFDS_RSYNC_TIMEOUT`。

## 草稿審查後的修正與已知限制(2026-09-03)

定稿前對草稿做了一輪逐行審查(bash/awk 語意在本機實證),修掉九個問題。
值得記住的是「為什麼會錯」,不是 diff:

| 問題 | 為什麼會錯 | 修法 |
| --- | --- | --- |
| `ProtectSystem=strict` 下 `mktemp -d` 失敗但 batch 照跑 | strict 讓 `/tmp` 唯讀;worker 找不到 rc 目錄就不寫,`batch_end ok=0 fail=0` 是假的 | mktemp 加 guard(`tmp-failed` / 90)+ unit `PrivateTmp=yes` |
| rc 檔以 subpath 命名 | config 重複行、`a/b` vs `a_b` 互相覆寫 → `ok+fail≠total` | 改 worker pid 命名 |
| journal 直通寫成 `[ -n … ] && echo` | 未設變數時回傳 1,而 `emit` 是 `cmd_all` 最後一句 → 手動跑的成功 batch 會 exit 1 | `if … fi` |
| env 旋鈕不驗證 | `FFDS_SYNC_JOBS=abc` 讓 `test` 出錯、pool 永不阻塞 → **無上限併發**;`FFDS_PROGRESS_EVERY=0` 讓 awk 除以零、filter 死掉 | 非數字 / 0 回預設值 |
| `wait -n \|\| true` 後無條件減計數 | 無子程序時回 127 也被減 → 計數負值 → 超額 spawn | 127 就 break |
| `valid_subpath` 放行反斜線與 `.` | awk `-v` 會把 `\t` 變 tab,破壞「值不含空白」;`one .` 會同步整個根 | 兩條拒絕規則 |
| `mkdir -p "$jobLogDir"` 不檢查 | log 目錄建不出來 → lock 的 `exec {lk}>>` 失敗、`$lk` 未設 → `set -u` 殺掉 worker、沒有 `job_end` | mkdir / exec 都檢查,失敗退 90;unit `LogsDirectory=` |
| config 只去尾端空白 | `"  sub"` 前導空白殘留 → 白燒一個 90 | 前導也去 |
| `all` 永遠 exit 0 | 整晚全失敗 `systemctl status` 仍是 success | 全成功才 0 |
| stats 的 `speedup` 取 `$NF` | `--dry-run` 時 rsync 印 `speedup is X (DRY RUN)` → 值變成 `RUN)`,monitor 靜默丟掉欄位;上線前的乾跑就是最需要 stats 的時候 | 取 `speedup is ` 之後第一個 token |

**已知限制(接受,不修)**

- **bash 5.2 的 `wait -n`**(Ubuntu 24.04)會漏接被 signal 殺掉的子程序:
  jobs=1 時 batch 可能卡到 `TimeoutStartSec` 才被 systemd 收掉(仍是乾淨的
  `batch_abort reason=signal`)。5.3 已修;systemd 是 backstop。
- **mawk 的 pipe 緩衝**可能讓 `job_progress` 延遲成批到達;`progressEvery=15`
  加 45 分鐘 stuck 門檻下可容忍。目標機觀察到再考慮 `-W interactive`。
  mawk 需 ≥ 1.3.4(POSIX 字元類別)。
- **檔名污染**:`name1,del1` 印檔名到 stdout,檔名長得像 progress/stats 行
  會污染那一次的數值(行仍 well-formed,monitor 不會炸)。
- **mangling 碰撞**:`a/b` 與 `a_b` 共用同一 job log 與 job lock,後者會拿到 92。
- **殘留的 rsync**:手動 `kill -TERM <batch>` 只殺 worker,rsync 孤兒會跑到
  結束、期間仍持有 job lock(這是對的:資料還在寫);filter 還會替它寫出
  `job_stats`,但那個 run 永遠沒有 `job_end`。systemd 的 cgroup kill
  沒有這個問題。harness T18 把這段行為釘成測試。
- `mkdir -p "$destParent"` 在 WEKA「掛著但掛住」時會 D-state 卡在 rsync 之前:
  `mounts_ok` 只證明掛載存在。持鎖 + monitor 的 last-activity 告警是 backstop。

## 本機驗證

[`test/ffds-sync-local-test.sh`](test/ffds-sync-local-test.sh):單一 bash
腳本,全部在 `mktemp -d` 底下,不碰任何真實掛載、主機、`/var/log`、`/run/lock`。
把腳本複製一份、sed 改寫 fixed config 區塊指到 scratch 樹
(`mountpoints=(/ /proc)`、`fileOwner` 改成自己),rsync 換成 shim:印一段
含真 `\r` 的 progress2 重寫 + 完整 stats2 區塊(涵蓋有/無 `(xfr#…)` 尾巴、
`to-chk` 變體、`1,234 (reg: …)`、`speedup is 2,345.67`),`sleep
$FFDS_SHIM_SLEEP`,`exit $FFDS_SHIM_RC`。這樣三段 pipeline、`\r→\n`、節流、
awk 擷取、PIPESTATUS 傳遞、lock 重疊都是決定性的。

覆蓋:單一 job 事件序列與欄位值、壞 subpath 全套 → 90、缺掛載 → 91、
job/batch lock → 92、config 缺/空/CRLF/前後空白、`all` jobs=1 的順序性與
`ok/fail/total`、jobs=2 + 重複 subpath 的併發交錯、整個 process group 收到
SIGTERM(= systemd 的 control-group kill)→ 94 + `batch_abort`、只殺 batch
時 rsync 孤兒持鎖 → 92 的已知限制、worker 被 SIGKILL 時 batch 續跑
(bash 5.2 `wait -n` 探針)、mktemp 失敗 → `tmp-failed`、log/lock 目錄建不出來
→ 90、rsync 結束碼 23/30 傳遞、`JOURNAL_STREAM` 鏡射逐位元相同且未設時
stdout 空、壞旋鈕回預設、`--dry-run` 的 `(DRY RUN)` 尾碼不污染 `speedup`,
最後把整份 events.log 餵給 `ffds_sync_monitor.py` 的 `State`(零 parse error、
各 subpath 的 `runs` 計數、abort 原因、`render_metrics()` 內容)。
2026-09-03 本機(bash 5.3 / gawk 5.4)127 項全綠;另起 monitor 對同一份
events.log `curl /metrics` 抽查 19 個 family 值正確。

**本機蓋不到、要到目標機(Ubuntu:mawk + bash 5.2)再跑的**:真 rsync 層
(harness 有,`command -v rsync` 有才跑,多 7 項 → 134:第二次
`transferred=0`、`--delete` 生效、`diff -r` 相等、mode 775)、bash 5.2 上的
`wait -n` 探針(harness 有,但只有在 5.2 上跑才能證實或排除)、mawk 的
trickle 輸入、first-run 的偽 exit 30 檢查。

完整的測試項目(本機 / 目標機 / systemd 整合 / 真資料 / monitor,含執行順序與
enable timer 前的驗收準則)在
[`test/ffds-sync-v3-test-plan.zh-tw.md`](test/ffds-sync-v3-test-plan.zh-tw.md)。

## 對照 smb-stall-report 的 review 結論(2026-09-03)

`../sync_monitor/smb-stall-report.zh-tw.md`
把 SMB 讀取釘死為 server 應用層 stall(~1.25s 窄帶、15–25% 機率),
latency-bound、並行度近線性放大;root cause 未定,2×2 實驗最高優先。
對本設計的影響:

1. **期望管理**:v3 砍的浪費大多在 WEKA 端與 CPU。SMB 端要精確表述:
   stall 支配的是**單流 QD1 讀者**(rsync 正是),per-request stall
   在高並行下並沒有消失,但吞吐面的影響會被足夠的 in-flight IO 攤薄
   (報告模型:吞吐 ≈ iodepth ÷ (stall率 × 1.25s),實測 4×qd8 =
   296 MiB/s、smbclient 645 MiB/s)。單一 rsync 自己拉不高 iodepth,
   所以 v3 不改變傳輸速度 —— 它止血浪費 + 提供可觀測性 + 為後手鋪路,
   **不是**解決同步慢;慢的出路在「攤薄」或「乾淨連線」,等實驗定罪。
2. **部署順序**:先跑 2×2 實驗(需要穩定的 v1 行為當變因),
   出結論後再上 v3 + timer;events.log 從此讓「測試期間 sync 是否在跑」
   有精確紀錄(報告未知 #5)。
3. **併發旋鈕暫緩,判準明確**:B 格卡(乾淨連線也 stall)→
   攤薄路線,開 `FFDS_SYNC_JOBS`(掃描期的序列 metadata ops 也只有
   多 subpath 平行能救);B 格乾淨(HOL 定罪)→ 拆連線/修
   multichannel,單流 rsync 可能直接快起來,連併發都不用;
   pool 慢定罪 → `FFDS_RSYNC_EXTRA=--bwlimit` 錯峰。
4. **stuck 偵測分兩層**:主要靠腳本內建的 rsync `--timeout`
   (卡死 → 30 分內 exit 30 + job_end);monitor 的
   `job_last_activity` 告警設 45 分鐘當保底 —— metadata 風暴
   (~22 ops/s)下大 subpath 掃描期可長達數小時且可能無 progress
   輸出,門檻太緊必誤報。
5. **hard mount 配套**:報告建議評估 soft → hard;`--timeout`
   正是讓 hard 安全的另一半(hard 解 EIO 資料面風險,timeout 解
   無限吊死)。兩者應同窗口一起上。
6. **ops 清單**(非腳本範圍,部署窗口一併評估):`actimeo=1` 調高
   以削掃描期 QueryInfo 風暴(夜間同步對 60s 屬性過期無感,但 mount
   共用要先協調);重複掛載二選一(bind mount 或 `nosharesock`);
   multichannel 未建立(3×10GbE 只用一條)待修。

## 環境變數一覽

| 變數 | 預設 | 用途 |
| --- | --- | --- |
| `FFDS_SYNC_JOBS` | 1 | `all` 的平行 subpath 數(先維持 1,見上) |
| `FFDS_RSYNC_TIMEOUT` | 1800 | rsync `--timeout` 秒數,0 = 關閉 |
| `FFDS_PROGRESS_EVERY` | 15 | progress 每 N 行留 1 行(log 與事件同步節流) |
| `FFDS_RSYNC_EXTRA` | (空) | 附加 rsync 旗標,空白分隔(如 `--bwlimit=50m`;上線前乾跑用 `--dry-run`,`job_stats deleted=` 與 job log 的 `deleting` 行就是 `--delete` 的預覽) |

路徑類(src/dst root、log 位置、config)寫死在腳本開頭的 fixed
configuration 區塊:要改就改在檔案裡,部署參數才走環境變數。

## 待決事項

- **`OnCalendar` 時間**(= 現行 cron 的時間):timer 已寫好、placeholder
  `02:30`,手動跑幾輪確認後再填、再 enable。`Persistent=false` 已定。
- **2×2 實驗結果** → 決定併發 / 限速 / 拆連線哪條路;定罪前 v3 不上線。
- 目錄要不要 setgid(`D2775`);`--max-delete` 上限(預設不設,
  要用 `FFDS_RSYNC_EXTRA="--max-delete=100000"`,超限 exit 25)。
- `CPUWeight`/`IOWeight` 的值(目前 30/30 是 placeholder)。
- 收尾未完(monitor 側):alerts.yml(Stuck → `time() -
  ffds_sync_job_last_activity_timestamp_seconds > 2700`;MountMissing →
  `batch_aborts_total{reason="mount-missing"}` / `last_run_exit_code == 91`;
  Overlap → aborts lock-busy)、ffds-sync dashboard(Mounts/Sampler 面板換
  aborts/事件年齡,IO/RSS/D-state 面板改接 cgroup-exporter)、
  `sync_monitor/README.md` 重寫(現仍描述已淘汰的第一版 BATCH-line 契約)、
  教材 `gpu-sync-scripts.zh-tw.html`
  補 v3 一節。
- sync 側已完成:腳本定稿、timer/oneshot unit、`emit` journal 直通、本機 harness。
