#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# modes/monitor.sh — Split-pane live monitor
# Works with any transport via transport_* and *_cmd helpers.
# Depends on: lib/constants.sh lib/log.sh lib/tmux.sh lib/android.sh
# =============================================================================

mode_monitor() {
  local app_string="$1" pkg="$2" save_logs="${3:-false}"
  need_tmux
  validate_installed "$app_string"

  local session safe_pkg transport_label
  session=$(make_session_name "mon_${pkg}")
  safe_pkg=$(escape_grep "$pkg")
  transport_label="${TRANSPORT:-local}"

  log_info "Starting monitor [$transport_label] for $pkg…"
  init_session "$session"

  do_launch "$app_string" || log_warn "Launch may have failed — continuing"

  # Top pane: scrolling logcat
  local logcmd
  logcmd=$(logcat_stream_cmd "$pkg" "-v time")
  local log_cmd="$logcmd | grep --line-buffered --color=always '${safe_pkg}'"
  [[ "$save_logs" == "true" ]] && log_cmd+=" | tee '$(new_logfile "${pkg}_monitor")'"
  pane_run "${session}:0" "clear; echo 'Monitor [$transport_label] — $pkg'; $log_cmd"

  # Bottom pane: stats bar + keyboard shortcuts
  tmux split-window -v -l 6 -t "${session}:0"
  local launch_cmd stop_cmd mem_cmd bat_cmd
  launch_cmd=$(am_start_cmd "$app_string")
  stop_cmd=$(am_stop_cmd "$pkg")
  mem_cmd=$(meminfo_cmd "$pkg")
  bat_cmd=$(battery_cmd)

  local stats
  stats=$(write_temp_script "
PKG='$pkg'
while true; do
  clear
  MEM=\$($mem_cmd 2>/dev/null | awk '/TOTAL/{print \$2; exit}')
  BAT=\$($bat_cmd 2>/dev/null | awk '/level/{print \$2}')
  TEMP=\$($bat_cmd 2>/dev/null | awk '/temperature/{printf \"%.1f\", \$2/10}')
  if [ -n \"\$MEM\" ]; then
    echo -e '${GREEN}● Running${NC}  Mem:\${MEM:-?}KB  '\$(date +%H:%M:%S)
  else
    echo -e '${RED}● Stopped${NC}  '\$(date +%H:%M:%S)
  fi
  echo \"  Battery: \${BAT:-?}%  Temp: \${TEMP:-?}°C\"
  printf '  [l]aunch [k]ill [r]estart [q]uit > '
  read -t 3 -r key || continue
  case \"\$key\" in
    l) $launch_cmd 2>/dev/null ;;
    k) $stop_cmd ;;
    r) $stop_cmd; sleep 1; $launch_cmd 2>/dev/null ;;
    q) exit 0 ;;
  esac
done
")
  pane_run "${session}:0.1" "bash '$stats'; rm -f '$stats'"

  attach_session "$session"
}
