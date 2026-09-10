# ffds-bench — v3/v4 同步引擎效能實驗

回答兩個問題(對照 stall report 未知 #9:rsync 實際 buffered 吞吐從未量過):

| # | 問題 | 情境 | 頭條指標 |
| --- | --- | --- | --- |
| Q1 | 同一資料夾完整同步要多久? | `cold`(空目的端全量拷) | 每 run 腳本總耗時,valid 中位數 |
| Q2 | 目的端已一致時,每秒能完成多少檔案的檢查? | `warm`(不變重掃) | 來源 regular-file 數 ÷ 總耗時 |
| 輔 | 缺 N 檔補齊要多久? | `incr` | 同 Q1 口徑 |

比較 **v3**(rsync)、**v4-mount**(rclone 走 kernel cifs)、**v4-smb**
(rclone 原生 SMB 連線);每組 × 每情境 ≥3 筆 valid。

## 架構

```
ffds-bench.sh(sync-host、root、手動、離峰)
 ├─ 腳本副本(sed 改寫 fixed config → 每引擎 scratch dst / live log)
 ├─ 每輪 systemd-run --scope 包 --scope-worker:worker 活著時自量
 │   cgroup CPU/IO/memory.peak,量完才退出
 ├─ live events → /var/log/ffds-bench/<engine>/events.log
 │       → ffds-sync-monitor@bench-* (:9757-9759) → Grafana Live 區
 └─ 每輪權威 JSON → /var/log/ffds-bench/results/<campaign>/runs/
         → ffds_bench_exporter (:9760) → Grafana Results 區
         → results.csv / SUMMARY.txt(離線重算,逐 byte 可攜副本)
```

**成績不從 monitor 收割**:monitor 的 last_run 系列以 subpath 為 key 只留
最後一次、scrape 時才 consume——短任務會被覆蓋/漏收。權威是逐輪不可覆寫
的 JSON;exporter 重啟即重建;Grafana 上任何數字都必須能由 JSON/CSV 重算
出**完全相同**的值。

## 用法

```
ffds-bench.sh -p <subpath> [-r reps=3] [-o outdir]
              [--engines v3,v4-mount,v4-smb] [--scenarios cold,warm,incr]
              [--incr-files N=100] [--no-drop-caches] [--keep-dst] [--force]
              [--run-timeout seconds=7200]
```

## 安全欄(硬編,任何旗標都關不掉)

1. 目的端一律 `/mnt/dst-fs/ffds-bench/<campaign>/<engine>/DataSet/…`;
   一切建立/刪除走 [`ffds_bench_data.py`](ffds_bench_data.py) 的 guard:
   component containment(不是字串前綴)、campaign marker(root:root 0700
   + 內容比對)、預期掛載(mountinfo 最長前綴)、逐層 symlink 檢查、
   nested mount 檢查;runner 從不自己拼 `rm -rf`。
2. 刪樹用 `shutil.rmtree`(確認 avoids_symlink_attacks);incr 逐檔刪除以
   dir_fd + O_NOFOLLOW 走 component、驗 regular file。
3. 來源唯讀;incr 只動 scratch 目的端(共同 manifest + rep 種子決定性選檔,
   所有引擎同一批)。
4. `/run/lock/ffds-bench.lock` 防同主機兩個 campaign;campaign id 不重用、
   同 tuple 不覆寫、不 resume(重跑另開 campaign)。
5. 空間預檢:來源 bytes × 引擎數 × 1.2 對 `df`。
6. 偵測 timer/其他 sync 程序 → 預設拒絕;`--force` 只給刻意共載的探索
   run(結果 `forced=1 valid=0` 不進主比較)。campaign 全程 1s 節奏的
   interference watcher 記錄任何其他 sync;看到 → 該輪 invalid、停跑。

## 情境定義與有效閘門

`cold` = 空目的端;`warm` = 目的端已一致(**不宣稱 server cache 冷熱**;
client cache policy 全 campaign 單一)。`ensure ready`:可重用已驗證的完整
dst,否則不計時 seed sync + 不計時 no-change check(transferred=0)+
manifest/owner/mode 驗證;任何 prep 失敗即停,不讓「修復殘缺 dst 的時間」
冒充 warm。

`valid=1` 要求全部成立:script/event/worker 三個 rc 一致且為 0、非
dry-run/forced/aborted、duration>0、來源前後 manifest 相同、目的端驗證通過、
無其他 sync 且 watcher 活著、(drop policy 時)drop_caches 確認、情境傳輸數
成立(cold=來源檔數、warm=0、incr=N)且刪除數為 0。失敗照樣保存
(valid=0 + 原因),再停跑——不悄悄重試覆蓋。

## 觀測面對照

| 想看什麼 | Grafana(`ffds-sync-bench`) | CSV/JSON 欄位 |
| --- | --- | --- |
| 一個資料夾多久同步完(Q1) | Folder sync duration(valid 中位數 bar) | `duration_s` |
| 每秒掃多少檔案(Q2) | Warm verification throughput | `source_files_total / duration_s` |
| 逐筆結果(含失敗) | Completed runs 表格 | 整列 |
| v4 分段 | V4 phase split | `engine_s` / `fixup_s`(v3 為 null,不偽造) |
| 資料可信度 | Results integrity(ready/loaded/parse errors) | — |
| 進行中 | Live 區(speed/progress/jobs) | —(不進成績) |
| CIFS metadata ops(smb 繞過證明) | —(不在 Prometheus) | `cifs_*_delta` |
| 資源帳 | — | `cpu_usec io_rbytes io_wbytes mem_peak_bytes` |
| 干擾/快取控制 | — | `other_sync_running drop_caches_ok cache_policy` |

Warm files/s 的口徑(面板描述也寫了):分母含完整 no-change run 的
metadata 比對、v4 fixup 與日誌成本——是「完整檢查流程」的吞吐,
**不是純 SMB 掃描階段速率**(本輪不宣稱可測純掃描;monitor 的 phase
不是引擎階段邊界)。

## sync-host runbook

窗口條件(規格 B7 的副作用盤點總結):**離峰 + 無任何 sync 程序 +
無人使用 /mnt/src-share 與 /mnt/other-share(mount 模式流量走共用 kernel cifs session,
watcher 偵測不到這些使用者)+ sync-host 無對快取/頻寬敏感的在跑工作**
(預設 drop_caches 是全主機生效)。v4-smb 會對 server 開新 SMB session
(帳號政策先確認)。

```bash
# 0. 預檢(唯讀):rclone version、/etc/ffds-rclone.conf 認證(lsd)、
#    df /mnt/dst-fs、systemctl is-active ffds-sync.timer、選封存 subpath
# 1. 部署監控(live ×3 + Results):
install -m 0644 ../sync_monitor/ffds-sync-monitor@.service /etc/systemd/system/
install -d /etc/ffds-sync-monitor
install -m 0644 ../sync_monitor/monitor-env/bench-*.env /etc/ffds-sync-monitor/
install -m 0755 ../sync_monitor/ffds_bench_exporter.py /usr/local/bin/ffds-bench-exporter
install -m 0644 ../sync_monitor/ffds-bench-exporter.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now ffds-sync-monitor@bench-{v3,v4-mount,v4-smb} ffds-bench-exporter
#    prometheus.yml 加五個 job(repo 已備好)後 reload;dashboard 佈署
# 2. 煙霧:小 subpath、單引擎單情境
./ffds-bench.sh -p <小subpath> -r 1 --engines v4-mount --scenarios cold
# 3. 正式:離峰窗口
./ffds-bench.sh -p <subpath> -r 3
# 4. 收尾:歸檔 <outdir>;停 bench live monitors、刪其 scrape jobs;
#    :9760 與 results 留到分析封存完
```

## Caveat(誠實界線)

- server ARC 不可控:client drop_caches 不清 server 快取;manifest/驗證本身
  也會暖快取。緩解:引擎順序每 rep 洗牌(seed 印出可重現)、≥3 reps、
  逐筆呈現非只中位數;**不自稱 cold-cache benchmark**。
- `cifs_*_delta` 是 host-wide 計數器,非零可能來自別的程序;
  v4-smb 的 delta≈0 是「繞過 kernel mount」的相容證據,不是成功必要條件。
- io.stat 是 block accounting,不等於 SMB/WEKA 網路 bytes;缺 counter 記
  null 與 `resource_missing`,不補 0。
- hard hang:`--run-timeout` 用 TERM→KILL 收 scope;scope 仍 populated
  (D-state)→ 保留 scratch 與診斷、**停止 campaign 不清理不續跑**。

## 與 2×2 stall 實驗的關係

v4-smb vs v4-mount ≈ 連線軸(自有連線 vs 共用 kernel session)、campaign 在
sync 停止窗口跑 ≈ C 列。v4-smb 明顯快 → 佐證共用連線/HOL 方向,但
mount→smb 同時換掉整個 client stack,**不能單因子歸因**;三者同慢 → 指向
server/pool。要定罪根因仍需原 2×2(控制 sync on/off × 連線隔離、相同 IO
工作負載)——**本 campaign 佐證判讀矩陣,不取代它**。

## 驗證狀態(2026-09-08)

- 本機 harness([`../test/ffds-bench-local-test.sh`](../test/ffds-bench-local-test.sh)):
  **50/50 綠**——路徑防護全套(traversal/symlink 祖先/偽 marker/錯掛載,
  外部 sentinel 證明拒絕時資料不變)、完整 campaign(cold/warm/incr × 2 reps
  全 valid、CSV 可重算、同 tuple 拒絕覆寫)、失敗即停且保留 scratch、
  干擾預檢拒絕。
- **真實迷你 campaign(本機容器化 samba + kernel cifs 掛載,真 systemd
  scope、無 shim)**:v4-mount × v4-smb × 3 情境全 valid;
  mount 引擎 `cifs_reads_delta` = 76/0/5(cold/warm/incr)、
  **smb 引擎全 0**;cpu/mem 資源帳來自真 scope cgroup;
  :9760 exporter 與未改的 monitor 對同一批資料 curl 驗證通過。
- exporter 單元測試 12/12(重啟重建、壞檔/重複鍵擋 ready、缺值缺席、
  label escape、warm 只算 valid)。

## 結果回填(campaign 後)

(待 sync-host campaign 完成後,由 SUMMARY/CSV 回填:各 engine×scenario 的
中位數、warm files/s、cifs QueryInfo/s、判讀與後續路線。)
