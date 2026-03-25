#!/bin/bash

# ============================================================
# BigQuery MCP Server 互動安裝腳本
# 適用平台：macOS
# 用途：引導使用者完成 Claude Desktop + BigQuery MCP 設定
# ============================================================
# 版本歷程：
#   v1.0.0  2026-03-21  初始版本
#   v1.1.0  2026-03-21  改善前置條件檢查：Homebrew/gcloud 自動安裝與提示
#   v1.2.0  2026-03-21  修正 brew 權限錯誤偵測（not writable / Permission denied）
#   v1.3.0  2026-03-21  移除 set -e，改為手動錯誤處理；修正 PIPESTATUS 捕獲
#   v1.4.0  2026-03-21  修正 gcloud 安裝成功但 brew 回傳非零的誤判
#   v1.5.0  2026-03-21  新增 Python 版本偵測與 CLOUDSDK_PYTHON 設定
#   v1.6.0  2026-03-21  修正全形字元緊接變數名稱導致 set -u 誤判（unbound variable）
#   v1.7.0  2026-03-21  移除 env.UV_PYTHON 設定；改用 uv python install 解決 Python 問題
#   v1.8.0  2026-03-21  新增 realpath 缺失偵測與自動建立替代腳本
# ============================================================

SCRIPT_VERSION="1.8.0"
SCRIPT_DATE="2026-03-21"

# 注意：此腳本為互動式安裝精靈，不使用 set -e（避免任何指令失敗就靜默終止）。
# 各關鍵步驟皆有明確的錯誤檢查。
set -u  # 仍保留未定義變數檢查

# ── 顏色定義 ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── 輔助函式 ────────────────────────────────────────────────
print_header() {
  echo ""
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${BLUE}  $1${RESET}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════${RESET}"
  echo ""
}

print_step() {
  echo -e "${CYAN}▶ $1${RESET}"
}

print_ok() {
  echo -e "${GREEN}✅ $1${RESET}"
}

print_warn() {
  echo -e "${YELLOW}⚠️  $1${RESET}"
}

print_error() {
  echo -e "${RED}❌ $1${RESET}"
}

print_info() {
  echo -e "   ${YELLOW}$1${RESET}"
}

ask() {
  # ask <variable_name> <prompt> [default]
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local input

  if [ -n "$default" ]; then
    echo -ne "${BOLD}$prompt${RESET} [預設: ${CYAN}$default${RESET}]: "
  else
    echo -ne "${BOLD}$prompt${RESET}: "
  fi

  read -r input
  if [ -z "$input" ] && [ -n "$default" ]; then
    input="$default"
  fi
  eval "$var_name=\"\$input\""
}

ask_yn() {
  # ask_yn <prompt> — returns 0 (yes) or 1 (no)
  local prompt="$1"
  local answer
  while true; do
    echo -ne "${BOLD}$prompt${RESET} [y/n]: "
    read -r answer
    case "$answer" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) print_warn "請輸入 y 或 n" ;;
    esac
  done
}

pause() {
  echo ""
  echo -ne "${YELLOW}按下 Enter 繼續...${RESET}"
  read -r
}

# ── 輔助：偵測並修復 Homebrew 目錄權限問題 ──────────────────
# 用法：brew_install_with_permission_fix <brew args...>
# 說明：執行 brew 指令，若遇到 "not writable" 權限錯誤，
#       提示使用者修復後自動重試一次。
brew_install_with_permission_fix() {
  local brew_args=("$@")
  local tmp_out exit_code pipe_status
  tmp_out="$(mktemp)"

  # 執行並同時顯示輸出（tee）
  # 注意：必須先宣告 exit_code，才能在 pipe 後立即讀取 PIPESTATUS
  # （local 指令本身會覆蓋 $? 和 PIPESTATUS，所以不能合併宣告與賦值）
  brew "${brew_args[@]}" 2>&1 | tee "$tmp_out"
  pipe_status=("${PIPESTATUS[@]}")   # 立即備份，下一行任何指令都會覆蓋 PIPESTATUS
  exit_code="${pipe_status[0]}"

  if [ "$exit_code" -eq 0 ]; then
    rm -f "$tmp_out"
    return 0
  fi

  # ── 偵測是否為 Homebrew 權限問題（兩種常見錯誤模式）──────
  # 模式 A：「not writable by your user」—— brew doctor / brew update 列出不可寫目錄
  # 模式 B：「Permission denied @ rb_file_s_rename」—— 安裝時無法移動檔案到 Cellar
  local is_perm_error=false
  if grep -q "not writable by your user" "$tmp_out"; then
    is_perm_error=true
  elif grep -q "Permission denied" "$tmp_out"; then
    is_perm_error=true
  fi

  if ! $is_perm_error; then
    rm -f "$tmp_out"
    return "$exit_code"
  fi

  # ── 偵測到權限問題，建立需修復的目錄清單 ──
  echo ""
  echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${YELLOW}  偵測到 Homebrew 目錄權限問題${RESET}"
  echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo -e "  Homebrew 沒有足夠權限寫入系統目錄，"
  echo -e "  這在 Intel Mac 的 /usr/local 上很常見。"
  echo ""

  local current_user brew_prefix
  current_user="$(whoami)"
  brew_prefix="$(brew --prefix 2>/dev/null || echo "/usr/local")"

  # 建立目錄清單（從多個來源合併）
  local bad_dirs_raw=""

  # 來源 1：「not writable」列表（brew doctor 格式：一行一個路徑）
  if grep -q "not writable by your user" "$tmp_out"; then
    bad_dirs_raw+=$(grep -A 200 "not writable by your user" "$tmp_out" \
      | grep "^  /" \
      | sed 's/^  //' \
      | head -50)
    bad_dirs_raw+=$'\n'
  fi

  # 來源 2：「Permission denied @ rb_file_s_rename - (src, dst)」—— 提取括號內的路徑
  # 格式：Permission denied @ rb_file_s_rename - (/path/a, /path/b)
  if grep -q "Permission denied.*rb_file_s_rename" "$tmp_out"; then
    # 提取所有涉及的路徑，取其父目錄
    while IFS= read -r line; do
      # 提取兩個路徑（逗號分隔，在括號內）
      local p1 p2
      p1=$(echo "$line" | sed -n 's/.*(\(\/[^,]*\),.*/\1/p')
      p2=$(echo "$line" | sed -n 's/.*, \(\/[^)]*\)).*/\1/p')
      [ -n "$p1" ] && bad_dirs_raw+="$(dirname "$p1")"$'\n'
      [ -n "$p2" ] && bad_dirs_raw+="$(dirname "$p2")"$'\n'
    done < <(grep "Permission denied.*rb_file_s_rename" "$tmp_out")
  fi

  # 來源 3：通用 Homebrew 關鍵目錄（作為保底，確保 Cellar / var 被修復）
  local brew_key_dirs=(
    "${brew_prefix}/Cellar"
    "${brew_prefix}/Casks"
    "${brew_prefix}/var/homebrew"
    "${brew_prefix}/var/homebrew/linked"
    "${brew_prefix}/var/homebrew/tmp"
    "${brew_prefix}/opt"
    "${brew_prefix}/bin"
    "${brew_prefix}/lib"
    "${brew_prefix}/share"
  )
  for d in "${brew_key_dirs[@]}"; do
    [ -d "$d" ] && bad_dirs_raw+="$d"$'\n'
  done

  rm -f "$tmp_out"

  # 去重並組成空格分隔字串（sort -u 去除重複）
  local bad_dirs
  bad_dirs=$(echo "$bad_dirs_raw" | sort -u | grep -v '^$' | tr '\n' ' ')

  local chown_cmd="sudo chown -R ${current_user} ${bad_dirs}"
  local chmod_cmd="chmod u+w ${bad_dirs}"

  echo -e "  ${BOLD}需要執行以下兩道指令來修復：${RESET}"
  echo ""
  echo -e "  ${CYAN}# 指令 1：變更目錄擁有者${RESET}"
  echo -e "  ${BOLD}${chown_cmd}${RESET}"
  echo ""
  echo -e "  ${CYAN}# 指令 2：開放寫入權限${RESET}"
  echo -e "  ${BOLD}${chmod_cmd}${RESET}"
  echo ""
  echo -e "  ${BOLD}請選擇處理方式：${RESET}"
  echo -e "  ${CYAN}[A]${RESET} 讓腳本自動執行修復（需要 sudo 密碼）"
  echo -e "  ${CYAN}[B]${RESET} 複製上方指令，手動在終端機貼上執行後按 Enter 繼續"
  echo -e "  ${CYAN}[S]${RESET} 略過，改用官方安裝包方式安裝"
  echo ""
  echo -ne "  ${BOLD}請輸入 A、B 或 S${RESET}: "
  local fix_choice
  read -r fix_choice

  case "$fix_choice" in
    [Aa]*)
      echo ""
      print_step "執行 sudo chown 修復目錄擁有者..."
      # shellcheck disable=SC2086
      if sudo chown -R "$current_user" $bad_dirs; then
        print_ok "chown 完成"
      else
        print_error "sudo chown 失敗，請改用方式 B 手動執行。"
        return 1
      fi
      print_step "執行 chmod 開放寫入權限..."
      # shellcheck disable=SC2086
      chmod u+w $bad_dirs
      print_ok "權限修復完成，重新嘗試安裝..."
      echo ""
      brew "${brew_args[@]}"
      return $?
      ;;
    [Bb]*)
      echo ""
      echo -e "  ${YELLOW}請在終端機複製並執行以下指令：${RESET}"
      echo ""
      echo -e "  ${BOLD}${chown_cmd}${RESET}"
      echo -e "  ${BOLD}${chmod_cmd}${RESET}"
      echo ""
      echo -ne "  ${YELLOW}完成後按 Enter 重新嘗試安裝...${RESET}"
      read -r
      echo ""
      brew "${brew_args[@]}"
      return $?
      ;;
    *)
      print_warn "略過，將改用官方安裝包方式。"
      return 99  # 特殊 code：讓呼叫方知道要 fallback
      ;;
  esac
}

# ── 輔助：顯示 Google Cloud SDK 官方安裝包指引並結束 ────────
_show_gcloud_manual_install() {
  echo ""
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}  Google Cloud SDK 官方安裝包${RESET}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  # 判斷 CPU 架構建議下載版本
  local arch_hint=""
  if [[ "$(uname -m)" == "arm64" ]]; then
    arch_hint="arm"
  else
    arch_hint="x86_64"
  fi

  echo -e "  依照以下步驟手動安裝 Google Cloud SDK："
  echo ""
  echo -e "  ${BOLD}步驟 1${RESET}  前往下載頁面："
  echo -e "          ${CYAN}https://cloud.google.com/sdk/docs/install${RESET}"
  echo ""
  echo -e "  ${BOLD}步驟 2${RESET}  下載 macOS ${BOLD}${arch_hint}${RESET} 版本的壓縮包"
  echo ""
  echo -e "  ${BOLD}步驟 3${RESET}  解壓縮，然後在終端機執行："
  echo -e "          ${CYAN}cd ~/Downloads/google-cloud-sdk${RESET}"
  echo -e "          ${CYAN}./install.sh${RESET}"
  echo ""
  echo -e "  ${BOLD}步驟 4${RESET}  安裝完成後，重新開啟終端機（或執行以下指令載入環境）："
  echo -e "          ${CYAN}source ~/google-cloud-sdk/path.bash.inc${RESET}"
  echo ""
  echo -e "  ${BOLD}步驟 5${RESET}  重新執行本安裝腳本："
  echo -e "          ${CYAN}bash setup-bigquery-mcp.sh${RESET}"
  echo ""
  print_error "請完成上述步驟後重新執行此腳本。"
  exit 1
}

# ── 輔助：嘗試載入 Homebrew 環境 ────────────────────────────
load_brew() {
  if [ -f "/opt/homebrew/bin/brew" ]; then          # Apple Silicon
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -f "/usr/local/bin/brew" ]; then            # Intel
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

# ── 輔助：嘗試載入 gcloud 環境 ──────────────────────────────
load_gcloud() {
  # Homebrew 安裝路徑（Apple Silicon / Intel）
  local candidates=(
    "$(brew --prefix 2>/dev/null)/share/google-cloud-sdk/path.bash.inc"
    "/opt/homebrew/share/google-cloud-sdk/path.bash.inc"
    "/usr/local/share/google-cloud-sdk/path.bash.inc"
    # 官方安裝包路徑
    "$HOME/google-cloud-sdk/path.bash.inc"
    "/usr/local/google-cloud-sdk/path.bash.inc"
  )
  for f in "${candidates[@]}"; do
    if [ -f "$f" ]; then
      # shellcheck disable=SC1090
      source "$f" 2>/dev/null && return 0
    fi
  done
  return 1
}

# ── 輔助：搜尋系統上符合 gcloud 需求的 Python（3.10+）────────
find_compatible_python() {
  local brew_prefix
  brew_prefix="$(brew --prefix 2>/dev/null || echo "/usr/local")"

  # 1. PATH 中的具名版本（優先最新）
  for minor in 13 12 11 10; do
    if command -v "python3.${minor}" &>/dev/null; then
      echo "$(command -v "python3.${minor}")"
      return 0
    fi
  done

  # 2. Homebrew opt 目錄（含 Intel /usr/local/opt 與 Apple Silicon /opt/homebrew/opt）
  for minor in 13 12 11 10; do
    for base in "${brew_prefix}/opt" "/usr/local/opt" "/opt/homebrew/opt"; do
      local bin="${base}/python@3.${minor}/bin/python3.${minor}"
      if [ -x "$bin" ]; then
        echo "$bin"
        return 0
      fi
    done
  done

  # 3. python3 / python 在 PATH 中，確認版本 >= 3.10
  for cmd in python3 python; do
    if command -v "$cmd" &>/dev/null; then
      local minor
      minor=$("$cmd" -c "import sys; print(sys.version_info.minor)" 2>/dev/null || echo "0")
      local major
      major=$("$cmd" -c "import sys; print(sys.version_info.major)" 2>/dev/null || echo "0")
      if [ "$major" -eq 3 ] && [ "$minor" -ge 10 ]; then
        echo "$(command -v "$cmd")"
        return 0
      fi
    fi
  done

  return 1
}

# ── 輔助：設定並持久化 CLOUDSDK_PYTHON ──────────────────────
setup_cloudsdk_python() {
  local gcloud_cmd="${1:-}"

  print_step "偵測系統上可用的 Python 版本（gcloud 需要 3.10+）..."

  # 先確認目前使用的 Python 版本
  local current_py=""
  if [ -n "$gcloud_cmd" ]; then
    current_py=$("$gcloud_cmd" --version 2>/dev/null | grep "Python" | awk '{print $NF}' || true)
  fi

  local compatible_py=""
  if compatible_py=$(find_compatible_python 2>/dev/null); then
    local py_version
    py_version=$("$compatible_py" --version 2>/dev/null | awk '{print $2}')
    print_ok "找到相容 Python：${compatible_py}（${py_version}）"
  else
    print_warn "找不到 Python 3.10+，gcloud 將使用系統預設 Python。"
    print_info "若出現 Python 版本警告，可安裝較新版本："
    print_info "  brew install python@3.13"
    return 0
  fi

  # 若已設定相同路徑則跳過
  if [ "${CLOUDSDK_PYTHON:-}" = "$compatible_py" ]; then
    print_ok "CLOUDSDK_PYTHON 已設定為正確路徑，略過。"
    return 0
  fi

  echo ""
  echo -e "  設定 ${BOLD}CLOUDSDK_PYTHON${RESET} 可讓 gcloud 使用正確的 Python 版本，"
  echo -e "  避免出現「Python 3.9 不支援」的警告或功能異常。"
  echo ""
  echo -e "  ${BOLD}設定路徑：${RESET}${CYAN}${compatible_py}${RESET}"
  echo ""

  # 寫入 shell 設定檔（偵測使用者的 shell）
  local shell_rc=""
  local current_shell
  current_shell="$(basename "${SHELL:-bash}")"
  case "$current_shell" in
    zsh)  shell_rc="$HOME/.zshrc" ;;
    bash) shell_rc="$HOME/.bash_profile" ;;
    *)    shell_rc="$HOME/.profile" ;;
  esac

  local export_line="export CLOUDSDK_PYTHON=\"${compatible_py}\""

  echo -e "  Shell 設定檔：${CYAN}${shell_rc}${RESET}"
  echo ""

  if ask_yn "是否將 CLOUDSDK_PYTHON 寫入 ${shell_rc}？（建議選 y，避免重複出現警告）"; then
    # 先移除舊的 CLOUDSDK_PYTHON 設定（若有）
    if grep -q "CLOUDSDK_PYTHON" "$shell_rc" 2>/dev/null; then
      local tmp_rc
      tmp_rc="$(mktemp)"
      grep -v "CLOUDSDK_PYTHON" "$shell_rc" > "$tmp_rc"
      mv "$tmp_rc" "$shell_rc"
      print_info "已移除舊的 CLOUDSDK_PYTHON 設定"
    fi
    # 寫入新設定
    echo "" >> "$shell_rc"
    echo "# gcloud Python（由 setup-bigquery-mcp.sh 設定）" >> "$shell_rc"
    echo "$export_line" >> "$shell_rc"
    print_ok "已寫入 ${shell_rc}"
  else
    print_warn "略過寫入。本次執行仍會套用，但重新開啟終端機後需手動設定："
    print_info "  $export_line"
  fi

  # 在目前 session 立即生效
  export CLOUDSDK_PYTHON="$compatible_py"
  print_ok "CLOUDSDK_PYTHON 已在目前 session 套用：$compatible_py"
}

# ── 輔助：多路徑搜尋 gcloud 執行檔 ─────────────────────────
find_gcloud() {
  # 1. 先看 PATH
  if command -v gcloud &>/dev/null; then
    command -v gcloud
    return 0
  fi
  # 2. 嘗試載入環境後再找
  load_gcloud 2>/dev/null
  if command -v gcloud &>/dev/null; then
    command -v gcloud
    return 0
  fi
  # 3. 常見硬編碼路徑（含 brew cask 的實際安裝位置）
  local candidates=(
    "/opt/homebrew/bin/gcloud"
    "/usr/local/bin/gcloud"
    # brew cask google-cloud-sdk / gcloud-cli 的實際二進位位置
    "/opt/homebrew/share/google-cloud-sdk/bin/gcloud"
    "/usr/local/share/google-cloud-sdk/bin/gcloud"
    # 官方安裝包路徑
    "$HOME/google-cloud-sdk/bin/gcloud"
    "/usr/local/google-cloud-sdk/bin/gcloud"
    "/usr/lib/google-cloud-sdk/bin/gcloud"
  )
  for p in "${candidates[@]}"; do
    if [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# ── 開始 ─────────────────────────────────────────────────────

clear
echo ""
echo -e "${BOLD}${BLUE}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   BigQuery MCP Server 互動安裝精靈               ║"
echo "  ║   Claude Desktop × Google BigQuery              ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  版本：${BOLD}v${SCRIPT_VERSION}${RESET}　日期：${SCRIPT_DATE}"
echo ""
echo -e "  此腳本將引導你完成 BigQuery MCP Server 的完整設定，"
echo -e "  讓 Claude Desktop 能直接查詢你的 BigQuery 資料。"
echo ""
echo -e "  預計需要 ${BOLD}5～10 分鐘${RESET}，過程中需要網路連線。"
echo ""

if ! ask_yn "準備好開始了嗎？"; then
  echo "已取消安裝。"
  exit 0
fi

# ══════════════════════════════════════════════
# 步驟一：前置條件檢查
# ══════════════════════════════════════════════
print_header "步驟一：前置條件檢查"

# 1-1 macOS 確認
print_step "確認作業系統..."
if [[ "$(uname)" != "Darwin" ]]; then
  print_error "此腳本僅支援 macOS，偵測到目前系統為 $(uname)。"
  exit 1
fi
print_ok "macOS 確認通過"

# 1-2 Claude Desktop 確認
print_step "確認 Claude Desktop 是否已安裝..."
CLAUDE_APP="/Applications/Claude.app"
CLAUDE_CONFIG_DIR="$HOME/Library/Application Support/Claude"

if [ ! -d "$CLAUDE_APP" ]; then
  print_warn "未偵測到 Claude Desktop（${CLAUDE_APP}）"
  print_info "請先下載安裝：https://claude.ai/download"
  echo ""
  if ! ask_yn "已確認安裝完成，繼續？"; then
    echo "請安裝 Claude Desktop 後再執行此腳本。"
    exit 1
  fi
else
  print_ok "Claude Desktop 已安裝"
fi

# 1-3 Homebrew 確認
print_step "確認 Homebrew 是否已安裝..."
load_brew  # 先嘗試從常見路徑載入
BREW_INSTALLED=false
if command -v brew &>/dev/null; then
  print_ok "Homebrew 已安裝（$(brew --version | head -1)）"
  BREW_INSTALLED=true
else
  print_warn "未偵測到 Homebrew"
  echo ""
  echo -e "  Homebrew 是 macOS 最常用的套件管理工具，建議透過它安裝 Google Cloud SDK。"
  echo -e "  ${BOLD}安裝方式 A（推薦）：${RESET}讓此腳本自動安裝"
  echo -e "  ${BOLD}安裝方式 B：${RESET}手動前往 ${CYAN}https://brew.sh${RESET} 安裝後重新執行此腳本"
  echo -e "  ${BOLD}略過：${RESET}若已透過其他方式安裝 gcloud，可略過 Homebrew"
  echo ""
  if ask_yn "是否讓腳本自動安裝 Homebrew？"; then
    print_step "開始安裝 Homebrew（過程中可能詢問 sudo 密碼）..."
    echo ""
    if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
      load_brew
      if command -v brew &>/dev/null; then
        print_ok "Homebrew 安裝成功（$(brew --version | head -1)）"
        BREW_INSTALLED=true
      else
        print_warn "Homebrew 已安裝，但目前 shell 尚未生效。"
        print_info "請重新開啟終端機後再執行此腳本，或手動執行："
        if [ -f "/opt/homebrew/bin/brew" ]; then
          print_info "  eval \"\$(/opt/homebrew/bin/brew shellenv)\""
        else
          print_info "  eval \"\$(/usr/local/bin/brew shellenv)\""
        fi
      fi
    else
      print_error "Homebrew 安裝失敗。"
      print_info "請手動前往 https://brew.sh 安裝，或直接下載 Google Cloud SDK。"
    fi
  else
    print_warn "略過 Homebrew 安裝。將嘗試其他方式安裝 Google Cloud SDK。"
  fi
fi

# 1-4 Google Cloud SDK 確認
echo ""
print_step "確認 Google Cloud SDK（gcloud）是否已安裝..."
GCLOUD_CMD=""
if GCLOUD_CMD=$(find_gcloud 2>/dev/null); then
  GCLOUD_VERSION=$("$GCLOUD_CMD" --version 2>/dev/null | head -1 || echo "已安裝")
  print_ok "Google Cloud SDK 已安裝：$GCLOUD_CMD"
  print_info "版本：$GCLOUD_VERSION"
  # 確保 gcloud 在 PATH 中
  GCLOUD_DIR="$(dirname "$GCLOUD_CMD")"
  export PATH="$GCLOUD_DIR:$PATH"
else
  print_warn "未偵測到 Google Cloud SDK"
  echo ""
  echo -e "  Google Cloud SDK 提供 ${BOLD}gcloud${RESET} 指令，用於驗證 BigQuery 存取權限。"
  echo ""
  echo -e "  可用的安裝方式："
  echo ""

  if $BREW_INSTALLED; then
    echo -e "  ${BOLD}[1] 透過 Homebrew 安裝（推薦）${RESET}"
    echo -e "      brew install --cask google-cloud-sdk"
    echo ""
  fi
  echo -e "  ${BOLD}[$(if $BREW_INSTALLED; then echo 2; else echo 1; fi)] 下載官方安裝包${RESET}"
  echo -e "      https://cloud.google.com/sdk/docs/install"
  echo -e "      → 選擇 macOS 版本下載，解壓縮後執行 install.sh"
  echo ""

  INSTALL_CHOICE=""
  if $BREW_INSTALLED; then
    echo -e "  請選擇安裝方式："
    echo -ne "  ${BOLD}輸入 1（Homebrew）、2（官方安裝包）或 s（略過）${RESET}: "
    read -r INSTALL_CHOICE
  else
    echo -ne "  ${BOLD}輸入 1（官方安裝包）或 s（略過）${RESET}: "
    read -r INSTALL_CHOICE
    # 重新映射：若無 Homebrew，選項 1 對應官方安裝包
    [ "$INSTALL_CHOICE" = "1" ] && INSTALL_CHOICE="2"
  fi

  case "$INSTALL_CHOICE" in
    1)
      print_step "透過 Homebrew 安裝 Google Cloud SDK（需要幾分鐘）..."
      echo ""
      brew_install_with_permission_fix install --cask google-cloud-sdk
      BREW_INSTALL_RESULT=$?

      if [ "$BREW_INSTALL_RESULT" -eq 99 ]; then
        # 用戶在權限修復時選擇 fallback，改為顯示官方安裝包指引
        _show_gcloud_manual_install
      else
        # 不論 brew 退出碼為何（含 Python 版本警告導致的非零），
        # 優先確認 gcloud 是否實際已安裝成功。
        load_gcloud
        if GCLOUD_CMD=$(find_gcloud 2>/dev/null); then
          print_ok "Google Cloud SDK 安裝成功：$GCLOUD_CMD"
          GCLOUD_DIR="$(dirname "$GCLOUD_CMD")"
          export PATH="$GCLOUD_DIR:$PATH"
          if [ "$BREW_INSTALL_RESULT" -ne 0 ]; then
            print_warn "brew 回傳非零退出碼（可能是 Python 版本警告），但 gcloud 已正常安裝，繼續進行。"
          fi
        else
          # gcloud 找不到，才真的視為安裝失敗
          if [ "$BREW_INSTALL_RESULT" -ne 0 ]; then
            print_error "Homebrew 安裝 Google Cloud SDK 失敗（exit code: ${BREW_INSTALL_RESULT}）。"
          else
            print_warn "Homebrew 安裝完成，但找不到 gcloud 執行檔。"
          fi
          print_info "請嘗試手動安裝：https://cloud.google.com/sdk/docs/install"
          print_info "或重新開啟終端機後再執行此腳本。"
          exit 1
        fi
      fi
      ;;
    2)
      _show_gcloud_manual_install
      ;;
    [Ss]*)
      print_warn "略過 Google Cloud SDK 安裝。"
      print_warn "若未安裝 gcloud，後續的 BigQuery 認證步驟將無法完成。"
      echo ""
      if ! ask_yn "確定要在沒有 gcloud 的情況下繼續嗎？"; then
        print_info "請安裝後重新執行：brew install --cask google-cloud-sdk"
        exit 1
      fi
      ;;
    *)
      print_error "無效的選擇，結束安裝。"
      exit 1
      ;;
  esac
fi

# ── 1-5 Python 版本設定（gcloud 需要 3.10+）──────────────────
if [ -n "${GCLOUD_CMD:-}" ]; then
  echo ""
  setup_cloudsdk_python "$GCLOUD_CMD"
fi

echo ""
print_ok "前置條件檢查完成！"
pause

# ══════════════════════════════════════════════
# 步驟二：取得 GCP Project ID
# ══════════════════════════════════════════════
print_header "步驟二：設定 Google Cloud 專案"

echo -e "  請輸入你的 GCP Project ID。"
echo -e "  可在 Google Cloud Console 右上角或 Dashboard 頁面找到。"
echo -e "  格式範例：${CYAN}my-project-123456${RESET}"
echo ""

# 嘗試取得目前已設定的專案
CURRENT_PROJECT=""
if [ -n "${GCLOUD_CMD:-}" ]; then
  CURRENT_PROJECT=$("$GCLOUD_CMD" config get-value project 2>/dev/null || true)
fi

ask GCP_PROJECT_ID "請輸入 GCP Project ID" "$CURRENT_PROJECT"

if [ -z "$GCP_PROJECT_ID" ]; then
  print_error "Project ID 不能為空。"
  exit 1
fi

print_ok "Project ID：$GCP_PROJECT_ID"

# ══════════════════════════════════════════════
# 步驟三：取得 BigQuery Location
# ══════════════════════════════════════════════
print_header "步驟三：設定 BigQuery 資料集區域"

echo -e "  請輸入你的 BigQuery dataset 所在區域。"
echo -e "  可在 Cloud Console → BigQuery → 點選 dataset → 查看「資料集位置」。"
echo ""
echo -e "  常見區域："
echo -e "    ${CYAN}asia-east1${RESET}      台灣（彰化）"
echo -e "    ${CYAN}asia-east2${RESET}      香港"
echo -e "    ${CYAN}asia-northeast1${RESET} 日本（東京）"
echo -e "    ${CYAN}asia-southeast1${RESET} 新加坡"
echo -e "    ${CYAN}US${RESET}              美國（多區域）"
echo -e "    ${CYAN}EU${RESET}              歐洲（多區域）"
echo ""

ask BQ_LOCATION "請輸入 BigQuery 資料集區域" "asia-east1"

if [ -z "$BQ_LOCATION" ]; then
  print_error "區域不能為空。"
  exit 1
fi

print_ok "BigQuery 區域：$BQ_LOCATION"

# 詢問是否限定特定 dataset（可選）
echo ""
print_info "（可選）是否限定只存取特定 dataset？留空表示存取所有 datasets。"
ask BQ_DATASET "Dataset 名稱（可留空）" ""

pause

# ══════════════════════════════════════════════
# 步驟四：Google Cloud 認證
# ══════════════════════════════════════════════
print_header "步驟四：Google Cloud 認證"

echo -e "  接下來需要登入 Google Cloud，取得應用程式預設憑證（ADC）。"
echo -e "  系統會開啟瀏覽器，請使用擁有 BigQuery 存取權限的 Google 帳號登入。"
echo ""
print_warn "若瀏覽器未自動開啟，請複製終端機顯示的網址手動前往。"
echo ""

if [ -z "${GCLOUD_CMD:-}" ]; then
  print_warn "找不到 gcloud，略過認證步驟。"
  print_info "請安裝 Google Cloud SDK 後，手動執行以下指令完成認證："
  print_info "  gcloud auth application-default login"
  print_info "  gcloud config set project <YOUR_PROJECT_ID>"
  print_info "  gcloud auth application-default set-quota-project <YOUR_PROJECT_ID>"
elif ask_yn "是否現在進行 Google Cloud 登入認證？"; then
  print_step "執行 gcloud auth application-default login..."
  echo ""
  print_info "系統即將開啟瀏覽器，請完成 Google 帳號授權後回到此終端機。"
  echo ""
  if "$GCLOUD_CMD" auth application-default login; then
    echo ""
    print_ok "Google Cloud 登入完成"
  else
    echo ""
    print_warn "Google Cloud 登入未完成（可能是取消或網路問題）。"
    print_info "你可以之後手動執行：gcloud auth application-default login"
    print_info "繼續後續設定步驟..."
  fi
else
  print_warn "略過登入步驟。若未登入，MCP Server 將無法存取 BigQuery。"
  print_info "可隨時手動執行：gcloud auth application-default login"
fi

# 設定預設專案與 quota project
if [ -n "${GCLOUD_CMD:-}" ]; then
  echo ""
  print_step "設定預設專案：$GCP_PROJECT_ID"
  if "$GCLOUD_CMD" config set project "$GCP_PROJECT_ID" 2>/dev/null; then
    print_ok "預設專案已設定"
  else
    print_warn "設定預設專案失敗，請手動執行：gcloud config set project $GCP_PROJECT_ID"
  fi

  print_step "設定 quota project：$GCP_PROJECT_ID"
  if "$GCLOUD_CMD" auth application-default set-quota-project "$GCP_PROJECT_ID" 2>/dev/null; then
    print_ok "Quota project 已設定"
  else
    print_warn "Quota project 設定失敗（若 ADC 尚未建立，屬正常現象）。"
    print_info "登入後可手動執行：gcloud auth application-default set-quota-project $GCP_PROJECT_ID"
  fi
fi

print_ok "Google Cloud 認證設定完成"
pause

# ══════════════════════════════════════════════
# 步驟五：安裝 uv
# ══════════════════════════════════════════════
print_header "步驟五：安裝 uv（Python 套件管理工具）"

if command -v uvx &>/dev/null; then
  UVX_PATH="$(command -v uvx)"
  print_ok "uv / uvx 已安裝：$UVX_PATH"
else
  print_step "未偵測到 uvx，即將安裝 uv..."
  echo ""
  if ask_yn "是否現在安裝 uv？（需要網路連線）"; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    echo ""
    # 嘗試讓目前 shell 可以找到 uvx
    export PATH="$HOME/.local/bin:$PATH"
    if command -v uvx &>/dev/null; then
      UVX_PATH="$(command -v uvx)"
      print_ok "uv 安裝完成，uvx 路徑：$UVX_PATH"
    else
      print_warn "安裝完成，但目前 shell 無法直接找到 uvx。"
      print_info "嘗試路徑：$HOME/.local/bin/uvx"
      UVX_PATH="$HOME/.local/bin/uvx"
      if [ ! -f "$UVX_PATH" ]; then
        print_error "無法確認 uvx 路徑，請手動確認後修改設定檔。"
        UVX_PATH="/Users/$(whoami)/.local/bin/uvx"
      fi
    fi
  else
    print_error "需要 uv 才能執行 mcp-server-bigquery。請手動安裝後重新執行。"
    print_info "安裝指令：curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
  fi
fi

print_ok "uvx 路徑：$UVX_PATH"

# ── 步驟五補充 A：確認 realpath 指令是否存在 ─────────────────
# uvx 執行 mcp-server-bigquery 時，產生的 wrapper script 會呼叫 realpath 解析路徑。
# macOS 原生沒有 realpath（屬於 GNU coreutils），缺少時會導致 Claude Desktop 啟動失敗。
echo ""
print_step "確認 realpath 指令是否存在（uvx wrapper script 需要）..."

if command -v realpath &>/dev/null; then
  print_ok "realpath 已存在：$(command -v realpath)"
else
  print_warn "系統缺少 realpath 指令，這會導致 Claude Desktop 載入 MCP 時失敗。"
  echo ""
  echo -e "  ${BOLD}解決方式 A（推薦）：${RESET}自動建立 realpath 替代腳本"
  echo -e "  ${BOLD}解決方式 B：${RESET}透過 Homebrew 安裝 GNU coreutils"
  echo -e "             ${CYAN}brew install coreutils${RESET}"
  echo ""
  echo -ne "  ${BOLD}請輸入 A（自動建立）、B（顯示 brew 指令）或 s（略過）${RESET}: "
  read -r realpath_choice

  case "$realpath_choice" in
    [Aa]*)
      echo ""
      print_step "建立 /usr/local/bin/realpath（需要 sudo 密碼）..."
      if sudo bash -c 'cat > /usr/local/bin/realpath << "RPEOF"
#!/bin/bash
# macOS realpath 替代腳本（由 setup-bigquery-mcp.sh 建立）
while [[ "$1" == -* ]]; do
  shift
done
python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1"
RPEOF
chmod +x /usr/local/bin/realpath'; then
        print_ok "realpath 已建立：/usr/local/bin/realpath"
      else
        print_error "建立失敗（sudo 權限問題？），請手動執行以下指令："
        echo ""
        echo -e "  ${CYAN}sudo bash -c 'cat > /usr/local/bin/realpath << \"EOF\"${RESET}"
        echo -e "  ${CYAN}#!/bin/bash${RESET}"
        echo -e "  ${CYAN}while [[ \"\$1\" == -* ]]; do shift; done${RESET}"
        echo -e "  ${CYAN}python3 -c \"import os,sys; print(os.path.realpath(sys.argv[1]))\" \"\$1\"${RESET}"
        echo -e "  ${CYAN}EOF${RESET}"
        echo -e "  ${CYAN}chmod +x /usr/local/bin/realpath'${RESET}"
      fi
      ;;
    [Bb]*)
      echo ""
      print_info "請執行以下指令安裝 GNU coreutils（含 realpath）："
      print_info "  brew install coreutils"
      print_info "安裝後 realpath 會位於 \$(brew --prefix)/bin/grealpath"
      print_info "或加入 PATH：export PATH=\"\$(brew --prefix)/opt/coreutils/libexec/gnubin:\$PATH\""
      echo ""
      print_warn "略過。請安裝後重新執行此腳本，或 Claude Desktop 載入時可能失敗。"
      ;;
    *)
      print_warn "略過 realpath 設定。Claude Desktop 載入 MCP 時可能出現 'realpath: command not found' 錯誤。"
      ;;
  esac
fi

# ── 步驟五補充 B：為 uvx 確認可用的 Python 版本 ────────────────
echo ""
print_step "確認 uvx 可用的 Python 版本（需要 3.10～3.13，避免找不到 3.14 的錯誤）..."

UV_PYTHON_PATH=""

# ── 策略：優先用 uv 自己管理的 Python（避免 macOS 缺少 realpath 造成 wrapper script 失敗）
# 設定 Homebrew 路徑（/usr/local/opt/...）給 UV_PYTHON 時，uv 生成的 wrapper script
# 會用 `realpath` 做路徑解析，但 macOS 原生沒有這個指令，導致 Claude Desktop 啟動失敗。
# uv 自己管理的 Python（~/.local/share/uv/python/...）使用絕對路徑，不依賴 realpath。
UV_PYTHON_PATH=""

# 先更新 uv 至最新版本
print_step "更新 uv 至最新版本（確保 macOS 相容性）..."
if uv self update 2>/dev/null; then
  print_ok "uv 已是最新版本"
else
  print_warn "uv self update 失敗（可能已是最新），繼續進行。"
fi

# 嘗試用 uv 安裝 Python 3.13（uv 管理的 Python 不會有 realpath 問題）
echo ""
print_step "透過 uv 安裝 Python 3.13（uvx 執行 mcp-server-bigquery 所需）..."
echo ""
echo -e "  ${BOLD}為什麼需要這個步驟？${RESET}"
echo -e "  uv 在 macOS 上需要自己管理的 Python，"
echo -e "  使用系統 Homebrew Python 會導致 Claude Desktop 出現 realpath 錯誤。"
echo ""

if ask_yn "是否透過 uv 安裝 Python 3.13？（約 30MB，建議選 y）"; then
  if uv python install 3.13; then
    UV_PYTHON_PATH=$(uv python find 3.13 2>/dev/null || true)
    if [ -n "$UV_PYTHON_PATH" ] && [ -f "$UV_PYTHON_PATH" ]; then
      local_py_ver=$("$UV_PYTHON_PATH" --version 2>/dev/null | awk '{print $2}')
      print_ok "uv Python 3.13 已就緒：${UV_PYTHON_PATH}（${local_py_ver}）"
    else
      # uv python find 找不到，但 install 成功 → 讓 uv 用版本號自行解析
      print_ok "uv Python 3.13 已安裝，使用版本號識別。"
      UV_PYTHON_PATH="3.13"
    fi
  else
    print_warn "uv python install 3.13 失敗，嘗試使用系統 Python 備援..."
    if UV_PYTHON_PATH=$(find_compatible_python 2>/dev/null); then
      local_py_ver=$("$UV_PYTHON_PATH" --version 2>/dev/null | awk '{print $2}')
      print_warn "使用系統 Python（注意：可能有 realpath 相容性問題）：${UV_PYTHON_PATH}（${local_py_ver}）"
    else
      print_warn "找不到相容 Python。Claude Desktop 可能出現 Python 路徑錯誤。"
      print_info "請手動執行：uv python install 3.13"
    fi
  fi
else
  print_warn "略過。若 Claude Desktop 出現以下錯誤，請執行 uv python install 3.13："
  print_info "  - 'failed to canonicalize path python@3.14'"
  print_info "  - 'realpath: command not found'"
fi

if [ -n "$UV_PYTHON_PATH" ]; then
  echo ""
  print_ok "uv Python 3.13 已就緒，Claude Desktop 啟動時將自動使用。"
fi

pause

# ══════════════════════════════════════════════
# 步驟六：寫入 Claude Desktop 設定檔
# ══════════════════════════════════════════════
print_header "步驟六：設定 Claude Desktop"

CONFIG_FILE="$CLAUDE_CONFIG_DIR/claude_desktop_config.json"
print_step "目標設定檔：$CONFIG_FILE"

# 確保目錄存在
mkdir -p "$CLAUDE_CONFIG_DIR"

# 組建 args 陣列（含可選的 --dataset）
if [ -n "$BQ_DATASET" ]; then
  DATASET_ARGS=",
        \"--dataset\",
        \"$BQ_DATASET\""
else
  DATASET_ARGS=""
fi

# 組建新的 bigquery MCP 設定區塊
NEW_BQ_CONFIG="    \"bigquery\": {
      \"command\": \"$UVX_PATH\",
      \"args\": [
        \"mcp-server-bigquery\",
        \"--project\",
        \"$GCP_PROJECT_ID\",
        \"--location\",
        \"$BQ_LOCATION\"$DATASET_ARGS
      ]
    }"

# 處理現有設定檔
if [ -f "$CONFIG_FILE" ]; then
  print_warn "偵測到現有設定檔，內容如下："
  echo ""
  cat "$CONFIG_FILE"
  echo ""
  echo ""

  if ask_yn "是否要在現有設定中新增/更新 bigquery 設定？（建議選 y）"; then
    # 備份現有設定
    BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    print_ok "已備份原始設定至：$BACKUP_FILE"

    # 使用 Python 合併 JSON（macOS 內建 Python3）
    python3 - <<PYEOF
import json, sys

config_file = "$CONFIG_FILE"
with open(config_file, "r", encoding="utf-8") as f:
    try:
        config = json.load(f)
    except json.JSONDecodeError:
        config = {}

if "mcpServers" not in config:
    config["mcpServers"] = {}

config["mcpServers"]["bigquery"] = {
    "command": "$UVX_PATH",
    "args": ["mcp-server-bigquery", "--project", "$GCP_PROJECT_ID", "--location", "$BQ_LOCATION"]
    + (["--dataset", "$BQ_DATASET"] if "$BQ_DATASET" else [])
}

with open(config_file, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write("\n")

print("設定已合併寫入。")
PYEOF
    print_ok "設定已更新"
  else
    print_warn "略過設定檔更新。請手動編輯：$CONFIG_FILE"
  fi
else
  # 全新寫入
  print_step "建立新的設定檔..."
  cat > "$CONFIG_FILE" <<JSONEOF
{
  "mcpServers": {
$NEW_BQ_CONFIG
  }
}
JSONEOF
  print_ok "設定檔已建立"
fi

# 顯示最終設定內容
echo ""
print_step "最終設定檔內容："
echo ""
cat "$CONFIG_FILE"
echo ""

pause

# ══════════════════════════════════════════════
# 步驟七：驗證設定
# ══════════════════════════════════════════════
print_header "步驟七：驗證設定"

print_step "驗證 uvx 路徑..."
if [ -f "$UVX_PATH" ] || command -v uvx &>/dev/null; then
  print_ok "uvx 可執行"
else
  print_warn "無法驗證 uvx 路徑：$UVX_PATH"
  print_info "請確認 uv 已正確安裝，或手動修改設定檔中的 command 路徑。"
fi

print_step "驗證 Google Cloud 認證..."
if [ -n "${GCLOUD_CMD:-}" ] && "$GCLOUD_CMD" auth application-default print-access-token &>/dev/null; then
  print_ok "Google Cloud ADC 認證有效"
else
  print_warn "無法驗證 Google Cloud 認證，請確認已完成步驟四的登入流程。"
fi

print_step "驗證設定檔格式..."
if python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
  print_ok "設定檔 JSON 格式正確"
else
  print_error "設定檔 JSON 格式有誤，請手動檢查：$CONFIG_FILE"
fi

# ══════════════════════════════════════════════
# 完成提示
# ══════════════════════════════════════════════
print_header "🎉 安裝完成！"

echo -e "  ${BOLD}接下來的步驟：${RESET}"
echo ""
echo -e "  ${CYAN}1.${RESET} 完全關閉 Claude Desktop（從 Dock 或選單列退出）"
echo -e "  ${CYAN}2.${RESET} 重新啟動 Claude Desktop"
echo -e "  ${CYAN}3.${RESET} 前往 ${BOLD}Settings → Developer${RESET}"
echo -e "     確認 ${BOLD}bigquery${RESET} 狀態顯示為 ${GREEN}running（藍色）${RESET}"
echo ""
echo -e "  ${BOLD}驗證連線（在 Claude 新對話中輸入）：${RESET}"
echo ""
echo -e "  ${CYAN}「請列出 $GCP_PROJECT_ID 專案中所有的 BigQuery datasets」${RESET}"
echo ""
echo -e "  ──────────────────────────────────────────────"
echo -e "  ${BOLD}設定摘要：${RESET}"
echo -e "    Project ID   : ${CYAN}$GCP_PROJECT_ID${RESET}"
echo -e "    Location     : ${CYAN}$BQ_LOCATION${RESET}"
if [ -n "$BQ_DATASET" ]; then
  echo -e "    Dataset      : ${CYAN}$BQ_DATASET${RESET}"
fi
echo -e "    uvx 路徑     : ${CYAN}$UVX_PATH${RESET}"
echo -e "    設定檔位置   : ${CYAN}$CONFIG_FILE${RESET}"
echo -e "  ──────────────────────────────────────────────"
echo ""

if ask_yn "是否現在重啟 Claude Desktop？"; then
  print_step "關閉 Claude Desktop..."
  osascript -e 'quit app "Claude"' 2>/dev/null || killall "Claude" 2>/dev/null || true
  sleep 2
  print_step "啟動 Claude Desktop..."
  open -a "Claude" 2>/dev/null || print_warn "無法自動啟動，請手動開啟 Claude Desktop。"
  print_ok "Claude Desktop 已重新啟動"
fi

echo ""
echo -e "${GREEN}${BOLD}  設定完成！祝使用愉快 🚀${RESET}"
echo ""
