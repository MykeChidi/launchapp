#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/log.sh — Logging helpers
# Depends on: lib/constants.sh
# =============================================================================

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { [[ "${LAUNCHAPP_DEBUG:-0}" == "1" ]] && echo -e "${PURPLE}[DEBUG]${NC} $*" >&2 || true; }

die() { log_error "$*"; exit 1; }

# Print a section banner to stdout
banner() {
  local title="$1"
  echo -e "${CYAN}┌────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│${NC}  ${PURPLE}${title}${NC}"
  echo -e "${CYAN}└────────────────────────────────────────────────┘${NC}"
  echo
}

# timestamp: DDMMYYYY_HHMMSS
timestamp() { date +%d%m%Y_%H%M%S; }

# Create a timestamped log file path inside LAUNCHAPP_LOG_DIR
# Usage: new_logfile LABEL → prints full path
new_logfile() {
  local label="$1"
  mkdir -p "$LAUNCHAPP_LOG_DIR"
  printf '%s/%s_%s.log' "$LAUNCHAPP_LOG_DIR" "$(timestamp)" "$label"
}
