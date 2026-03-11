#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# modes/debug.sh — 6-window tmux debug session
# Works with any transport (local, adb, agent) via transport_* and *_cmd helpers.
# Depends on: lib/constants.sh lib/log.sh lib/tmux.sh lib/android.sh
# =============================================================================

mode_debug() {
  local app_string="$1" pkg="$2" save_logs="${3:-false}"
  need_tmux
  validate_installed "$app_string"

  local session safe_pkg
  session=$(make_session_name "dbg_${pkg}")
  safe_pkg=$(escape_grep "$pkg")

  [[ "$save_logs" == "true" ]] && \
    { mkdir -p "$LAUNCHAPP_LOG_DIR"; log_info "Logs → $LAUNCHAPP_LOG_DIR"; }

  local transport_label="${TRANSPORT:-local}"
  log_info "Starting debug session [$transport_label] for $pkg…"
  init_session "$session"

  # ── Window 0: Main logcat ─────────────────────────────────────────────────
  tmux rename-window -t "${session}:0" "Logs"
  local logcmd
  logcmd=$(logcat_stream_cmd "$pkg")
  local main_cmd="$logcmd | grep --line-buffered --color=always -E '${safe_pkg}|AndroidRuntime|ActivityManager'"
  [[ "$save_logs" == "true" ]] && main_cmd+=" | tee '$(new_logfile "${pkg}_main")'"
  pane_run "${session}:0" "clear; echo 'Logs [$transport_label] — $pkg'; echo; $main_cmd"

  # ── Window 0 lower: control REPL ─────────────────────────────────────────
  tmux split-window -v -l 8 -t "${session}:0"
  local launch_cmd stop_cmd restart_cmd clear_cmd dump_cmd mem_cmd
  launch_cmd=$(am_start_cmd "$app_string")
  stop_cmd=$(am_stop_cmd "$pkg")
  clear_cmd=$(pm_clear_cmd "$pkg")
  dump_cmd=$(pm_dump_cmd "$pkg")
  mem_cmd=$(meminfo_cmd "$pkg")

  local ctrl
  ctrl=$(write_temp_script "
echo -e '${PURPLE}Control [$transport_label] — $pkg${NC}'
echo -e 'Commands: ${YELLOW}launch kill restart clear info meminfo exit${NC}'
echo
$launch_cmd 2>/dev/null && echo 'Launched'
while true; do
  printf '> '
  read -r cmd arg
  case \"\$cmd\" in
    launch)  $launch_cmd ;;
    kill)    $stop_cmd && echo Stopped ;;
    restart) $stop_cmd; sleep 1; $launch_cmd ;;
    clear)   $clear_cmd && echo 'Data cleared' ;;
    info)    $dump_cmd | head -40 ;;
    meminfo) $mem_cmd ;;
    exit)    exit 0 ;;
    '')      ;;
    *)       echo \"Unknown: \$cmd\" ;;
  esac
done
")
  pane_run "${session}:0.1" "bash '$ctrl'; rm -f '$ctrl'"

  # ── Window 1: Errors + Fatal ──────────────────────────────────────────────
  new_window "$session" "Errors"
  local err_logcmd
  err_logcmd=$(logcat_stream_cmd "$pkg" "*:E *:F")
  local err_cmd="$err_logcmd | grep --line-buffered --color=always -E '${safe_pkg}|FATAL|AndroidRuntime'"
  [[ "$save_logs" == "true" ]] && err_cmd+=" | tee '$(new_logfile "${pkg}_errors")'"
  pane_run "${session}:1" "clear; echo 'Errors [$transport_label] — $pkg'; echo; $err_cmd"

  # ── Window 2: Activity lifecycle ─────────────────────────────────────────
  new_window "$session" "Activity"
  local act_logcmd
  act_logcmd=$(logcat_stream_cmd "$pkg" "-s ActivityManager:V ActivityTaskManager:V")
  pane_run "${session}:2" \
    "clear; echo 'Activity Lifecycle [$transport_label] — $pkg'; echo; \
     $act_logcmd | grep --line-buffered --color=always '${safe_pkg}'"

  # ── Window 3: Crash + ANR monitor ────────────────────────────────────────
  new_window "$session" "Crashes"
  local crash_logcmd
  crash_logcmd=$(logcat_stream_cmd "$pkg" "*:E *:F")
  local crash
  crash=$(write_temp_script "
PKG='$pkg'
SAVE='$save_logs'
LOGDIR='$LAUNCHAPP_LOG_DIR'
echo -e '${RED}Crash+ANR Monitor [$transport_label] — $pkg${NC}'
echo
OUTFILE=''
[ \"\$SAVE\" = 'true' ] && OUTFILE=\"\${LOGDIR}/\$(date +%Y%m%d_%H%M%S)_\${PKG}_crashes.log\"
$crash_logcmd \\
  | grep --line-buffered -E 'FATAL|AndroidRuntime|ANR in|Exception|${safe_pkg}' \\
  | while IFS= read -r line; do
      ts=\$(date '+%H:%M:%S.%3N')
      echo \"\$ts \$line\"
      [ -n \"\$OUTFILE\" ] && echo \"\$ts \$line\" >> \"\$OUTFILE\"
      echo \"\$line\" | grep -qE 'FATAL|ANR in' && {
        command -v termux-notification &>/dev/null && \\
          termux-notification --title 'CRASH/ANR' --content \"\$PKG\" --priority high 2>/dev/null &
        command -v termux-vibrate &>/dev/null && termux-vibrate -d 800 2>/dev/null &
      }
    done
")
  pane_run "${session}:3" "bash '$crash'; rm -f '$crash'"

  # ── Window 4: Performance ────────────────────────────────────────────────
  new_window "$session" "Performance"
  local perf_mem_cmd perf_bat_cmd perf_logcmd
  perf_mem_cmd=$(meminfo_cmd "$pkg")
  perf_bat_cmd=$(battery_cmd)
  perf_logcmd=$(logcat_stream_cmd "$pkg" "-d -s dalvikvm")
  local perf
  perf=$(write_temp_script "
PKG='$pkg'
echo -e '${BLUE}Performance [$transport_label] — $pkg${NC}'
while true; do
  clear
  echo -e '${BLUE}══ Perf: $pkg ══${NC}  \$(date +%H:%M:%S)'
  echo
  echo '── Memory ───────────────────────────────────'
  $perf_mem_cmd 2>/dev/null \\
    | grep -E 'TOTAL|Native Heap|Dalvik Heap|HEAP|Java' || echo '  unavailable'
  echo
  echo '── Battery ──────────────────────────────────'
  $perf_bat_cmd 2>/dev/null | grep -E 'level|temperature|status' | sed 's/^/  /'
  echo
  echo '── Recent GC ────────────────────────────────'
  $perf_logcmd 2>/dev/null | grep \"\$PKG\" | tail -3 | sed 's/^/  /' || echo '  none'
  sleep 3
done
")
  pane_run "${session}:4" "bash '$perf'; rm -f '$perf'"

  # ── Window 5: Network calls ───────────────────────────────────────────────
  new_window "$session" "Network"
  local net_logcmd
  net_logcmd=$(logcat_stream_cmd "$pkg")
  local net_cmd="$net_logcmd | grep --line-buffered --color=always -iE"
  net_cmd+=" '${safe_pkg}.*(https?|okhttp|retrofit|volley|request|response|url|api|endpoint|socket|dns|connect)'"
  [[ "$save_logs" == "true" ]] && net_cmd+=" | tee '$(new_logfile "${pkg}_network")'"
  pane_run "${session}:5" "clear; echo 'Network [$transport_label] — $pkg'; echo; $net_cmd"

  # ── Window 6: System stats (agent transport only) ─────────────────────────
  # /stats returns CPU% and RAM% from /proc on the target device.
  # Not added for local/ADB where the data is less useful (same device or
  # where /proc is directly readable in the Perf window).
  if [[ "${TRANSPORT:-local}" == "agent" ]]; then
    new_window "$session" "Stats"
    local sys_stats_cmd
    sys_stats_cmd=$(stats_cmd)
    local stats_scr
    stats_scr=$(write_temp_script "
BASE='http://${DEVICE_IP}:${DEVICE_PORT}'
TOKEN='${AGENT_TOKEN:-}'
AUTH=\${TOKEN:+-H '${TOKEN_HEADER}: '\$TOKEN}
PKG='$pkg'
echo -e '${BLUE}System Stats [$transport_label] — ${DEVICE_NAME:-target}${NC}'
while true; do
  clear
  echo -e '${BLUE}══ System Stats — ${DEVICE_NAME:-target}  \$(date +%H:%M:%S) ══${NC}'
  echo

  # Device info (cached after first fetch)
  info=\$(curl -s -m 5 \$AUTH \"\$BASE/info\" 2>/dev/null)
  if [ -n \"\$info\" ]; then
    model=\$(echo \"\$info\" | jq -r '.model // \"?\"' 2>/dev/null)
    android=\$(echo \"\$info\" | jq -r '.android // \"?\"' 2>/dev/null)
    echo -e '${YELLOW}Device${NC}'
    echo \"  \$model  (Android \$android)\"
    echo
  fi

  # System stats
  sys=\$(curl -s -m 5 \$AUTH \"\$BASE/stats\" 2>/dev/null)
  if [ -n \"\$sys\" ]; then
    cpu=\$(echo \"\$sys\"  | jq -r '.cpu_used_pct // \"?\"' 2>/dev/null)
    mem_pct=\$(echo \"\$sys\" | jq -r '.mem_percent  // \"?\"' 2>/dev/null)
    mem_used=\$(echo \"\$sys\" | jq -r '.mem_used_kb  // 0'   2>/dev/null)
    mem_total=\$(echo \"\$sys\" | jq -r '.mem_total_kb // 0'  2>/dev/null)
    mem_used_mb=\$(( mem_used  / 1024 ))
    mem_total_mb=\$(( mem_total / 1024 ))
    echo -e '${YELLOW}System${NC}'
    echo \"  CPU:    \${cpu}%\"
    echo \"  RAM:    \${mem_pct}%  (\${mem_used_mb}MB / \${mem_total_mb}MB)\"
    echo
  fi

  # Battery
  bat=\$(curl -s -m 5 \$AUTH \"\$BASE/battery\" 2>/dev/null)
  if [ -n \"\$bat\" ]; then
    level=\$(echo \"\$bat\" | jq -r '.percentage // \"?\"' 2>/dev/null)
    status=\$(echo \"\$bat\" | jq -r '.status     // \"?\"' 2>/dev/null)
    temp=\$(echo \"\$bat\"   | jq -r '.temperature // \"?\"' 2>/dev/null)
    plugged=\$(echo \"\$bat\" | jq -r 'if .plugged then \"plugged\" else \"unplugged\" end' 2>/dev/null)
    echo -e '${YELLOW}Battery${NC}'
    echo \"  \${level}%  \${status}  \${temp}°C  \${plugged}\"
    echo
  fi

  # App meminfo
  mem=\$(curl -s -m 5 \$AUTH \"\$BASE/meminfo/\$PKG\" 2>/dev/null)
  if [ -n \"\$mem\" ]; then
    total_kb=\$(echo \"\$mem\" | jq -r '.total_kb      // \"?\"' 2>/dev/null)
    native_kb=\$(echo \"\$mem\" | jq -r '.native_heap_kb // \"?\"' 2>/dev/null)
    echo -e '${YELLOW}App Memory — $pkg${NC}'
    echo \"  Total:       \${total_kb} KB\"
    echo \"  Native heap: \${native_kb} KB\"
    echo
  fi

  sleep 4
done
")
    pane_run "${session}:6" "bash '$stats_scr'; rm -f '$stats_scr'"
  fi

  tmux select-window -t "${session}:0"
  attach_session "$session"
}
