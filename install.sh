#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# install.sh — launchapp setup and install helper
#
# Run once after cloning/copying the project:
#   bash install.sh
#
# What it does:
#   1. Installs required Termux packages
#   2. Makes entry-point scripts executable
#   3. Creates shell aliases in ~/.bashrc / ~/.zshrc
#   4. Creates config directories
#   5. Optionally generates an agent token
#   6. Prints a quickstart summary
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TERMUX_SHELL="/data/data/com.termux/files/usr/bin/bash"

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; PURPLE='\033[0;35m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; PURPLE=''; NC=''
fi

step()    { echo -e "\n${CYAN}▶ $*${NC}"; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; }
confirm() {
  local msg="$1" default="${2:-y}"
  local prompt="[Y/n]"
  [[ "$default" == "n" ]] && prompt="[y/N]"
  read -rp "  $msg $prompt: " ans
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy] ]]
}

# =============================================================================
# BANNER
# =============================================================================

echo
echo -e "${CYAN}┌─────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│${NC}  ${PURPLE}launchapp${NC} — Install & Setup              ${CYAN}│${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────┘${NC}"
echo
echo "  Project directory: $SCRIPT_DIR"
echo

# =============================================================================
# 1. TERMUX PACKAGE INSTALLATION
# =============================================================================

step "Checking Termux packages"

REQUIRED_PKGS=(tmux jq curl python)
OPTIONAL_PKGS=(nmap android-tools termux-api)

# Update pkg list first
if confirm "Update Termux package list first?"; then
  pkg update -y 2>/dev/null || warn "pkg update had errors (continuing)"
fi

echo
echo "  Required packages:"
missing_required=()
for p in "${REQUIRED_PKGS[@]}"; do
  if command -v "$p" &>/dev/null || \
     dpkg -l "$p" &>/dev/null 2>&1 || \
     pkg list-installed 2>/dev/null | grep -q "^$p"; then
    ok "$p (already installed)"
  else
    fail "$p (missing)"
    missing_required+=("$p")
  fi
done

echo
echo "  Optional packages:"
missing_optional=()
for p in "${OPTIONAL_PKGS[@]}"; do
  local_cmd="$p"
  [[ "$p" == "android-tools" ]] && local_cmd="adb"
  [[ "$p" == "termux-api" ]] && local_cmd="termux-notification"
  if command -v "$local_cmd" &>/dev/null; then
    ok "$p (already installed)"
  else
    warn "$p (missing — some features unavailable)"
    missing_optional+=("$p")
  fi
done

if [[ ${#missing_required[@]} -gt 0 ]]; then
  echo
  if confirm "Install missing required packages: ${missing_required[*]}?"; then
    pkg install -y "${missing_required[@]}" \
      && ok "Required packages installed" \
      || { fail "Some packages failed to install"; echo "  Run manually: pkg install ${missing_required[*]}"; }
  else
    warn "Skipped — some features will not work without: ${missing_required[*]}"
  fi
fi

if [[ ${#missing_optional[@]} -gt 0 ]]; then
  echo
  if confirm "Install optional packages: ${missing_optional[*]}?"; then
    pkg install -y "${missing_optional[@]}" 2>/dev/null \
      && ok "Optional packages installed" \
      || warn "Some optional packages failed — this is OK"
  fi
fi

# =============================================================================
# 2. MAKE SCRIPTS EXECUTABLE
# =============================================================================

step "Setting permissions"

chmod +x "$SCRIPT_DIR/launchapp.sh"
chmod +x "$SCRIPT_DIR/remote_monitor.sh"
chmod +x "$SCRIPT_DIR/install.sh"
[[ -f "$SCRIPT_DIR/agent.py" ]] && chmod +x "$SCRIPT_DIR/agent.py"

# All lib/modes/remote shell files
find "$SCRIPT_DIR/lib" "$SCRIPT_DIR/modes" "$SCRIPT_DIR/remote" \
  -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

ok "Permissions set"

# =============================================================================
# 3. SHELL ALIASES
# =============================================================================

step "Setting up shell aliases"

LA_CMD="bash '$SCRIPT_DIR/launchapp.sh'"
RM_CMD="bash '$SCRIPT_DIR/remote_monitor.sh'"

ALIAS_BLOCK="
# ── launchapp aliases ──────────────────────────────────────────
alias launchapp='$LA_CMD'
alias remote='$RM_CMD'
# ──────────────────────────────────────────────────────────────
"

_add_alias_to_file() {
  local rcfile="$1"
  if [[ -f "$rcfile" ]] && grep -q "launchapp aliases" "$rcfile" 2>/dev/null; then
    ok "Aliases already in $rcfile"
    return
  fi
  if confirm "Add aliases to $rcfile?"; then
    echo "$ALIAS_BLOCK" >> "$rcfile"
    ok "Aliases added to $rcfile"
  fi
}

# Detect shell rc files
[[ -f "$HOME/.bashrc" ]]  && _add_alias_to_file "$HOME/.bashrc"
[[ -f "$HOME/.zshrc" ]]   && _add_alias_to_file "$HOME/.zshrc"
[[ -f "$HOME/.profile" ]] && _add_alias_to_file "$HOME/.profile"

# Termux default shell rc
TERMUX_RC="$HOME/.bashrc"
if [[ ! -f "$TERMUX_RC" ]]; then
  touch "$TERMUX_RC"
  _add_alias_to_file "$TERMUX_RC"
fi

# ── Optionally add to PATH so scripts work without alias ──────────────────────
PREFIX_BIN="${PREFIX:-/data/data/com.termux/files/usr}/bin"
if confirm "Also symlink to $PREFIX_BIN/launchapp and $PREFIX_BIN/remote_monitor?"; then
  ln -sf "$SCRIPT_DIR/launchapp.sh"     "$PREFIX_BIN/launchapp"     2>/dev/null \
    && ok "Symlinked: launchapp" \
    || warn "Could not symlink to $PREFIX_BIN — try manually: ln -sf '$SCRIPT_DIR/launchapp.sh' '$PREFIX_BIN/launchapp'"
  ln -sf "$SCRIPT_DIR/remote_monitor.sh" "$PREFIX_BIN/remote_monitor" 2>/dev/null \
    && ok "Symlinked: remote_monitor" \
    || warn "Could not symlink to $PREFIX_BIN"
fi

# =============================================================================
# 4. CONFIG DIRECTORIES
# =============================================================================

step "Creating config directories"

CONFIG_DIR="${LAUNCHAPP_CONFIG_DIR:-$HOME/.launchapp}"
LOG_DIR="${LAUNCHAPP_LOG_DIR:-$HOME/launchapp_logs}"
CACHE_DIR="$CONFIG_DIR/cache"
SCREENSHOTS_DIR="$HOME/launchapp_screenshots"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR" "$SCREENSHOTS_DIR"
touch "$CONFIG_DIR/aliases"
[[ -f "$CONFIG_DIR/devices.json" ]] || echo "[]" > "$CONFIG_DIR/devices.json"

ok "Config:       $CONFIG_DIR"
ok "Logs:         $LOG_DIR"
ok "Cache:        $CACHE_DIR"
ok "Screenshots:  $SCREENSHOTS_DIR"

# =============================================================================
# 5. AGENT TOKEN
# =============================================================================

step "Agent authentication token"

TOKEN_FILE="$CONFIG_DIR/token"

if [[ -f "$TOKEN_FILE" ]]; then
  existing_token=$(cat "$TOKEN_FILE")
  ok "Existing token found: ${existing_token:0:12}…"
  if ! confirm "Generate a new token? (keeps existing if no)"; then
    AGENT_TOKEN="$existing_token"
  fi
fi

if [[ -z "${AGENT_TOKEN:-}" ]]; then
  AGENT_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null \
    || openssl rand -hex 32 2>/dev/null \
    || cat /dev/urandom | tr -dc 'a-f0-9' | head -c 64)
  echo "$AGENT_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  ok "Token generated and saved to $TOKEN_FILE"
fi

# Add token export to shell rc if not already present
_add_token_to_rc() {
  local rcfile="$1"
  [[ -f "$rcfile" ]] || return
  grep -q "LAUNCHAPP_TOKEN" "$rcfile" 2>/dev/null && return
  if confirm "Add LAUNCHAPP_TOKEN export to $rcfile?"; then
    echo "" >> "$rcfile"
    echo "# launchapp agent token" >> "$rcfile"
    echo "export LAUNCHAPP_TOKEN=\$(cat '$TOKEN_FILE' 2>/dev/null)" >> "$rcfile"
    ok "Token export added to $rcfile"
  fi
}

[[ -f "$HOME/.bashrc" ]] && _add_token_to_rc "$HOME/.bashrc"
[[ -f "$HOME/.zshrc" ]]  && _add_token_to_rc "$HOME/.zshrc"

# =============================================================================
# 6. VERIFICATION
# =============================================================================

step "Verifying installation"

errors=0
for f in \
    "$SCRIPT_DIR/launchapp.sh" \
    "$SCRIPT_DIR/remote_monitor.sh" \
    "$SCRIPT_DIR/lib/constants.sh" \
    "$SCRIPT_DIR/lib/transport_local.sh" \
    "$SCRIPT_DIR/lib/transport_adb.sh" \
    "$SCRIPT_DIR/lib/transport_agent.sh" \
    "$SCRIPT_DIR/lib/android.sh" \
    "$SCRIPT_DIR/modes/debug.sh" \
    "$SCRIPT_DIR/modes/monitor.sh" \
    "$SCRIPT_DIR/modes/crash.sh" \
    "$SCRIPT_DIR/modes/perf.sh" \
    "$SCRIPT_DIR/modes/network.sh"; do
  if bash -n "$f" 2>/dev/null; then
    ok "$(basename "$f")"
  else
    fail "$(basename "$f") — syntax error!"
    ((errors++))
  fi
done

if [[ -f "$SCRIPT_DIR/agent.py" ]]; then
  if python3 -m py_compile "$SCRIPT_DIR/agent.py" 2>/dev/null; then
    ok "agent.py"
  else
    fail "agent.py — syntax error!"
    ((errors++))
  fi
fi

if [[ $errors -gt 0 ]]; then
  echo
  warn "Installation completed with $errors error(s). Check the files above."
else
  ok "All files verified"
fi

# =============================================================================
# 7. QUICKSTART SUMMARY
# =============================================================================

echo
echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│${NC}  ${GREEN}Installation complete!${NC}                                       ${CYAN}│${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
echo
echo -e "${YELLOW}Reload your shell first:${NC}"
echo "  source ~/.bashrc"
echo
echo -e "${YELLOW}Local debugging (on this phone):${NC}"
echo "  launchapp chrome debug"
echo "  launchapp spotify monitor"
echo "  launchapp com.example.myapp crash --save"
echo
echo -e "${YELLOW}Remote debugging via agent (controller → target):${NC}"
echo "  # On the TARGET phone (run agent):"
echo "  export LAUNCHAPP_TOKEN='\$(cat $TOKEN_FILE)'"
echo "  launchapp -r --agent"
echo
echo "  # On the CONTROLLER phone (run modes):"
echo "  export LAUNCHAPP_TOKEN='\$(cat $TOKEN_FILE)'"
echo "  launchapp -r --connect <TARGET_IP> chrome debug"
echo
echo -e "${YELLOW}Remote debugging via ADB:${NC}"
echo "  # Enable Wireless Debugging on target, then:"
echo "  remote_monitor --adb <TARGET_IP>:5555 spotify monitor"
echo
echo -e "${YELLOW}Your agent token:${NC}"
echo "  ${AGENT_TOKEN:0:16}…  (full token in $TOKEN_FILE)"
echo
echo -e "  ${CYAN}See README.md for full documentation.${NC}"
echo
