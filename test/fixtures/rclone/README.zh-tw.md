# rclone JSON log fixtures

v4 filter 契約的釘定樣本:受支援 rclone 版本在純本地 scratch 產生的
`--use-json-log` 原始輸出(`<case>.jsonl`)與末筆 stats 的關鍵值
(`expected.json`)。版本見 `version.txt`。

| 檔 | 情境 | 重點 |
| --- | --- | --- |
| `cold.jsonl` | 空目的端全量拷 | transfers = 檔數 |
| `warm.jsonl` | 不變重掃 | transfers=0、checks=檔數 |
| `incr.jsonl` | 刪一檔後補齊 | transfers=1 |
| `updated.jsonl` | 同大小改寫(mtime 變) | transfers=1 —— 證實 mtime 比對有效 |
| `error-nosrc.jsonl` | 來源不存在 | 非零退出的輸出形狀 |

**sync-host 部署的 rclone 版本若與 `version.txt` 不同,先在該機跑
`bash generate-fixtures.sh` 重新釘定**(它只碰 mktemp scratch),並重跑
`ffds-sync-v4-local-test.sh` 的 V9 真實層確認契約仍成立,才准 smoke。

目前釘定:rclone v1.75.1(2026-09-08,本機產生;同日已另以容器化 samba
驗證 smb backend 端到端——見 `../../ffds-sync-v4.zh-tw.md` 驗證狀態一節)。
