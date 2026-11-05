# lot-sync 程式碼解釋

這份文件說明 [lot_sync/](lot_sync/) 每個模組在做什麼、資料怎麼流動,以及已知限制。
使用方式看 [README.zh-tw.md](README.zh-tw.md)。

## 1. 核心想法:規劃與執行分開

舊程式是「掃到就做」,所以 dry-run、測試都很難加。新程式拆成兩段:

```
掃描 / 比對(唯讀)            執行(有副作用)
  folders.py ─┐
  lrf.py     ─┼─► list[Action] ─► Executor.run() ─► Report
  relocate.py ┘      │                  │
                     │                  └─ dry-run:只印出來,什麼都不做
                     └─ 每個 Action 說明「做什麼、從哪到哪、為什麼」
```

- 規劃函式**不會寫任何東西**(包括不建資料夾),所以 dry-run 的輸出就是真正會執行的計畫。
- 規劃的邏輯都是純函式加上檔案系統讀取,測試只要建暫存目錄。

## 2. 模組一覽

| 檔案 | 責任 |
| --- | --- |
| [timeslot.py](lot_sync/timeslot.py) | 月份規則:lot 名稱 / `.lrf` 檔名 → `YYYYMM`(只看名稱裡的日期) |
| [fileinfo.py](lot_sync/fileinfo.py) | 檔案比較:大小 + mtime(容差 2 秒);「相同 / 較新 / 會被取代」;覆蓋紀錄的文字格式 |
| [scan.py](lot_sync/scan.py) | 唯讀掃描:找資料夾、找 `.lrf`、算資料夾簽章。**讀不到就丟 `ScanError`,不會假裝是空的** |
| [plan.py](lot_sync/plan.py) | `Action` 與 `Kind`:規劃的輸出格式 |
| [folders.py](lot_sync/folders.py) | 規劃 lot 資料夾的同步 |
| [lrf.py](lot_sync/lrf.py) | 規劃 `.lrf` 檔的同步 |
| [relocate.py](lot_sync/relocate.py) | 規劃「把放錯月份的項目搬到正確月份」 |
| [executor.py](lot_sync/executor.py) | 執行 Action、dry-run、統計 `Report` |
| [problems.py](lot_sync/problems.py) | error log 的「每個問題只寫一次」 |
| [rsync.py](lot_sync/rsync.py) | `rsync` 複製與乾跑驗證的薄包裝(可注入,測試用替身) |
| [state.py](lot_sync/state.py) | 持久化:已完整複製的 lot(含擁有的來源)、已寫進 error log 的問題 |
| [config.py](lot_sync/config.py) | 設定的 dataclass |
| [cli.py](lot_sync/cli.py) | 參數解析、串起各模組、常駐迴圈 |

## 3. Action:規劃的共同語言

[plan.py](lot_sync/plan.py) 的 `Action` 有 `kind / src / dst / reason`;資料夾複製另帶 `signature`,會覆蓋目的地檔案的動作另帶 `notes`(逐檔的覆蓋紀錄)。

| `Kind` | 意思 | Executor 的處理 |
| --- | --- | --- |
| `COPY_TREE` | 用 rsync 複製一個資料夾 | 真的複製;計入 `applied` |
| `COPY_FILE` | 複製單一檔案(`.lrf`) | 真的複製;計入 `applied` |
| `MOVE` | 在目的地內搬移 | 真的搬;計入 `applied` |
| `SKIP` | 這次不處理,附原因 | 計入 `skipped` 與原因計數 |
| `DUPLICATE` | 同一個 lot-id 重複,需要人工檢查 | **不複製**;`ERROR` 等級 log `DUPLICATE LOT`;計入 `duplicates` |
| `UP_TO_DATE` | 已經是最新 | 計入 `up_to_date` |
| `ERROR` | 規劃階段就失敗(讀不到) | 計入 `failed` |

dry-run 時,前三種只印 `DRY-RUN | …` 不執行,仍計入 `applied`
(摘要會改寫成 `would_apply=`,避免誤會成真的做了)。

## 4. lot 資料夾:`folders.py`

`plan_folder_sync` 對來源下每個名稱以 `YYYYMMDD-HHMMSS` 結尾的資料夾,依序判斷:

```
月份算不出來(日期不合法) ─────────────────► SKIP "cannot derive a month…"
同一輪還有別的來源位置是同一個 lot 名稱 ────► DUPLICATE "lot-id also found at: …"
狀態檔記錄此 lot 是從另一個來源同步的 ──────► DUPLICATE "lot-id already synced from: …"
讀取來源失敗(權限 / 掛載) ────────────────► ERROR
來源沒有任何檔案 ──────────────────────────► SKIP "no files yet"
最新檔案距現在 < stable_seconds ────────────► SKIP "still being written"
有記錄(同一來源),簽章相同 ───────────────► UP_TO_DATE
其他(第一次,或簽章有變) ─────────────────► COPY_TREE(帶 notes:將被覆蓋的目的地檔案)
```

- **目的地**:`<dst_root>/<YYYYMM>/<lot 名稱>`,月份與名稱都只取自資料夾**自己的名稱**,
  不帶任何上層路徑。`sendout_20261103/PE-test/EXP1/20261030-120000` → `202610/20261030-120000`;
  `sendout_20261103`(寄檔日)完全不參與。
- **重複判斷在量測簽章之前**,所以資料夾還在寫入時也會先告警。兩邊都標成 `DUPLICATE`,
  不選其中一份當正本;**這兩種情況不會覆蓋任何東西**。
- **擁有者**:複製成功後狀態檔記下 `lot(目的地)→ 來源路徑 + 簽章`。同一個 lot 只能有一個來源。
- **目的地已有內容**(舊程式留下的,或來源較早版本複製的)不算衝突,而是**更新到最新**:
  `_replacements` 比對兩邊相同相對路徑的檔案,凡是「內容不同且目的地不比來源新」的,
  逐檔寫進 `notes`(`路徑: 舊大小 @ 舊時間 -> 新大小 @ 新時間`)。
  只有目的地有的檔案不動(不刪除)。
- **簽章(`TreeSignature`)**:`(檔案數, 總位元組, 最新 mtime)`,由 `measure_tree` 遞迴計算。
  同時是穩定判斷(最新 mtime 夠舊才算寫完)和完成標記(簽章相同就不再碰)。
- 找資料夾時,`find_timeslot_dirs` 命中後不再往該資料夾內部找。

## 5. LRF 檔:`lrf.py`

`.lrf` 檔名範例:`LOTAAAA0001-20260911-172530.lrf`、`…_filtered.lrf`、`…_pub.lrf`。
**月份取自檔名裡的日期**(`timeslot.month_of_lrf_name`),不看 `sendout_*`、mtime 或複製時間。

`plan_lrf_sync` 先建立目的地索引(各月份目錄裡每個 `.lrf` 名稱的最新一份),
再挑出「每個名稱最新的來源」,然後逐檔判斷:

```
檔名沒有合法日期 ────────────────────────────► ERROR "cannot derive a date from the file name"
mtime 距現在 < stable_seconds ────────────────► SKIP "still being written"
同名還有更新的來源 ──────────────────────────► SKIP "a newer source with the same name exists"
目的地沒有這個名稱 ──────────────────────────► COPY_FILE → dst/<檔名月份>/<名稱>
目的地有,大小相同且 mtime 差 ≤2 秒 ───────────► UP_TO_DATE
目的地有,且目的地比來源新 ───────────────────► SKIP "destination is newer"
目的地有,來源較新 ──────────────────────────► COPY_FILE → 目的地那份的原路徑(帶 notes)
```

- **同名 = 同一個檔案**。取代是**原地**進行(不論目的地那份在哪個月份目錄),
  所以不會出現兩份;如果它放在錯的月份,交給 `relocate` 搬。
- 目的地不存在時 `index_destination` 回傳空索引;目錄讀不到才是 `ERROR`。
- 沒有 `dup` 目錄了。

## 6. 搬移放錯月份的項目:`relocate.py`

`plan_relocation(folder_dst, lrf_dst)` 掃每個根目錄底下的 `YYYYMM` 資料夾(以及根目錄本身),
對每個候選項目算出「它應該在哪個月」:

| 項目 | 候選條件 | 正確月份 |
| --- | --- | --- |
| 時間戳資料夾 | 目錄,名稱以 `YYYYMMDD-HHMMSS` 結尾 | 名稱裡的日期 |
| `.lrf` 檔 | 檔案,副檔名 `.lrf` | 檔名裡的日期 |

然後:

```
正確月份與目前所在月份相同 ─────────► 不產生 Action
算不出正確月份 ───────────────────► SKIP "cannot decide the correct month"
目標路徑已存在,或本輪已有別的項目要搬去 ─► SKIP "target already exists; …"
其他 ─────────────────────────────► MOVE(reason 寫明 "belongs in 202608, found in 202609")
```

- 直接放在根目錄、不在任何月份資料夾裡的項目也會被視為放錯(目前月份記為 `root`)。
- 搬移用 `os.rename`,目的地在同一個檔案系統(同一個 share 掛載)所以是原子的;
  `Executor._move` 在搬之前會再檢查一次目標不存在。
- **不會刪除**搬走後留下的空月份資料夾。

## 7. 執行與統計:`executor.py`

- **`_copy_tree`**:
  1. 目的資料夾已存在 → 直接在原地更新;不存在 → 先複製到同層的 `.<名稱>.partial`。
  2. `rsync -a -u --no-owner --no-group 來源/ 目的/`(不加 `--delete`;`-u` 不覆蓋較新的目的地檔案),
     再(預設)用 `rsync -rn -u --size-only --itemize-changes` 乾跑驗證:輸出裡還有 `>f` 開頭的行(檔案缺少或大小不同)就視為失敗。
  3. 新資料夾才需要 `os.rename` 成正式名稱。
  4. 成功後才把(來源、簽章)寫進狀態檔。失敗**不**標記,下一輪會重試。
  - 月份資料夾在這裡才 `makedirs`,所以不會再出現沒東西卻建出來的空月份。
- **`_copy_file`**:`shutil.copy2` 到 `.<名稱>.partial`,再 `os.replace`(覆蓋已存在的檔案是原子的);
  失敗會清掉暫存檔。暫存檔名不以 `.lrf` 結尾,不會被索引誤認。
- **`_move`**:`os.rename`,目標已存在就拒絕。
- **覆蓋紀錄**:動手前先寫 `REPLACING | <notes>`(複製中途掛掉也留得下紀錄);dry-run 寫 `DRY-RUN REPLACE | …`。
  **沒有 backup**:被覆蓋的舊內容不保留,只留這筆紀錄。
- 單一 Action 的 `OSError` / `RsyncError` 只計入 `failed` 並記 log,**不會中斷整輪**。
- **error log 只寫一次**:`DUPLICATE`、`ERROR`、複製失敗都經過 `ProblemLog`
  ([problems.py](lot_sync/problems.py)):每個問題有個 key(`種類|來源|原因`),key 已在狀態檔的
  `reported` 裡就不再寫。一輪結束後,`reported` 換成「這一輪仍存在的問題」,所以問題消失後再出現會再寫。
  dry-run 全部印出,而且不改狀態檔。
- `Report.summary()` 例:`applied=2 up_to_date=100 skipped=4 [no files yet: 3, still being written: 1] duplicates=0 failed=0`。
  每一輪都印,所以即使 error log 沒有新行,也看得出問題還在。
  跳過的項目預設不逐筆 log,dry-run 或 `--verbose` 才逐筆列出。

## 8. 狀態檔:`state.py`

JSON:

```json
{"done": {"<目的地路徑(= lot)>": {"source": "…", "files": 3, "bytes": 123, "newest_mtime": 1.0}},
 "reported": ["DUPLICATE|<來源>|<原因>", "…"]}
```

- `done`:一個 lot 只有一個擁有者。
- `reported`:已寫進 error log 的問題 key。
- 寫入時先寫 `.tmp` 再 `os.replace`,不會留下寫一半的檔。檔案壞掉或不存在 → 從空狀態開始並記 warning
  (安全:`rsync` 本來就是冪等的,只是第一輪會慢,而且已報過的問題會再報一次)。

## 9. CLI 與常駐:`cli.py`

- `sync`:建立 `SyncConfig` → 載入狀態 → 每輪 `run_sync_pass`(規劃資料夾線、LRF 線 → 一起交給 `Executor`)。
  `--once` 或 `--dry-run` 只跑一輪;否則每 `--interval` 秒一輪,收到 SIGINT / SIGTERM 才結束。
  失敗的一輪不會讓常駐程式退出。
- `relocate`:`--dry-run` / `--apply` 為必選的互斥參數,沒有預設值。
- 啟動檢查:資料夾線且非 dry-run 時,找不到 `rsync` 會直接以參數錯誤結束(exit 2)。
- 結束碼:`--once` / `relocate` 在有任何失敗或重複時回 1,否則 0。
- log 格式沿用舊程式的 `時間 | 等級 | 訊息`,原有的 grep 習慣仍可用。`--error-log-file` 只收 ERROR 等級。

## 10. 已知限制

1. **一直有新檔寫入的資料夾不會被複製**,直到最新檔案超過 `--stable-seconds`。
2. **已存在的資料夾是原地更新**,下游若在更新途中讀取可能看到不完整的內容;
   只有「新建」的資料夾有 rename 保護。
3. **一個 lot 只認一個來源**,而且兩個來源衝突時**不挑最新的**,只告警(每個問題寫一次到 error log)。
   PE 把同一個 lot 搬到別的資料夾也會被當成重複;確認無誤後要人工處理
   (刪多餘的來源,或從狀態檔移除該筆記錄)。
4. **覆蓋沒有 backup**,舊內容救不回來。
5. **簽章是在規劃時量的**。複製途中來源又變動,下一輪簽章不同,會再補一次(不會漏,但多一輪)。
6. **循序處理**。一個很大的資料夾(例如 32 萬檔案)跑 rsync 時,同一輪的其他項目要等。
   沒有單一項目的逾時;可用 `--rsync-arg=--timeout=…` 等參數限制 rsync 本身。
7. **`.lrf` 索引每輪都掃一次目的地**,檔案很多時在 SMB 上會慢。
8. **只比大小與 mtime(容差 2 秒)**,不比內容。
9. **檔名沒有日期的 `.lrf` 永遠不會被同步**,只在 error log 出現一次。
10. **`relocate` 目標已存在時只跳過**(計入摘要的 `skipped`,不進 error log)。
11. 與真實 rsync、SMB 掛載、sync-host 資料的互動**尚未驗證**,目前只有以假的 rsync 做的單元測試與端到端演練。
