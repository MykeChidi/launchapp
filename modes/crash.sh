#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# modes/crash.sh — Foreground crash and ANR watcher
# Works with any transport via transport_* helpers.
# Supports --watch to auto-restart the app after each crash.
# Depends on: lib/constants.sh lib/log.sh lib/android.sh
# =============================================================================

mode_crash() {
  local app_string="$1" pkg="$2" save_logs="${3:-false}" watch="${4:-false}"
  validate_installed "$app_string"

  local safe_pkg transport_label
  safe_pkg=$(escape_grep "$pkg")
  transport_label="${TRANSPORT:-local}"

  echo -e "${RED}Crash + ANR Monitor [$transport_label] — $pkg${NC}"
  [[ "$watch" == "true" ]] && echo -e "${YELLOW}  --watch active: app will auto-restart after each crash${NC}"
  echo

  local outfile=""
  if [[ "$save_logs" == "true" ]]; then
    outfile=$(new_logfile "${pkg}_crashes")
    log_info "Saving to: $outfile"
  fi

  export TRANSPORT_LOGCAT_PKG="$pkg"

  # ── Capability check ───────────────────────────────────────────────────────
  # On future Android versions, logcat may be restricted for shell processes.
  # Check upfront so users get a clear message rather than a silent empty stream.
  if [[ "${TRANSPORT:-local}" == "local" && "${LAUNCHAPP_HAS_LOGCAT:-1}" == "0" ]]; then
    log_warn "logcat is not accessible on this Android version."
    log_warn "Crash detection requires logcat. Consider using ADB or agent transport:"
    log_warn "  launchapp -r --adb <device> $pkg crash"
    return 1
  fi

  transport_logcat -c 2>/dev/null || true
  do_launch "$app_string" || log_warn "Launch may have failed — monitoring anyway"

  echo -e "${YELLOW}Watching for crashes and ANRs… (Ctrl+C to stop)${NC}"
  echo

  local crash_count=0

  while IFS= read -r line; do
    local ts out
    ts=$(date '+%H:%M:%S.%3N')
    out="${ts} ${line}"
    echo -e "$out"
    [[ -n "$outfile" ]] && echo "$out" >> "$outfile"

    if echo "$line" | grep -qE 'FATAL EXCEPTION|ANR in'; then
      ((crash_count++))
      command -v termux-notification &>/dev/null && \
        termux_notify \
          --title "CRASH #${crash_count} DETECTED" \
          --content "$pkg" \
          --priority high
      termux_vibrate -d 1000
      mkdir -p "$LAUNCHAPP_LOG_DIR"
      echo "$(date '+%Y-%m-%d %H:%M:%S') CRASH/ANR #${crash_count}: $line" \
        >> "$LAUNCHAPP_LOG_DIR/crash_summary.log" || true

      if [[ "$watch" == "true" ]]; then
        echo -e "\n${YELLOW}  Auto-restarting in 2s… (crash #${crash_count})${NC}\n"
        sleep 2
        transport_am force-stop "$pkg" 2>/dev/null || true
        sleep 1
        do_launch "$app_string" 2>/dev/null || true
      fi
    fi
  done < <(transport_logcat *:E *:F \
    | grep --line-buffered -E "FATAL|ANR in|AndroidRuntime|${safe_pkg}")
}
