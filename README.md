# sync_proj — FFDS SMB→WEKA 夜間同步腳本(v3 / v4)與效能實驗框架

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
| [`test/ffds-bench-local-test.sh`](test/ffds-bench-local-test.sh) | bench 本機 harness(50 項,全 sandbox) |

### 效能實驗框架(v3 vs v4)

| 檔案 | 用途 |
| --- | --- |
| [`bench/DEPLOY.zh-tw.md`](bench/DEPLOY.zh-tw.md) | **實驗部署手冊**(預檢 → 監控安裝 → smoke → campaign → 收尾) |
| [`bench/ffds-bench.zh-tw.md`](bench/ffds-bench.zh-tw.md) | 實驗設計(要回答的問題、情境定義、有效閘門、誠實界線) |
| [`bench/ffds-bench.sh`](bench/ffds-bench.sh) | campaign runner(root、手動、離峰) |
| [`bench/ffds_bench_data.py`](bench/ffds_bench_data.py) | 路徑防護 / manifest / 結果層(runner 的工具箱) |

### 監控(events.log 的消費端)

| 檔案 | 用途 |
| --- | --- |
| [`sync_monitor/ffds_sync_monitor.py`](sync_monitor/ffds_sync_monitor.py) | events.log → Prometheus exporter(v3/v4 共用同一支) |
| [`sync_monitor/ffds-sync-monitor.service`](sync_monitor/ffds-sync-monitor.service) / [`@.service`](sync_monitor/ffds-sync-monitor@.service) | 單一實例 / 多實例 template |
| [`sync_monitor/monitor-env/`](sync_monitor/monitor-env/) | 各實例的 env(`@v4`=9756、`@bench-*`=9757-9759) |
| [`sync_monitor/ffds_bench_exporter.py`](sync_monitor/ffds_bench_exporter.py) + [`.service`](sync_monitor/ffds-bench-exporter.service) | 實驗結果 exporter(9760,讀逐輪權威 JSON) |
| [`sync_monitor/test_ffds_bench_exporter.py`](sync_monitor/test_ffds_bench_exporter.py) | 上者的單元測試(12 項) |
| [`monitoring/prometheus-ffds-jobs.yml`](monitoring/prometheus-ffds-jobs.yml) | 六個 ffds scrape job(貼進你的 prometheus.yml) |
| [`monitoring/ffds-sync-bench.json`](monitoring/ffds-sync-bench.json) | Grafana 引擎對比 dashboard |

兩支 harness 全部在 mktemp sandbox 執行,不碰真實掛載與系統路徑:

```bash
bash test/ffds-sync-local-test.sh
bash test/ffds-sync-v4-local-test.sh    # rclone 在 PATH 時多跑真實層
bash test/ffds-bench-local-test.sh      # 50 項
python3 sync_monitor/test_ffds_bench_exporter.py
```

**所有路徑、主機名、share 與資料集名稱都是佔位符**,實值不在本 repo,
部署第一步就是照 [`DEPLOY.zh-tw.md`](DEPLOY.zh-tw.md) 步驟 0 替換掉。
促成 v4 的 SMB stall 調查報告在另外的工作區維護(文件中對它的引用是
外部參照)。程式碼與註解英文、給人讀的文件正體中文。
