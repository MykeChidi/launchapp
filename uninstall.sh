#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# uninstall.sh — launchapp clean removal
#
# Reverses every action performed by install.sh:
#   1. Kills any running launchapp tmux sessions
#   2. Stops any running agent process
#   3. Removes $PREFIX/bin symlinks
#   4. Strips alias and token blocks from shell rc files
#   5. Removes config, cache, log, screenshot, and download directories
#   6. Removes tmpfile locks
#   7. Optionally removes the project directory itself
#
# Run from anywhere:
#   bash /path/to/launchapp/uninstall.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

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
skipped() { echo -e "  ${YELLOW}–${NC} $*  (skipped)"; }
removed() { echo -e "  ${RED}✗${NC} $*  (removed)"; }

confirm() {
  local msg="$1" default="${2:-y}"
  local prompt="[Y/n]"
  [[ "$default" == "n" ]] && prompt="[y/N]"
  read -rp "  $msg $prompt: " ans
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy] ]]
}

# ── Resolve config/log dirs the same way install.sh set them ─────────────────
CONFIG_DIR="${LAUNCHAPP_CONFIG_DIR:-$HOME/.launchapp}"
LOG_DIR="${LAUNCHAPP_LOG_DIR:-$HOME/launchapp_logs}"
CACHE_DIR="$CONFIG_DIR/cache"
SCREENSHOTS_DIR="$HOME/launchapp_screenshots"
DOWNLOADS_DIR="$HOME/launchapp_downloads"
TOKEN_FILE="$CONFIG_DIR/token"
LOCK_DIR="/tmp/launchapp_locks"
PREFIX_BIN="${PREFIX:-/data/data/com.termux/files/usr}/bin"

# =============================================================================
# BANNER
# =============================================================================

echo
echo -e "${CYAN}┌─────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│${NC}  ${PURPLE}launchapp${NC} — Uninstall                      ${CYAN}│${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────┘${NC}"
echo
echo "  Project directory : $SCRIPT_DIR"
echo "  Config directory  : $CONFIG_DIR"
echo "  Log directory     : $LOG_DIR"
echo

if ! confirm "This will remove launchapp and all its data. Continue?" "n"; then
  echo
  echo "  Aborted — nothing was changed."
  echo
  exit 0
fi

# =============================================================================
# 1. KILL RUNNING TMUX SESSIONS
# =============================================================================

step "Stopping active launchapp tmux sessions"

SESSION_PREFIXES=(dbg_ mon_ adg_ amon_ adbg_ net_)
killed_any=false

if command -v tmux &>/dev/null; then
  while IFS= read -r session; do
    [[ -z "$session" ]] && continue
    for prefix in "${SESSION_PREFIXES[@]}"; do
      if [[ "$session" == "${prefix}"* ]]; then
        tmux kill-session -t "$session" 2>/dev/null && \
          removed "tmux session: $session" || \
          warn "Could not kill session: $session"
        killed_any=true
        break
      fi
    done
  done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null || true)
fi

$killed_any || ok "No active launchapp sessions found"

# =============================================================================
# 2. STOP RUNNING AGENT PROCESS
# =============================================================================

step "Stopping agent process"

agent_pids=$(pgrep -f "agent\.py" 2>/dev/null || true)

if [[ -n "$agent_pids" ]]; then
  echo "$agent_pids" | while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    kill "$pid" 2>/dev/null && removed "agent process PID $pid" || \
      warn "Could not stop agent PID $pid — may already be dead"
  done
  # Give it a moment then SIGKILL any survivors
  sleep 1
  remaining=$(pgrep -f "agent\.py" 2>/dev/null || true)
  if [[ -n "$remaining" ]]; then
    echo "$remaining" | while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      kill -9 "$pid" 2>/dev/null || true
      warn "Force-killed agent PID $pid"
    done
  fi
else
  ok "No running agent process found"
fi

# =============================================================================
# 3. REMOVE $PREFIX/BIN SYMLINKS
# =============================================================================

step "Removing $PREFIX_BIN symlinks"

_remove_symlink() {
  local link="$1"
  if [[ -L "$link" ]]; then
    local target
    target=$(readlink "$link" 2>/dev/null || true)
    # Only remove if the symlink points into our project directory
    if [[ "$target" == "$SCRIPT_DIR"* ]]; then
      rm -f "$link" && removed "symlink: $link → $target"
    else
      skipped "symlink $link points elsewhere ($target) — not ours"
    fi
  elif [[ -f "$link" ]]; then
    warn "$link exists but is not a symlink — leaving it untouched"
  else
    skipped "$link (not found)"
  fi
}

_remove_symlink "$PREFIX_BIN/launchapp"
_remove_symlink "$PREFIX_BIN/remote_monitor"

# =============================================================================
# 4. STRIP RC FILE ENTRIES
# =============================================================================

step "Removing shell rc entries"

# Removes a delimited block from a file using a sentinel comment as the anchor.
# Handles three block formats written by install.sh:

# We use Python for the multi-line sed equivalent because POSIX sed and Termux's
# busybox sed differ in their support for multi-line address ranges.

_strip_rc_block() {
  local rcfile="$1"
  [[ -f "$rcfile" ]] || return 0

  local changed=false

  # ── Strip alias block ─────────────────────────────────────────────────────
  if grep -q "launchapp aliases" "$rcfile" 2>/dev/null; then
    python3 - "$rcfile" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
# Remove the block between the two sentinel comment lines (inclusive)
cleaned = re.sub(
    r'\n# ── launchapp aliases.*?# ─{20,}\n',
    '\n',
    content,
    flags=re.DOTALL
)
with open(path, 'w') as f:
    f.write(cleaned)
PYEOF
    changed=true
  fi

  # ── Strip token export block ──────────────────────────────────────────────
  if grep -q "LAUNCHAPP_TOKEN" "$rcfile" 2>/dev/null; then
    python3 - "$rcfile" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
# Remove optional blank line + comment + export line
cleaned = re.sub(
    r'\n?\n?# launchapp agent token\nexport LAUNCHAPP_TOKEN=.*\n',
    '\n',
    content
)
with open(path, 'w') as f:
    f.write(cleaned)
PYEOF
    changed=true
  fi

  if $changed; then
    removed "rc entries from $rcfile"
  else
    skipped "$rcfile (no launchapp entries found)"
  fi
}

_strip_rc_block "$HOME/.bashrc"
_strip_rc_block "$HOME/.zshrc"
_strip_rc_block "$HOME/.profile"

# =============================================================================
# 5. REMOVE DATA DIRECTORIES
# =============================================================================

step "Removing data directories"

# ── Cache — always safe to remove ────────────────────────────────────────────
if [[ -d "$CACHE_DIR" ]]; then
  rm -rf "$CACHE_DIR" && removed "cache: $CACHE_DIR"
else
  skipped "cache dir (not found)"
fi

# ── Logs ─────────────────────────────────────────────────────────────────────
if [[ -d "$LOG_DIR" ]]; then
  log_count=$(find "$LOG_DIR" -type f 2>/dev/null | wc -l || echo 0)
  if [[ "$log_count" -gt 0 ]]; then
    if confirm "Remove $log_count log file(s) in $LOG_DIR?"; then
      rm -rf "$LOG_DIR" && removed "logs: $LOG_DIR"
    else
      skipped "logs (kept at $LOG_DIR)"
    fi
  else
    rm -rf "$LOG_DIR" && removed "logs: $LOG_DIR (empty)"
  fi
else
  skipped "log dir (not found)"
fi

# ── Screenshots ───────────────────────────────────────────────────────────────
if [[ -d "$SCREENSHOTS_DIR" ]]; then
  shot_count=$(find "$SCREENSHOTS_DIR" -type f 2>/dev/null | wc -l || echo 0)
  if [[ "$shot_count" -gt 0 ]]; then
    if confirm "Remove $shot_count screenshot(s) in $SCREENSHOTS_DIR?"; then
      rm -rf "$SCREENSHOTS_DIR" && removed "screenshots: $SCREENSHOTS_DIR"
    else
      skipped "screenshots (kept at $SCREENSHOTS_DIR)"
    fi
  else
    rm -rf "$SCREENSHOTS_DIR" && removed "screenshots: $SCREENSHOTS_DIR (empty)"
  fi
else
  skipped "screenshots dir (not found)"
fi

# ── Downloads ─────────────────────────────────────────────────────────────────
if [[ -d "$DOWNLOADS_DIR" ]]; then
  dl_count=$(find "$DOWNLOADS_DIR" -type f 2>/dev/null | wc -l || echo 0)
  if [[ "$dl_count" -gt 0 ]]; then
    if confirm "Remove $dl_count downloaded file(s) in $DOWNLOADS_DIR?"; then
      rm -rf "$DOWNLOADS_DIR" && removed "downloads: $DOWNLOADS_DIR"
    else
      skipped "downloads (kept at $DOWNLOADS_DIR)"
    fi
  else
    rm -rf "$DOWNLOADS_DIR" && removed "downloads: $DOWNLOADS_DIR (empty)"
  fi
else
  skipped "downloads dir (not found)"
fi

# ── Config directory (aliases, devices.json, token) ──────────────────────────
if [[ -d "$CONFIG_DIR" ]]; then
  # Warn specifically about the token — it may be in use on another device
  if [[ -f "$TOKEN_FILE" ]]; then
    warn "Token file found at $TOKEN_FILE"
    warn "If the agent is still running on another phone with this token, it"
    warn "will stop accepting connections from a new install until re-paired."
  fi
  if confirm "Remove config directory $CONFIG_DIR? (aliases, devices, token)"; then
    rm -rf "$CONFIG_DIR" && removed "config: $CONFIG_DIR"
  else
    skipped "config dir (kept at $CONFIG_DIR)"
  fi
else
  skipped "config dir (not found)"
fi

# =============================================================================
# 6. REMOVE STALE LOCK FILES
# =============================================================================

step "Removing lock files"

if [[ -d "$LOCK_DIR" ]]; then
  lock_count=$(find "$LOCK_DIR" -name "*.lock" 2>/dev/null | wc -l || echo 0)
  if [[ "$lock_count" -gt 0 ]]; then
    find "$LOCK_DIR" -name "*.lock" -delete 2>/dev/null || true
    removed "$lock_count lock file(s) from $LOCK_DIR"
  else
    ok "No lock files found"
  fi
  # Remove the lock dir only if it's now empty
  rmdir "$LOCK_DIR" 2>/dev/null && removed "lock dir: $LOCK_DIR" || true
else
  skipped "lock dir (not found)"
fi

# Also sweep any leftover tempscripts from previous sessions
tmp_count=$(find /tmp -maxdepth 1 -name 'la_*.sh' 2>/dev/null | wc -l || echo 0)
if [[ "$tmp_count" -gt 0 ]]; then
  find /tmp -maxdepth 1 -name 'la_*.sh' -delete 2>/dev/null || true
  removed "$tmp_count tempscript(s) from /tmp"
else
  ok "No leftover tempscripts found"
fi

# =============================================================================
# 7. REMOVE PROJECT DIRECTORY
# =============================================================================

step "Project directory"

echo
echo -e "  Project directory: ${YELLOW}$SCRIPT_DIR${NC}"
echo

if confirm "Remove the project directory? (source files, agent, all scripts)" "n"; then
  # Self-deletion: copy this script to /tmp and schedule removal from there
  # so we are not trying to delete the directory we're running from.
  tmp_self=$(mktemp /tmp/la_uninstall_XXXXXX.sh)
  cp "$0" "$tmp_self"
  chmod +x "$tmp_self"

  # Perform the deletion in a subshell with the copied script
  (
    sleep 1
    rm -rf "$SCRIPT_DIR" 2>/dev/null && \
      echo -e "\n  ${RED}✗${NC}  project dir: $SCRIPT_DIR  (removed)" || \
      echo -e "\n  ${YELLOW}⚠${NC}  Could not fully remove $SCRIPT_DIR — remove manually"
    rm -f "$tmp_self"
  ) &

  echo
  echo -e "  ${YELLOW}Project directory will be removed in 1 second.${NC}"
else
  skipped "project directory (kept at $SCRIPT_DIR)"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo
echo -e "${CYAN}┌─────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│${NC}  ${GREEN}Uninstall complete${NC}                          ${CYAN}│${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────┘${NC}"
echo
echo "  Reload your shell to clear any in-session aliases:"
echo "    source ~/.bashrc"
echo
echo "  If you kept any data directories, they are at:"
[[ -d "$LOG_DIR" ]]         && echo "    Logs        : $LOG_DIR"
[[ -d "$SCREENSHOTS_DIR" ]] && echo "    Screenshots : $SCREENSHOTS_DIR"
[[ -d "$DOWNLOADS_DIR" ]]   && echo "    Downloads   : $DOWNLOADS_DIR"
[[ -d "$CONFIG_DIR" ]]      && echo "    Config      : $CONFIG_DIR"
echo
