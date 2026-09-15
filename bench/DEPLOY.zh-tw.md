# ffds v3/v4 效能實驗 — 部署手冊

範圍:**bench campaign 的實驗部署**(sync-host + 監控主機),不是 v3/v4 正式
上線——timer 不裝、現行 v1/v2 cron sync 不動,實驗寫入只碰
`/mnt/dst-fs/ffds-bench/` scratch。設計背景見
[`ffds-sync-v4.zh-tw.md`](ffds-sync-v4.zh-tw.md) 與
[`bench/ffds-bench.zh-tw.md`](bench/ffds-bench.zh-tw.md)。

## 1. 檔案清單

### sync-host — 實驗本體(保持 repo 相對結構,整包放例如 `/root/llt/`)

`ffds-bench.sh` 以自身位置找 `../ffds-sync-v{3,4}.sh` 與同目錄的
`ffds_bench_data.py`,**目錄結構不能拆**:

| repo 路徑 | 用途 |
| --- | --- |
| `ffds-sync-v3.sh` | v3/rsync 引擎(bench 產生副本執行,不裝到 /usr/local) |
| `ffds-sync-v4.sh` | v4/rclone 引擎(mount/smb 雙 backend) |
| `bench/ffds-bench.sh` | campaign runner(root、手動) |
| `bench/ffds_bench_data.py` | 路徑防護/manifest/結果層(runner 的工具箱) |
| `bench/ffds_bench_analyze.py` | campaign 結束後的離線分析(讀 results.csv) |
| `v1-measure/ffds_v1_measure.py` | v1 引擎的 instrumenter(bench 用它產生 v1 副本) |
| (不裝、不改)`/usr/local/ffds/sync_ffds.sh` | v1 引擎的來源:bench 只讀它 |

### sync-host — 監控(安裝到系統)

| repo 路徑 | 部署位置 | 用途 |
| --- | --- | --- |
| `sync_monitor/ffds_sync_monitor.py` | `/usr/local/bin/ffds-sync-monitor`(0755) | 事件 monitor 本體(9755 既有部署共用同一支) |
| `sync_monitor/ffds-sync-monitor@.service` | `/etc/systemd/system/` | 多實例 template |
| `sync_monitor/monitor-env/*.env`(5 檔) | `/etc/ffds-sync-monitor/` | `@v4`=9756、`@bench-{v3,v4-mount,v4-smb}`=9757-9759、`@bench-v1`=9761 |
| `sync_monitor/ffds_bench_exporter.py` | `/usr/local/bin/ffds-bench-exporter`(0755) | Results exporter(9760,讀逐輪結果 JSON) |
| `sync_monitor/ffds-bench-exporter.service` | `/etc/systemd/system/` | 上者的 unit |
| (手建)`/etc/ffds-rclone.conf` | root:root **0600** | v4-smb 的 SMB 憑證(`rclone obscure`) |

### 監控主機(Prometheus/Grafana stack)

| repo 路徑 | 用途 |
| --- | --- |
| `monitoring/prometheus-ffds-jobs.yml` | 已含七個 ffds job(9755 既有 + 9756–9761);reload 生效 |
| `monitoring/ffds-sync-bench.json` | 引擎對比 dashboard(檔案佈署自動載入) |

### 只在 sync-host 跑一次的驗證件(不安裝)

| repo 路徑 | 用途 |
| --- | --- |
| `test/ffds-sync-v4-local-test.sh` | v4 harness(135 項;含真實 rclone 層) |
| `test/ffds-sync-local-test.sh` | v3 harness(有 rsync 時 134 項) |
| `test/ffds-bench-local-test.sh` | bench harness(57 項,sandbox;含 v1 引擎) |
| `test/ffds-v1-measure-local-test.sh` | v1 獨立量測工具的 harness(65 項,sandbox) |
| `test/fixtures/v1/sync_ffds.sh` | v1 原文(佔位符版),harness 的 instrument 錨點對照 |
| `test/fixtures/rclone/generate-fixtures.sh` | 用 sync-host 的 rclone 版本重釘 JSON 契約 fixture |

## 2. 部署步驟

### 步驟 0 — 預檢(唯讀,任何時段可做)

```bash
rclone version                     # :smb: 需 >= 1.60;版本 != fixtures/version.txt 就要重釘
python3 --version; rsync --version | head -1
df -B1 /mnt/dst-fs                    # 空間:來源 bytes x 引擎數 x 1.2
systemctl is-active ffds-sync.timer 2>/dev/null   # 應為 inactive/not-found
ss -tln | grep -E ':(9756|9757|9758|9759|9760|9761)\b' && echo "port 衝突!" || echo ports-free
```

另需向管理者確認(規格 B7):SMB 帳號無鎖定/session 上限政策、
決定 v4-smb 沿用 mount 帳號或專用帳號、`/mnt/other-share` 使用情況怎麼查。

### 步驟 1 — 在 sync-host 跑驗證件

```bash
cd /root/llt
bash test/fixtures/rclone/generate-fixtures.sh   # 版本不同時先重釘
bash test/ffds-sync-v4-local-test.sh             # 期望 135/135(rclone 在 PATH)
bash test/ffds-sync-local-test.sh                # 期望 134/134(有 rsync)
bash test/ffds-bench-local-test.sh               # 期望 57/57
bash test/ffds-v1-measure-local-test.sh          # 期望 65/65
```

任何一項紅 → 停,先修再繼續(mawk/bash 版本差異最可能在這裡現形)。

### 步驟 2 — 憑證與監控安裝(sync-host,root)

```bash
umask 077; : > /etc/ffds-rclone.conf; chmod 600 /etc/ffds-rclone.conf
cat > /etc/ffds-rclone.conf <<EOF
[nas]
type = smb
host = <NAS 位址>
user = <帳號>
pass = $(rclone obscure '<密碼>')
EOF
RCLONE_CONFIG=/etc/ffds-rclone.conf rclone lsd nas:share1   # 認證煙霧

cd /root/llt/sync_monitor
install -m 0755 ffds_sync_monitor.py  /usr/local/bin/ffds-sync-monitor
install -m 0755 ffds_bench_exporter.py /usr/local/bin/ffds-bench-exporter
install -m 0644 ffds-sync-monitor@.service ffds-bench-exporter.service /etc/systemd/system/
install -d /etc/ffds-sync-monitor
install -m 0644 monitor-env/*.env /etc/ffds-sync-monitor/
systemctl daemon-reload
systemctl enable --now ffds-sync-monitor@bench-{v1,v3,v4-mount,v4-smb} ffds-bench-exporter
curl -s localhost:9760/metrics | grep ffds_bench_exporter_ready   # 期望 1(空結果也 ready)
```

`@v4`(9756)是 v4 正式/長期煙霧用,本輪 campaign 可先不啟。

### 步驟 3 — 監控主機

```bash
# prometheus.yml 與 dashboard 已在 repo,照現行流程佈署後:
curl -s -X POST localhost:9090/-/reload      # 或重啟 prometheus container
# Grafana: Dashboards -> FFDS Sync Bench,五個新 target 應在 1 分鐘內 up
```

### 步驟 4 — smoke(sync-host,root,小 subpath)

```bash
cd /root/llt/bench
./ffds-bench.sh -p <小subpath> -r 1 --engines v4-mount --scenarios cold
./ffds-bench.sh -p <小subpath> -r 1 --engines v4-smb   --scenarios cold,warm
```

驗收:兩次 campaign rc=0、SUMMARY 全 valid、Grafana Results 區看得到逐筆、
`ffds_bench_result_parse_errors` = 0;v4-smb 那輪的 `cifs_reads_delta` 應 ≈ 0
(繞過 kernel mount 的證明)。

### 步驟 5 — 正式 campaign

窗口條件(缺一不跑):**離峰 + 無任何 sync 程序/timer + 無人使用
`/mnt/src-share` 與 `/mnt/other-share` + sync-host 無對快取/頻寬敏感的在跑工作**
(預設 `drop_caches` 全主機生效;不確定就加 `--no-drop-caches`,
整個 campaign 只能用同一種 cache policy)。

```bash
./ffds-bench.sh -p <正式subpath> -r 3          # 三引擎 x 三情境 x 3 reps
```

進行中在 Grafana Live 區盯;任何 run 失敗會**先存檔再停跑**、scratch 保留。

### 步驟 6 — 收尾

```bash
# 分析:outdir 的 SUMMARY.txt / results.csv(可由權威 JSON 重算);
# 結果回填 bench/ffds-bench.zh-tw.md 的「結果回填」節
systemctl disable --now ffds-sync-monitor@bench-{v1,v3,v4-mount,v4-smb}
# prometheus.yml 刪掉三個 ffds-sync-bench-* job(否則永遠 up==0)並 reload;
# 9760 與 /var/log/ffds-bench/results 留到分析歸檔完才下線
```

### 回滾

實驗不動現行 sync,回滾 = 上面收尾 + `systemctl disable --now
ffds-bench-exporter`、移除 units/env/binaries、刪 `/etc/ffds-rclone.conf`、
清 `/mnt/dst-fs/ffds-bench/` 與 `/var/log/ffds-bench/`。

## 3. Port 一覽

| Port | 服務 | 生命週期 |
| --- | --- | --- |
| 9755 | 既有 ffds-sync exporter | 不動 |
| 9756 | monitor@v4 | v4 煙霧/長期(本輪可不啟) |
| 9757–9759 | monitor@bench-{v3,v4-mount,v4-smb} | 僅 campaign 期間 |
| 9761 | monitor@bench-v1 | 僅 campaign 期間(v1 只有 start/end,沒有 progress) |
| 9760 | ffds-bench-exporter | 留到分析歸檔完 |

均為 0.0.0.0 無認證(沿既有 exporter 模式)——網路層是唯一存取控制。
