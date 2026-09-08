# sync_proj — FFDS SMB→WEKA 夜間同步腳本(v3 / v4)

sync-host 上的夜間同步(SMB share → WEKA `DataSet`)兩個版本:

- **v3(rsync,定稿)**:一支腳本取代舊的 v1/v2 兩支——單趟樹遍歷
  (`--chown/--chmod` 併進 rsync 本趟)、flock 取代 pgrep、掛載預檢只讀
  `/proc/mounts`、結構化 `events.log` 作為與監控之間的唯一契約。
- **v4(rclone,實驗)**:同一套 CLI 與事件契約,`FFDS_V4_BACKEND=mount|smb`
  雙資料路徑、事後 owner/mode fixup、95/96 區分 fixup/telemetry 失敗;
  定位是效能比較引擎,是否取代 v3 由實驗數據決定。

| 檔案 | 用途 |
| --- | --- |
| [`DEPLOY.zh-tw.md`](DEPLOY.zh-tw.md) | **部署手冊(從佔位符替換開始)** |
| [`ffds-sync-v3.sh`](ffds-sync-v3.sh) | v3 本體(部署名 `ffds_sync.sh`) |
| [`ffds-sync-v3.zh-tw.md`](ffds-sync-v3.zh-tw.md) | v3 設計說明(帳、決策、上線順序) |
| [`ffds-sync.service`](ffds-sync.service) / [`ffds-sync.timer`](ffds-sync.timer) | systemd oneshot + timer(timer 先不啟用) |
| [`ffds-sync.logrotate`](ffds-sync.logrotate) | log 輪替 |
| [`ffds-sync-v4.sh`](ffds-sync-v4.sh) | v4 本體(部署名 `ffds_sync_v4.sh`) |
| [`ffds-sync-v4.zh-tw.md`](ffds-sync-v4.zh-tw.md) | v4 設計說明(backend、事件差異、fixup、限制) |
| [`test/ffds-sync-local-test.sh`](test/ffds-sync-local-test.sh) | v3 本機 harness(126 項;有 rsync +7、有 monitor +1) |
| [`test/ffds-sync-v4-local-test.sh`](test/ffds-sync-v4-local-test.sh) | v4 本機 harness(134 項;含真實 rclone 層,有 monitor +1) |
| [`test/ffds-sync-v3-test-plan.zh-tw.md`](test/ffds-sync-v3-test-plan.zh-tw.md) | L1 本機 → L4 上線的測試計畫與驗收準則 |
| [`test/fixtures/rclone/`](test/fixtures/rclone/) | rclone JSON 契約 fixture(釘於 v1.75.1,附重釘腳本) |

兩支 harness 全部在 mktemp sandbox 執行,不碰真實掛載與系統路徑:

```bash
bash test/ffds-sync-local-test.sh
bash test/ffds-sync-v4-local-test.sh    # rclone 在 PATH 時多跑真實層
```

事件契約的消費端(`ffds_sync_monitor.py`)與 v3/v4 效能實驗框架(bench、
SMB stall 調查)在另外的工作區維護;harness 的 monitor gate 在本 repo
會自動 skip。程式碼與註解英文、給人讀的文件正體中文。
