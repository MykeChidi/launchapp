#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# modes/network.sh — Foreground network call monitor via logcat
# Works with any transport via transport_* helpers.
# Depends on: lib/constants.sh lib/log.sh lib/android.sh
# =============================================================================

mode_network() {
  local app_string="$1" pkg="$2" save_logs="${3:-false}"
  validate_installed "$app_string"

  local safe_pkg transport_label
  safe_pkg=$(escape_grep "$pkg")
  transport_label="${TRANSPORT:-local}"

  echo -e "${GREEN}Network Monitor [$transport_label] — $pkg${NC}"
  echo

  local outfile=""
  if [[ "$save_logs" == "true" ]]; then
    outfile=$(new_logfile "${pkg}_network")
    log_info "Saving to: $outfile"
  fi

  transport_logcat -c 2>/dev/null || true
  do_launch "$app_string" || log_warn "Launch may have failed — monitoring anyway"

  echo -e "${YELLOW}Monitoring network activity… (Ctrl+C to stop)${NC}"
  echo

  export TRANSPORT_LOGCAT_PKG="$pkg"

  local pattern
  pattern="${safe_pkg}.*(https?://|okhttp|retrofit|volley|request|response|\\.json|api/|/v[0-9]|socket|dns|grpc|websocket)"

  while IFS= read -r line; do
    local ts
    ts=$(date '+%H:%M:%S.%3N')
    echo -e "${ts} ${line}"
    [[ -n "$outfile" ]] && echo "${ts} ${line}" >> "$outfile"
  done < <(transport_logcat | grep --line-buffered -iE "$pattern")
}
