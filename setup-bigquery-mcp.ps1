#Requires -Version 5.1
<#
.SYNOPSIS
    BigQuery MCP Server 互動安裝腳本 for Windows
.DESCRIPTION
    引導使用者完成 Claude Desktop + BigQuery MCP 設定
    版本：1.2.0  日期：2026-05-05

.NOTES
    執行方式（二選一）：
      powershell -ExecutionPolicy Bypass -File setup-bigquery-mcp.ps1
    或先允許目前 session 執行腳本：
      Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
      .\setup-bigquery-mcp.ps1
#>

$SCRIPT_VERSION = "1.2.0"
$SCRIPT_DATE    = "2026-05-05"

# ── 強制 UTF-8 輸出（避免 Windows PowerShell 5.1 預設 ANSI 代碼頁造成中文亂碼）─
try {
    if ($PSVersionTable.PSVersion.Major -le 5) {
        chcp 65001 > $null
    }
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch { }

# ── 系統需求檢查（OS 平台 / Windows 版本）────────────────────
# 注意：此區塊在函式定義之前，需直接使用 Write-Host
$platform = [System.Environment]::OSVersion.Platform
if ($platform -ne 'Win32NT') {
    Write-Host ""
    Write-Host "XX 此腳本僅支援 Windows 平台（偵測到: $platform）。" -ForegroundColor Red
    Write-Host "   macOS 使用者請改執行 setup-bigquery-mcp.sh" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

$osVersion = [System.Environment]::OSVersion.Version
if ($osVersion.Major -lt 10) {
    Write-Host ""
    Write-Host "XX 偵測到 Windows 版本 $($osVersion.ToString())，本腳本需要 Windows 10 或更新版本。" -ForegroundColor Red
    Write-Host "   建議升級至 Windows 10 (1809 以後) 或 Windows 11。" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

# Windows 11 起 OSVersion.Version.Major 仍為 10，需以 Build 編號區分（22000+ = Win11）
$winLabel = if ($osVersion.Build -ge 22000) { "Windows 11" } else { "Windows 10" }
Write-Host "OK 系統檢查通過：$winLabel (Build $($osVersion.Build)), PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green

# ── 顏色輸出 ────────────────────────────────────────────────

function Print-Header([string]$Title) {
    Write-Host ""
    Write-Host ("=" * 48) -ForegroundColor Blue
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 48) -ForegroundColor Blue
    Write-Host ""
}

function Print-Step([string]$Msg) { Write-Host ">> $Msg" -ForegroundColor Cyan }
function Print-Ok([string]$Msg)   { Write-Host "OK $Msg" -ForegroundColor Green }
function Print-Warn([string]$Msg) { Write-Host "!! $Msg" -ForegroundColor Yellow }
function Print-Err([string]$Msg)  { Write-Host "XX $Msg" -ForegroundColor Red }
function Print-Info([string]$Msg) { Write-Host "   $Msg" -ForegroundColor Gray }

function Ask([string]$Prompt, [string]$Default = "") {
    if ($Default) {
        $in = Read-Host "$Prompt [預設: $Default]"
        if ([string]::IsNullOrWhiteSpace($in)) { return $Default }
        return $in.Trim()
    }
    return (Read-Host $Prompt).Trim()
}

function Ask-YN([string]$Prompt) {
    while ($true) {
        $a = Read-Host "$Prompt [y/n]"
        if ($a -match '^[Yy]') { return $true }
        if ($a -match '^[Nn]') { return $false }
        Print-Warn "請輸入 y 或 n"
    }
}

function Pause-Wait {
    Write-Host ""
    Read-Host "按下 Enter 繼續..." | Out-Null
}

# ── 更新目前 session 的 PATH（讀取 Machine + User 合併）──────
function Refresh-EnvPath {
    $mp = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $up = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:PATH = "$mp;$up"
}

# ── 搜尋 gcloud 執行檔 ───────────────────────────────────────
function Find-Gcloud {
    # 1. PATH
    $found = Get-Command gcloud -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }

    Refresh-EnvPath
    $found = Get-Command gcloud -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }

    # 2. 常見硬編碼路徑（winget 安裝 / 官方安裝包）
    $candidates = @(
        "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
        "$env:ProgramFiles\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
        "${env:ProgramFiles(x86)}\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
        "$env:USERPROFILE\google-cloud-sdk\bin\gcloud.cmd"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ── 搜尋 uvx 執行檔 ──────────────────────────────────────────
function Find-Uvx {
    $found = Get-Command uvx -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }

    Refresh-EnvPath
    $found = Get-Command uvx -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }

    $candidates = @(
        "$env:USERPROFILE\.local\bin\uvx.exe",
        "$env:APPDATA\uv\bin\uvx.exe",
        "$env:USERPROFILE\.cargo\bin\uvx.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ── 搜尋相容 Python（3.10+）────────────────────────────────
function Find-CompatiblePython {
    foreach ($minor in 13, 12, 11, 10) {
        $cmd = Get-Command "python3.$minor" -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    foreach ($name in "python3", "python") {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            $ver = & $cmd.Source -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
            if ($ver -match '^3\.(\d+)$' -and [int]$Matches[1] -ge 10) {
                return $cmd.Source
            }
        }
    }
    return $null
}

# ── 寫入 JSON（UTF-8 無 BOM，PS 5.1 相容）───────────────────
function Write-JsonFile([string]$Path, [object]$Data) {
    $json    = $Data | ConvertTo-Json -Depth 10
    $utf8nb  = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $json + "`n", $utf8nb)
}

# ════════════════════════════════════════════════════════════
# 開始
# ════════════════════════════════════════════════════════════
Clear-Host
Write-Host ""
Write-Host "  +--------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |   BigQuery MCP Server 互動安裝精靈               |" -ForegroundColor Cyan
Write-Host "  |   Claude Desktop x Google BigQuery              |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  版本：v$SCRIPT_VERSION   日期：$SCRIPT_DATE" -ForegroundColor Gray
Write-Host ""
Write-Host "  此腳本將引導你完成 BigQuery MCP Server 的完整設定，"
Write-Host "  讓 Claude Desktop 能直接查詢你的 BigQuery 資料。"
Write-Host ""
Write-Host "  預計需要 5～10 分鐘，過程中需要網路連線。"
Write-Host ""

if (-not (Ask-YN "準備好開始了嗎？")) {
    Write-Host "已取消安裝。"
    exit 0
}

# ════════════════════════════════════════════════════════════
# 步驟一：前置條件檢查
# ════════════════════════════════════════════════════════════
Print-Header "步驟一：前置條件檢查"

# 1-1 確認 Windows
Print-Step "確認作業系統..."
if ($env:OS -ne "Windows_NT") {
    Print-Err "此腳本僅支援 Windows，偵測到目前系統為 $($env:OS)。"
    exit 1
}
Print-Ok "Windows 確認通過（$([System.Environment]::OSVersion.VersionString)）"

# 1-2 確認 Claude Desktop
Print-Step "確認 Claude Desktop 是否已安裝..."
$claudeCandidates = @(
    "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe",
    "$env:LOCALAPPDATA\Programs\Claude\Claude.exe",
    "$env:ProgramFiles\Claude\Claude.exe",
    "${env:ProgramFiles(x86)}\Claude\Claude.exe"
)
$claudeExe = $null
foreach ($p in $claudeCandidates) {
    if (Test-Path $p) { $claudeExe = $p; break }
}

if (-not $claudeExe) {
    Print-Warn "未偵測到 Claude Desktop（已搜尋常見路徑）"
    Print-Info "請先下載安裝：https://claude.ai/download"
    Write-Host ""
    if (-not (Ask-YN "已確認安裝完成，繼續？")) {
        Write-Host "請安裝 Claude Desktop 後再執行此腳本。"
        exit 1
    }
} else {
    Print-Ok "Claude Desktop 已安裝：$claudeExe"
}

# 1-3 Google Cloud SDK
Write-Host ""
Print-Step "確認 Google Cloud SDK (gcloud) 是否已安裝..."
$gcloudCmd = Find-Gcloud

if ($gcloudCmd) {
    $gcloudVer = (& $gcloudCmd --version 2>$null) | Select-Object -First 1
    Print-Ok "Google Cloud SDK 已安裝：$gcloudCmd"
    Print-Info "版本：$gcloudVer"
} else {
    Print-Warn "未偵測到 Google Cloud SDK"
    Write-Host ""
    Write-Host "  Google Cloud SDK 提供 gcloud 指令，用於驗證 BigQuery 存取權限。"
    Write-Host ""

    if (Ask-YN "是否透過 winget 安裝 Google Cloud SDK？") {
        Print-Step "執行 winget install Google.CloudSDK..."
        Write-Host ""
        winget install --id Google.CloudSDK --exact --accept-package-agreements --accept-source-agreements
        $wingetExit = $LASTEXITCODE

        # winget 有時回傳 -1978335212（已安裝）也算成功
        Refresh-EnvPath
        $gcloudCmd = Find-Gcloud

        if ($gcloudCmd) {
            Print-Ok "Google Cloud SDK 安裝成功：$gcloudCmd"
        } elseif ($wingetExit -ne 0) {
            Print-Err "winget 安裝失敗（exit code: $wingetExit）。"
            Print-Info "請以系統管理員身份重新執行，或手動下載安裝："
            Print-Info "  https://cloud.google.com/sdk/docs/install-sdk#windows"
            exit 1
        } else {
            Print-Warn "winget 安裝完成，但目前 session 找不到 gcloud。"
            Print-Info "請關閉並重新開啟 PowerShell 後再執行此腳本。"
            exit 1
        }
    } else {
        Print-Warn "略過 Google Cloud SDK 安裝。"
        if (-not (Ask-YN "確定要在沒有 gcloud 的情況下繼續嗎？")) {
            Print-Info "請安裝後重新執行：winget install Google.CloudSDK"
            exit 1
        }
    }
}

# 1-4 CLOUDSDK_PYTHON（選填）
if ($gcloudCmd) {
    Write-Host ""
    Print-Step "偵測系統上可用的 Python 版本（gcloud 建議 3.10+）..."
    $compatiblePy = Find-CompatiblePython
    if ($compatiblePy) {
        $pyVer = (& $compatiblePy --version 2>$null)
        Print-Ok "找到相容 Python：$compatiblePy（$pyVer）"
        $currentEnvPy = [System.Environment]::GetEnvironmentVariable("CLOUDSDK_PYTHON", "User")
        if ($currentEnvPy -ne $compatiblePy) {
            Write-Host ""
            Write-Host "  設定 CLOUDSDK_PYTHON 可讓 gcloud 使用正確的 Python 版本。"
            Write-Host "  設定路徑：" -NoNewline; Write-Host $compatiblePy -ForegroundColor Cyan
            Write-Host ""
            if (Ask-YN "是否將 CLOUDSDK_PYTHON 寫入使用者環境變數？（建議選 y）") {
                [System.Environment]::SetEnvironmentVariable("CLOUDSDK_PYTHON", $compatiblePy, "User")
                $env:CLOUDSDK_PYTHON = $compatiblePy
                Print-Ok "CLOUDSDK_PYTHON 已設定"
            }
        } else {
            Print-Ok "CLOUDSDK_PYTHON 已設定為正確路徑，略過。"
        }
    } else {
        Print-Warn "找不到 Python 3.10+，gcloud 將使用系統預設 Python。"
    }
}

Write-Host ""
Print-Ok "前置條件檢查完成！"
Pause-Wait

# ════════════════════════════════════════════════════════════
# 步驟二：取得 GCP Project ID
# ════════════════════════════════════════════════════════════
Print-Header "步驟二：設定 Google Cloud 專案"

Write-Host "  請輸入你的 GCP Project ID。"
Write-Host "  可在 Google Cloud Console 右上角或 Dashboard 頁面找到。"
Write-Host "  格式範例：" -NoNewline; Write-Host "my-project-123456" -ForegroundColor Cyan
Write-Host ""

$currentProject = ""
if ($gcloudCmd) {
    $raw = (& $gcloudCmd config get-value project 2>$null) | Where-Object { $_ -match '\S' } | Select-Object -First 1
    if ($raw -and $raw -ne "(unset)") { $currentProject = $raw.Trim() }
}

$gcpProjectId = Ask "請輸入 GCP Project ID" $currentProject
if ([string]::IsNullOrWhiteSpace($gcpProjectId)) {
    Print-Err "Project ID 不能為空。"
    exit 1
}
Print-Ok "Project ID：$gcpProjectId"

# ════════════════════════════════════════════════════════════
# 步驟三：取得 BigQuery Location
# ════════════════════════════════════════════════════════════
Print-Header "步驟三：設定 BigQuery 資料集區域"

Write-Host "  請輸入你的 BigQuery dataset 所在區域。"
Write-Host "  可在 Cloud Console → BigQuery → 點選 dataset → 查看「資料集位置」。"
Write-Host ""
Write-Host "  常見區域："
Write-Host "    asia-east1      " -ForegroundColor Cyan -NoNewline; Write-Host "台灣（彰化）"
Write-Host "    asia-east2      " -ForegroundColor Cyan -NoNewline; Write-Host "香港"
Write-Host "    asia-northeast1 " -ForegroundColor Cyan -NoNewline; Write-Host "日本（東京）"
Write-Host "    asia-southeast1 " -ForegroundColor Cyan -NoNewline; Write-Host "新加坡"
Write-Host "    US              " -ForegroundColor Cyan -NoNewline; Write-Host "美國（多區域）"
Write-Host "    EU              " -ForegroundColor Cyan -NoNewline; Write-Host "歐洲（多區域）"
Write-Host ""

$bqLocation = Ask "請輸入 BigQuery 資料集區域" "asia-east1"
if ([string]::IsNullOrWhiteSpace($bqLocation)) {
    Print-Err "區域不能為空。"
    exit 1
}
Print-Ok "BigQuery 區域：$bqLocation"

Write-Host ""
Print-Info "（可選）是否限定只存取特定 dataset？留空表示存取所有 datasets。"
$bqDataset = Ask "Dataset 名稱（可留空）" ""

Pause-Wait

# ════════════════════════════════════════════════════════════
# 步驟四：Google Cloud 認證
# ════════════════════════════════════════════════════════════
Print-Header "步驟四：Google Cloud 認證"

Write-Host "  接下來需要登入 Google Cloud，取得應用程式預設憑證（ADC）。"
Write-Host "  系統會開啟瀏覽器，請使用擁有 BigQuery 存取權限的 Google 帳號登入。"
Write-Host ""
Print-Warn "若瀏覽器未自動開啟，請複製終端機顯示的網址手動前往。"
Write-Host ""

if (-not $gcloudCmd) {
    Print-Warn "找不到 gcloud，略過認證步驟。"
    Print-Info "請安裝 Google Cloud SDK 後，手動執行以下指令完成認證："
    Print-Info "  gcloud auth application-default login"
    Print-Info "  gcloud config set project <YOUR_PROJECT_ID>"
    Print-Info "  gcloud auth application-default set-quota-project <YOUR_PROJECT_ID>"
} elseif (Ask-YN "是否現在進行 Google Cloud 登入認證？") {
    Print-Step "執行 gcloud auth application-default login..."
    Write-Host ""
    Print-Info "系統即將開啟瀏覽器，請完成 Google 帳號授權後回到此終端機。"
    Write-Host ""
    & $gcloudCmd auth application-default login
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Print-Ok "Google Cloud 登入完成"
    } else {
        Write-Host ""
        Print-Warn "Google Cloud 登入未完成（可能是取消或網路問題）。"
        Print-Info "你可以之後手動執行：gcloud auth application-default login"
        Print-Info "繼續後續設定步驟..."
    }
} else {
    Print-Warn "略過登入步驟。若未登入，MCP Server 將無法存取 BigQuery。"
    Print-Info "可隨時手動執行：gcloud auth application-default login"
}

if ($gcloudCmd) {
    Write-Host ""
    Print-Step "設定預設專案：$gcpProjectId"
    & $gcloudCmd config set project $gcpProjectId 2>$null
    if ($LASTEXITCODE -eq 0) {
        Print-Ok "預設專案已設定"
    } else {
        Print-Warn "設定預設專案失敗，請手動執行：gcloud config set project $gcpProjectId"
    }

    Print-Step "設定 quota project：$gcpProjectId"
    & $gcloudCmd auth application-default set-quota-project $gcpProjectId 2>$null
    if ($LASTEXITCODE -eq 0) {
        Print-Ok "Quota project 已設定"
    } else {
        Print-Warn "Quota project 設定失敗（若 ADC 尚未建立，屬正常現象）。"
        Print-Info "登入後可手動執行：gcloud auth application-default set-quota-project $gcpProjectId"
    }
}

Print-Ok "Google Cloud 認證設定完成"
Pause-Wait

# ════════════════════════════════════════════════════════════
# 步驟五：安裝 uv
# ════════════════════════════════════════════════════════════
Print-Header "步驟五：安裝 uv（Python 套件管理工具）"

$uvxPath = Find-Uvx

if ($uvxPath) {
    Print-Ok "uv / uvx 已安裝：$uvxPath"
} else {
    Print-Step "未偵測到 uvx，即將安裝 uv..."
    Write-Host ""
    if (Ask-YN "是否現在安裝 uv？（需要網路連線）") {
        Print-Step "執行 uv Windows 安裝腳本..."
        Write-Host ""
        Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression

        # 更新 PATH
        $env:PATH = "$env:USERPROFILE\.local\bin;$env:PATH"
        Refresh-EnvPath

        $uvxPath = Find-Uvx
        if (-not $uvxPath) {
            # fallback：尚未在 PATH 但檔案存在
            $fallback = "$env:USERPROFILE\.local\bin\uvx.exe"
            if (Test-Path $fallback) {
                $uvxPath = $fallback
                Print-Ok "uv 安裝完成，uvx 路徑：$uvxPath"
            } else {
                Print-Err "無法確認 uvx 路徑，請手動確認後修改設定檔。"
                Print-Info "常見安裝路徑：$env:USERPROFILE\.local\bin\uvx.exe"
                $uvxPath = "$env:USERPROFILE\.local\bin\uvx.exe"
            }
        } else {
            Print-Ok "uv 安裝完成，uvx 路徑：$uvxPath"
        }
    } else {
        Print-Err "需要 uv 才能執行 mcp-server-bigquery。請手動安裝後重新執行。"
        Print-Info '安裝指令（PowerShell）：powershell -c "irm https://astral.sh/uv/install.ps1 | iex"'
        exit 1
    }
}

Print-Ok "uvx 路徑：$uvxPath"

# ── 步驟五補充：確認 Python 3.13 ────────────────────────────
Write-Host ""
Print-Step "確認 uvx 可用的 Python 版本（需要 3.10+）..."

# 更新 uv
Print-Step "更新 uv 至最新版本..."
uv self update 2>$null
if ($LASTEXITCODE -eq 0) {
    Print-Ok "uv 已是最新版本"
} else {
    Print-Warn "uv self update 失敗（可能已是最新），繼續進行。"
}

Write-Host ""
Print-Step "透過 uv 安裝 Python 3.13（uvx 執行 mcp-server-bigquery 所需）..."
Write-Host ""

$uvPythonPath = ""
if (Ask-YN "是否透過 uv 安裝 Python 3.13？（約 30MB，建議選 y）") {
    uv python install 3.13
    if ($LASTEXITCODE -eq 0) {
        $uvPythonPath = (uv python find 3.13 2>$null | Select-Object -First 1)
        if ($uvPythonPath -and (Test-Path $uvPythonPath)) {
            $pyVer = (& $uvPythonPath --version 2>$null)
            Print-Ok "uv Python 3.13 已就緒：$uvPythonPath（$pyVer）"
        } else {
            Print-Ok "uv Python 3.13 已安裝，使用版本號識別。"
            $uvPythonPath = "3.13"
        }
    } else {
        Print-Warn "uv python install 3.13 失敗，Claude Desktop 可能出現 Python 路徑錯誤。"
        Print-Info "請之後手動執行：uv python install 3.13"
    }
} else {
    Print-Warn "略過。若 Claude Desktop 出現 Python 路徑錯誤，請執行：uv python install 3.13"
}

Pause-Wait

# ════════════════════════════════════════════════════════════
# 步驟六：寫入 Claude Desktop 設定檔
# ════════════════════════════════════════════════════════════
Print-Header "步驟六：設定 Claude Desktop"

$claudeConfigDir = "$env:APPDATA\Claude"
$configFile      = "$claudeConfigDir\claude_desktop_config.json"
Print-Step "目標設定檔：$configFile"

New-Item -ItemType Directory -Force -Path $claudeConfigDir | Out-Null

# 組建 args 陣列
$mcpArgs = [System.Collections.Generic.List[string]]@(
    "mcp-server-bigquery", "--project", $gcpProjectId, "--location", $bqLocation
)
if (-not [string]::IsNullOrWhiteSpace($bqDataset)) {
    $mcpArgs.Add("--dataset")
    $mcpArgs.Add($bqDataset)
}

$bqEntry = [PSCustomObject]@{
    command = $uvxPath
    args    = $mcpArgs.ToArray()
}

if (Test-Path $configFile) {
    Print-Warn "偵測到現有設定檔，內容如下："
    Write-Host ""
    Get-Content $configFile | ForEach-Object { Write-Host "  $_" }
    Write-Host ""

    if (Ask-YN "是否要在現有設定中新增/更新 bigquery 設定？（建議選 y）") {
        $backupFile = "$configFile.backup.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item $configFile $backupFile
        Print-Ok "已備份原始設定至：$backupFile"

        $rawJson = Get-Content $configFile -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($rawJson)) {
            $config = [PSCustomObject]@{ mcpServers = [PSCustomObject]@{} }
        } else {
            try {
                $config = $rawJson | ConvertFrom-Json
            } catch {
                Print-Warn "設定檔 JSON 解析失敗，將建立全新設定。"
                $config = [PSCustomObject]@{ mcpServers = [PSCustomObject]@{} }
            }
        }

        if (-not $config.PSObject.Properties["mcpServers"]) {
            $config | Add-Member -MemberType NoteProperty -Name "mcpServers" -Value ([PSCustomObject]@{})
        }

        if ($config.mcpServers.PSObject.Properties["bigquery"]) {
            $config.mcpServers.bigquery = $bqEntry
        } else {
            $config.mcpServers | Add-Member -MemberType NoteProperty -Name "bigquery" -Value $bqEntry
        }

        Write-JsonFile $configFile $config
        Print-Ok "設定已更新"
    } else {
        Print-Warn "略過設定檔更新。請手動編輯：$configFile"
    }
} else {
    Print-Step "建立新的設定檔..."
    $newConfig = [PSCustomObject]@{
        mcpServers = [PSCustomObject]@{
            bigquery = $bqEntry
        }
    }
    Write-JsonFile $configFile $newConfig
    Print-Ok "設定檔已建立"
}

Write-Host ""
Print-Step "最終設定檔內容："
Write-Host ""
Get-Content $configFile | ForEach-Object { Write-Host "  $_" }
Write-Host ""

Pause-Wait

# ════════════════════════════════════════════════════════════
# 步驟七：驗證設定
# ════════════════════════════════════════════════════════════
Print-Header "步驟七：驗證設定"

Print-Step "驗證 uvx 路徑..."
if ((Test-Path $uvxPath -ErrorAction SilentlyContinue) -or (Get-Command uvx -ErrorAction SilentlyContinue)) {
    Print-Ok "uvx 可執行"
} else {
    Print-Warn "無法驗證 uvx 路徑：$uvxPath"
    Print-Info "請確認 uv 已正確安裝，或手動修改設定檔中的 command 路徑。"
}

Print-Step "驗證 Google Cloud 認證..."
if ($gcloudCmd) {
    $token = (& $gcloudCmd auth application-default print-access-token 2>$null)
    if ($LASTEXITCODE -eq 0 -and $token) {
        Print-Ok "Google Cloud ADC 認證有效"
    } else {
        Print-Warn "無法驗證 Google Cloud 認證，請確認已完成步驟四的登入流程。"
    }
}

Print-Step "驗證設定檔格式..."
try {
    Get-Content $configFile -Raw | ConvertFrom-Json | Out-Null
    Print-Ok "設定檔 JSON 格式正確"
} catch {
    Print-Err "設定檔 JSON 格式有誤，請手動檢查：$configFile"
}

# ════════════════════════════════════════════════════════════
# 完成
# ════════════════════════════════════════════════════════════
Print-Header "安裝完成！"

Write-Host "  接下來的步驟：" -ForegroundColor White
Write-Host ""
Write-Host "  1. " -ForegroundColor Cyan -NoNewline
Write-Host "完全關閉 Claude Desktop（從系統匣右鍵選 Quit）"
Write-Host "  2. " -ForegroundColor Cyan -NoNewline
Write-Host "重新啟動 Claude Desktop"
Write-Host "  3. " -ForegroundColor Cyan -NoNewline
Write-Host "前往 Settings -> Developer"
Write-Host "     確認 bigquery 狀態顯示為 running（藍色）"
Write-Host ""
Write-Host "  驗證連線（在 Claude 新對話中輸入）：" -ForegroundColor White
Write-Host ""
Write-Host "  「請列出 $gcpProjectId 專案中所有的 BigQuery datasets」" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ──────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  設定摘要：" -ForegroundColor White
Write-Host "    Project ID   : " -NoNewline; Write-Host $gcpProjectId -ForegroundColor Cyan
Write-Host "    Location     : " -NoNewline; Write-Host $bqLocation -ForegroundColor Cyan
if (-not [string]::IsNullOrWhiteSpace($bqDataset)) {
    Write-Host "    Dataset      : " -NoNewline; Write-Host $bqDataset -ForegroundColor Cyan
}
Write-Host "    uvx 路徑     : " -NoNewline; Write-Host $uvxPath -ForegroundColor Cyan
Write-Host "    設定檔位置   : " -NoNewline; Write-Host $configFile -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

if (Ask-YN "是否現在重啟 Claude Desktop？") {
    Print-Step "關閉 Claude Desktop..."
    $procs = Get-Process -Name "Claude","claude" -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force
        Start-Sleep -Seconds 2
        Print-Ok "Claude Desktop 已關閉"
    } else {
        Print-Info "Claude Desktop 未在執行中"
    }

    Print-Step "啟動 Claude Desktop..."
    $launched = $false
    if ($claudeExe -and (Test-Path $claudeExe)) {
        Start-Process $claudeExe
        $launched = $true
    } else {
        $fromPath = Get-Command "Claude" -ErrorAction SilentlyContinue
        if ($fromPath) {
            Start-Process $fromPath.Source
            $launched = $true
        }
    }

    if ($launched) {
        Print-Ok "Claude Desktop 已重新啟動"
    } else {
        Print-Warn "無法自動啟動，請手動開啟 Claude Desktop。"
    }
}

Write-Host ""
Write-Host "  設定完成！祝使用愉快！" -ForegroundColor Green
Write-Host ""
