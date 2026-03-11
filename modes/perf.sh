#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# modes/perf.sh — Foreground performance dashboard
# Works with any transport via transport_* helpers.
# Depends on: lib/constants.sh lib/log.sh lib/android.sh
# =============================================================================

mode_perf() {
  local app_string="$1" pkg="$2"
  validate_installed "$app_string"

  local transport_label="${TRANSPORT:-local}"

  do_launch "$app_string" || log_warn "Launch may have failed"
  sleep 2

  echo -e "${YELLOW}Performance monitor [$transport_label] — Ctrl+C to stop${NC}"
  echo

  export TRANSPORT_LOGCAT_PKG="$pkg"

  while true; do
    clear
    echo -e "${BLUE}══ Performance [$transport_label]: $pkg  $(date +%H:%M:%S) ══${NC}"
    echo

    local pid
    pid=$(get_pid "$pkg")

    if [[ -z "$pid" ]]; then
      echo -e "${RED}App is not running${NC}"
    else
      echo -e "${GREEN}PID: $pid${NC}"
      echo

      echo "── Memory ──────────────────────────────────────────"
      # dumpsys meminfo output format varies across Android versions.
      # Try broad patterns first; fall back to TOTAL-only if nothing matches.
      local memout
      memout=$(transport_dumpsys meminfo "$pkg" 2>/dev/null)
      if [[ -n "$memout" ]]; then
        # Android 10-14 formats: match known field names with flexible whitespace
        echo "$memout" \
          | grep -iE '^\s*(TOTAL|Native Heap|Dalvik Heap|HEAP SIZE|Graphics|Stack|Java Heap)' \
          | sed 's/^/  /'
        # If nothing matched (format changed again), just print first 8 lines raw
        if ! echo "$memout" | grep -qiE 'TOTAL|Native Heap|Dalvik'; then
          echo "  (raw — format unrecognised on this Android version)"
          echo "$memout" | head -8 | sed 's/^/  /'
        fi
      else
        echo "  unavailable"
      fi
      echo

      # /proc is only available on local transport and only on Android <10 for
      # third-party processes. Check before reading — don't assume it's there.
      if [[ "${TRANSPORT:-local}" == "local" ]]; then
        if [[ -r "/proc/$pid/stat" ]]; then
          echo "── CPU (proc ticks) ────────────────────────────────"
          awk '{utime=$14; stime=$15; printf "  User+Sys ticks: %d\n", utime+stime}' \
            /proc/"$pid"/stat 2>/dev/null \
            || echo "  unavailable"
          echo

          echo "── Threads / FDs ───────────────────────────────────"
          local threads fds
          threads=$(ls /proc/"$pid"/task 2>/dev/null | wc -l || echo "?")
          fds=$(ls /proc/"$pid"/fd 2>/dev/null | wc -l || echo "?")
          echo "  Threads: $threads    Open FDs: $fds"
          echo
        else
          echo "── CPU / Threads ───────────────────────────────────"
          echo "  unavailable (/proc restricted on this Android version)"
          echo
        fi
      fi

      echo "── Recent GC events ────────────────────────────────"
      # Android 14+ logs GC under 'art' tag, not 'dalvikvm'
      # Try both; deduplicate; show last 3 lines
      {
        transport_logcat -d -s dalvikvm 2>/dev/null | grep -F "$pkg"
        transport_logcat -d -s art 2>/dev/null      | grep -F "$pkg"
      } 2>/dev/null | sort -u | tail -3 | sed 's/^/  /' \
        || echo "  none"
      echo

      echo "── Battery ─────────────────────────────────────────"
      # dumpsys battery field names are stable but values format varies
      transport_dumpsys battery 2>/dev/null \
        | grep -iE '^\s*(level|temperature|status|plugged|powered)' | sed 's/^/  /' \
        || echo "  unavailable"
    fi

    sleep 3
  done
}
