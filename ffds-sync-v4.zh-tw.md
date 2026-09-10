# ffds_sync_v4.sh — rclone 引擎設計說明

[`ffds-sync-v4.sh`](ffds-sync-v4.sh)(部署名 `ffds_sync_v4.sh`)是
[v3](ffds-sync-v3.sh) 的 rclone 姊妹作:**同一套 CLI(`all | one <subpath> |
status`)、同一份 events.log 契約**,monitor
一行不改就能讀。定位是 **bench campaign 的比較引擎**(見
`bench/ffds-bench.zh-tw.md`),不是 v3 的替代品——
是否升級由數據決定,升級時才另寫 service/timer。

## 為什麼有 v4

stall report(`sync_monitor/smb-stall-report.zh-tw.md`)
釘死 SMB 讀取被 ~1.25s 的 server 應用層 stall 支配,吞吐 ≈ iodepth ÷
(stall率 × 1.25s),單流 QD1 讀者(rsync 正是)最慘。rclone 的三個旋鈕直接
拉高 in-flight IO:`--transfers`(檔案並行)、`--checkers`(列舉/比對並行)、
`--multi-thread-streams`(大檔分流);原生 `:smb:` backend 又能繞過 kernel
cifs 的共用連線(2×2 實驗「隔離連線」軸的探針)。

## 雙 backend

| `FFDS_V4_BACKEND` | 資料路徑 | 用途 |
| --- | --- | --- |
| `mount`(預設) | 讀 `/mnt/src-share`(kernel cifs),寫 WEKA | 與 v3 純引擎對比:同一條 kernel 連線,只換引擎 |
| `smb` | rclone 自開 SMB 連線(go-smb2)直連 server,寫 WEKA | 繞過 kernel mount;同時驗證「乾淨連線」假設 |

smb 模式的預檢:掛載檢查只看目的端;來源改用
`rclone lsd <remote>/<subpath> --contimeout 10s --timeout 20s --retries 1`,
失敗 → exit 91(與 v3 的 mount-missing 同語意)。SMB 憑證放
`/etc/ffds-rclone.conf`(root:root 0600),所有 rclone 呼叫經 `rclone_cmd`
launcher:清掉繼承的 `RCLONE_*`、固定 `RCLONE_CONFIG`——環境變數不可能
偷偷改變同步行為,憑證不進命令列與事件。

## 與 v3 的事件契約差異

事件名七種**完全相同**,不新增(monitor 對未知事件名記 parse error)。
欄位差異:

| 項目 | v3 | v4 |
| --- | --- | --- |
| `job_progress` | rsync token(`1.23G`、`12.34MB/s`) | 純整數 `bytes=`/`speed=`(monitor 讀不懂 GiB);`pct=` 整數(總量未知或估計越界時省略);`eta=H:MM:SS`(null 省略);**無 `chk=`**(rclone 的 totalChecks 是工作量,不是 rsync 的檔案列舉總數,錯的總數比沒有更糟) |
| `job_stats` | `files= created= deleted= transferred= size= listgen= speedup=` | 只有 `transferred=`(等價語意);另帶 rclone 原生 `checks= total_checks= transfers_total= transfer_bytes= transfer_bytes_total= deletes= deleted_dirs= errors=`(monitor 忽略未知 key、缺 key 視為缺席——**不填不等價的數字**) |
| `job_end` | `exit= duration=(整數秒)` | `duration=` 小數秒(monotonic,/proc/uptime),另帶 `dry_run= rclone_exit= filter_exit= fixup_exit= preflight_s= engine_s= fixup=`;被 signal 收掉時加 `aborted=1 termination_signal=` |
| `exit=` 1–35 | rsync 原生碼 | rclone 原生碼(不假設只到 9,以部署版本文件為準) |

成功但零傳輸仍發 `job_stats transferred=0 …`,讓 monitor 一定拿到本輪 stats
(它缺本輪 stats 時會保留上一輪的)。

## 退出碼

| exit | 意義 |
| --- | --- |
| 0 | 同步 + fixup + telemetry 全成功(dry-run 成功另帶 `dry_run=1`) |
| 1.. | rclone 原生碼原樣傳遞 |
| 90 | 用法/subpath/旋鈕錯、目的端祖先不安全(symlink)、log/lock/state 目錄不可寫 |
| 91 | 來源或目的不可用(掛載缺、smb 預檢失敗、目的端跨到非預期掛載) |
| 92 | lock 忙(同 subpath 已在跑 / 批次已在跑) |
| 93 | config 缺/空/**無效**(重複、mangle 碰撞、父子重疊——spawn 前整批拒絕,v3 沒有這層) |
| 94 | 批次被 signal 中止 |
| 95 | rclone 成功但必要 fixup 失敗(含「引擎成功但目的端不存在」) |
| 96 | rclone 成功但 telemetry 失敗(filter 錯誤、final stats 缺/壞、事件寫入失敗) |
| 130/143 | `one` 被 INT/TERM 收掉(128+signal) |

收尾優先序:rclone 非零 → 96 → 95 → 0;可處理的 signal 蓋過一切
(即使只剩 fixup 被中止也不落回 0)。三個階段 rc
(`rclone_exit/filter_exit/fixup_exit`)初始化為 `skipped`,沒跑過絕不寫成 0。

## Ownership/mode:事後 fixup

rclone 做不到 `--chown/--chmod`。引擎跑完後(rc<90 都跑,部分失敗也已寫入
檔案)單趟 GNU find(`,` operator)只修「錯的」entry:

```
find -P <dst> '(' ! -user root -o ! -group datasetgrp ')' -exec chown -hc ... {} + ,
              ! -type l ! -perm 775 -exec chmod -c 775 {} +
```

chown 不跟 symlink、chmod 排除 symlink;實際改動逐條進 job log;耗時記在
`job_end fixup=`。**限制**:fixup 完成前,新寫入的檔案不保證已有最終
owner/mode——若資料集消費者在同步窗口內讀檔,正式上線前要評估這點
(v3 的 `--chown/--chmod` 是同趟生效,沒有這個窗口)。

## 刪除語意

`rclone sync --delete-during` = rsync ≥3.0 的 `--delete` 預設(明寫自我說明)。
安全閥用 `FFDS_V4_MAX_DELETE`;超限的退出碼以部署版本實測為準,
不自行編造。逐檔 forensic:INFO 層的 `Copied (new)` / `Deleted` 行進 job log
(= v3 的 `name1,del1`)。

## 旋鈕

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `FFDS_V4_BACKEND` | mount | mount \| smb;其他值退 90 |
| `FFDS_V4_TRANSFERS` | 4 | 檔案並行 |
| `FFDS_V4_CHECKERS` | 8 | 列舉/比對並行 |
| `FFDS_V4_MULTI_THREAD_STREAMS` | 4 | 大檔分流;0 關閉 |
| `FFDS_V4_TIMEOUT` | 1800 | rclone IO idle timeout 秒;**0 明傳 `--timeout 0s`**(省略旗標會回 rclone 預設 5m)。它不是整個 job 的 deadline,擋不住卡死的 local syscall,也不涵蓋 find |
| `FFDS_V4_DRY_RUN` | 0 | 0/1;dry-run 不建立/修改/刪除目的端、fixup 跳過 |
| `FFDS_V4_BWLIMIT` | 空 | 有值時附加 `--bwlimit <值>`(字元白名單驗證,非法退 90) |
| `FFDS_V4_MAX_DELETE` | 空 | 有值時附加 `--max-delete <N>`(整數,非法退 90) |
| `FFDS_SYNC_JOBS` | 1 | `all` 的 subpath 並行(總並行 ≈ jobs × transfers,開之前先想) |
| `FFDS_PROGRESS_EVERY` | 15 | 名稱沿用 v3;v4 語意 = `--stats=<N>s` 的事件節奏 |

數字旋鈕非法值回預設並經十進位正規化(`08` 不會變八進位);
backend/dry-run/bwlimit/max-delete 錯誤採明確拒絕,不靜默改行為。

## 程序模型與鎖

`one` 的公開程序只當 coordinator(它的 PID = 事件的 `run=`);
rclone|filter 管線與 fixup 在 `setsid` 起的內部 `__worker`(**獨立 process
group**,PGID 由 worker 寫回、不用猜)。coordinator 做可中斷的 wait;
INT/TERM → TERM 整個 worker group → 等它們死透 → 恰好一次
`job_end`(`aborted=1`)。worker 的私有狀態目錄驗 ownership 與 mode,
不吃任意 argv。filter 在 EOF 只寫「final stats 候選」;**job_stats 由 worker
在拿到 PIPESTATUS 之後定案**——引擎死活未知前不承諾統計數字,壞掉的
final 也不回退到較早的 periodic snapshot。

鎖:per-subpath job lock **與 v3 同名**(`ffds-sync-job-<mangled>.lock`)——
結構上杜絕 v3/v4 同時對同一 subpath 跑 `--delete`;batch lock 分開
(`ffds-sync-v4-all.lock`)。此鎖只對同一 mangled key 互斥,擋不住 `A` 與
`A/B` 跨程序重疊(v4 的 `all` 會在 spawn 前拒絕 config 內的父子重疊,
但跨引擎混跑仍需排程互斥)。

## 已知限制

- **symlink**:`--links` 只作用於 local backend——mount 模式兩端、smb 模式僅
  目的端(SMB 來源看不到 symlink 本體),兩 backend 的 symlink 樹形可能不同。
  bench 的主要比較排除非 regular file/dir。
- **go-smb2 無 multichannel**;單連線/連線池行為要實測(`ss -t 'dport = :445'`)。
- **rclone 版本下限 1.60**::smb: backend 需要它;另外 ≤1.55 的 stats 物件缺 `totalBytes/totalTransfers/totalChecks`,final stats 會被 telemetry 契約拒收(exit 96,原因記在 job log)。實測通過:1.60.1、1.75.1。
- rclone exit 1–9 與 rsync 1–35 在 `runs_total{exit_code}` 同名不同義。
- monitor 的 phase=scan/transfer 對 v4 只代表「尚未/已收到 progress」
  (stats 每 tick 都發,即使 bytes=0),last_activity 是回報新鮮度,
  **不是 IO 推進證據**。

## 驗證狀態(2026-09-08)

- 本機 harness([`test/ffds-sync-v4-local-test.sh`](test/ffds-sync-v4-local-test.sh)):
  **135/135 綠**(shim 128 項 + 真實 rclone 層 7 項),v3 harness 原樣重跑
  127/127 無回歸。
- **真實 rclone v1.75.1**:JSON stats 契約以真實輸出驗證;fixture 釘於
  [`test/fixtures/rclone/`](test/fixtures/rclone/)(cold/warm/incr/updated/
  error 五案例 + expected.json;sync-host 換版本用 `generate-fixtures.sh` 重釘)。
- **真實 SMB server(容器化 samba,本機)**:
  - smb 模式 cold:62 檔 / 12.6MB 走真 SMB,`diff -r` 相等、fixup 775、
    事件逐欄正確;warm `transferred=0 checks=62`;錯密碼 → lsd 預檢乾淨退 91。
  - mount 模式(kernel cifs 掛載容器 share):cold/warm/incr 全過;
    `/proc/fs/cifs/Stats` 的 Reads delta 76/0/5 對應三情境,
    **smb 模式全程 delta=0 = 繞過 kernel mount 的直接證明**。
- sync-host 尚未部署;正式煙霧測試與 campaign 流程見 bench 文件。

## 部署(scratch/smoke 範圍)

```bash
# sync-host(先不裝 timer/service——v4 尚未定案為正式引擎)
install -m 0755 ffds-sync-v4.sh /usr/local/ffds/ffds_sync_v4.sh
install -m 0600 /dev/null /etc/ffds-rclone.conf   # 填入 smb 憑證(rclone obscure)
install -m 0644 sync_monitor/ffds-sync-monitor@.service /etc/systemd/system/
install -d /etc/ffds-sync-monitor
install -m 0644 sync_monitor/monitor-env/v4.env /etc/ffds-sync-monitor/
systemctl daemon-reload && systemctl enable --now ffds-sync-monitor@v4
# 煙霧:小 subpath、scratch dst(改腳本 fixed config 或用 bench 的副本機制)
FFDS_V4_BACKEND=mount /usr/local/ffds/ffds_sync_v4.sh one <小subpath>
curl -s localhost:9756/metrics | grep -c parse_errors   # 必須 0 行(無錯誤)
```

## 待決

- sync-host 的 rclone 版本釘定(≥1.60 才有 :smb:;fixture 用實機版本重新產生)。
- smb 帳號:沿用 mount 憑證或申請專用帳號(server 端 session 上限/鎖定政策
  先向管理者確認)。
- campaign 結果出來後:v4 是否升級為正式引擎(才寫 service/timer +
  logrotate 條目)、`FFDS_V4_TRANSFERS/CHECKERS` 的正式值。
