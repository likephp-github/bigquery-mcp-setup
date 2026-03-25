# BigQuery MCP Server 自動安裝腳本

讓 **Claude Desktop** 直接查詢你的 **Google BigQuery** 資料，一鍵完成所有設定。

## 效果預覽

安裝完成後，你可以在 Claude 對話中直接問：

> 「請列出 `my-project` 專案中所有的 BigQuery datasets」
> 「查詢 `sales` 資料集最近 7 天的訂單數量」

Claude 會透過 MCP Server 即時查詢你的 BigQuery 資料並回覆。

---

## 系統需求

| 項目 | 說明 |
|------|------|
| 作業系統 | macOS（Intel 或 Apple Silicon） |
| Claude Desktop | [下載頁面](https://claude.ai/download) |
| Google Cloud 帳號 | 需有目標專案的 BigQuery 存取權限 |
| 網路連線 | 安裝過程需要下載套件 |

> **注意：此腳本目前僅支援 macOS。**

---

## 快速開始

### 方式一：一行指令直接安裝（最快）

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/likephp-github/bigquery-mcp-setup/main/setup-bigquery-mcp.sh)"
```

### 方式二：下載後執行

```bash
curl -fsSL https://raw.githubusercontent.com/likephp-github/bigquery-mcp-setup/main/setup-bigquery-mcp.sh -o setup-bigquery-mcp.sh
chmod +x setup-bigquery-mcp.sh
./setup-bigquery-mcp.sh
```

### 方式三：git clone 後執行

```bash
git clone https://github.com/likephp-github/bigquery-mcp-setup.git
cd bigquery-mcp-setup
chmod +x setup-bigquery-mcp.sh
./setup-bigquery-mcp.sh
```

---

## 安裝流程說明

腳本會以互動式精靈引導你完成以下 7 個步驟：

```
步驟一：前置條件檢查
  ├── 確認 macOS 環境
  ├── 確認 Claude Desktop 已安裝
  ├── 安裝 Homebrew（若未安裝）
  └── 安裝 Google Cloud SDK（若未安裝）

步驟二：設定 GCP Project ID
步驟三：設定 BigQuery 資料集區域（如 asia-east1）

步驟四：Google Cloud 認證
  └── gcloud auth application-default login（開啟瀏覽器登入）

步驟五：安裝 uv（Python 套件管理工具）
  ├── 安裝 uv
  ├── 確認 realpath 相容性（macOS 缺少時自動修復）
  └── 透過 uv 安裝 Python 3.13

步驟六：寫入 Claude Desktop 設定檔
  ├── 自動偵測現有設定並合併（不覆蓋其他 MCP 設定）
  └── 備份原始設定檔

步驟七：驗證設定
  └── 可選：自動重啟 Claude Desktop
```

---

## 設定摘要（安裝完成後）

腳本會在 `~/Library/Application Support/Claude/claude_desktop_config.json` 寫入以下設定：

```json
{
  "mcpServers": {
    "bigquery": {
      "command": "/Users/你的使用者名稱/.local/bin/uvx",
      "args": [
        "mcp-server-bigquery",
        "--project", "your-gcp-project-id",
        "--location", "asia-east1"
      ]
    }
  }
}
```

---

## 常見問題

### Q：安裝後在 Claude Desktop 看不到 bigquery 連線？

**A：** 請確認以下步驟：
1. **完全退出** Claude Desktop（從選單列 → Quit，而非只關閉視窗）
2. 重新啟動 Claude Desktop
3. 前往 **Settings → Developer**，確認 `bigquery` 狀態為藍色（running）

---

### Q：遇到 `realpath: command not found` 錯誤？

**A：** 腳本會自動偵測並提供修復選項。若錯過，可手動解決：

```bash
# 方式 A：建立替代腳本（推薦）
sudo bash -c 'cat > /usr/local/bin/realpath << "EOF"
#!/bin/bash
while [[ "$1" == -* ]]; do shift; done
python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1"
EOF
chmod +x /usr/local/bin/realpath'

# 方式 B：安裝 GNU coreutils
brew install coreutils
```

---

### Q：Homebrew 安裝出現權限錯誤？

**A：** 腳本會自動偵測並提示你修復（支援自動或手動兩種方式），常見於 Intel Mac 的 `/usr/local` 目錄。

---

### Q：`gcloud` 安裝後找不到指令？

**A：** 重新開啟終端機，或手動載入環境：

```bash
# Apple Silicon
eval "$(/opt/homebrew/bin/brew shellenv)"

# Intel
eval "$(/usr/local/bin/brew shellenv)"
```

---

### Q：如何限定只存取特定 dataset？

**A：** 在步驟三詢問 Dataset 名稱時輸入即可，腳本會自動加入 `--dataset` 參數：

```json
"args": [
  "mcp-server-bigquery",
  "--project", "your-project",
  "--location", "asia-east1",
  "--dataset", "your_dataset"
]
```

---

### Q：想更換 GCP Project 或 BigQuery 區域？

**A：** 直接重新執行腳本，它會偵測到現有設定並詢問是否更新（自動備份原始設定）。

---

## 手動還原

若需要移除 BigQuery MCP 設定，直接編輯設定檔：

```bash
open ~/Library/Application\ Support/Claude/claude_desktop_config.json
```

刪除 `mcpServers.bigquery` 區塊後儲存，重啟 Claude Desktop 即可。

備份檔案位於同目錄下，檔名格式為 `claude_desktop_config.json.backup.YYYYMMDD_HHMMSS`。

---

## 版本歷程

| 版本 | 日期 | 說明 |
|------|------|------|
| v1.8.0 | 2026-03-21 | 新增 realpath 缺失偵測與自動建立替代腳本 |
| v1.7.0 | 2026-03-21 | 移除 env.UV_PYTHON 設定；改用 uv python install 解決 Python 問題 |
| v1.6.0 | 2026-03-21 | 修正全形字元緊接變數名稱導致 set -u 誤判 |
| v1.5.0 | 2026-03-21 | 新增 Python 版本偵測與 CLOUDSDK_PYTHON 設定 |
| v1.4.0 | 2026-03-21 | 修正 gcloud 安裝成功但 brew 回傳非零的誤判 |
| v1.3.0 | 2026-03-21 | 移除 set -e，改為手動錯誤處理 |
| v1.2.0 | 2026-03-21 | 修正 brew 權限錯誤偵測 |
| v1.1.0 | 2026-03-21 | 改善前置條件檢查：Homebrew/gcloud 自動安裝 |
| v1.0.0 | 2026-03-21 | 初始版本 |

---

## License

MIT
