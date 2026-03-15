#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# launchapp — Android debug toolkit (local + remote via -r flag)
# Version: 1.0.0
#
# LOCAL:   launchapp chrome debug
# REMOTE:  launchapp -r --connect 192.168.1.42 chrome debug
#          launchapp -r --adb 192.168.1.42:5555 chrome debug
#          launchapp -r --agent          (start agent on this phone)
#          launchapp -r scan             (scan network + interactive menu)
#          launchapp -r --connect 192.168.1.42   (interactive remote menu)
# =============================================================================
set -euo pipefail

# ── Locate library files ──────────────────────────────────────────────────────
# Three resolution strategies, in order:
#   1. Explicit override via LAUNCHAPP_DATA_DIR env var
#   2. pkg install layout: $PREFIX/share/launchapp/
#   3. Development / git clone layout: same directory as this script

_find_data_dir() {
  if [[ -n "${LAUNCHAPP_DATA_DIR:-}" && -d "$LAUNCHAPP_DATA_DIR/lib" ]]; then
    echo "$LAUNCHAPP_DATA_DIR"; return
  fi
  local prefix_share="${PREFIX:-/data/data/com.termux/files/usr}/share/launchapp"
  if [[ -d "$prefix_share/lib" ]]; then
    echo "$prefix_share"; return
  fi
  local script_dir
  script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  echo "$script_dir"
}

SCRIPT_DIR="$(_find_data_dir)"

# ── Diagnostic: clear error if library files are missing ─────────────────────
if [[ ! -f "$SCRIPT_DIR/lib/constants.sh" ]]; then
  echo >&2 ""
  echo >&2 "ERROR: launchapp library files not found."
  echo >&2 ""
  echo >&2 "Looked in:"
  echo >&2 "  ${LAUNCHAPP_DATA_DIR:-}  (LAUNCHAPP_DATA_DIR — not set or missing)"
  echo >&2 "  ${PREFIX:-/data/data/com.termux/files/usr}/share/launchapp  (pkg install layout)"
  echo >&2 "  $SCRIPT_DIR  (script directory)"
  echo >&2 ""
  echo >&2 "If you installed via git clone, run:  bash install.sh"
  echo >&2 "Or set:  export LAUNCHAPP_DATA_DIR=/path/to/launchapp"
  exit 1
fi

# ── Core libraries (always loaded) ───────────────────────────────────────────
source "$SCRIPT_DIR/lib/constants.sh"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/tmux.sh"
source "$SCRIPT_DIR/lib/aliases.sh"

# ── Shared modes (always loaded) ─────────────────────────────────────────────
source "$SCRIPT_DIR/modes/debug.sh"
source "$SCRIPT_DIR/modes/monitor.sh"
source "$SCRIPT_DIR/modes/crash.sh"
source "$SCRIPT_DIR/modes/perf.sh"
source "$SCRIPT_DIR/modes/network.sh"
source "$SCRIPT_DIR/modes/files.sh"

readonly SCRIPT_NAME="launchapp"

# ── Remote connection state (populated when -r is used) ──────────────────────
DEVICE_IP=""
DEVICE_NAME=""
DEVICE_TYPE=""
DEVICE_PORT="${AGENT_DEFAULT_PORT}"
DEVICE_ADB_ID=""
AGENT_TOKEN="${LAUNCHAPP_TOKEN:-}"

# =============================================================================
# TRANSPORT ACTIVATION
# Called after -r connection flags are parsed. Sources the right transport,
# then android.sh (which depends on transport_* being defined).
# =============================================================================

activate_local_transport() {
  need_adb

  # Enable TCP/IP mode and connect ADB to this device over loopback.
  # This gives full shell permissions regardless of Android version or OEM.
  if ! adb devices 2>/dev/null | grep -q "^localhost:5555.*device$"; then
    log_info "Connecting ADB to localhost…"
    adb tcpip 5555 2>/dev/null || true
    sleep 1
    adb connect localhost:5555 2>/dev/null || true
    sleep 1
    if ! adb devices 2>/dev/null | grep -q "^localhost:5555.*device$"; then
      echo
      log_error "Could not connect ADB to this device."
      echo
      echo "  One-time setup required:"
      echo "  1. Settings → About phone → tap Build number 7 times"
      echo "  2. Settings → Developer Options → Enable Wireless Debugging"
      echo "  3. Run: launchapp setup"
      echo
      exit 1
    fi
    log_info "ADB connected to localhost"
  fi

  source "$SCRIPT_DIR/lib/transport_local.sh"
  source "$SCRIPT_DIR/lib/android.sh"
  _cleanup_stale_tempfiles
}

activate_remote_transport() {
  source "$SCRIPT_DIR/lib/devices.sh"
  source "$SCRIPT_DIR/lib/agent_client.sh"
  source "$SCRIPT_DIR/lib/adb_client.sh"
  source "$SCRIPT_DIR/remote/scan.sh"
  source "$SCRIPT_DIR/remote/network_traffic.sh"

  case "$DEVICE_TYPE" in
    agent) source "$SCRIPT_DIR/lib/transport_agent.sh" ;;
    adb)   source "$SCRIPT_DIR/lib/transport_adb.sh" ;;
    *)     die "Cannot activate transport for type '$DEVICE_TYPE'" ;;
  esac
  source "$SCRIPT_DIR/lib/android.sh"
  log_debug "Transport: $TRANSPORT ($DEVICE_TYPE @ ${DEVICE_IP:-$DEVICE_ADB_ID})"
}

# =============================================================================
# REMOTE CONNECTION SETUP
# =============================================================================

_connect_agent() {
  local addr="$1"
  need_jq; need_curl

  local ip port
  if [[ "$addr" =~ ^([^:]+):([0-9]+)$ ]]; then
    ip="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
  else
    ip="$addr"; port="$AGENT_DEFAULT_PORT"
  fi

  log_info "Connecting to agent at $ip:$port…"

  source "$SCRIPT_DIR/lib/agent_client.sh" 2>/dev/null || true
  DEVICE_IP="$ip"; DEVICE_PORT="$port"

  local args=(-s -m 5)
  [[ -n "$AGENT_TOKEN" ]] && args+=(-H "${TOKEN_HEADER}: $AGENT_TOKEN")

  # Capture HTTP status code separately so we can give a clear auth error
  local http_code info
  http_code=$(curl "${args[@]}" -o /tmp/la_agent_info.json -w "%{http_code}" \
    "http://${ip}:${port}/info" 2>/dev/null || echo "000")
  info=$(cat /tmp/la_agent_info.json 2>/dev/null); rm -f /tmp/la_agent_info.json

  case "$http_code" in
    000) die "Cannot reach agent at $ip:$port — is agent.py running? Are both phones on the same WiFi?" ;;
    401) die "Authentication failed (HTTP 401) — LAUNCHAPP_TOKEN does not match the agent's token" ;;
    403) die "Access denied (HTTP 403) — your IP is not on the agent's allowlist" ;;
    200) ;;  # ok, fall through
    *)   die "Agent returned unexpected HTTP $http_code from $ip:$port" ;;
  esac

  if [[ -z "$info" ]] || ! echo "$info" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
    die "Agent at $ip:$port returned invalid JSON — version mismatch? Try upgrading launchapp on both phones."
  fi

  # ── Version compatibility check ───────────────────────────────────────────
  local agent_ver controller_ver
  agent_ver=$(echo "$info" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('version','0.0.0'))" 2>/dev/null || echo "0.0.0")
  controller_ver="${VERSION:-1.0.0}"

  # Compare major versions only — minor/patch changes are backwards-compatible
  local agent_major controller_major
  agent_major="${agent_ver%%.*}"
  controller_major="${controller_ver%%.*}"
  if [[ "$agent_major" != "$controller_major" ]]; then
    log_warn "Version mismatch: controller is v${controller_ver}, agent is v${agent_ver}"
    log_warn "Some features may not work correctly. Upgrade launchapp on both phones."
  fi

  DEVICE_TYPE="agent"
  DEVICE_NAME=$(echo "$info" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('model','?') + ' (Android ' + d.get('android','?') + ')')" \
    2>/dev/null || echo "$ip")
  log_info "Connected: $DEVICE_NAME (agent v${agent_ver})"
}

_connect_adb() {
  local device_id="$1"
  need_adb

  source "$SCRIPT_DIR/lib/adb_client.sh" 2>/dev/null || true
  DEVICE_ADB_ID="$device_id"
  DEVICE_TYPE="adb"

  if ! adb devices 2>/dev/null | grep -q "^${device_id}.*device$"; then
    log_info "Connecting ADB: $device_id…"
    adb connect "$device_id" 2>/dev/null
    sleep 1
    adb devices 2>/dev/null | grep -q "^${device_id}.*device$" \
      || die "ADB connect failed for $device_id — is Wireless Debugging enabled on the target?"
  fi

  local model android android_int
  model=$(adb -s "$device_id" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
  android=$(adb -s "$device_id" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
  android_int=$(adb -s "$device_id" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
  DEVICE_IP=$(echo "$device_id" | cut -d: -f1)
  DEVICE_NAME="${model:-$device_id} (Android ${android:-?})"

  # ── Android version gate for pairing flow ────────────────────────────────
  # The `adb pair` command (code-based pairing) was added in Android 11 (API 30).
  # On Android 10 and below, wireless ADB uses a simpler flow — no pairing step,
  # just `adb connect IP:5555` after enabling in Developer Options.
  # Store this on DEVICE_ADB_ANDROID_INT for adb_setup_device() to check.
  export DEVICE_ADB_ANDROID_INT="${android_int:-0}"

  log_info "ADB connected: $DEVICE_NAME"
}

# =============================================================================
# LOCAL COMMANDS
# =============================================================================

mode_attach() {
  local pattern="${1:-}"
  local sessions
  sessions=$(list_la_sessions)
  if [[ -z "$sessions" ]]; then
    die "No active launchapp sessions."
  fi
  if [[ -n "$pattern" ]]; then
    local match
    match=$(echo "$sessions" | grep -i "$pattern" | head -1 || true)
    if [[ -n "$match" ]]; then tmux attach-session -t "$match"; return; fi
  fi
  echo -e "${CYAN}Active sessions:${NC}"
  local i=1; declare -A sm
  while IFS= read -r s; do echo "  $i. $s"; sm[$i]="$s"; ((i++)); done <<< "$sessions"
  echo; read -rp "Select: " choice
  [[ -n "${sm[$choice]:-}" ]] && tmux attach-session -t "${sm[$choice]}" || die "Invalid selection"
}

mode_list() {
  local filter="${1:-}"
  echo -e "${CYAN}Installed user packages:${NC}"; echo
  if [[ -n "$filter" ]]; then
    list_user_packages | grep -i "$filter" || echo "  No packages matching '$filter'"
  else
    list_user_packages | column
  fi
}

mode_info() {
  local app_arg="$1"
  local app_string pkg
  app_string=$(resolve_app "$app_arg") || die "App '$app_arg' not found"
  pkg=$(package_from_string "$app_string")

  echo -e "${CYAN}── App Info: $pkg ──────────────────────────────────${NC}"
  echo

  echo -e "${YELLOW}Identity${NC}"
  transport_pm dump "$pkg" 2>/dev/null | grep -E 'versionName|versionCode|firstInstallTime|lastUpdateTime|userId' \
    | sed 's/^ */  /' | head -10

  echo
  echo -e "${YELLOW}Main activity${NC}"
  echo "  $app_string"

  echo
  echo -e "${YELLOW}Permissions${NC}"
  transport_pm dump "$pkg" 2>/dev/null | grep -E 'granted=true' | grep -oP 'android\.\w+\.\w+' \
    | sort -u | sed 's/^/  /' | head -20

  echo
  echo -e "${YELLOW}Activities${NC}"
  transport_pm dump "$pkg" 2>/dev/null | grep -E 'Activity{' | grep -oP '[^ ]+/\.[^ ]+' \
    | sed 's/^/  /' | head -10

  echo
  echo -e "${YELLOW}Size${NC}"
  transport_pm dump "$pkg" 2>/dev/null | grep -E 'codePath|dataDir|resourcePath' \
    | sed 's/^ */  /' | head -5
}

mode_top() {
  echo -e "${YELLOW}Live process list — Ctrl+C to stop${NC}"; echo
  while true; do
    clear
    echo -e "${BLUE}══ Running Apps  $(date +%H:%M:%S) ══${NC}"
    printf "  %-10s %-14s %s\n" "PID" "MEM(KB)" "PACKAGE"
    echo "  ──────────────────────────────────────────────────"

    # Collect all running PIDs in one subprocess call,
    # then intersect with the installed package list.
    local ps_out pkg_list pid mem entry
    ps_out=$(transport_shell "ps -A" 2>/dev/null || true)
    pkg_list=$(transport_pm list packages -3 2>/dev/null | sed 's/^package://')

    local results=""
    while IFS= read -r pkg; do
      [[ -z "$pkg" ]] && continue
      pid=$(printf '%s\n' "$ps_out" | awk -v p="$pkg" '$0 ~ p {print $1; exit}')
      [[ -z "$pid" ]] && continue
      mem=$(transport_dumpsys meminfo "$pkg" 2>/dev/null | awk '/TOTAL/{print $2; exit}')
      [[ -z "$mem" ]] && continue
      results+=$(printf "  %-10s %-14s %s\n" "$pid" "$mem" "$pkg")$'\n'
    done <<< "$pkg_list"

    printf '%s' "$results" | sort -k2 -rn | head -15
    sleep 3
  done
}

mode_history() {
  local summary="$LAUNCHAPP_LOG_DIR/crash_summary.log"
  if [[ ! -f "$summary" ]]; then
    echo "No crash history yet. Run 'launchapp <app> crash' to start collecting."
    return
  fi
  echo -e "${RED}Crash History${NC}"
  echo "──────────────────────────────────────────────────"
  cat "$summary"
}

run_agent() {
  echo -e "${GREEN}Starting monitoring agent on this phone…${NC}"; echo
  need_python

  if [[ -z "$AGENT_TOKEN" ]]; then
    AGENT_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    local token_file="$LAUNCHAPP_CONFIG_DIR/token"
    mkdir -p "$LAUNCHAPP_CONFIG_DIR"
    echo "$AGENT_TOKEN" > "$token_file"; chmod 600 "$token_file"
    log_warn "No token set — generated and saved to $token_file"
    echo -e "  ${YELLOW}$AGENT_TOKEN${NC}"
    echo -e "  On controller: ${CYAN}export LAUNCHAPP_TOKEN='\$(cat $token_file)'${NC}"; echo
  fi

  local agent_script
  agent_script=$(find "$SCRIPT_DIR" "$LAUNCHAPP_CONFIG_DIR" "$HOME" \
    -maxdepth 2 -name "agent.py" 2>/dev/null | head -1 || true)
  [[ -z "$agent_script" ]] && die "agent.py not found in $SCRIPT_DIR"
  log_info "Starting: python3 $agent_script"
  python3 "$agent_script" --token "$AGENT_TOKEN"
}

# Interactive remote menu (shown when -r --connect is used without a mode)
show_remote_menu() {
  source "$SCRIPT_DIR/lib/devices.sh" 2>/dev/null || true
  source "$SCRIPT_DIR/remote/network_traffic.sh" 2>/dev/null || true
  while true; do
    clear
    echo -e "${CYAN}┌────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${PURPLE}launchapp -r${NC}  Remote: ${YELLOW}$DEVICE_NAME${NC}  [$TRANSPORT]  ${CYAN}│${NC}"
    echo -e "${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
    echo
    echo -e "${GREEN}Modes (identical to local launchapp):${NC}"
    echo "  1. debug    6-window tmux session"
    echo "  2. monitor  split-pane live monitor"
    echo "  3. crash    crash + ANR watcher"
    echo "  4. perf     performance dashboard"
    echo "  5. network  network call monitor"
    echo "  6. launch   launch an app"
    echo "  7. info     app info"
    echo "  8. top      live process list"
    echo "  9. network traffic (tcpdump — root required)"
    echo "  0. Exit"
    echo
    read -rp "Choice: " c
    local app_arg app_string pkg
    _pick_app() {
      read -rp "  App/package: " app_arg
      app_string=$(resolve_app "$app_arg") || { log_error "Not found"; sleep 2; return 1; }
      pkg=$(package_from_string "$app_string")
    }
    case "$c" in
      1) _pick_app && mode_debug   "$app_string" "$pkg" false ;;
      2) _pick_app && mode_monitor "$app_string" "$pkg" false ;;
      3) _pick_app && mode_crash   "$app_string" "$pkg" false ;;
      4) _pick_app && mode_perf    "$app_string" "$pkg" ;;
      5) _pick_app && mode_network "$app_string" "$pkg" false ;;
      6) _pick_app && do_launch    "$app_string" ;;
      7) _pick_app && mode_info    "$app_arg" ;;
      8) mode_top ;;
      9) mode_network_traffic ;;
      0) exit 0 ;;
      *) log_warn "Unknown option"; sleep 1 ;;
    esac
  done
}

show_scan_menu() {
  source "$SCRIPT_DIR/lib/devices.sh" 2>/dev/null || true
  source "$SCRIPT_DIR/lib/agent_client.sh" 2>/dev/null || true
  source "$SCRIPT_DIR/lib/adb_client.sh" 2>/dev/null || true
  source "$SCRIPT_DIR/remote/scan.sh" 2>/dev/null || true
  source "$SCRIPT_DIR/remote/network_traffic.sh" 2>/dev/null || true

  while true; do
    clear
    echo -e "${CYAN}┌────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${PURPLE}launchapp -r${NC} — Remote Device Manager          ${CYAN}│${NC}"
    echo -e "${CYAN}└────────────────────────────────────────────────┘${NC}"
    echo
    echo "  1. Scan network for devices"
    echo "  2. Select saved device"
    echo "  3. List saved devices"
    echo "  4. Remove device"
    echo "  5. Run agent on this phone"
    echo "  0. Exit"
    echo
    read -rp "Choice: " choice
    local init_devices 2>/dev/null; init_devices 2>/dev/null || true
    case "$choice" in
      1) scan_network && activate_remote_transport && show_remote_menu ;;
      2) select_device && activate_remote_transport && show_remote_menu ;;
      3) devices_print_list 2>/dev/null; read -rp "Press Enter…" _ ;;
      4) remove_device 2>/dev/null ;;
      5) run_agent ;;
      0) exit 0 ;;
      *) log_warn "Unknown"; sleep 1 ;;
    esac
  done
}

_setup_local_adb() {
  need_adb
  echo
  echo -e "${CYAN}launchapp local setup — ADB loopback${NC}"
  echo
  echo "This connects ADB to your own device over WiFi loopback so launchapp"
  echo "has full permissions regardless of Android version or OEM skin."
  echo
  echo "Requirements:"
  echo "  1. Settings → About phone → tap Build number 7 times"
  echo "  2. Settings → Developer Options → Wireless Debugging → Enable"
  echo
  read -rp "  Ready? Press Enter to continue…" _
  echo
  log_info "Enabling ADB TCP mode on port 5555…"
  adb tcpip 5555 2>/dev/null || true
  sleep 2
  log_info "Connecting to localhost:5555…"
  adb connect localhost:5555 2>/dev/null || true
  sleep 1
  if adb devices 2>/dev/null | grep -q "^localhost:5555.*device$"; then
    log_info "Success — ADB loopback connected"
    echo
    echo -e "  ${GREEN}launchapp is ready to use.${NC}"
    echo "  Try: launchapp telegram debug"
  else
    log_error "Connection failed."
    echo
    echo "  Make sure Wireless Debugging is enabled in Developer Options."
    echo "  On Android 11+, you may need to pair first:"
    echo "    Settings → Developer Options → Wireless Debugging → Pair with code"
    echo "    Then run: adb pair localhost:PORT  (use the port shown on screen)"
  fi
  echo
}

# =============================================================================
# HELP
# =============================================================================

print_usage() {
  echo -e "${CYAN}┌──────────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│${NC}  ${PURPLE}launchapp${NC} v${VERSION} — Android Debug Toolkit              ${CYAN}│${NC}"
  echo -e "${CYAN}└──────────────────────────────────────────────────────────┘${NC}"
  echo
  cat <<HELP
${GREEN}LOCAL usage:${NC}
  $SCRIPT_NAME <app> [mode] [options]

${GREEN}REMOTE usage:${NC}
  $SCRIPT_NAME -r --connect IP[:PORT] <app> [mode] [options]
  $SCRIPT_NAME -r --adb DEVICE_ID <app> [mode] [options]
  $SCRIPT_NAME -r --connect IP[:PORT]        (interactive menu)
  $SCRIPT_NAME -r --agent                    (start agent on this phone)
  $SCRIPT_NAME -r scan                       (scan network + menu)

${GREEN}Modes:${NC} (default: launch)
  ${YELLOW}launch${NC}    Launch the app
  ${YELLOW}debug${NC}     6-window tmux session
  ${YELLOW}monitor${NC}   Split-pane monitor with controls
  ${YELLOW}crash${NC}     Crash + ANR watcher (--watch to auto-restart)
  ${YELLOW}perf${NC}      Performance dashboard
  ${YELLOW}network${NC}   Network call monitor
  ${YELLOW}install${NC}   Install an APK (local only)
  ${YELLOW}info${NC}      Show app version, permissions, activities
  ${YELLOW}top${NC}       Live running app list with memory

${GREEN}Other commands:${NC}
  $SCRIPT_NAME alias add|remove|list [name] [pkg]
  $SCRIPT_NAME list [filter]
  $SCRIPT_NAME attach [session]
  $SCRIPT_NAME history
  $SCRIPT_NAME cache clear [package]

${GREEN}Options:${NC}
  ${YELLOW}-r, --remote${NC}          Enable remote mode
  ${YELLOW}--connect IP[:PORT]${NC}   Connect via agent HTTP
  ${YELLOW}--adb DEVICE_ID${NC}       Connect via ADB wireless
  ${YELLOW}--token TOKEN${NC}         Agent auth token (or set LAUNCHAPP_TOKEN)
  ${YELLOW}--save${NC}                Save logs to $LAUNCHAPP_LOG_DIR
  ${YELLOW}--watch${NC}               Auto-restart app on crash (crash mode)
  ${YELLOW}-v${NC}                    Verbose output

${GREEN}Examples:${NC}
  $SCRIPT_NAME spotify
  $SCRIPT_NAME chrome debug
  $SCRIPT_NAME com.example.myapp crash --watch --save
  $SCRIPT_NAME youtube perf
  $SCRIPT_NAME myapp info
  $SCRIPT_NAME top

  $SCRIPT_NAME -r --connect 192.168.1.42 chrome debug
  $SCRIPT_NAME -r --adb 192.168.1.42:5555 spotify monitor
  $SCRIPT_NAME -r --connect 192.168.1.42 com.example.myapp crash --watch
  $SCRIPT_NAME -r --agent
  $SCRIPT_NAME -r scan

${GREEN}Token setup:${NC}
  export LAUNCHAPP_TOKEN='\$(cat ~/.launchapp/token)'
HELP
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  local app_arg="" mode="launch" save_logs=false watch=false
  local remote=false connect_addr="" adb_device=""

  [[ $# -eq 0 ]] && { activate_local_transport; print_usage; exit 0; }

  # ── Pre-pass: detect -r / --remote and grab connection flags ─────────────
  # Handles both --connect IP and --connect=IP forms.
  # We need transport sourced before main parse runs.
  local args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    local arg="${args[$i]}"
    case "$arg" in
      -r|--remote)
        remote=true ;;
      --connect=*)
        remote=true; connect_addr="${arg#--connect=}" ;;
      --connect)
        remote=true; ((i++)) || true; connect_addr="${args[$i]:-}" ;;
      --adb=*)
        remote=true; adb_device="${arg#--adb=}" ;;
      --adb)
        remote=true; ((i++)) || true; adb_device="${args[$i]:-}" ;;
      --token=*)
        AGENT_TOKEN="${arg#--token=}" ;;
      --token)
        ((i++)) || true; AGENT_TOKEN="${args[$i]:-}" ;;
    esac
    ((i++)) || true
  done

  # ── Source transport based on mode ────────────────────────────────────────
  if [[ "$remote" == "true" ]]; then
    if [[ -n "$connect_addr" ]]; then
      _connect_agent "$connect_addr"
    elif [[ -n "$adb_device" ]]; then
      _connect_adb "$adb_device"
    fi
    # If we have a device type, activate transport now
    [[ -n "$DEVICE_TYPE" ]] && activate_remote_transport
  else
    activate_local_transport
  fi

  # ── Main arg parse ────────────────────────────────────────────────────────
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)     print_usage; exit 0 ;;
      --version)  echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
      -r|--remote)   shift ;;   # already handled
      --connect)     shift 2 ;; # already handled
      --adb)         shift 2 ;; # already handled
      --token)       shift 2 ;; # already handled
      --save)        save_logs=true; shift ;;
      --watch)       watch=true; shift ;;
      -v)       export LAUNCHAPP_DEBUG=1; shift ;;
      alias)         shift; alias_cmd "$@"; exit $? ;;
      list)          shift; mode_list "${1:-}"; exit 0 ;;
      attach)        shift; mode_attach "${1:-}"; exit $? ;;
      history)       mode_history; exit 0 ;;
      setup)         _setup_local_adb; exit 0 ;;
      scan)
        [[ "$remote" != "true" ]] && die "'scan' requires -r flag. Use: $SCRIPT_NAME -r scan"
        show_scan_menu; exit 0
        ;;
      cache)
        shift
        case "${1:-}" in
          clear) shift; invalidate_cache "${1:-}"; exit 0 ;;
          *)     die "Usage: $SCRIPT_NAME cache clear [package]" ;;
        esac
        ;;
      --agent)
        [[ "$remote" != "true" ]] && die "--agent requires -r flag. Use: $SCRIPT_NAME -r --agent"
        run_agent; exit 0
        ;;
      launch|debug|monitor|crash|perf|network|install|info|top)
        [[ -z "$app_arg" && "$1" != "top" ]] && \
          die "Specify app before mode. e.g.: $SCRIPT_NAME chrome debug"
        mode="$1"; shift
        ;;
      -*) die "Unknown option: $1. Try --help" ;;
      *)
        [[ -z "$app_arg" ]] && { app_arg="$1"; shift; } || die "Unexpected argument: $1"
        ;;
    esac
  done

  # ── Remote: no app/mode given — show menu ────────────────────────────────
  if [[ "$remote" == "true" && -z "$app_arg" && "$mode" == "launch" ]]; then
    if [[ -n "$DEVICE_TYPE" ]]; then
      show_remote_menu
    else
      show_scan_menu
    fi
    exit 0
  fi

  # ── top and history don't need an app ────────────────────────────────────
  if [[ "$mode" == "top" ]]; then mode_top; exit 0; fi

  [[ -z "$app_arg" ]] && { print_usage; exit 1; }

  # ── Install (local only, no app resolution needed) ───────────────────────
  if [[ "$mode" == "install" ]]; then
    [[ "$remote" == "true" ]] && die "install mode is local only"
    do_install "$app_arg"; exit 0
  fi

  # ── Resolve app alias/pkg → app_string ───────────────────────────────────
  local app_string
  app_string=$(resolve_app "$app_arg") \
    || die "App '$app_arg' not found. Run '$SCRIPT_NAME list' to search."
  local pkg
  pkg=$(package_from_string "$app_string")
  log_debug "Resolved: $app_arg → $app_string (pkg: $pkg, transport: ${TRANSPORT:-local})"

  # ── Dispatch ──────────────────────────────────────────────────────────────
  case "$mode" in
    launch)  do_launch    "$app_string" ;;
    debug)   mode_debug   "$app_string" "$pkg" "$save_logs" ;;
    monitor) mode_monitor "$app_string" "$pkg" "$save_logs" ;;
    crash)   mode_crash   "$app_string" "$pkg" "$save_logs" "$watch" ;;
    perf)    mode_perf    "$app_string" "$pkg" ;;
    network) mode_network "$app_string" "$pkg" "$save_logs" ;;
    info)    mode_info    "$app_arg" ;;
    *)       die "Unknown mode: $mode" ;;
  esac
}

main "$@"
