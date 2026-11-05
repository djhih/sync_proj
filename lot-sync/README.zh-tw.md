# lot-sync

把 `copy_folder.py`(lot 資料夾)和 `copy_lrf.py`(`.lrf` 檔)合成一支,
另外提供 `relocate`:把 share 上放錯月份的資料夾 / 檔案移到正確位置。
逐模組的程式碼說明見 [code-explained.zh-tw.md](code-explained.zh-tw.md)。

> 路徑佔位符沿用 sync_proj 的其他文件:`/mnt/dst-fs` 是 WEKA、`/mnt/src-share` 是 SMB share。
> **本專案的方向與 FFDS 同步相反**:來源在 `/mnt/dst-fs`,目的在 `/mnt/src-share`。

只用標準函式庫(Python ≥ 3.8)+ `rsync`(只有複製資料夾時需要;sync-host 上舊程式本來就在用,不需要安裝新東西)。

## 用法

```bash
cd sendout/lot-sync        # 部署時把整個 lot_sync/ 目錄複製過去即可

# 同步:常駐(預設每 300 秒一輪),或 --once 跑一輪
python3 -m lot_sync --log-file /var/log/lot-sync.log --error-log-file /var/log/lot-sync.error.log \
  sync \
  --folder-src /mnt/dst-fs/DataSetB/SENDOUT --folder-dst /mnt/src-share/OutDir/SENDOUT \
  --lrf-src <LRF 來源> --lrf-dst <LRF 目的> \
  --state-file /var/lib/lot-sync/state.json

# 只想看它會做什麼(什麼都不寫):加 --dry-run
python3 -m lot_sync sync ... --once --dry-run

# 移動放錯月份的項目:一定要二選一,沒有預設
python3 -m lot_sync relocate --folder-dst /mnt/src-share/OutDir/SENDOUT --lrf-dst <…> --dry-run
python3 -m lot_sync relocate --folder-dst /mnt/src-share/OutDir/SENDOUT --lrf-dst <…> --apply
```

資料夾與 `.lrf` 兩條線可以只開一條(各自的參數要給齊)。`--verbose` 會列出每個被跳過的項目。
`--log-file` / `--error-log-file` 是**全域**選項,要放在 `sync` / `relocate` **之前**。

## 規則

### lot 資料夾(名稱以 `YYYYMMDD-HHMMSS` 結尾,例如 `LOTAAAA0001-20260911-172530`)

- **目的地** `<dst>/<YYYYMM>/<lot 名稱>`。月份只看 lot 名稱裡的日期;
  中間幾層 PE 資料夾、`sendout_YYYYMMDD`(寄檔日)都**不看、不搬**。
- **何時才複製**:資料夾裡最新的檔案已超過 `--stable-seconds`(預設 60)沒有被寫過,且至少有一個檔案。
  空的 lot 不複製。
- **lot 名稱重複 → 只告警,不複製、不覆蓋**:
  1. 同一輪在兩個以上的來源位置看到同一個 lot 名稱(兩邊都標出來,不挑一個)。
  2. 狀態檔記錄這個 lot 已從**另一個**來源同步過(晚幾天才出現的重複)。
- **目的地已經有內容 → 更新到最新**:來源的檔案比目的地新(或不同)就覆蓋;
  目的地比較新的檔案不動(`rsync -u`);只有目的地有的檔案保留(不刪除)。
  **每個被覆蓋的檔案都會逐筆寫進 log**:`REPLACING | <路徑>: <舊大小> @ <舊時間> -> <新大小> @ <新時間>`。
  (沒有 backup:被覆蓋的舊內容無法復原,只留下這筆紀錄。)
- 來源的簽章(檔案數、總大小、最新 mtime)有變就會再補一次,所以晚到的檔案會補進來。
- 新資料夾先寫到 `.<名稱>.partial` 再 rename;已存在的資料夾原地更新。複製後用 `rsync -rn --size-only` 乾跑驗證。

### `.lrf` 檔(例如 `LOTAAAA0001-20260911-172530_pub.lrf`)

- **月份取自檔名裡的日期**(`…-20260911-…` → `202609`)。
  `_filtered`、`_pub` 這類後綴不影響。不看 `sendout_*`、不看 mtime、不看複製當下的時間。
- 檔名裡沒有合法日期 → 當成錯誤(error log),不複製。
- **同名 = 同一個檔案,更新到最新版**:
  - 目的地沒有 → 複製到 `<dst>/<YYYYMM>/<名稱>`。
  - 目的地有、大小與 mtime 相同(容差 2 秒) → 不動。
  - 來源比較新 → **原地覆蓋**目的地那份(不論它在哪個月份目錄),並逐筆記錄。
  - 目的地比較新 → 跳過(原因 `destination is newer`)。
  - 多個來源有同名檔 → 只同步最新的那個。
- 要求檔案 mtime 已超過 `--stable-seconds`。

### 搬移放錯月份(`relocate`)

- lot 資料夾看名稱的日期,`.lrf` 看檔名的日期;直接放在根目錄、不在任何 `YYYYMM` 裡的也算放錯。
- 目標路徑已存在就跳過(絕不覆蓋),也不會刪除搬走後留下的空月份資料夾。

## log

- `--log-file`:一般 log,每輪有一行摘要:
  `PASS | applied=… up_to_date=… skipped=… [原因: 數量] duplicates=N failed=N`。
- `--error-log-file`:只放 ERROR。**每個問題只寫一次**(重複 lot、檔名沒日期、複製失敗…);
  問題消失後再出現才會再寫。已寫過的問題記在 `--state-file`,重啟後不會重複。
  所以 error log 是歷史紀錄;問題是否還在,看一般 log 摘要裡的 `duplicates=` / `failed=`。
- `--dry-run` 會把所有問題都印出來,而且不記進狀態檔。
- 重複 lot 或失敗都不會讓常駐程式退出;`--once` 在有 duplicates 或 failed 時結束碼為 1。

## 相對舊程式修掉的問題

- **空資料夾**:來源沒有檔案就跳過,不在 share 建立空資料夾,也不標記完成。
- **晚到的檔案**:完成標記存的是(來源、檔案數、總大小、最新 mtime);來源有變就會再補,不再因為「目的地存在」永遠 SKIP。
- **讀取失敗**:列目錄失敗會回報 `ERROR`,不再被當成「0 files」。
- **重啟**:狀態存在 `--state-file`,不再丟失。
- **8 月進 9 月**:`.lrf` 月份取自檔名;`relocate` 可修正已放錯的。
- **月份空資料夾**:目的資料夾只在真的要寫入時才建立。
- **重複的 lot 名稱**:舊程式先到先得、後到的 SKIP,而且不會告警;新程式告警並且不動任何一份。
- **`.lrf` 同名**:舊程式放進 `dup` 並加 `_N`;新程式更新到最新版,不再有 `dup`。

## 假設與限制(請確認)

1. `.lrf` 是獨立檔案,月份取自檔名;檔名沒有日期的 `.lrf` 會一直報錯(只寫一次)。
2. 兩個來源有同一個 lot 名稱時**不挑最新的**,只告警。PE 若合法地把同一個 lot 搬到別的資料夾,也會被當成重複。
3. 覆蓋沒有 backup,無法復原;只有 log 紀錄。
4. 下游不會在複製途中讀 share 的新資料夾(新資料夾用 rename 整個出現;已存在的資料夾原地更新)。
5. 目的地已有、但沒有記錄的資料夾(舊程式複製的),第一輪會對它們各做一次檔案清單比對,資料夾很多時會比較慢。
6. 比較檔案只看大小與 mtime(容差 2 秒),不比內容。

## 換掉舊程式的建議順序

1. 先備份現有的狀態與 log,**不要**先停舊程式。
2. 跑 `relocate --dry-run`,確認清單合理,再 `--apply`。
3. 跑 `sync --once --dry-run`,看 `would_apply`、`REPLACE` 與 `skipped [...]` 的原因分佈。
4. 停掉 `copy_folder.py` / `copy_lrf.py`(兩套**不要同時**寫同一個目的地),啟動新的。

## 測試

```bash
cd sendout/lot-sync && python3 -m pytest -q    # 48 項,用暫存目錄與假的 rsync
```

**尚未做的**:沒有用真的 rsync、真的 SMB 掛載、或 sync-host 上的資料跑過(這台筆電沒有 rsync;
端到端只用一支假的 rsync 腳本跑過我們這端的流程)。請先確認:
`rsync -a -u` 不會覆蓋較新的檔案,以及驗證用的 `rsync -rn -u --size-only --itemize-changes` 輸出裡 `>f` 的行為。
