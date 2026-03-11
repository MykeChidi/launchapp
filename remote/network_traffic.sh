#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# remote/network_traffic.sh — tcpdump network traffic monitor (requires root)
# Depends on: lib/constants.sh lib/log.sh lib/tmux.sh
#
# Expects globals: DEVICE_IP, DEVICE_NAME
# =============================================================================

mode_network_traffic() {
  need_tmux

  if ! id 2>/dev/null | grep -q 'uid=0'; then
    log_warn "tcpdump usually requires root. This may fail with 'Permission denied'."
  fi
  if ! command -v tcpdump &>/dev/null; then
    log_warn "tcpdump not found. Network mode will not work."
    log_warn "Install with: pkg install root-repo && pkg install tcpdump"
    return 1
  fi

  local session ip
  session=$(make_session_name "net_${DEVICE_NAME}")
  ip="$DEVICE_IP"
  init_session "$session"

  # ── Window 0: All traffic ─────────────────────────────────────────────────
  tmux rename-window -t "${session}:0" "Traffic"
  pane_run "${session}:0" \
    "echo 'All traffic — $DEVICE_NAME ($ip)'; \
     tcpdump -i wlan0 -n 'host $ip' 2>/dev/null"

  # ── Window 1: HTTP / HTTPS ────────────────────────────────────────────────
  new_window "$session" "HTTP"
  pane_run "${session}:1" \
    "echo 'HTTP/HTTPS — $DEVICE_NAME'; \
     tcpdump -i wlan0 -n -A 'host $ip and (port 80 or port 443)' 2>/dev/null"

  # ── Window 2: DNS ─────────────────────────────────────────────────────────
  new_window "$session" "DNS"
  pane_run "${session}:2" \
    "echo 'DNS — $DEVICE_NAME'; \
     tcpdump -i wlan0 -n 'host $ip and port 53' 2>/dev/null"

  # ── Window 3: App detection by domain ────────────────────────────────────
  new_window "$session" "AppDetect"
  local detect_scr
  detect_scr=$(write_temp_script "
IP='$ip'
echo 'App detection — $DEVICE_NAME'
echo
declare -A COLORS=(
  [youtube]='${RED}'      [spotify]='${GREEN}'  [instagram]='${PURPLE}'
  [facebook]='${BLUE}'   [whatsapp]='${CYAN}'  [twitter]='${YELLOW}'
  [tiktok]='${PURPLE}'   [netflix]='${RED}'    [discord]='${BLUE}'
  [reddit]='${RED}'      [snapchat]='${YELLOW}' [telegram]='${CYAN}'
  [google]='${BLUE}'     
)
tcpdump -i wlan0 -n 'host '\$IP 2>/dev/null \\
  | grep -oP '([a-z0-9-]+\\.)+[a-z]{2,6}' \\
  | while read -r domain; do
      ts=\$(date '+%H:%M:%S')
      label=''
      for app in \"\${!COLORS[@]}\"; do
        echo \"\$domain\" | grep -qi \"\$app\" && label=\"\${COLORS[\$app]}\${app}${NC}\" && break
      done
      echo \"\$ts \${label:-\$domain}  [\$domain]\"
    done
")
  pane_run "${session}:3" "bash '$detect_scr'; rm -f '$detect_scr'"

  attach_session "$session"
}
