#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/deps.sh — Dependency checking and installation helpers
# Depends on: lib/log.sh
# =============================================================================

# Check if a command exists. If not, warn and return 1.
# Usage: require_cmd CMD [PKG_NAME]
require_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" &>/dev/null && return 0
  log_warn "'$cmd' not found. Install with: pkg install $pkg"
  return 1
}

# Like require_cmd but exits fatally if missing.
# Usage: need_cmd CMD [PKG_NAME]
need_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  require_cmd "$cmd" "$pkg" || die "'$cmd' is required. Run: pkg install $pkg"
}

# Prompt to install a missing command; exit if declined.
# Usage: prompt_install CMD PKG_NAME
prompt_install() {
  local cmd="$1" pkg="$2"
  if command -v "$cmd" &>/dev/null; then return 0; fi
  log_warn "'$cmd' is not installed."
  read -rp "  Install $pkg now? (y/n): " yn
  if [[ "$yn" == "y" ]]; then
    pkg install -y "$pkg" || die "Failed to install $pkg"
  else
    die "$cmd is required"
  fi
}

need_tmux()   { need_cmd tmux; }
need_jq()     { need_cmd jq; }
need_curl()   { need_cmd curl; }
need_nmap()   { need_cmd nmap; }
need_python() { need_cmd python3 python; }
need_adb()    { need_cmd adb android-tools; }

# ── Bash version guard ────────────────────────────────────────────────────────
# Associative arrays (declare -gA) require bash 4.2+.
# Termux ships bash 5.x so this only matters if someone has a very old install.
_check_bash_version() {
  local major="${BASH_VERSINFO[0]}" minor="${BASH_VERSINFO[1]}"
  if (( major < 4 || ( major == 4 && minor < 2 ) )); then
    die "launchapp requires bash 4.2+. You have bash ${BASH_VERSION}. Run: pkg upgrade bash"
  fi
}
_check_bash_version

# ── Termux:API availability check ────────────────────────────────────────────
# Returns 0 if termux-notification is callable and functional, 1 otherwise.
# Suppresses errors so callers can degrade gracefully without noise.
#
# The Termux:API app and the termux-api package must both be present AND at
# compatible versions. A version mismatch causes silent failures. We smoke-test
# rather than just checking command existence.
_termux_api_ok() {
  command -v termux-notification &>/dev/null || return 1
  # Smoke test: send an info-level notification with a 0s timeout.
  # If the Termux:API app is not installed or is version-mismatched, this will
  # either hang (we time out it) or exit non-zero.
  timeout 3 termux-info &>/dev/null && return 0 || return 1
}

# Safe wrappers — degrade silently if API unavailable
termux_notify() {
  _termux_api_ok || return 0
  termux-notification "$@" 2>/dev/null &
}

termux_vibrate() {
  command -v termux-vibrate &>/dev/null || return 0
  _termux_api_ok || return 0
  termux-vibrate "$@" 2>/dev/null &
}
