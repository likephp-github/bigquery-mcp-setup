#Requires -Version 5.1
<#
.SYNOPSIS
    BigQuery MCP Server interactive installer for Windows
.DESCRIPTION
    Guides the user through Claude Desktop + BigQuery MCP setup.
    Version: 2.1.0  Date: 2026-05-05

.NOTES
    How to run (pick one):
      powershell -ExecutionPolicy Bypass -File setup-bigquery-mcp.ps1
    Or relax the policy for the current session first:
      Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
      .\setup-bigquery-mcp.ps1
#>

$SCRIPT_VERSION = "2.1.0"
$SCRIPT_DATE    = "2026-05-05"

# Force UTF-8 output (defensive: covers the case where future strings include non-ASCII)
try {
    if ($PSVersionTable.PSVersion.Major -le 5) {
        chcp 65001 > $null
    }
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch { }

# System check (OS platform / Windows version)
# Note: this block runs before function definitions, so use Write-Host directly.
$platform = [System.Environment]::OSVersion.Platform
if ($platform -ne 'Win32NT') {
    Write-Host ""
    Write-Host "XX This script only supports Windows (detected: $platform)." -ForegroundColor Red
    Write-Host "   macOS users: please run setup-bigquery-mcp.sh instead." -ForegroundColor Gray
    Write-Host ""
    exit 1
}

$osVersion = [System.Environment]::OSVersion.Version
if ($osVersion.Major -lt 10) {
    Write-Host ""
    Write-Host "XX Detected Windows $($osVersion.ToString()); this script requires Windows 10 or later." -ForegroundColor Red
    Write-Host "   Please upgrade to Windows 10 (1809+) or Windows 11." -ForegroundColor Gray
    Write-Host ""
    exit 1
}

# Windows 11 still reports OSVersion.Major = 10; tell them apart by build number (22000+ = Win11).
$winLabel = if ($osVersion.Build -ge 22000) { "Windows 11" } else { "Windows 10" }
Write-Host "OK System check passed: $winLabel (Build $($osVersion.Build)), PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green

# Pretty-printing helpers

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
        $in = Read-Host "$Prompt [default: $Default]"
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
        Print-Warn "Please enter y or n."
    }
}

function Pause-Wait {
    Write-Host ""
    Read-Host "Press Enter to continue..." | Out-Null
}

# Refresh the current session's PATH (merge Machine + User scopes)
function Refresh-EnvPath {
    $mp = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $up = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:PATH = "$mp;$up"
}

# Locate the gcloud executable
function Find-Gcloud {
    # 1. PATH
    $found = Get-Command gcloud -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }

    Refresh-EnvPath
    $found = Get-Command gcloud -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }

    # 2. Common install paths (winget / official installer)
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

# Locate the uvx executable
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

# Locate a compatible Python (3.10+)
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

# Write JSON file (UTF-8 without BOM, PS 5.1 compatible)
function Write-JsonFile([string]$Path, [object]$Data) {
    $json    = $Data | ConvertTo-Json -Depth 10
    $utf8nb  = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $json + "`n", $utf8nb)
}

# ============================================================
# Start
# ============================================================
Clear-Host
Write-Host ""
Write-Host "  +--------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |   BigQuery MCP Server Interactive Installer      |" -ForegroundColor Cyan
Write-Host "  |   Claude Desktop x Google BigQuery               |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Version: v$SCRIPT_VERSION   Date: $SCRIPT_DATE" -ForegroundColor Gray
Write-Host ""
Write-Host "  This wizard will guide you through the full BigQuery MCP"
Write-Host "  setup so Claude Desktop can query your BigQuery data."
Write-Host ""
Write-Host "  Estimated time: 5-10 minutes. An internet connection is required."
Write-Host ""

if (-not (Ask-YN "Ready to begin?")) {
    Write-Host "Installation cancelled."
    exit 0
}

# ============================================================
# Step 1: Prerequisite checks
# ============================================================
Print-Header "Step 1: Prerequisite checks"

# 1-1 Confirm Windows
Print-Step "Checking operating system..."
if ($env:OS -ne "Windows_NT") {
    Print-Err "This script only supports Windows. Detected: $($env:OS)."
    exit 1
}
Print-Ok "Windows confirmed ($([System.Environment]::OSVersion.VersionString))"

# 1-2 Confirm Claude Desktop
Print-Step "Checking whether Claude Desktop is installed..."
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
    Print-Warn "Claude Desktop not found in common install paths."
    Print-Info "Please download and install: https://claude.ai/download"
    Write-Host ""
    if (-not (Ask-YN "Have you finished installing? Continue?")) {
        Write-Host "Please install Claude Desktop and rerun this script."
        exit 1
    }
} else {
    Print-Ok "Claude Desktop found: $claudeExe"
}

# 1-3 Google Cloud SDK
Write-Host ""
Print-Step "Checking whether Google Cloud SDK (gcloud) is installed..."
$gcloudCmd = Find-Gcloud

if ($gcloudCmd) {
    $gcloudVer = (& $gcloudCmd --version 2>$null) | Select-Object -First 1
    Print-Ok "Google Cloud SDK found: $gcloudCmd"
    Print-Info "Version: $gcloudVer"
} else {
    Print-Warn "Google Cloud SDK not found."
    Write-Host ""
    Write-Host "  The Google Cloud SDK provides the gcloud command, used to"
    Write-Host "  authenticate to BigQuery."
    Write-Host ""

    # winget is not bundled with Windows Server editions; detect first instead of assuming.
    $wingetAvail = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
    if (-not $wingetAvail) {
        Print-Info "winget is not available on this system (common on Windows Server)."
        Print-Info "Will fall back to downloading the official installer directly."
        Write-Host ""
    }

    if (Ask-YN "Install Google Cloud SDK now?") {
        $installExit = 0
        $installerLaunched = $false

        if ($wingetAvail) {
            Print-Step "Running: winget install Google.CloudSDK..."
            Write-Host ""
            winget install --id Google.CloudSDK --exact --accept-package-agreements --accept-source-agreements
            $installExit = $LASTEXITCODE
            # winget sometimes returns -1978335212 (already installed); treat that as success.
        } else {
            $installerUrl  = "https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe"
            $installerPath = Join-Path $env:TEMP "GoogleCloudSDKInstaller.exe"
            Print-Step "Downloading installer: $installerUrl"
            try {
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
                Print-Ok "Downloaded to $installerPath"
            } catch {
                Print-Err "Download failed: $($_.Exception.Message)"
                Print-Info "Please install manually: https://cloud.google.com/sdk/docs/install-sdk#windows"
                exit 1
            }
            Print-Step "Launching installer. Please complete the wizard (keep 'Add gcloud to PATH' checked)."
            try {
                Start-Process -FilePath $installerPath -Wait
                $installerLaunched = $true
            } catch {
                Print-Err "Failed to launch installer: $($_.Exception.Message)"
                exit 1
            }
        }

        Refresh-EnvPath
        $gcloudCmd = Find-Gcloud

        if ($gcloudCmd) {
            Print-Ok "Google Cloud SDK installed: $gcloudCmd"
        } elseif ($wingetAvail -and $installExit -ne 0) {
            Print-Err "winget install failed (exit code: $installExit)."
            Print-Info "Try rerunning as Administrator, or install manually:"
            Print-Info "  https://cloud.google.com/sdk/docs/install-sdk#windows"
            exit 1
        } else {
            Print-Warn "Install completed but gcloud is not visible in this session."
            Print-Info "Please close this PowerShell window, open a new one, then rerun this script."
            exit 1
        }
    } else {
        Print-Warn "Skipping Google Cloud SDK installation."
        if (-not (Ask-YN "Are you sure you want to continue without gcloud?")) {
            if ($wingetAvail) {
                Print-Info "Install it and rerun: winget install Google.CloudSDK"
            } else {
                Print-Info "Install it from: https://cloud.google.com/sdk/docs/install-sdk#windows"
            }
            exit 1
        }
    }
}

# 1-4 CLOUDSDK_PYTHON (optional)
if ($gcloudCmd) {
    Write-Host ""
    Print-Step "Detecting available Python versions (gcloud recommends 3.10+)..."
    $compatiblePy = Find-CompatiblePython
    if ($compatiblePy) {
        $pyVer = (& $compatiblePy --version 2>$null)
        Print-Ok "Compatible Python found: $compatiblePy ($pyVer)"
        $currentEnvPy = [System.Environment]::GetEnvironmentVariable("CLOUDSDK_PYTHON", "User")
        if ($currentEnvPy -ne $compatiblePy) {
            Write-Host ""
            Write-Host "  Setting CLOUDSDK_PYTHON tells gcloud which Python to use."
            Write-Host "  Path: " -NoNewline; Write-Host $compatiblePy -ForegroundColor Cyan
            Write-Host ""
            if (Ask-YN "Persist CLOUDSDK_PYTHON to user environment variables? (recommended: y)") {
                [System.Environment]::SetEnvironmentVariable("CLOUDSDK_PYTHON", $compatiblePy, "User")
                $env:CLOUDSDK_PYTHON = $compatiblePy
                Print-Ok "CLOUDSDK_PYTHON set."
            }
        } else {
            Print-Ok "CLOUDSDK_PYTHON already points to the right path; skipping."
        }
    } else {
        Print-Warn "No Python 3.10+ found. gcloud will fall back to its default Python."
    }
}

Write-Host ""
Print-Ok "Prerequisite checks complete!"
Pause-Wait

# ============================================================
# Step 2: GCP Project ID
# ============================================================
Print-Header "Step 2: Google Cloud project"

Write-Host "  Enter your GCP Project ID."
Write-Host "  You can find it in the Google Cloud Console (top right or Dashboard)."
Write-Host "  Example: " -NoNewline; Write-Host "my-project-123456" -ForegroundColor Cyan
Write-Host ""

$currentProject = ""
if ($gcloudCmd) {
    $raw = (& $gcloudCmd config get-value project 2>$null) | Where-Object { $_ -match '\S' } | Select-Object -First 1
    if ($raw -and $raw -ne "(unset)") { $currentProject = $raw.Trim() }
}

$gcpProjectId = Ask "GCP Project ID" $currentProject
if ([string]::IsNullOrWhiteSpace($gcpProjectId)) {
    Print-Err "Project ID cannot be empty."
    exit 1
}
Print-Ok "Project ID: $gcpProjectId"

# ============================================================
# Step 3: BigQuery Location
# ============================================================
Print-Header "Step 3: BigQuery dataset region"

Write-Host "  Enter the region your BigQuery dataset lives in."
Write-Host "  In Cloud Console: BigQuery -> click the dataset -> 'Dataset location'."
Write-Host ""
Write-Host "  Common regions:"
Write-Host "    asia-east1      " -ForegroundColor Cyan -NoNewline; Write-Host "Taiwan (Changhua)"
Write-Host "    asia-east2      " -ForegroundColor Cyan -NoNewline; Write-Host "Hong Kong"
Write-Host "    asia-northeast1 " -ForegroundColor Cyan -NoNewline; Write-Host "Japan (Tokyo)"
Write-Host "    asia-southeast1 " -ForegroundColor Cyan -NoNewline; Write-Host "Singapore"
Write-Host "    US              " -ForegroundColor Cyan -NoNewline; Write-Host "United States (multi-region)"
Write-Host "    EU              " -ForegroundColor Cyan -NoNewline; Write-Host "Europe (multi-region)"
Write-Host ""

$bqLocation = Ask "BigQuery dataset region" "asia-east1"
if ([string]::IsNullOrWhiteSpace($bqLocation)) {
    Print-Err "Region cannot be empty."
    exit 1
}
Print-Ok "BigQuery region: $bqLocation"

Write-Host ""
Print-Info "(Optional) Restrict access to a specific dataset? Leave blank to access all datasets."
$bqDataset = Ask "Dataset name (leave blank for none)" ""

Pause-Wait

# ============================================================
# Step 4: Google Cloud authentication
# ============================================================
Print-Header "Step 4: Google Cloud authentication"

Write-Host "  Next we'll sign in to Google Cloud and create Application Default"
Write-Host "  Credentials (ADC). A browser window will open. Use a Google account"
Write-Host "  that has BigQuery access."
Write-Host ""
Print-Warn "If the browser does not open automatically, copy the URL printed in the terminal."
Write-Host ""

if (-not $gcloudCmd) {
    Print-Warn "gcloud not available; skipping authentication."
    Print-Info "After installing the Google Cloud SDK, run these manually:"
    Print-Info "  gcloud auth application-default login"
    Print-Info "  gcloud config set project <YOUR_PROJECT_ID>"
    Print-Info "  gcloud auth application-default set-quota-project <YOUR_PROJECT_ID>"
} elseif (Ask-YN "Sign in to Google Cloud now?") {
    Print-Step "Running: gcloud auth application-default login..."
    Write-Host ""
    Print-Info "A browser window will open. Approve the consent screen, then return to this terminal."
    Write-Host ""
    & $gcloudCmd auth application-default login
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Print-Ok "Google Cloud sign-in completed."
    } else {
        Write-Host ""
        Print-Warn "Sign-in did not complete (cancelled or network issue)."
        Print-Info "You can run this later: gcloud auth application-default login"
        Print-Info "Continuing with the rest of the setup..."
    }
} else {
    Print-Warn "Skipping sign-in. Without it, the MCP server cannot access BigQuery."
    Print-Info "You can run this any time: gcloud auth application-default login"
}

if ($gcloudCmd) {
    Write-Host ""
    Print-Step "Setting default project: $gcpProjectId"
    & $gcloudCmd config set project $gcpProjectId 2>$null
    if ($LASTEXITCODE -eq 0) {
        Print-Ok "Default project set."
    } else {
        Print-Warn "Failed to set default project. Run manually: gcloud config set project $gcpProjectId"
    }

    Print-Step "Setting quota project: $gcpProjectId"
    & $gcloudCmd auth application-default set-quota-project $gcpProjectId 2>$null
    if ($LASTEXITCODE -eq 0) {
        Print-Ok "Quota project set."
    } else {
        Print-Warn "Failed to set quota project (expected if ADC isn't created yet)."
        Print-Info "After signing in, run: gcloud auth application-default set-quota-project $gcpProjectId"
    }
}

Print-Ok "Google Cloud authentication step complete."
Pause-Wait

# ============================================================
# Step 5: Install uv
# ============================================================
Print-Header "Step 5: Install uv (Python package manager)"

$uvxPath = Find-Uvx

if ($uvxPath) {
    Print-Ok "uv / uvx already installed: $uvxPath"
} else {
    Print-Step "uvx not found; installing uv..."
    Write-Host ""
    if (Ask-YN "Install uv now? (requires internet)") {
        Print-Step "Running the uv Windows install script..."
        Write-Host ""
        Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression

        # Refresh PATH
        $env:PATH = "$env:USERPROFILE\.local\bin;$env:PATH"
        Refresh-EnvPath

        $uvxPath = Find-Uvx
        if (-not $uvxPath) {
            # Fallback: not yet on PATH but the file exists
            $fallback = "$env:USERPROFILE\.local\bin\uvx.exe"
            if (Test-Path $fallback) {
                $uvxPath = $fallback
                Print-Ok "uv installed. uvx path: $uvxPath"
            } else {
                Print-Err "Could not determine uvx path; please verify and edit the config file later."
                Print-Info "Common install path: $env:USERPROFILE\.local\bin\uvx.exe"
                $uvxPath = "$env:USERPROFILE\.local\bin\uvx.exe"
            }
        } else {
            Print-Ok "uv installed. uvx path: $uvxPath"
        }
    } else {
        Print-Err "uv is required to run mcp-server-bigquery. Please install it manually and rerun."
        Print-Info 'Install command (PowerShell): powershell -c "irm https://astral.sh/uv/install.ps1 | iex"'
        exit 1
    }
}

Print-Ok "uvx path: $uvxPath"

# Step 5 (cont.): ensure Python 3.13 is available
Write-Host ""
Print-Step "Checking Python versions available to uvx (3.10+ required)..."

# Update uv
Print-Step "Updating uv to the latest version..."
uv self update 2>$null
if ($LASTEXITCODE -eq 0) {
    Print-Ok "uv is up to date."
} else {
    Print-Warn "uv self update failed (likely already up to date); continuing."
}

Write-Host ""
Print-Step "Installing Python 3.13 via uv (required by uvx to run mcp-server-bigquery)..."
Write-Host ""

$uvPythonPath = ""
if (Ask-YN "Install Python 3.13 via uv? (~30MB; recommended: y)") {
    uv python install 3.13
    if ($LASTEXITCODE -eq 0) {
        $uvPythonPath = (uv python find 3.13 2>$null | Select-Object -First 1)
        if ($uvPythonPath -and (Test-Path $uvPythonPath)) {
            $pyVer = (& $uvPythonPath --version 2>$null)
            Print-Ok "uv Python 3.13 ready: $uvPythonPath ($pyVer)"
        } else {
            Print-Ok "uv Python 3.13 installed (referencing it by version)."
            $uvPythonPath = "3.13"
        }
    } else {
        Print-Warn "uv python install 3.13 failed; Claude Desktop may report a Python path error."
        Print-Info "Run manually later: uv python install 3.13"
    }
} else {
    Print-Warn "Skipping. If Claude Desktop reports a Python path error, run: uv python install 3.13"
}

Pause-Wait

# ============================================================
# Step 6: Write Claude Desktop config
# ============================================================
Print-Header "Step 6: Configure Claude Desktop"

$claudeConfigDir = "$env:APPDATA\Claude"
$configFile      = "$claudeConfigDir\claude_desktop_config.json"
Print-Step "Target config file: $configFile"

New-Item -ItemType Directory -Force -Path $claudeConfigDir | Out-Null

# Build the args array
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
    Print-Warn "Existing config file detected. Current contents:"
    Write-Host ""
    Get-Content $configFile | ForEach-Object { Write-Host "  $_" }
    Write-Host ""

    if (Ask-YN "Add/update the bigquery entry inside this config? (recommended: y)") {
        $backupFile = "$configFile.backup.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item $configFile $backupFile
        Print-Ok "Original config backed up to: $backupFile"

        $rawJson = Get-Content $configFile -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($rawJson)) {
            $config = [PSCustomObject]@{ mcpServers = [PSCustomObject]@{} }
        } else {
            try {
                $config = $rawJson | ConvertFrom-Json
            } catch {
                Print-Warn "Failed to parse the existing config as JSON; creating a fresh one."
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
        Print-Ok "Config updated."
    } else {
        Print-Warn "Skipping config update. Edit it manually if needed: $configFile"
    }
} else {
    Print-Step "Creating a new config file..."
    $newConfig = [PSCustomObject]@{
        mcpServers = [PSCustomObject]@{
            bigquery = $bqEntry
        }
    }
    Write-JsonFile $configFile $newConfig
    Print-Ok "Config file created."
}

Write-Host ""
Print-Step "Final config contents:"
Write-Host ""
Get-Content $configFile | ForEach-Object { Write-Host "  $_" }
Write-Host ""

# Workaround for upstream mcp-server-bigquery: server.py hardcodes
# logging.FileHandler('/tmp/mcp_bigquery_server.log'). On Windows that resolves
# to C:\tmp\... which doesn't exist by default, causing the server to crash on
# startup. We pre-create the directory so the upstream package works as-is.
$tmpDir = "C:\tmp"
if (-not (Test-Path $tmpDir)) {
    Print-Step "Creating $tmpDir (workaround for upstream mcp-server-bigquery hardcoded /tmp path)..."
    try {
        New-Item -ItemType Directory -Force -Path $tmpDir -ErrorAction Stop | Out-Null
        Print-Ok "Created $tmpDir"
    } catch {
        Print-Warn "Failed to create $tmpDir: $($_.Exception.Message)"
        Print-Info "If Claude Desktop reports a log-file error later, run as admin: mkdir C:\tmp"
    }
} else {
    Print-Info "Log directory $tmpDir already exists; skipping."
}

Pause-Wait

# ============================================================
# Step 7: Verify
# ============================================================
Print-Header "Step 7: Verify the setup"

Print-Step "Verifying uvx path..."
if ((Test-Path $uvxPath -ErrorAction SilentlyContinue) -or (Get-Command uvx -ErrorAction SilentlyContinue)) {
    Print-Ok "uvx is executable."
} else {
    Print-Warn "Could not verify uvx path: $uvxPath"
    Print-Info "Make sure uv is installed correctly, or update the 'command' field in the config."
}

Print-Step "Verifying Google Cloud authentication..."
if ($gcloudCmd) {
    $token = (& $gcloudCmd auth application-default print-access-token 2>$null)
    if ($LASTEXITCODE -eq 0 -and $token) {
        Print-Ok "Google Cloud ADC credentials are valid."
    } else {
        Print-Warn "Could not verify Google Cloud credentials. Make sure Step 4 sign-in completed."
    }
}

Print-Step "Validating config file format..."
try {
    Get-Content $configFile -Raw | ConvertFrom-Json | Out-Null
    Print-Ok "Config file is valid JSON."
} catch {
    Print-Err "Config file JSON is invalid; please inspect manually: $configFile"
}

# ============================================================
# Done
# ============================================================
Print-Header "Installation complete!"

Write-Host "  Next steps:" -ForegroundColor White
Write-Host ""
Write-Host "  1. " -ForegroundColor Cyan -NoNewline
Write-Host "Fully quit Claude Desktop (right-click the tray icon -> Quit)."
Write-Host "  2. " -ForegroundColor Cyan -NoNewline
Write-Host "Relaunch Claude Desktop."
Write-Host "  3. " -ForegroundColor Cyan -NoNewline
Write-Host "Go to Settings -> Developer."
Write-Host "     Confirm bigquery shows status 'running' (blue)."
Write-Host ""
Write-Host "  Test the connection (in a new Claude conversation):" -ForegroundColor White
Write-Host ""
Write-Host "  'List all BigQuery datasets in the $gcpProjectId project.'" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ----------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Configuration summary:" -ForegroundColor White
Write-Host "    Project ID   : " -NoNewline; Write-Host $gcpProjectId -ForegroundColor Cyan
Write-Host "    Location     : " -NoNewline; Write-Host $bqLocation -ForegroundColor Cyan
if (-not [string]::IsNullOrWhiteSpace($bqDataset)) {
    Write-Host "    Dataset      : " -NoNewline; Write-Host $bqDataset -ForegroundColor Cyan
}
Write-Host "    uvx path     : " -NoNewline; Write-Host $uvxPath -ForegroundColor Cyan
Write-Host "    Config file  : " -NoNewline; Write-Host $configFile -ForegroundColor Cyan
Write-Host "  ----------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

if (Ask-YN "Restart Claude Desktop now?") {
    Print-Step "Stopping Claude Desktop..."
    $procs = Get-Process -Name "Claude","claude" -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force
        Start-Sleep -Seconds 2
        Print-Ok "Claude Desktop stopped."
    } else {
        Print-Info "Claude Desktop is not running."
    }

    Print-Step "Launching Claude Desktop..."
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
        Print-Ok "Claude Desktop relaunched."
    } else {
        Print-Warn "Could not launch automatically; please open Claude Desktop manually."
    }
}

Write-Host ""
Write-Host "  Setup complete. Enjoy!" -ForegroundColor Green
Write-Host ""
