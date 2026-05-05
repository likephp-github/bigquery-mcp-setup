**English** | [繁體中文](./README.md)

# BigQuery MCP Server Auto-Install Script

Let **Claude Desktop** query your **Google BigQuery** data directly — one command sets everything up.

## Preview

After installation, you can ask Claude things like:

> "List all BigQuery datasets in the `my-project` project."
> "How many orders did the `sales` dataset get in the last 7 days?"

Claude will query your BigQuery data through the MCP Server in real time and reply.

---

## Requirements

| Item | Description |
|------|-------------|
| Operating System | macOS (Intel or Apple Silicon) / Windows 10, 11 (PowerShell 5.1+) |
| Claude Desktop | [Download page](https://claude.ai/download) |
| Google Cloud account | Must have BigQuery access to the target project |
| Network | Internet connection required for downloading packages |

---

## Quick Start (macOS)

### Option 1: One-line install (fastest)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/likephp-github/bigquery-mcp-setup/main/setup-bigquery-mcp.sh)"
```

### Option 2: Download then run

```bash
curl -fsSL https://raw.githubusercontent.com/likephp-github/bigquery-mcp-setup/main/setup-bigquery-mcp.sh -o setup-bigquery-mcp.sh
chmod +x setup-bigquery-mcp.sh
./setup-bigquery-mcp.sh
```

### Option 3: git clone then run

```bash
git clone https://github.com/likephp-github/bigquery-mcp-setup.git
cd bigquery-mcp-setup
chmod +x setup-bigquery-mcp.sh
./setup-bigquery-mcp.sh
```

---

## Quick Start (Windows)

> Use **PowerShell 5.1 or later** (running as a regular user is recommended).

### Option 1: One-line install (fastest)

```powershell
powershell -ExecutionPolicy Bypass -Command "iwr -useb https://raw.githubusercontent.com/likephp-github/bigquery-mcp-setup/main/setup-bigquery-mcp.ps1 | iex"
```

### Option 2: Download then run

```powershell
iwr -useb https://raw.githubusercontent.com/likephp-github/bigquery-mcp-setup/main/setup-bigquery-mcp.ps1 -OutFile setup-bigquery-mcp.ps1
powershell -ExecutionPolicy Bypass -File .\setup-bigquery-mcp.ps1
```

### Option 3: git clone then run

```powershell
git clone https://github.com/likephp-github/bigquery-mcp-setup.git
cd bigquery-mcp-setup
powershell -ExecutionPolicy Bypass -File .\setup-bigquery-mcp.ps1
```

> If you see "running scripts is disabled on this system", relax the execution policy for the current session:
>
> ```powershell
> Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
> .\setup-bigquery-mcp.ps1
> ```

---

## Installation Flow

The script guides you through 7 steps via an interactive wizard:

```
Step 1: Prerequisite checks
  ├── Verify macOS environment
  ├── Verify Claude Desktop is installed
  ├── Install Homebrew (if missing)
  └── Install Google Cloud SDK (if missing)

Step 2: Set GCP Project ID
Step 3: Set BigQuery dataset region (e.g. asia-east1)

Step 4: Google Cloud authentication
  └── gcloud auth application-default login (opens browser)

Step 5: Install uv (Python package manager)
  ├── Install uv
  ├── Verify realpath compatibility (auto-fix if missing on macOS)
  └── Install Python 3.13 via uv

Step 6: Write Claude Desktop config
  ├── Detect existing config and merge (does not overwrite other MCP settings)
  └── Back up the original config file

Step 7: Verify the configuration
  └── Optional: auto-restart Claude Desktop
```

---

## Config Summary (after installation)

The script writes the BigQuery MCP entry into the Claude Desktop config file. Locations:

| Platform | Path |
|----------|------|
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Windows | `%APPDATA%\Claude\claude_desktop_config.json` |

Written content (macOS example):

```json
{
  "mcpServers": {
    "bigquery": {
      "command": "/Users/your-username/.local/bin/uvx",
      "args": [
        "mcp-server-bigquery",
        "--project", "your-gcp-project-id",
        "--location", "asia-east1"
      ]
    }
  }
}
```

On Windows the `command` will point to `C:\Users\your-username\.local\bin\uvx.exe` (or `%APPDATA%\uv\bin\uvx.exe`); the rest of the fields are the same.

---

## FAQ

### Q: I don't see the bigquery connection in Claude Desktop after install.

**A:** Check the following:
1. **Fully quit** Claude Desktop (menu bar → Quit, not just closing the window).
2. Relaunch Claude Desktop.
3. Go to **Settings → Developer** and confirm `bigquery` is shown in blue (running).

---

### Q: I'm hitting `realpath: command not found`.

**A:** The script auto-detects this and offers a fix. If you missed it, you can resolve it manually:

```bash
# Option A: install a shim (recommended)
sudo bash -c 'cat > /usr/local/bin/realpath << "EOF"
#!/bin/bash
while [[ "$1" == -* ]]; do shift; done
python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1"
EOF
chmod +x /usr/local/bin/realpath'

# Option B: install GNU coreutils
brew install coreutils
```

---

### Q: Homebrew install hits a permission error.

**A:** The script auto-detects this and prompts to fix it (auto or manual). It's common on Intel Macs under `/usr/local`.

---

### Q: `gcloud` is installed but the command isn't found.

**A:** Reopen the terminal, or load the environment manually:

```bash
# Apple Silicon
eval "$(/opt/homebrew/bin/brew shellenv)"

# Intel
eval "$(/usr/local/bin/brew shellenv)"
```

---

### Q: How do I restrict access to a specific dataset?

**A:** Enter the dataset name when the script asks in Step 3 — it will append a `--dataset` argument:

```json
"args": [
  "mcp-server-bigquery",
  "--project", "your-project",
  "--location", "asia-east1",
  "--dataset", "your_dataset"
]
```

---

### Q: How do I change the GCP project or BigQuery region?

**A:** Just rerun the script — it detects the existing config and asks whether to update (the original config is backed up automatically).

---

## Manual Removal

To remove the BigQuery MCP entry, edit the config file directly:

**macOS:**

```bash
open ~/Library/Application\ Support/Claude/claude_desktop_config.json
```

**Windows (PowerShell):**

```powershell
notepad "$env:APPDATA\Claude\claude_desktop_config.json"
```

Delete the `mcpServers.bigquery` block, save, and restart Claude Desktop.

The backup file lives in the same directory, named `claude_desktop_config.json.backup.YYYYMMDD_HHMMSS`.

---

## Version History

| Version | Date | Notes |
|---------|------|-------|
| v1.12.0 | 2026-05-05 | Windows script messages translated to English to sidestep Windows PowerShell console mojibake (internal script version bumped to 2.0.0) |
| v1.11.0 | 2026-05-05 | Windows script now performs OS platform and Windows version checks at startup (requires Windows 10+) |
| v1.10.0 | 2026-05-05 | Fixed mojibake on Windows PowerShell 5.1: added UTF-8 BOM and forced console output encoding to UTF-8 |
| v1.9.0 | 2026-05-05 | Added Windows 10/11 interactive installer (PowerShell) and dual-platform README |
| v1.8.0 | 2026-03-21 | Detect missing `realpath` and auto-create a shim |
| v1.7.0 | 2026-03-21 | Removed `env.UV_PYTHON`; switched to `uv python install` |
| v1.6.0 | 2026-03-21 | Fixed false positive when full-width chars are adjacent to variable names under `set -u` |
| v1.5.0 | 2026-03-21 | Added Python version detection and `CLOUDSDK_PYTHON` setup |
| v1.4.0 | 2026-03-21 | Fixed false negative when gcloud installs but `brew` returns non-zero |
| v1.3.0 | 2026-03-21 | Removed `set -e` in favor of explicit error handling |
| v1.2.0 | 2026-03-21 | Improved brew permission error detection |
| v1.1.0 | 2026-03-21 | Better prerequisite checks: auto-install Homebrew/gcloud |
| v1.0.0 | 2026-03-21 | Initial release |

---

## License

MIT
