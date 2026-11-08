# lot-sync 程式碼解釋

這份文件逐模組、逐函式說明 [lot_sync/](lot_sync/) 在做什麼:
資料怎麼流動、每個判斷為什麼這樣寫、出錯或被中斷時會發生什麼事。

- 用法與規則摘要:[README.zh-tw.md](README.zh-tw.md)
- 路徑佔位符沿用 sync_proj 的其他文件:`/mnt/dst-fs` 是 WEKA、`/mnt/src-share` 是 SMB share,
  跑這支程式的主機稱為 sync-host。lot-id 與檔名都是虛構的範例。
- 從 log 產生報告、還原腳本的工具與指令:[第 11 節](#11-從-log-產生報告與還原檔)

> 行號對應 2026-11-09 的程式碼(67 項測試通過)。改了程式請順手更新這份文件。
> 第 4.4 節與第 9 節的邊界情況,都在暫存目錄實際跑過;SIGTERM 的行為是讀程式碼推得的。
> 文中用到的 Python 寫法(`@dataclass`、`raise … from`、`defaultdict`…)整理在[附錄](#附錄python-寫法小抄)。

---

## 1. 全貌

### 1.1 它做什麼

```
來源(WEKA)                                   目的地(SMB share)
--folder-src/…/sendout_YYYYMMDD/…/<lot-id>/  ──►  --folder-dst/YYYYMM/<lot-id>/   資料夾線  folders.py
--lrf-src/…/<任何深度>/<name>.lrf             ──►  --lrf-dst/YYYYMM/<name>.lrf     LRF 線    lrf.py
                                                    放錯月份的項目 ──► 正確的 YYYYMM/  relocate  relocate.py
```

- **lot-id**:名稱以 `YYYYMMDD-HHMMSS` 結尾的資料夾,例如
  `LOTAAAA0001-20260911-172530`、`LOTC-20261103-112600`。
- **月份只看名稱裡的日期**。上面有幾層 PE 資料夾、在哪個 `sendout_YYYYMMDD` 裡、
  什麼時候複製的,都不影響。
- 兩條線可以只開一條。`sync` 會一輪做完兩條線;`relocate` 是另一個子指令,只整理目的地。

### 1.2 核心設計:規劃與執行分開

舊程式是「掃到就做」,所以很難加 dry-run,也很難寫測試。新程式拆成兩段:

```
規劃(唯讀)                         執行(唯一有副作用的地方)
  folders.py  ─┐
  lrf.py      ─┼─► list[Action] ─► Executor.run() ─► Report ─► "PASS | …"
  relocate.py ─┘       │                  │
                       │                  └─ dry-run:只印出來,什麼都不做
                       └─ 每個 Action 說明「做什麼、從哪到哪、為什麼」
```

這個切法帶來三條規則,後面每個模組都遵守:

1. **規劃不寫任何東西**,連空資料夾都不建。所以 dry-run 印出來的就是正式執行時的計畫。
2. **所有副作用都在 [executor.py](lot_sync/executor.py)**(加上 `SyncState.save()`)。
3. **讀不到就說讀不到**:列目錄失敗會丟 `ScanError`,變成 `ERROR` Action,不會被當成空資料夾。
   舊程式「一直只複製 0 files」就是吃了這個虧。

### 1.3 模組分層

```
cli.py                                  進入點:參數、常駐迴圈,把下面全部串起來
 ├─ folders.py   lrf.py   relocate.py   規劃(唯讀),各自回傳 list[Action]
 │     ├─ scan.py                       掃描檔案系統(唯讀)
 │     ├─ timeslot.py                   命名規則:名稱 → YYYYMM
 │     ├─ fileinfo.py                   兩個檔案的比較(大小 + mtime)
 │     └─ plan.py                       Action / Kind:規劃的輸出格式
 ├─ executor.py                         執行 Action、統計 Report
 │     ├─ rsync.py                      呼叫 rsync
 │     └─ problems.py                   error log 每個問題只寫一次
 ├─ state.py                            狀態檔(folders.py 讀它,executor.py 寫它)
 └─ config.py                           設定的 dataclass
```

| 檔案 | 行數 | 責任 |
| --- | ---: | --- |
| [timeslot.py](lot_sync/timeslot.py) | 41 | 月份規則:lot 名稱、`.lrf` 檔名 → `YYYYMM` |
| [fileinfo.py](lot_sync/fileinfo.py) | 33 | 大小 + mtime(容差 2 秒)的比較;覆蓋紀錄的文字格式 |
| [scan.py](lot_sync/scan.py) | 93 | 找 lot 資料夾、找 `.lrf`、算資料夾簽章。讀不到就丟 `ScanError` |
| [plan.py](lot_sync/plan.py) | 35 | `Kind` 與 `Action` |
| [folders.py](lot_sync/folders.py) | 103 | 規劃 lot 資料夾的同步 |
| [lrf.py](lot_sync/lrf.py) | 115 | 規劃 `.lrf` 檔的同步 |
| [relocate.py](lot_sync/relocate.py) | 68 | 規劃「把放錯月份的項目搬到正確月份」 |
| [executor.py](lot_sync/executor.py) | 138 | 執行 Action、dry-run、統計 `Report` |
| [problems.py](lot_sync/problems.py) | 16 | error log 去重 |
| [rsync.py](lot_sync/rsync.py) | 45 | `rsync` 的薄包裝,可以換成測試替身 |
| [state.py](lot_sync/state.py) | 64 | 狀態檔:已複製完的 lot 與它的來源、已報過的問題 |
| [config.py](lot_sync/config.py) | 29 | `FolderLane`、`LrfLane`、`SyncConfig` |
| [cli.py](lot_sync/cli.py) | 154 | 參數解析、串接、常駐迴圈、結束碼 |

只用標準函式庫(Python ≥ 3.8);複製資料夾時才需要外部的 `rsync`。

套件之外還有一支 [tools/report.py](tools/report.py),把一次執行的 log 整理成報告,見[第 11 節](#11-從-log-產生報告與還原檔)。

---

## 2. 一次 `sync` 從頭到尾

```
python3 -m lot_sync --log-file … --error-log-file … sync --once --folder-src … --lrf-src … …

 1. __main__.py               raise SystemExit(main())      main() 的回傳值就是結束碼
 2. cli.main                  build_parser → parse_args → configure_logging
 3. cli.sync_config_from      檢查參數組合,組成 SyncConfig(不可變)
 4. cli.run_sync              SyncState.load(state.json);建 Rsync;印 "LRF FALLBACK DIRS | …"
 5. cli.run_sync_pass         now = time.time()             ← 整輪共用同一個「現在」
      ├─ plan_folder_sync(folder_lane, state, stable_seconds, now) → [Action, …]
      ├─ plan_lrf_sync(lrf_lane, stable_seconds, now)              → [Action, …]
      └─ Executor(dry_run, rsync, state, verify).run(兩串 Action 接起來) → Report
 6. Executor.run              逐個 _handle(action);最後 _remember_problems 存回 reported
 7. log "PASS | applied=… up_to_date=… skipped=… [原因: 數量, …] duplicates=… failed=…"
 8. --once 或 --dry-run:Report.ok 就回 0,否則回 1
    常駐:_repeat 等 --interval 秒再從第 5 步開始,收到 SIGINT/SIGTERM 才停
```

幾個容易忽略的點:

- **兩條線全部規劃完,才開始執行**。規劃階段如果整個崩掉(見 [9.3](#93-錯誤處理的缺口)),
  這一輪什麼都不會做。
- **`now` 只取一次**。同一輪裡每個項目的「是否還在寫入」都用同一個時間點判斷。
- **規劃會讀狀態檔**(folders.py 用 `state.record_for`),但只有 executor 會寫。
  dry-run 也會讀狀態檔,所以 dry-run 的結果跟狀態檔的內容有關。

一輪正式執行的 log 大概長這樣(路徑縮寫):

```
2026-11-08 01:00:00,123 | INFO | LRF FALLBACK DIRS | derived
2026-11-08 01:00:41,002 | INFO | START | COPY_TREE  …/sendout_20261103/…/LOTC-20261103-112600 -> …/SENDOUT/202611/LOTC-20261103-112600
2026-11-08 01:00:52,310 | INFO | DONE | COPY_TREE  …/sendout_20261103/…/LOTC-20261103-112600 -> …/SENDOUT/202611/LOTC-20261103-112600
2026-11-08 01:00:52,400 | INFO | START | COPY_FILE  …/LOTAAAA0001-20260911-172530.lrf -> …/SENDOUT/202609/LOTAAAA0001-20260911-172530.lrf
2026-11-08 01:00:52,401 | INFO | REPLACING | …/SENDOUT/202609/LOTAAAA0001-20260911-172530.lrf: 1200000 B @ 2026-09-12 10:00:00 -> 1500000 B @ 2026-09-15 08:00:00
2026-11-08 01:00:52,512 | INFO | DONE | COPY_FILE  …
2026-11-08 01:00:53,000 | ERROR | DUPLICATE LOT | DUPLICATE  …/sendout_20261105/…/LOTAAAA0002-20261030-101500 -> …/SENDOUT/202610/LOTAAAA0002-20261030-101500  (lot-id also found at: …)
2026-11-08 01:00:53,100 | INFO | PASS | applied=2 up_to_date=500 skipped=100 [...] duplicates=20 failed=10
```

每一行的前綴代表什麼,見[第 7 節](#7-log-對照表)。

---

## 3. 基礎層

### 3.1 命名規則:`timeslot.py`

三個正規式([timeslot.py:10-13](lot_sync/timeslot.py#L10-L13)):

| 名稱 | 正規式 | 意思 |
| --- | --- | --- |
| `_TIMESLOT_SUFFIX` | `(\d{8})-\d{6}$` | 以「8 位數-6 位數」**結尾**。用 `search`,所以前面可以有任何字 |
| `_LRF_NAME` | `(\d{8})-\d{6}(?:_[A-Za-z0-9]+)*\.lrf$`,不分大小寫 | 時間戳後面可以接任意個 `_英數` 後綴,最後是 `.lrf` |
| `_MONTH_DIR` | `^\d{6}$` | 剛好 6 位數,例如 `202609` |

函式:

- `is_timeslot_name(name)`:名稱是不是 lot-id。
- `is_month_dir_name(name)`:是不是 `YYYYMM` 目錄名稱。只檢查 6 位數,不檢查月份是否合法。
- `month_of_timeslot(name)` / `month_of_lrf_name(name)`:回傳 `"YYYYMM"`,或 `None`。
- `_month_of_match`([:35](lot_sync/timeslot.py#L35)):把抓到的 8 位數交給
  `datetime.strptime(…, "%Y%m%d")`,**日期不存在(例如 13 月)就回傳 `None`**。
  時分秒那 6 位數不檢查。

實際結果(測過):

| 名稱 | 結果 |
| --- | --- |
| `LOTC-20261103-112600`(資料夾) | `202611` |
| `20261103-112600_x`(資料夾) | 不是 lot-id(不是以時間戳結尾) |
| `LOTAAAA0001-20260911-172530_pub.lrf` | `202609` |
| `…-20260911-172530_filtered_removed.lrf` | `202609`(後綴可以有好幾段) |
| `…-20260911-172530.LRF` | `202609`(副檔名不分大小寫) |
| `…-20260911-172530_pub(1).lrf` | `None`(括號不是英數) |
| `…-20260911-172530-2.lrf` | `None`(`-2` 不是 `_` 後綴) |
| `summary.lrf`、`notes(2).lrf`、`…_images.lrf` | `None`(沒有時間戳) |
| `…-20261399-000000.lrf` | `None`(日期不存在) |
| `…-20260911-999999.lrf` | `202609`(時分秒不檢查) |

為什麼回傳 `None` 而不是丟例外:由呼叫的人決定怎麼處理。
資料夾線變成 `SKIP`、LRF 線變成 `ERROR`(會進 error log)、relocate 變成 `SKIP`。

### 3.2 檔案比較:`fileinfo.py`

`FileInfo(size, mtime)` 是一個檔案的「指紋」。不比內容。

`MTIME_TOLERANCE_SECONDS = 2`([:5](lot_sync/fileinfo.py#L5)):SMB 上的時間戳精度可能比來源粗,
差 2 秒以內視為同一個時間。

三個判斷,S 是來源、D 是目的地:

| 情況 | `is_same_file(S, D)` | `is_newer(D, S)` | `is_replacement(S, D)` | 結論 |
| --- | :---: | :---: | :---: | --- |
| 大小相同,mtime 差 ≤ 2 秒 | ✓ | | | 同一份,不動 |
| D 比 S 新超過 2 秒 | | ✓ | | 目的地較新,不動 |
| 其他(大小不同,或 S 比較新) | | | ✓ | 會被覆蓋 |

- `is_replacement` = 「不是同一份,而且目的地不比較新」。這就是 `rsync -u` 的語意。
- `describe_replacement(path, old, new)` 產生覆蓋紀錄的文字:
  `<路徑>: <舊大小> B @ <舊時間> -> <新大小> B @ <新時間>`(本地時間)。

> **容差只存在於我們這邊。** LRF 線自己複製檔案,所以這裡的判斷就是最終決定。
> 資料夾線是交給 rsync 複製的,而 rsync 比的是精確的 mtime。所以在「差不到 2 秒」的邊界上,
> `REPLACING` 清單可能和 rsync 實際做的有一點出入,見 [9.4](#94-其他)。

### 3.3 唯讀掃描:`scan.py`

**`ScanError`**([:12](lot_sync/scan.py#L12))與 **`_walk`**([:31](lot_sync/scan.py#L31)):
`os.walk` 預設**遇到讀不到的目錄就靜靜跳過**。這樣一來,一個讀不到的目錄看起來就跟空的一樣。
`_walk` 傳了 `onerror=_raise_scan_error`,讓任何列目錄失敗都丟 `ScanError`,整個掃描中止。
根目錄不存在(例如掛載掉了)也算,實測會變成 `ERROR`。

| 函式 | 做什麼 | 注意 |
| --- | --- | --- |
| `list_dir(path)` | 排序過的 `os.listdir` | 失敗包成 `ScanError` |
| `find_timeslot_dirs(root)` | 遞迴找所有 lot-id 資料夾 | **命中就不再往裡面找**:從 `dirnames` 移除,`os.walk` 就不會進去。所以不會走進 lot 裡面的幾十萬個檔案,lot 裡的 lot 也不會被找到 |
| `find_lrf_files(root)` | 遞迴找所有 `.lrf`(不分大小寫) | 會走進 lot 資料夾裡面。結果排序過,後面的同分處理會用到這個順序 |
| `month_dirs(root)` | `root` 底下**直接**的 `YYYYMM` 目錄 | 只看一層 |
| `_iter_file_stats(root)` | 走過每個檔案,`os.lstat` | 用 `lstat`:symlink 算它自己,不跟過去。掃描途中被刪掉的檔案(`FileNotFoundError`)直接略過 |
| `measure_tree(root)` | 算 `TreeSignature(files, bytes, newest_mtime)` | 見下 |
| `file_infos(root)` | `{相對路徑: FileInfo}` | 用來比對目的地已有的檔案 |

**`TreeSignature`**([:17](lot_sync/scan.py#L17))是一個資料夾的指紋:檔案數、總位元組、最新的 mtime。它有兩個用途:

1. **判斷寫完了沒**:最新 mtime 離現在超過 `--stable-seconds`,才算寫完。
2. **判斷要不要再複製**:跟狀態檔裡上次複製時的簽章一樣,就不用再碰。

### 3.4 規劃的輸出格式:`plan.py`

`Kind`([:9](lot_sync/plan.py#L9))有七種:

| `Kind` | 意思 | 誰會產生 |
| --- | --- | --- |
| `COPY_TREE` | 用 rsync 複製一個資料夾 | folders |
| `COPY_FILE` | 複製一個檔案 | lrf |
| `MOVE` | 在目的地內搬移 | relocate |
| `SKIP` | 這次不處理,附原因 | 三個都會 |
| `UP_TO_DATE` | 已經是最新 | folders、lrf |
| `DUPLICATE` | 同一個 lot-id 有兩個來源,需要人看 | folders |
| `ERROR` | 規劃時就失敗(讀不到、檔名沒日期) | 三個都會 |

`Action`([:20](lot_sync/plan.py#L20))是不可變的 dataclass:

| 欄位 | 用途 |
| --- | --- |
| `kind` | 上表 |
| `src` | 來源路徑(relocate 的話是目前位置) |
| `dst` | 目的路徑。`SKIP`、`ERROR` 可能沒有 |
| `reason` | 人看的原因。`SKIP` 的原因會被統計進 `PASS` 摘要 |
| `signature` | 只有 `COPY_TREE` 有:規劃時量到的簽章,複製成功後寫進狀態檔 |
| `notes` | 這個動作會覆蓋的目的地檔案,每檔一筆 `describe_replacement` |

兩個方法:

- `problem_key()`:`"種類|來源|原因"`,用來判斷「這個問題報過了沒」(見 [5.2](#52-error-log-去重problemspy))。
  **reason 是 key 的一部分**。reason 變了(例如重複的 lot 多了第三份,`also found at:` 後面的清單變長),
  就會被當成新問題再報一次。
- `describe()`:log 裡看到的那一段,格式是 `"{:<10} {src}{ -> dst}{  (reason)}"`。
  種類靠左補空白到 10 個字元,所以 `COPY_TREE  /…` 中間有兩個空格。

### 3.5 設定:`config.py`

三個 `frozen=True` 的 dataclass:

- `FolderLane(src_root, dst_root)`
- `LrfLane(src_root, dst_root, fallback_dirs=())`
- `SyncConfig(folder_lane, lrf_lane, state_file, stable_seconds=60, verify=True, dry_run=False, rsync_binary="rsync", rsync_args=())`

沒開的線是 `None`。設定建好之後就不能改;cli.py 要加上 `fallback_dirs` 時,是用
`dataclasses.replace` 做一份新的。

---

## 4. 規劃層

### 4.1 lot 資料夾:`folders.py`

**`plan_folder_sync(lane, state, stable_seconds, now)`**([:28](lot_sync/folders.py#L28)):

1. `find_timeslot_dirs(src_root)` 找出所有 lot-id 資料夾。讀不到 → 整條線只回一個 `ERROR`。
2. `_destination_of`([:48](lot_sync/folders.py#L48))算每個來源的目的地:
   `<dst_root>/<名稱的月份>/<名稱>`,只用資料夾**自己的名稱**,不帶上層路徑。
   `sendout_20261103/PE-test/EXP1/20261030-120000` → `202610/20261030-120000`。
3. 建 `claimants`:「目的地 → 想要它的來源清單」。同一個目的地有兩個以上的來源,就是重複。
4. 每個來源交給 `_plan_one`,`_others` 告訴它「還有誰也要這個目的地」。

**`_plan_one`**([:58](lot_sync/folders.py#L58))依序判斷,第一個成立的就是結果:

```
名稱的日期不合法 ───────────────────────────► SKIP       "cannot derive a month from the folder name"
這一輪還有別的來源是同一個 lot-id ──────────► DUPLICATE  "lot-id also found at: …"
狀態檔說這個 lot 是從另一個來源同步的 ──────► DUPLICATE  "lot-id already synced from: …"
measure_tree 讀不到 ────────────────────────► ERROR
來源沒有任何檔案 ───────────────────────────► SKIP       "no files yet"
最新檔案離現在 < stable_seconds ────────────► SKIP       "still being written"
狀態檔有紀錄(同一個來源),簽章相同 ───────► UP_TO_DATE
其他(第一次看到,或簽章變了) ─────────────► COPY_TREE  帶 signature 與 notes
```

設計上的理由:

- **重複判斷放在量簽章之前**。資料夾還在寫入時就先告警,而且重複的 lot 不必付出掃描的成本。
  兩邊都標 `DUPLICATE`,不挑其中一份當正本,**也不覆蓋任何東西**。
- **狀態檔決定擁有者**。`done` 以目的地路徑為 key,一個 lot-id 只有一個來源。
  第一次成功複製的那個來源就是擁有者;之後在別處出現同名的,即使原來的來源已經被刪,也是 `DUPLICATE`。
- **沒有紀錄但目的地已存在**(舊程式複製的)不算衝突,而是當成 `COPY_TREE`:rsync 補齊後寫入紀錄,
  也就是「接管」它。第一次部署時,第一輪會對每個這樣的 lot 都跑一次。

**`_plan_copy` / `_replacements`**([:85](lot_sync/folders.py#L85)、[:93](lot_sync/folders.py#L93)):
目的地已經存在時,用 `file_infos` 分別列出兩邊的檔案,把相同相對路徑、`is_replacement` 成立的,
逐筆寫進 `notes`。

- 只有目的地有的檔案不列,也不會被刪(rsync 沒加 `--delete`)。
- 目的地比較新的檔案不列(rsync `-u` 不會覆蓋它)。
- 這一步要在 SMB 上列出整個目的地資料夾,大的 lot 會慢。

### 4.2 `.lrf` 檔:`lrf.py`

**`plan_lrf_sync(lane, stable_seconds, now)`**([:30](lot_sync/lrf.py#L30)):

1. `find_lrf_files(src_root)`:所有來源 `.lrf`。
2. `index_destination(dst_root)`:目的地已有的 `.lrf`,依名稱建索引。
3. `fallback`:哪些來源位在 fallback 目錄底下。
4. `_chosen_source_by_name`:每個名稱挑出一個勝出的來源。
5. 以上任何一步丟 `ScanError` 或 `OSError` → **整條線只回一個 `ERROR`**。
6. 每個來源交給 `_plan_one`。

**`index_destination`**([:43](lot_sync/lrf.py#L43)):掃 `dst_root` 底下**每個 `YYYYMM` 目錄的直接子項目**,
同一個名稱出現在好幾個月份時,留 mtime 最新的那份。

- 目的地根目錄不存在 → 空索引(第一次跑)。
- **索引不含根目錄本身,也不含月份目錄底下的子目錄**。後果見 [4.4](#44-兩條線看目的地的方式不一樣)。

**`_under_any(path, root, dir_names)`**([:61](lot_sync/lrf.py#L61)):
把「`root` 到檔案之間的每一層目錄名稱」拿出來,有任何一層**完整等於** `dir_names` 裡的名字就成立。

- `derived` 不會命中 `derived_old`。
- 檔案直接放在 `root` 時,相對路徑是 `.`,不會命中(cli.py 也不接受 `.` 當目錄名)。

**`_chosen_source_by_name(paths, fallback)`**([:69](lot_sync/lrf.py#L69)):
每個來源的排名是 tuple `(不在 fallback 裡, mtime)`。Python 比 tuple 時先比第一個元素,一樣才比第二個,所以:

| 同名的來源 | 勝出的 |
| --- | --- |
| 原始檔(舊)+ fallback 裡的(新) | 原始檔。`(True, 舊) > (False, 新)` |
| 兩份都不在 fallback 裡 | mtime 新的 |
| 兩份都在 fallback 裡 | mtime 新的 |
| 只有 fallback 裡有 | 它,照常同步 |
| 排名完全一樣(同 mtime) | 路徑排序在前的那份(`>` 是嚴格大於,先到先贏) |

沒設 `--lrf-fallback-dir` 時,第一個元素全是 `True`,就只比 mtime。

**`_plan_one`**([:84](lot_sync/lrf.py#L84)):

```
檔名沒有合法日期 ───────────────────────────► ERROR      "cannot derive a date from the file name"
stat 時檔案已經不見 ─────────────────────────► SKIP       "removed while planning"
stat 失敗(其他原因) ────────────────────────► ERROR      <錯誤訊息>
mtime 離現在 < stable_seconds ──────────────► SKIP       "still being written"
自己在 fallback 裡,勝出的不在 ──────────────► SKIP       "same name exists outside a fallback directory"
勝出的是別人 ───────────────────────────────► SKIP       "a newer source with the same name exists"
目的地沒有這個名稱 ─────────────────────────► COPY_FILE  → <dst>/<檔名的月份>/<名稱>
目的地有,大小相同、mtime 差 ≤ 2 秒 ─────────► UP_TO_DATE
目的地那份比較新 ───────────────────────────► SKIP       "destination is newer"
其他(來源比較新,或大小不同) ───────────────► COPY_FILE  → 目的地那份的原路徑,帶 notes
```

- **同名就是同一個檔案**。更新是**原地**的:寫回目的地那份所在的路徑,不管它在哪個月份。
  所以不會因為更新而多出一份;放錯月份的交給 `relocate` 搬。
- **沒有日期的檔名每一份都是 `ERROR`**,而且這個判斷在挑勝出者之前。
- 「還在寫入」的判斷在挑勝出者之前:如果勝出的那份還在寫,這一輪這個名稱什麼都不複製,下一輪再說。
- 舊程式那個放同名檔的 `dup` 目錄已經不用了。

### 4.3 搬移放錯月份的項目:`relocate.py`

**`plan_relocation(folder_dst, lrf_dst)`**([:19](lot_sync/relocate.py#L19))對每個給定的根目錄跑一次 `_plan_root`,
每次帶兩個小函式:

| | 候選條件(`Candidate`) | 正確月份(`MonthRule`) |
| --- | --- | --- |
| 資料夾線 | `_is_timeslot_dir`:是目錄,名稱是 lot-id | 名稱的日期 |
| LRF 線 | `_is_lrf_file`:是檔案,副檔名 `.lrf` | 檔名的日期 |

`MonthRule` 和 `Candidate` 只是型別別名(「吃一個路徑、回傳 X 的函式」),讓 `_plan_root` 不用知道它在處理哪一種東西。

**`_plan_root`**([:38](lot_sync/relocate.py#L38)):要看的容器是「根目錄本身 + 每個 `YYYYMM` 目錄」,
只看它們的**直接子項目**。`claimed` 記住這一輪已經有人要搬去的目標,避免兩個項目搬到同一個位置。

**`_plan_entry`**([:55](lot_sync/relocate.py#L55)):

```
算不出正確月份 ─────────────────────────────► SKIP  "cannot decide the correct month"
正確月份 = 目前所在月份 ────────────────────► (不產生 Action,也不計數)
目標已存在,或這一輪已有別人要搬去 ─────────► SKIP  "target already exists; belongs in 202608, found in 202609"
其他 ───────────────────────────────────────► MOVE  "belongs in 202608, found in 202609"
```

- 直接放在根目錄的項目,目前月份記為 `root`,一定算放錯。
- 只搬不刪:搬走後留下的空月份目錄不會被刪。
- relocate 不讀也不寫狀態檔,也不檢查「是不是還在寫入」。

### 4.4 兩條線看目的地的方式不一樣

這一節的每一格都在暫存目錄實際跑過。

| 目的地上已有一份,它放在… | 資料夾線(`folders.py`) | LRF 線(`lrf.py`) |
| --- | --- | --- |
| 正確的月份 | 看得到 → 補齊或 `UP_TO_DATE` | 看得到 → 原地更新或 `UP_TO_DATE` |
| 錯的月份 | **看不到** → 在正確月份**再複製一份** | 看得到 → 原地更新那份(還是在錯的月份) |
| 根目錄(不在任何月份裡) | **看不到** → 再複製一份 | **看不到** → 在正確月份**再複製一份** |
| 月份目錄底下的子目錄 | 看不到 | 看不到 |

原因:資料夾線只檢查 `<dst>/<正確月份>/<lot-id>` 這**一個**路徑;LRF 線的索引只涵蓋各月份目錄的直接子項目。

對部署的意義:

- **正式 sync 之前,`relocate --dry-run` 不能有資料夾的 `MOVE`**,否則那些 lot 會在目的地上變成兩份。
- **relocate 裡 `found in root` 的 `.lrf`**:如果來源也有同名檔,sync 會在月份目錄放第二份;
  之後 relocate 會因為「目標已存在」而跳過根目錄那份,要人工比對後刪掉。不會覆蓋或遺失資料,只是多一份。
  檢查:`grep 'DRY-RUN | MOVE' relocate-dryrun.log | grep -c 'found in root)'`。

---

## 5. 執行層

### 5.1 `executor.py`

**`Report`**([:16](lot_sync/executor.py#L16)):五個計數加上 `skip_reasons`(每種 SKIP 原因各幾個)。

- `ok`:`failed == 0 and duplicates == 0`。只要有重複的 lot,`ok` 就是 False。
- `summary(dry_run)`:`PASS` 那一行。dry-run 時 `applied` 會改寫成 `would_apply`,避免誤會成真的做了。
  原因依字母排序。

**`Executor.run`**([:49](lot_sync/executor.py#L49)):建一個 `ProblemLog`,逐個 `_handle`,最後 `_remember_problems`。

**`_handle`**([:64](lot_sync/executor.py#L64)) 依種類分派:

| `Kind` | 計入 | log |
| --- | --- | --- |
| `UP_TO_DATE` | `up_to_date` | DEBUG(只有 `--verbose` 看得到,dry-run 也一樣) |
| `SKIP` | `skipped`、`skip_reasons[reason]` | dry-run 是 INFO,正式是 DEBUG |
| `DUPLICATE` | `duplicates` | ERROR `DUPLICATE LOT \| …`,經過 ProblemLog |
| `ERROR` | `failed` | ERROR `PLAN FAILED \| …`,經過 ProblemLog |
| 其他三種,dry-run | `applied` | INFO `DRY-RUN \| …`,加上每筆 `DRY-RUN REPLACE \| …` |
| 其他三種,正式 | 交給 `_apply` | 見下 |

**`_apply`**([:86](lot_sync/executor.py#L86)):

1. log `START | …`。
2. **先**把 `notes` 逐筆 log 成 `REPLACING | …`。先記再做,複製到一半掛掉也留得下紀錄。
3. 呼叫對應的 `_copy_tree` / `_copy_file` / `_move`。
4. 成功 → `applied += 1`、log `DONE | …`。
   丟 `OSError` 或 `RsyncError` → `failed += 1`、經過 ProblemLog 記 `FAILED | …: <錯誤>`
   (key 是 `FAILED|<來源>`,不含錯誤訊息)。**單一動作失敗不會中斷這一輪**,下一個動作照做。

**`_copy_tree`**([:109](lot_sync/executor.py#L109)):

```
目的地已存在?
  是 → staging = 目的地本身(原地更新:補晚到的檔案、接續上次中斷的)
  否 → staging = 同一層的 .<名稱>.partial(partial_path)
makedirs(月份目錄)              ← 月份目錄到這裡才建,所以不會有空的月份目錄
rsync.copy_tree(src, staging)   ← rsync -a -u --no-owner --no-group src/ staging/
rsync.verify_tree(src, staging) ← 除非 --no-verify
staging 不是目的地 → os.rename(staging, 目的地)
state.mark_done(目的地, src, 規劃時的簽章);state.save()
```

- **新資料夾整個一次出現**:先寫在 `.名稱.partial`,驗證通過才 rename。讀目的地的人看不到寫一半的新資料夾。
- **失敗時不清掉 `.partial`**。下一輪會 rsync 進同一個 `.partial`,接著做,不必從頭來。
- **每複製完一個 lot 就存一次狀態檔**。中途被殺掉的話,已完成的 lot 不會重做。
- 簽章用的是規劃時量的。複製途中來源又有新檔案的話,下一輪簽章不同,會再補一次。

**`_copy_file`**([:123](lot_sync/executor.py#L123)):

- `shutil.copy2` 複製到 `.<名稱>.partial`,再用 `os.replace` 換成正式名稱。
  `os.replace` 在同一個檔案系統內是原子的,覆蓋舊檔也是。
- `copy2` 會連 mtime 一起複製,所以下一輪 `is_same_file` 成立,變成 `UP_TO_DATE`。
  **這一點是「不會每輪重複複製」的關鍵**。
- 暫存檔名以 `.partial` 結尾,不會被 `index_destination` 誤認成 `.lrf`。
- `finally` 會清掉失敗留下的暫存檔(成功的話它已經被 rename 走了)。

**`_move`**([:134](lot_sync/executor.py#L134)):目標存在就丟 `FileExistsError`(規劃後到執行前這段時間被別人建了),
否則建月份目錄,再 `os.rename`。

**`_remember_problems`**([:58](lot_sync/executor.py#L58)):正式執行、而且這一輪的問題集合跟上次不同,
才把 `state.reported` 換成這一輪的集合並存檔。dry-run 和 relocate(沒有 state)都不存。

### 5.2 error log 去重:`problems.py`

`ProblemLog(already_reported, repeat_all)`([:6](lot_sync/problems.py#L6)):

- `report(key, message)`:把 key 加進 `current`;key 不在 `already_reported` 裡才真的 `logging.error`。
- 一輪結束後,`current` 變成新的 `reported`。

所以:

| 情況 | error log |
| --- | --- |
| 問題第一次出現 | 寫一次 |
| 問題連續好幾輪都在 | 不再寫,但 `PASS` 摘要的 `duplicates=` / `failed=` 每輪都算 |
| 問題消失一輪後又出現 | 再寫一次 |
| 程式重啟 | `reported` 存在狀態檔裡,不會重寫 |
| dry-run(`repeat_all=True`) | 每次都全部印出,而且不記下來 |

一般 log 裡也看得到這些 ERROR 行(`logging` 會送到所有 handler),只是同樣受去重影響。

### 5.3 `rsync.py`

```python
_BASE_FLAGS = ["-a", "-u", "--no-owner", "--no-group"]
```

| 參數 | 為什麼 |
| --- | --- |
| `-a` | 遞迴,保留 mtime、權限、symlink |
| `-u` | 目的地比較新的檔案不覆蓋 |
| `--no-owner --no-group` | SMB 上設不了擁有者。舊的 `copy_folder.py` 用的是同一組參數,只少了 `-u` |
| 不加 `--delete` | 只有目的地有的檔案永遠不刪 |

- `copy_tree(src, dst)`:`rsync <extra> -a -u --no-owner --no-group src/ dst/`。
- `verify_tree(src, dst)`:`rsync <extra> -rn -u --size-only --itemize-changes src/ dst/`,
  也就是「假裝再同步一次,看會不會傳任何檔案」。輸出裡有 `>f` 開頭的行(檔案缺少或大小不同)就丟 `RsyncError`。
  只有目錄的行(`cd+++…`、`.d..t…`)不算。`-u` 讓「目的地比較新所以刻意沒覆蓋」的檔案不被當成失敗。
- `_as_dir`([:43](lot_sync/rsync.py#L43)):路徑結尾補 `/`。rsync 的來源**有斜線**是「複製裡面的東西」,
  沒有斜線是「把這個資料夾本身複製進去」,會多一層。
- `_run`:結束碼不是 0 → `RsyncError("rsync exited N: <stderr 最後 500 字>")`。
- `runner` 參數預設是 `subprocess.run`,測試換成假的,用來檢查組出來的指令。
- `--rsync-arg` 給的額外參數放在最前面,每次呼叫都會帶。值以 `--` 開頭時要寫成
  `--rsync-arg=--timeout=600`(用 `=` 連起來),不然 argparse 會把它當成另一個選項。

### 5.4 狀態檔:`state.py`

```json
{"done": {"<目的地路徑>": {"source": "<來源路徑>", "files": 3, "bytes": 123, "newest_mtime": 1730000000.0}},
 "reported": ["DUPLICATE|<來源>|<原因>", "FAILED|<來源>", "…"]}
```

- `done`:只有資料夾線用。key 是目的地路徑,也就是 lot-id(加上月份)。`.lrf` 不記,它每輪直接跟目的地比。
- `reported`:已經寫進 error log 的問題 key。
- `load`:檔案不存在 → 空狀態。壞掉(JSON 錯、欄位缺)或讀不到 → 空狀態,加一行 `STATE UNREADABLE` warning。
  從空開始是安全的:rsync 本身是冪等的,代價只是第一輪比較慢,而且報過的問題會再報一次。
- `save`:先寫 `state.json.tmp`,再 `os.replace`,不會留下寫一半的檔。
- **人工處理重複的 lot**:如果確認某個 lot 合法地換了來源,刪掉 `done` 裡那一筆(先停程式),
  下一輪就會把新來源當成擁有者。

---

## 6. CLI:`cli.py`

### 6.1 參數結構

```
python3 -m lot_sync [--log-file F] [--error-log-file F] [--verbose]  sync     [sync 的選項]
                                                                       relocate [relocate 的選項]
```

**`--log-file`、`--error-log-file`、`--verbose` 是全域選項,要放在子指令前面**。
寫成 `sync --verbose` 會被拒絕。

| `sync` 選項 | 預設 | 說明 |
| --- | --- | --- |
| `--folder-src` / `--folder-dst` | | 資料夾線,要一起給 |
| `--lrf-src` / `--lrf-dst` | | LRF 線,要一起給 |
| `--lrf-fallback-dir NAME` | 無 | 可重複。只能是目錄名稱,不能是路徑 |
| `--state-file` | `/var/lib/lot-sync/state.json` | |
| `--stable-seconds` | 60 | |
| `--interval` | 300 | 一輪**結束後**等多久再開始下一輪,不是固定週期 |
| `--once` | | 只跑一輪 |
| `--dry-run` | | 只印計畫;也只跑一輪 |
| `--no-verify` | | 不做複製後的 rsync 驗證 |
| `--rsync` / `--rsync-arg` | `rsync` / 無 | |

`relocate` 只有 `--folder-dst`、`--lrf-dst`,以及**必選、互斥**的 `--dry-run` / `--apply`,沒有預設值,
避免手滑真的搬了。

### 6.2 函式

- **`configure_logging`**([:63](lot_sync/cli.py#L63)):一律寫到 stderr(在 systemd 底下會進 journal),
  有給就再寫到 `--log-file`,以及一個只收 ERROR 的 `--error-log-file`。格式沿用舊程式的
  `時間 | 等級 | 訊息`,以前的 grep 習慣還能用。
- **`sync_config_from`**([:76](lot_sync/cli.py#L76)):把參數變成 `SyncConfig`,有問題就 `parser.error`(結束碼 2):
  - 一條線的兩個路徑只給了一個(`_lane`,[:98](lot_sync/cli.py#L98))。
  - 兩條線都沒給。
  - 有 `--lrf-fallback-dir` 但沒開 LRF 線;或名稱是空字串、`.`、`..`、含 `/`。
  - 開了資料夾線、不是 dry-run,卻找不到 rsync。
- **`run_sync_pass`**([:106](lot_sync/cli.py#L106)):一輪,見第 2 節。
- **`run_sync`**([:119](lot_sync/cli.py#L119)):載入狀態、建 `Rsync`;`--once` 或 `--dry-run` 跑一輪就回傳;
  否則交給 `_repeat`。
- **`_repeat`**([:130](lot_sync/cli.py#L130)):SIGINT / SIGTERM 的處理只是 `stop.set()`;
  `stop.wait(interval)` 等待時收到訊號會立刻醒來。**這一輪做到一半收到訊號,會做完這一輪才停**,
  見 [9.3](#93-錯誤處理的缺口)。
- **`run_relocate`**([:139](lot_sync/cli.py#L139)):`Executor(dry_run=…)` 不帶 rsync、不帶 state,
  印 `RELOCATE | …`。
- **`main`**([:148](lot_sync/cli.py#L148)):解析、設 log、分派子指令。

### 6.3 結束碼

| 結束碼 | 什麼時候 |
| --- | --- |
| 0 | `--once` / `--dry-run` / `relocate`:沒有 failed 也沒有 duplicates;常駐模式收到訊號正常結束 |
| 1 | 有任何 failed 或 duplicates(**只要目的地還有沒處理的重複 lot,`--once` 就一定是 1**);或沒被接住的例外(會印 traceback) |
| 2 | 參數錯誤(`parser.error`),包括找不到 rsync |

`systemctl status` 對結束碼 1 會顯示 `failed`。判斷一輪有沒有問題,要看 `PASS` 那一行的 `failed=`,不是看結束碼。

---

## 7. log 對照表

### 7.1 前綴

| 前綴 | 等級 | 印出的地方 | 進 error log | 意思 |
| --- | --- | --- | :---: | --- |
| `LRF FALLBACK DIRS \| a, b` | INFO | `run_sync` | | 啟動時一行,確認 fallback 目錄有生效 |
| `STATE UNREADABLE \| …` | WARNING | `SyncState.load` | | 狀態檔壞了,從空狀態開始 |
| `START \| <describe>` | INFO | `_apply` | | 開始一個動作 |
| `REPLACING \| <note>` | INFO | `_apply` | | 動手**前**記下會被覆蓋的檔案 |
| `DONE \| <describe>` | INFO | `_apply` | | 動作成功 |
| `FAILED \| <describe>: <錯誤>` | ERROR | `_apply` | ✓(每個來源一次) | 動作失敗,下一輪重試 |
| `DRY-RUN \| <describe>` | INFO | `_handle` | | 正式執行時會做這件事 |
| `DRY-RUN REPLACE \| <note>` | INFO | `_handle` | | 正式執行時會覆蓋這個檔案 |
| `DUPLICATE LOT \| <describe>` | ERROR | `_handle` | ✓ | 同一個 lot-id 有兩個來源,兩邊都不複製 |
| `PLAN FAILED \| <describe>` | ERROR | `_handle` | ✓ | 規劃時就失敗 |
| `SKIP …`、`UP_TO_DATE …`(沒有前綴) | INFO / DEBUG | `_handle` | | 見 5.1 的表 |
| `PASS \| …` | INFO | `run_sync_pass` | | 每輪的摘要 |
| `RELOCATE \| …` | INFO | `run_relocate` | | relocate 的摘要 |

`FAILED` 和 `PLAN FAILED` 都算進摘要的 `failed=`。要找真正複製失敗的,grep `'| FAILED |'`。

### 7.2 所有原因字串

| reason | `Kind` | 出自 | 意思 |
| --- | --- | --- | --- |
| `cannot derive a month from the folder name` | SKIP | folders | lot-id 的日期不存在 |
| `lot-id also found at: …` | DUPLICATE | folders | 這一輪有別的來源是同一個 lot-id |
| `lot-id already synced from: …` | DUPLICATE | folders | 狀態檔說擁有者是別的來源 |
| `no files yet` | SKIP | folders | 來源資料夾是空的 |
| `still being written` | SKIP | folders、lrf | 最新的 mtime 太近 |
| `cannot derive a date from the file name` | ERROR | lrf | `.lrf` 檔名沒有合法日期 |
| `removed while planning` | SKIP | lrf | 規劃途中檔案被刪 |
| `same name exists outside a fallback directory` | SKIP | lrf | 自己在 fallback 目錄裡,外面有同名的原始檔 |
| `a newer source with the same name exists` | SKIP | lrf | 同名的另一個來源勝出 |
| `destination is newer` | SKIP | lrf | 目的地那份比較新 |
| `cannot decide the correct month` | SKIP | relocate | 名稱沒有合法日期 |
| `target already exists; belongs in …, found in …` | SKIP | relocate | 正確位置已經有東西 |
| `belongs in …, found in …` | MOVE | relocate | 會搬 |
| 作業系統的錯誤訊息(`[Errno …] …`) | ERROR | 三者 | 讀不到 |

relocate 的兩種原因帶有月份,所以 `RELOCATE |` 摘要會依月份拆成好幾項。例如
`…belongs in 202601, found in 202604` 和 `…belongs in 202607, found in 202608` 會分開計數,要自己加起來。

### 7.3 例:讀一次 dry-run 的摘要(數字是示意)

```
PASS | would_apply=400 up_to_date=500 skipped=100 [a newer source with the same name exists: 50,
       cannot derive a month from the folder name: 1, destination is newer: 30, no files yet: 10,
       same name exists outside a fallback directory: 9] duplicates=20 failed=10
```

| 數字 | 來自哪裡 |
| --- | --- |
| `would_apply=400` | `COPY_TREE`(包含接管舊程式複製的 lot)加上 `COPY_FILE`;會覆蓋的檔案逐筆列在 `DRY-RUN REPLACE` |
| `up_to_date=500` | 大多是 LRF 線的 `is_same_file`。dry-run 時狀態檔還是空的,所以資料夾線幾乎不會有 `UP_TO_DATE` |
| `a newer source…: 50`、`same name…: 9` | `_chosen_source_by_name` 選掉的同名來源 |
| `destination is newer: 30` | 目的地那份比較新,不動 |
| `no files yet: 10`、`cannot derive a month…: 1` | folders 的 `_plan_one` |
| `duplicates=20` | folders 的兩種 `DUPLICATE` |
| `failed=10` | `PLAN FAILED`。常見的是 `cannot derive a date from the file name` |

---

## 8. 測試

```bash
cd sendout/lot-sync && python3 -m pytest -q     # 67 passed
```

- 全部用 pytest 的 `tmp_path` 暫存目錄。[tests/helpers.py](tests/helpers.py) 的 `write()` 建檔時可以指定 mtime,
  預設是一小時前(`OLD`),剛好超過「還在寫入」的門檻。
- `FakeRsync` 用 `shutil.copytree` 代替 rsync,可以設定成「一定失敗」;[tests/test_rsync.py](tests/test_rsync.py)
  則用假的 `runner` 檢查組出來的 rsync 指令。

| 測試檔 | 涵蓋 |
| --- | --- |
| [test_timeslot.py](tests/test_timeslot.py) | 名稱 → 月份,不存在的日期 |
| [test_folders.py](tests/test_folders.py) | 月份與目的地、空資料夾、寫入中、簽章相同就不動、兩種重複、接管舊程式的目的地、覆蓋清單 |
| [test_lrf.py](tests/test_lrf.py) | 月份取自檔名、原地更新、目的地較新不動、同名只取最新、沒日期是錯誤、規劃不建目錄、fallback 目錄 7 項 |
| [test_relocate.py](tests/test_relocate.py) | 搬到正確月份、根目錄的項目、目標存在不覆蓋、dry-run 不動 |
| [test_executor.py](tests/test_executor.py) | 複製後記住、失敗不記住也不留正式資料夾、dry-run 不動、原地補齊、覆蓋紀錄、error log 去重、重啟後仍記得 |
| [test_rsync.py](tests/test_rsync.py) | 參數(有 `-u`、沒有 `--delete`)、額外參數的位置、失敗訊息、驗證的判斷 |
| [test_cli.py](tests/test_cli.py) | `--lrf-fallback-dir` 的傳遞與拒絕 |
| [test_report.py](tests/test_report.py) | `tools/report.py` 讀得懂 Executor 實際寫出的 log:正式 sync、失敗與中斷、dry-run、relocate、TSV 格式 |

**沒有測到的**:真正的 rsync 執行檔、SMB 掛載、`_repeat` 與訊號、`main()` 從頭到尾、`configure_logging`、
壞掉的狀態檔。

---

## 9. 已知限制

### 9.1 刻意的取捨

1. **一直有新檔寫入的資料夾不會被複製**,直到最新的檔案超過 `--stable-seconds`。
2. **已存在的資料夾是原地更新**,下游如果在更新途中讀取,可能看到不完整的內容。只有新資料夾有 rename 保護。
3. **一個 lot 只認一個來源**。兩個來源衝突時不挑最新的,只告警。PE 合法地把 lot 搬到別的資料夾,
   也會被當成重複,要人工處理(見 5.4)。
4. **覆蓋沒有 backup**,只有 `REPLACING` 紀錄。第一次正式執行前是手動備份的,見 [11.4 A](#114-指令)。
5. **只比大小和 mtime**,不比內容。
6. **檔名沒有日期的 `.lrf` 永遠不會被同步**,只在 error log 出現一次。
7. **relocate 只看根目錄和月份目錄的直接子項目**;目標已存在只跳過(計入 `skipped`,不進 error log)。

### 9.2 效能

8. **循序處理**。一個很大的 lot 在跑 rsync 時,同一輪的其他項目都要等。
   沒有單一項目的逾時(`subprocess.run` 沒設 timeout),只能用 `--rsync-arg=--timeout=…` 限制 rsync 本身。
9. **LRF 線每輪都把目的地的月份目錄全部列一次**,檔案多時在 SMB 上會慢。
10. **第一輪會對每個「目的地已有、狀態檔沒記錄」的 lot** 做一次雙邊檔案清單比對、一次 rsync、一次驗證。

### 9.3 錯誤處理的缺口

以下是讀程式碼找到、並在暫存目錄重現過的行為。都還沒修。

11. **`_iter_file_stats` 只吞 `FileNotFoundError`**([scan.py:75](lot_sync/scan.py#L75))。
    其他 `lstat` 錯誤(權限、SMB 斷線的 `EIO`…)不會變成 `ScanError`,folders.py 也接不住,
    會從規劃階段一路丟出去:
    - `--once`:印 traceback,結束碼 1。因為規劃還沒做完,**這一輪什麼都沒改**。
    - 常駐:`_repeat` 沒有 `try`,**程式會直接結束**。要靠 systemd 的 `Restart=` 拉起來。
12. **LRF 目的地有一個 `stat` 不到的 `.lrf`**(例如斷掉的 symlink、SMB 錯誤),**整條 LRF 線這一輪就只剩一個 `ERROR`**。
    這個 `ERROR` 的來源欄寫的是 `--lrf-src`,真正出問題的目的地檔案在原因裡。
13. **常駐模式收到 SIGTERM 不會馬上停**:訊號處理只設旗標,`Executor.run` 不會在動作之間檢查它,
    所以會把這一輪做完。如果 systemd 也把 SIGTERM 送給正在跑的 rsync,那個動作會變成 `FAILED`,
    其餘動作繼續做;systemd 預設 90 秒後送 SIGKILL。新資料夾因為有 `.partial` 不會壞,
    原地更新中的資料夾可能停在一半,下一輪會補齊。`--once` 沒有裝訊號處理,收到 SIGTERM 就直接結束。
14. **log 檔不會自己輪替**。`logging.FileHandler` 一直開著同一個檔案;用 logrotate 時要設 `copytruncate`,
    不然 rotate 之後還是寫進舊檔。

### 9.4 其他

15. **`REPLACING` 清單用 2 秒容差,rsync 不用**。所以在邊界上會有兩種出入:
    - 大小相同、目的地舊 1–2 秒的檔案:rsync 會重寫,但清單裡沒有它。
    - 大小不同、目的地新 1–2 秒的檔案:清單裡有它,但 rsync `-u` 不會覆蓋。
16. **兩條線看目的地的範圍不同**(見 4.4):放錯月份或放在根目錄的項目,可能讓 sync 多複製一份。
17. **驗證狀態(截至 2026-11-09)**:
    - sync-host 的真實資料跑過 `sync` 與 `relocate` 的 dry-run,規劃層的結果都對得上。
    - `relocate --apply` 已經在 sync-host 正式執行,沒有失敗。
    - `sync` 在 2026-11-08 夜間第一次正式執行(`--once`,當時舊程式也還在跑),結果還在整理。

---

## 10. 修改程式時

- **新規則加在規劃層**,回傳新的 `Action`(或新的 reason),不要在規劃層寫檔案。
  這樣 dry-run 自動就會顯示它。
- **新的 SKIP 原因會直接出現在 `PASS` 摘要的 `[…]` 裡**。原因字串要短、穩定、不帶會變動的內容。
  它也是 `problem_key` 的一部分,改字串會讓已經報過的問題再報一次。
- **每條新規則都寫一個測試**,先確認拿掉新程式碼時測試會失敗。
- **改了 log 的格式**(`LOG_FORMAT`、`Action.describe()`、log 前綴),要一起改 [tools/report.py](tools/report.py)。
  [tests/test_report.py](tests/test_report.py) 會失敗提醒你。
- **範例只用佔位符**:文件、測試、註解裡的主機名、路徑、share 名稱、lot-id 都用虛構的值。

---

## 11. 從 log 產生報告與還原檔

正式執行的 log 是寫給 grep 用的,直接拿來看或拿來還原都不方便:

- 一個動作會分成好幾行(`START`、`REPLACING`、`DONE`)。
- `/var/log/lot-sync.log` 會累積每一次執行,dry-run 也算在內。

所以要先把**一次執行**整理成「一個項目一列」的表,才能拿去看、拿去報告,或拿來產生還原腳本。

### 11.1 報告工具:`tools/report.py`

```bash
python3 tools/report.py <一次執行的 log> <輸出.tsv>
```

- 只用標準函式庫,也不 import 套件,可以單獨複製到任何地方。
  部署主機上可以直接存成 `~/lot-sync-report.py`,下面的指令都用這個名字。
- 輸出 TSV,欄位是 `time  result  kind  src  dst  reason`。
  空欄位寫成 `-`,因為有些版本的 `column` 會把連續的 tab 合併,欄位就會錯位。
- 結束時印出每種 `result` 各有幾列。

它認得這些 log 行:

| log 行 | `result` | `src` / `dst` | `reason` |
| --- | --- | --- | --- |
| `DONE \| …` | `updated` | 動作的 a / b | relocate 的話是 `belongs in …, found in …` |
| `START \| …`,之後沒有對應的 `DONE` 或 `FAILED` | `unfinished` | 動作的 a / b | `START logged, no DONE or FAILED` |
| `REPLACING \| …` | `overwrote` | 所屬動作的來源 / 被覆蓋的檔案 | `舊大小 B @ 時間 -> 新大小 B @ 時間` |
| `FAILED \| …` | `failed` | 動作的 a / b | 錯誤訊息 |
| `DUPLICATE LOT \| …` | `duplicate` | 這個來源 / lot 的目的地 | `lot-id also found at: …` 或 `lot-id already synced from: …` |
| `PLAN FAILED \| …` | `error` | 出問題的路徑 / 通常是 `-` | 原因 |
| `DRY-RUN \| …` | `would-update` | a / b | |
| `DRY-RUN REPLACE \| …` | `would-overwrite` | 同 `overwrote` | 同 `overwrote` |
| `SKIP …`(只有 dry-run 會印) | `skipped` | a / b | 原因 |
| 其他(`PASS`、`RELOCATE`、`LRF FALLBACK DIRS`…) | 不列出 | | |

解析的方式:

- `LINE`:拆出時間、前綴、內容。前綴不在上表、內容也不是 `SKIP ` 開頭的行,直接跳過。
- `ACTION`:解析 `Action.describe()` 的格式 `種類  a -> b  (原因)`。
  `a` 用非貪婪比對,` -> b` 和 `  (原因)` 都可有可無。
- `FAILURE`:`FAILED` 行的格式是 `describe(): 錯誤`,`b` 取到第一個 `: ` 為止。
- `NOTE`:`REPLACING` 行是 `describe_replacement` 的格式。
- `REPLACING` 行本身沒有來源,所以程式會記住最近一個 `START`(dry-run 則是 `DRY-RUN`)的來源。
- `START` 先記在 `started` 裡,遇到同一組 a / b 的 `DONE` 或 `FAILED` 就拿掉。最後還留著的就是 `unfinished`。

限制:

- **一次只能餵一次執行的 log**。dry-run 每次都會把所有問題重印一遍,好幾次執行混在一起就會重複計算。
- **`skipped` 只有 dry-run 的 log 才有**,因為正式執行時 SKIP 是 DEBUG 等級。`UP_TO_DATE` 兩種都沒有。
- **它依賴 log 的格式**(`cli.LOG_FORMAT` 與 `Action.describe()`)。格式改了,
  [tests/test_report.py](tests/test_report.py) 會失敗,要一起改。
- **路徑裡如果有 ` -> `、或「兩個空格加左括號」,解析會出錯**。目前的資料沒有這種名稱。

### 11.2 取得「一次執行」的 log

| 方法 | 指令 | 適用 |
| --- | --- | --- |
| 執行時順便存一份(最簡單) | `… 2>&1 \| tee ~/<名稱>.log` | 手動跑的 dry-run、relocate |
| 從累積的 log 抽出最後一次 | `tac /var/log/lot-sync.log \| sed '/LRF FALLBACK DIRS/q' \| tac > ~/lot-sync-first.log` | 有給 `--lrf-fallback-dir` 的 sync。每次執行都以一行 `LRF FALLBACK DIRS` 開頭。**要在下一次執行之前抽** |
| 從 journal 抽 | `journalctl -u lot-sync-first -o cat > ~/lot-sync-first.log` | 用 `systemd-run --unit=…` 跑的。journald 預設每 30 秒最多收 10000 行,超過的會被丟掉 |

stderr 和 `--log-file` 寫的內容一樣,所以 tee 存下來的跟 log 檔裡的那一段相同。
`tac` 是倒過來的 `cat`:從檔尾往上讀,讀到第一行 `LRF FALLBACK DIRS`(也就是最後一次執行的開頭)就停,再倒回來。

### 11.3 部署主機上的報告檔一覽(以第一次切換為例)

這些都是照 11.4 的步驟產生的;還沒做的步驟就不會有對應的檔案。

| 檔案 | 內容 | 步驟 |
| --- | --- | --- |
| `~/lot-sync-dryrun.log`、`~/lot-sync-dryrun2.log` | 正式執行前的兩次 sync dry-run(第二次有加 fallback 目錄) | A |
| `/var/backups/lot-sync-pre-replace/` | 第一次正式 sync 前,會被覆蓋的檔案的舊版,保留完整路徑 | A |
| `~/lot-sync-first.log` | 第一次正式 sync(2026-11-08 夜間)的 log | B |
| `~/lot-sync-report.tsv` | 同上,一個項目一列 | B |
| `~/overwrote.txt`、`~/backed-up.txt` | 實際被覆蓋的檔案和已備份的檔案,用來比對有沒有漏 | B |
| `~/lot-sync-after.log`、`~/lot-sync-after.tsv` | 正式 sync 之後再跑一次 dry-run:現在還沒同步的,包含 SKIP | C |
| `~/relocate-dryrun.log`、`~/relocate-dryrun2.log` | relocate 之前的 dry-run | D |
| `~/relocate-apply.log`、`~/relocate-apply.tsv` | `relocate --apply`(2026-11-09)的 log 與逐筆搬移 | D |
| `~/relocate-undo.sh` | 把 relocate 搬過的全部搬回原位 | D |
| `/var/backups/lot-sync-relocate-20261109/` | 上面三個 relocate 檔案的備份 | D |
| `~/relocate-dryrun3.log` | 搬完之後的 dry-run,列出被跳過的項目 | E |
| `~/relocate-conflicts.txt`、`~/relocate-conflicts-cmp.txt` | 兩個月份都有一份的檔案,以及內容比對結果 | E |
| `/var/backups/lot-sync-relocate-same/` | 刪掉錯月份那份重複檔之前的備份 | E |

### 11.4 指令

`lot-sync-run.sh` 代表部署時包好路徑參數(來源、目的、log、狀態檔)的 wrapper,
`~/lot-sync-report.py` 是 11.1 的工具。

**A. 正式 sync 之前:備份會被覆蓋的檔案**

```bash
sudo lot-sync-run.sh sync --dry-run --lrf-fallback-dir derived 2>&1 \
  | tee ~/lot-sync-dryrun2.log | grep 'PASS |'
sudo mkdir -p /var/backups/lot-sync-pre-replace
grep 'DRY-RUN REPLACE' ~/lot-sync-dryrun2.log | sed -e 's/.*DRY-RUN REPLACE | //' -e 's/: [0-9]* B @ .*//' \
  | while read -r f; do sudo cp -p --parents "$f" /var/backups/lot-sync-pre-replace/; done
sudo find /var/backups/lot-sync-pre-replace -type f | wc -l     # 等於 DRY-RUN REPLACE 的行數
```

- `sed` 把 `DRY-RUN REPLACE | <路徑>: <大小> B @ …` 剪到只剩路徑。
- `cp -p --parents` 會保留 mtime,並在備份目錄底下重建完整路徑。還原時直接複製回原位就好。
- 這裡備份的是 dry-run 當下會被覆蓋的檔案。dry-run 之後到正式執行之間如果有新資料進來,
  要用 B 的最後一步檢查有沒有漏。

**B. 正式 sync 之後:抽出 log、產生報告、確認備份沒漏**

```bash
tac /var/log/lot-sync.log | sed '/LRF FALLBACK DIRS/q' | tac > ~/lot-sync-first.log
python3 ~/lot-sync-report.py ~/lot-sync-first.log ~/lot-sync-report.tsv

T=~/lot-sync-report.tsv
awk -F'\t' 'NR>1{print $2"\t"$3}' $T | sort | uniq -c                    # 每種結果 × 動作各幾個
awk -F'\t' '$2=="overwrote"{print $5}' $T | sort > ~/overwrote.txt
sudo find /var/backups/lot-sync-pre-replace -type f | sed 's|^/var/backups/lot-sync-pre-replace||' | sort > ~/backed-up.txt
comm -23 ~/overwrote.txt ~/backed-up.txt                                  # 被覆蓋但沒備份到的;應該沒有輸出
```

看表:

```bash
column -t -s $'\t' ~/lot-sync-report.tsv | less -S                                                   # 全部
awk -F'\t' 'NR==1 || $2=="updated"' ~/lot-sync-report.tsv | column -t -s $'\t' | less -S             # 只看成功的
awk -F'\t' 'NR==1 || ($2!="updated" && $2!="overwrote")' ~/lot-sync-report.tsv | column -t -s $'\t' | less -S   # 只看沒成功的
```

**C. 現在還有什麼沒同步**

```bash
sudo lot-sync-run.sh sync --dry-run --lrf-fallback-dir derived 2>&1 \
  | tee ~/lot-sync-after.log | grep 'PASS |'
python3 ~/lot-sync-report.py ~/lot-sync-after.log ~/lot-sync-after.tsv
```

這次 dry-run 也會寫進 `/var/log/lot-sync.log`,而且同樣以 `LRF FALLBACK DIRS` 開頭。
所以 **B 的 `tac` 那一步要在 C 之前做**,不然抽到的會是這次 dry-run。

**D. relocate:搬移、報告、還原腳本**

```bash
sudo lot-sync-run.sh relocate --dry-run 2>&1 | tee ~/relocate-dryrun2.log | grep 'RELOCATE |'
sudo lot-sync-run.sh relocate --apply   2>&1 | tee ~/relocate-apply.log   | grep 'RELOCATE |'
python3 ~/lot-sync-report.py ~/relocate-apply.log ~/relocate-apply.tsv
awk -F'\t' '$2=="updated" && $3=="MOVE"{printf "mv -n \"%s\" \"%s\"\n", $5, $4}' ~/relocate-apply.tsv > ~/relocate-undo.sh
wc -l < ~/relocate-undo.sh                                                # 等於 RELOCATE 摘要的 applied
sudo mkdir -p /var/backups/lot-sync-relocate-20261109
sudo cp -p ~/relocate-apply.log ~/relocate-apply.tsv ~/relocate-undo.sh /var/backups/lot-sync-relocate-20261109/
```

還原腳本:

- 每一行是 `mv -n "新位置" "舊位置"`,也就是把 TSV 的 `dst` 搬回 `src`。
- `-n`:舊位置已經有同名檔就不搬,不會覆蓋。還原後用 `relocate --dry-run` 確認一下。
- 全部還原:`sudo bash ~/relocate-undo.sh`。只還原一部分:`grep '/202608/' ~/relocate-undo.sh | sudo bash`。
- 還原之後檔案回到錯的月份,下次跑 relocate 又會被搬一次。新程式的同步不受影響,因為它的索引會看所有月份。
- 路徑裡如果有 `"`、`$` 或反引號,這個 awk 產生的指令會壞掉。目前的檔名沒有。

**E. 兩個月份都有一份的檔案**

```bash
sudo lot-sync-run.sh relocate --dry-run 2>&1 | tee ~/relocate-dryrun3.log | grep 'RELOCATE |'     # 搬完後應該是 would_apply=0
grep 'target already exists' ~/relocate-dryrun3.log | sed -E 's/.*\| SKIP +//; s/  \(.*//' > ~/relocate-conflicts.txt
while IFS= read -r line; do
  a=${line%% -> *}; b=${line#* -> }
  if sudo cmp -s "$a" "$b"; then printf 'SAME\t%s\t%s\n' "$a" "$b"; else printf 'DIFF\t%s\t%s\n' "$a" "$b"; fi
done < ~/relocate-conflicts.txt > ~/relocate-conflicts-cmp.txt
cut -f1 ~/relocate-conflicts-cmp.txt | sort | uniq -c
```

- 正式執行不會逐筆記下 SKIP,所以清單要從 dry-run 拿。
- `${line%% -> *}` 是 bash 的字串截斷:去掉第一個 ` -> ` 和它後面的全部,剩下錯月份那份的路徑。
  `${line#* -> }` 去掉第一個 ` -> ` 和它前面的全部,剩下正確月份那份的路徑。
- `cmp -s` 逐 byte 比對兩個檔案,不印任何東西,只用結束碼表示一不一樣。

內容一樣(SAME)的,錯月份那份是多餘的。先備份,再刪掉:

```bash
sudo mkdir -p /var/backups/lot-sync-relocate-same
grep '^SAME' ~/relocate-conflicts-cmp.txt | cut -f2 | while IFS= read -r f; do
  sudo cp -p --parents "$f" /var/backups/lot-sync-relocate-same/ && sudo rm "$f"
done
```

內容不一樣(DIFF)的先不要動,列出大小和時間交給資料負責人決定。在那之前,新程式只會更新兩份裡比較新的那份:

```bash
grep '^DIFF' ~/relocate-conflicts-cmp.txt | while IFS=$'\t' read -r _ a b; do sudo stat -c '%s B  %y  %n' "$a" "$b"; echo; done
```

---

## 附錄:Python 寫法小抄

| 寫法 | 出現在 | 意思 |
| --- | --- | --- |
| `@dataclass(frozen=True)` | config、plan、scan、state、lrf | 自動產生 `__init__`、`==`。`frozen` = 建好就不能改,也因此可以放進 set、當 dict 的 key |
| `field(default_factory=Counter)` | executor.Report | 每個 Report 各自一個新的 Counter。dataclass 不允許直接寫 `= Counter()`,因為那樣所有物件會共用同一個 |
| `dataclasses.replace(obj, x=…)` | cli | 複製一份 frozen 物件,只改一個欄位 |
| `class Kind(Enum)` | plan | 一組固定的名字,用 `is` 比較:`action.kind is Kind.SKIP` |
| `Optional[str]`、`Tuple[str, ...]` | 到處 | 型別提示:「可能是 None」、「任意長度、元素都是 str 的 tuple」。執行時不檢查 |
| `raise ScanError(...) from error` | scan | 丟出新的例外,並記下原因是 `error`。traceback 兩個都會印 |
| `os.walk(root, onerror=f)` | scan._walk | 預設遇到錯誤就跳過;給了 `onerror` 才會知道 |
| 在迴圈裡 `dirnames.remove(name)` | scan.find_timeslot_dirs | `os.walk` 由上往下走時,從 `dirnames` 拿掉的目錄就不會進去。迴圈跑的是 `list(dirnames)` 這份複本,才能邊跑邊刪 |
| `defaultdict(list)` | folders | 讀不存在的 key 時自動放一個空 list |
| `Counter` | executor | 專門計數的 dict,`c[key] += 1` 不用先初始化 |
| `(True, 5.0) > (False, 9.0)` | lrf._chosen_source_by_name | tuple 從第一個元素開始比,一樣才比下一個 |
| `lambda path: …` | relocate | 一行的匿名函式 |
| `Callable[[str], bool]` | relocate | 型別提示:「吃一個 str、回傳 bool 的函式」 |
| `try / except / else / finally` | executor | `else`:沒出錯才跑;`finally`:不管怎樣都跑 |
| `@classmethod` | state(`load`、`empty`) | 用類別本身呼叫,常用來寫「另一種建立物件的方式」 |
| `@staticmethod` | executor | 不需要 `self` 的方法 |
| `@property` | executor.Report.ok | 像屬性一樣讀(`report.ok`,沒有括號),其實是函式 |
| `threading.Event` + `signal.signal` | cli._repeat | 訊號處理只設旗標;`event.wait(秒數)` 可以被提早叫醒 |
| `subprocess.run(cmd, capture_output=True, text=True)` | rsync | 跑外部指令,stdout / stderr 收成字串,結束碼在 `returncode` |
| `os.replace` / `os.rename` | executor、state | 同一個檔案系統內都是原子的。在 Linux 上兩者對檔案都會直接覆蓋目標,所以 `_move` 先自己檢查目標存不存在 |
| `raise SystemExit(main())` | `__main__` | 用 `main()` 的回傳值當結束碼 |
| `"{:<10}".format(x)` | plan.describe | 靠左對齊,補空白到 10 個字元 |
