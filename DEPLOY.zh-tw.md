# 部署手冊(v3 / v4)

本 repo 是公開的,所有站點相關值(主機名、掛載點、share 名、資料集名、
群組名)都是**佔位符**。部署第一步就是在目標機的 clone 上把它們換成
你環境的實值——實值不在本文件、也永遠不要 commit 回這個 repo。

## 步驟 0 — 佔位符替換(必做)

只有下列**功能行**需要改,其餘出現佔位符的地方都是註解與文件,不影響執行:

| 檔案 | 行(key) | 佔位符 | 換成 |
| --- | --- | --- | --- |
| `ffds-sync-v3.sh`、`ffds-sync-v4.sh` | `srcRoot=` | `/mnt/src-share/DataSet` | 來源 SMB 掛載點 + 資料集根目錄 |
| 同上 | `dstRoot=` | `/mnt/dst-fs/DataSet` | 目的端掛載點 + 資料集根目錄 |
| 同上 | `mountpoints=` | `(/mnt/src-share /mnt/dst-fs)` | 兩個掛載點(smb 模式下 v4 自動略過第一個) |
| 同上 | `fileOwner=` | `root:datasetgrp` | 目的端檔案要強制的 owner:group |
| `ffds-sync-v4.sh` | `smbRemote=` | `nas:share1/DataSet` | rclone remote 名:share 名/資料集根目錄(remote 名須與 rclone config 的 section 名一致) |
| `ffds-sync.service` | `RequiresMountsFor=`、`ReadWritePaths=` | `/mnt/src-share`、`/mnt/dst-fs` | 同上兩個掛載點 |
| `bench/ffds-bench.sh` | `scratchBase=`、`expectMount=`、`copyMountpoints=`、`copyFileOwner=`、`srcRoot=`、`smbRemote=` | 同上各值 | 實驗 runner 的固定設定(scratch 一律在目的端掛載下) |
| `bench/ffds_bench_data.py` | `DATASET =` | `"DataSet"` | 資料集目錄名(路徑防護用,必須與 `srcRoot=` 末段一致) |
| `monitoring/prometheus-ffds-jobs.yml` | `targets:`、`instance:` | `sync-host` | 跑同步/實驗那台機器的主機名 |

一行搞定(把 `<...>` 換成實值後執行):

```bash
sed -i "s|/mnt/src-share|<來源掛載點>|g; s|/mnt/dst-fs|<目的掛載點>|g; \
        s|DataSet|<資料集目錄名>|g; s|datasetgrp|<群組名>|g; \
        s|nas:share1|<remote名:share名>|g" \
    ffds-sync-v3.sh ffds-sync-v4.sh ffds-sync.service \
    bench/ffds-bench.sh bench/ffds_bench_data.py
git diff        # 逐行確認只改到預期的 key
```

改完的 clone **不要 push**(或只把改完的檔案安裝走,clone 保持乾淨)。
`sync-host` 在腳本裡只出現在註解(可改可不改),但在
`monitoring/prometheus-ffds-jobs.yml` 的 `targets:`/`instance:` 是**功能值**,
一定要換成真實主機名;`/mnt/other-share` 同理,只出現在「安靜窗口」的說明裡。
`ffds-sync.timer` 與 `ffds-sync.logrotate` 完全不用動。

## 步驟 1 — 目標機驗證(不碰真實資料)

```bash
bash test/ffds-sync-local-test.sh        # v3:期望全綠(有 rsync 會多跑真實層)
bash test/ffds-sync-v4-local-test.sh     # v4:期望全綠(rclone 在 PATH 會多跑真實層)
```

harness 全部在 mktemp sandbox 執行,不碰任何掛載與系統路徑。若目標機的
rclone 版本與 `test/fixtures/rclone/version.txt` 不同,先跑
`bash test/fixtures/rclone/generate-fixtures.sh` 重釘契約再驗。
monitor gate 在本 repo 會自動 skip(事件契約的消費端在另外的工作區維護)。

## 步驟 2 — v3 上線(正式路徑)

順序與驗收準則詳見 [`ffds-sync-v3.zh-tw.md`](ffds-sync-v3.zh-tw.md) 的
「上線順序」與 [`test/ffds-sync-v3-test-plan.zh-tw.md`](test/ffds-sync-v3-test-plan.zh-tw.md);濃縮版:

```bash
install -m 0755 ffds-sync-v3.sh /usr/local/ffds/ffds_sync.sh
install -m 0644 ffds-sync.logrotate /etc/logrotate.d/ffds-sync
install -m 0644 ffds-sync.service ffds-sync.timer /etc/systemd/system/
systemctl daemon-reload
# 煙霧(不動 timer):
/usr/local/ffds/ffds_sync.sh one <某個小subpath>
tail /var/log/ffds-sync/events.log
# 手動跑幾輪整批(先停舊排程,避免兩套同時跑):
systemctl start ffds-sync; journalctl -u ffds-sync -f
# 連續數輪 batch_end ok=total 後:填 OnCalendar(= 原排程時段)再
systemctl enable --now ffds-sync.timer
```

`ffds-sync.timer` 的 `OnCalendar` 是 placeholder(02:30),**確認前不要 enable**。

## 步驟 3 — v4(實驗引擎,選用)

```bash
install -m 0755 ffds-sync-v4.sh /usr/local/ffds/ffds_sync_v4.sh
# smb 模式需要憑證檔(root:root 0600;section 名 = smbRemote 的 remote 名):
umask 077
cat > /etc/ffds-rclone.conf <<EOF
[<remote名>]
type = smb
host = <NAS 位址>
user = <SMB 帳號>
pass = $(rclone obscure '<密碼>')
EOF
RCLONE_CONFIG=/etc/ffds-rclone.conf rclone lsd <remote名>:<share名>   # 認證煙霧
# 煙霧(先對 scratch 目的端,見 v4 文件「部署」一節):
FFDS_V4_BACKEND=mount /usr/local/ffds/ffds_sync_v4.sh one <小subpath>
FFDS_V4_BACKEND=smb   /usr/local/ffds/ffds_sync_v4.sh one <小subpath>
```

v4 不裝 timer/service——它是效能比較引擎,是否升級由實驗數據決定
(旋鈕、退出碼、已知限制見 [`ffds-sync-v4.zh-tw.md`](ffds-sync-v4.zh-tw.md))。

## 回滾

```bash
systemctl disable --now ffds-sync.timer
# 舊排程腳本復原;新檔移除:
rm -f /usr/local/ffds/ffds_sync.sh /usr/local/ffds/ffds_sync_v4.sh \
      /etc/logrotate.d/ffds-sync /etc/ffds-rclone.conf
rm -f /etc/systemd/system/ffds-sync.{service,timer}; systemctl daemon-reload
# /var/log/ffds-sync* 留作紀錄,確認不需要後再清
```
