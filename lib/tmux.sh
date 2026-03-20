#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/tmux.sh — tmux session creation, pane management, script injection
# Depends on: lib/constants.sh, lib/log.sh, lib/deps.sh
# =============================================================================

# Sanitize a name for use as a tmux session name (alphanum + underscore only)
make_session_name() {
  printf '%s' "$1" | tr -cs 'a-zA-Z0-9' '_' | head -c 50
}

# Check if a tmux session exists
session_exists() {
  tmux has-session -t "$1" 2>/dev/null
}

# Create a new tmux session (destroying any existing one with the same name).
# Uses a lockfile to prevent simultaneous duplicate creation.
# Usage: init_session SESSION_NAME
init_session() {
  local session="$1"
  local cols rows
  cols=$(tput cols 2>/dev/null || echo 220)
  rows=$(tput lines 2>/dev/null || echo 50)

  mkdir -p "$LAUNCHAPP_LOCK_DIR"
  local lock="$LAUNCHAPP_LOCK_DIR/${session}.lock"

  # If a lockfile exists, treat it as stale if it is older than 30 seconds
  # (guards against orphaned locks from SIGKILL / crashes).
  if [[ -f "$lock" ]]; then
    local lock_age
    lock_age=$(( $(date +%s) - $(stat -c %Y "$lock" 2>/dev/null || echo 0) ))
    if (( lock_age < 30 )); then
      log_warn "Session '$session' creation already in progress (lock age: ${lock_age}s)"
      return 1
    fi
    log_warn "Removing stale lock for '$session' (age: ${lock_age}s)"
    rm -f "$lock"
  fi

  touch "$lock"
  # Clean up lock on normal return AND on INT/TERM so the file never orphans
  trap 'rm -f "$lock"' RETURN INT TERM

  tmux kill-session -t "$session" 2>/dev/null || true
  tmux new-session -d -s "$session" -x "$cols" -y "$rows"
}

# Send a shell command to a tmux pane
# Usage: pane_run TARGET CMD
#   TARGET: session:window.pane  e.g. "mysession:0.1"
pane_run() {
  tmux send-keys -t "$1" "$2" Enter
}

# Create a new named window in a session
# Usage: new_window SESSION NAME
new_window() {
  tmux new-window -t "$1" -n "$2"
}

# Attach to a session with a help overlay printed first
# Usage: attach_session SESSION_NAME
attach_session() {
  local session="$1"
  echo
  echo -e "${CYAN}┌──────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│${NC}  Session: ${YELLOW}${session}${NC}"
  echo -e "${CYAN}│${NC}  Ctrl+b 0-9  → switch windows"
  echo -e "${CYAN}│${NC}  Ctrl+b ↑↓   → switch panes"
  echo -e "${CYAN}│${NC}  Ctrl+b d    → detach (session stays alive)"
  echo -e "${CYAN}│${NC}  Ctrl+b &    → kill window"
  echo -e "${CYAN}└──────────────────────────────────────────────┘${NC}"
  echo
  sleep 1
  tmux attach-session -t "$session"
}

# Write a bash script body to a self-deleting tempfile.
# Returns the tempfile path via stdout.
# The generated script removes itself on EXIT so orphaned files don't accumulate
# even when the pane is killed mid-run.
# Usage: write_temp_script BODY_STRING
write_temp_script() {
  local body="$1"
  local tmp
  tmp=$(mktemp /tmp/la_XXXXXX.sh)
  # Prepend a self-cleanup trap so the file is always removed, even on kill/crash
  printf '#!%s\ntrap '"'"'rm -f "%s"'"'"' EXIT\n%s\n' \
    "$TERMUX_SHELL" "$tmp" "$body" > "$tmp"
  chmod +x "$tmp"
  echo "$tmp"
}

# Sweep leftover tempfiles from previous sessions (older than 1 hour).
# Called once at startup. Silent — never blocks or errors.
_cleanup_stale_tempfiles() {
  find /tmp -maxdepth 1 -name 'la_*.sh' -mmin +60 -delete 2>/dev/null || true
}

# List all active launchapp-owned sessions (prefix: dbg_ mon_ adg_ amon_ adbg_ net_)
list_la_sessions() {
  tmux list-sessions -F "#{session_name}" 2>/dev/null \
    | grep -E '^(dbg_|mon_|adg_|amon_|adbg_|net_)' \
    || true
}
