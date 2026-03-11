#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/constants.sh — Global constants and color definitions
# Sourced by every script. Must not execute any side-effects.
# =============================================================================

readonly VERSION="1.0.0"
readonly LAUNCHAPP_CONFIG_DIR="${LAUNCHAPP_CONFIG_DIR:-$HOME/.launchapp}"
readonly LAUNCHAPP_CACHE_DIR="$LAUNCHAPP_CONFIG_DIR/cache"
readonly LAUNCHAPP_LOG_DIR="${LAUNCHAPP_LOG_DIR:-$HOME/launchapp_logs}"
readonly LAUNCHAPP_ALIAS_FILE="$LAUNCHAPP_CONFIG_DIR/aliases"
readonly LAUNCHAPP_DEVICES_FILE="$LAUNCHAPP_CONFIG_DIR/devices.json"
readonly LAUNCHAPP_LOCK_DIR="/tmp/launchapp_locks"
readonly AGENT_DEFAULT_PORT=8765
readonly TOKEN_HEADER="X-Launchapp-Token"
readonly TERMUX_SHELL="/data/data/com.termux/files/usr/bin/bash"

# ── Android capability detection ─────────────────────────────────────────────
# Detected once at source time. Scripts use these flags to degrade gracefully
# instead of failing silently when Android restricts a capability.
#
# LAUNCHAPP_HAS_LOGCAT   — logcat is accessible (may be restricted in future Android)
# LAUNCHAPP_HAS_PROC     — /proc/<pid>/stat readable (restricted Android 10+)
# LAUNCHAPP_HAS_AM       — am command available (may lose subcommands over time)
#
# These are exported so tempscripts written by write_temp_script can read them.
_detect_android_capabilities() {
  # logcat: try a quick dump with a very short timeout
  if timeout 2 logcat -d -t 1 &>/dev/null 2>&1; then
    export LAUNCHAPP_HAS_LOGCAT=1
  else
    export LAUNCHAPP_HAS_LOGCAT=0
  fi

  # /proc: check our own pid as a proxy for any app pid
  if [[ -r "/proc/$$/stat" ]]; then
    export LAUNCHAPP_HAS_PROC=1
  else
    export LAUNCHAPP_HAS_PROC=0
  fi

  # am: check it exists and prints usage (not just "not found")
  if am help &>/dev/null 2>&1 || am &>/dev/null 2>&1; then
    export LAUNCHAPP_HAS_AM=1
  else
    export LAUNCHAPP_HAS_AM=0
  fi
}

# Only run detection for local transport — remote transports do their own checks
[[ "${TRANSPORT:-local}" == "local" ]] && _detect_android_capabilities || true

# ── Colors (disabled when stdout is not a terminal) ──────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; PURPLE=''; CYAN=''; NC=''
fi
readonly RED GREEN YELLOW BLUE PURPLE CYAN NC
