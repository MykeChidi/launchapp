#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/transport_agent.sh — HTTP agent transport
# Sourced by remote_monitor.sh after a device is selected.
# Expects DEVICE_IP, DEVICE_PORT, AGENT_TOKEN to be set.
#
# Translates transport_* calls into agent API calls.
# Logcat is polled from /logs/<pkg> (2s interval) since HTTP is not a stream.
# All other calls map 1:1 to agent endpoints.
# =============================================================================

TRANSPORT="agent"

# ── Connection state ──────────────────────────────────────────────────────────
_AGENT_CONSECUTIVE_FAILURES=0
_AGENT_MAX_FAILURES=3   # warn after this many consecutive timeouts

# ── Internal curl helper ──────────────────────────────────────────────────────
# Tracks consecutive failures and warns the user when the agent appears dead.
# Does not auto-reconnect (no way to restart the agent remotely) but gives a
# clear message instead of silently returning empty strings.
_agent_curl() {
  local endpoint="$1"; shift
  local url="http://${DEVICE_IP}:${DEVICE_PORT}${endpoint}"
  local args=(-s -m 10)
  [[ -n "${AGENT_TOKEN:-}" ]] && args+=(-H "${TOKEN_HEADER}: ${AGENT_TOKEN}")
  local result exit_code
  if [[ "${LAUNCHAPP_DEBUG:-0}" == "1" ]]; then
    result=$(curl "${args[@]}" "$@" "$url")
    exit_code=$?
  else
    result=$(curl "${args[@]}" "$@" "$url" 2>/dev/null)
    exit_code=$?
  fi

  if [[ $exit_code -ne 0 || -z "$result" ]]; then
    (( _AGENT_CONSECUTIVE_FAILURES++ )) || true
    if (( _AGENT_CONSECUTIVE_FAILURES >= _AGENT_MAX_FAILURES )); then
      log_warn "Agent at ${DEVICE_IP}:${DEVICE_PORT} is not responding (${_AGENT_CONSECUTIVE_FAILURES} consecutive failures)"
      log_warn "The target phone may have killed the agent (screen off / battery optimisation)"
      log_warn "On the target phone, run: launchapp -r --agent"
      _AGENT_CONSECUTIVE_FAILURES=0  # reset so we don't spam every call
    fi
    echo ""
    return 1
  fi

  _AGENT_CONSECUTIVE_FAILURES=0
  echo "$result"
  return 0
}

# ── Transport interface ───────────────────────────────────────────────────────

# am start -n PKG/ACTIVITY → POST /launch/PKG
# am force-stop PKG        → POST /kill/PKG
transport_am() {
  local subcmd="$1"; shift
  case "$subcmd" in
    start)
      local pkg=""
      while [[ $# -gt 0 ]]; do
        [[ "$1" == "-n" ]] && { shift; pkg="${1%%/*}"; }
        shift
      done
      [[ -n "$pkg" ]] && _agent_curl "/launch/${pkg}" -X POST \
        | jq -r '.launched // .error' 2>/dev/null
      ;;
    force-stop)
      _agent_curl "/kill/${1}" -X POST | jq -r '.killed // .error' 2>/dev/null
      ;;
    *)
      log_warn "transport_agent: unsupported am subcommand: $subcmd"
      ;;
  esac
}

# pm list packages → GET /packages
# pm dump PKG      → GET /meminfo/PKG (best approximation via agent)
# pm clear PKG     → not supported, warn
transport_pm() {
  local subcmd="$1"; shift
  case "$subcmd" in
    "list")
      # pm list packages [-3] → strip flags, return package list
      _agent_curl "/packages" | jq -r '.[].package' 2>/dev/null | sed 's/^/package:/'
      ;;
    dump)
      # Used by find_main_activity — query the agent's /launch/<pkg> info endpoint
      # to get the main activity for the specific package, then emit a fake pm dump
      # block that find_main_activity's awk strategies can parse.
      local pkg="$1"
      local act
      # /launch/<pkg> returns {"launched":pkg,"activity":"pkg/.Activity"} on GET
      # We derive the activity from the agent's find_main_activity logic server-side.
      act=$(_agent_curl "/activity/${pkg}" 2>/dev/null \
        | jq -r '.activity // empty' 2>/dev/null)
      if [[ -n "$act" ]]; then
        printf 'android.intent.action.MAIN:\n  %s\n' "$act"
      fi
      ;;
    clear)
      log_warn "pm clear not supported in agent transport"
      ;;
    *)
      log_warn "transport_agent: unsupported pm subcommand: $subcmd"
      ;;
  esac
}

# logcat — poll /logs/<pkg> every 2 seconds, stream lines to stdout
# Supports: logcat -c (clear, no-op for agent), logcat *:E (filtered)
# The pkg is extracted from the environment var TRANSPORT_LOGCAT_PKG
# set by android.sh wrappers before calling transport_logcat.
transport_logcat() {
  # Handle -c (clear buffer) — agent has no clear, just return
  [[ "${1:-}" == "-c" ]] && return 0

  local pkg="${TRANSPORT_LOGCAT_PKG:-}"
  local level_filter=""
  local seen_lines=0

  # Parse basic flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c)        return 0 ;;         # clear — no-op
      -d)        local one_shot=1 ;;  # dump and exit
      -s)        shift ;;             # tag filter — ignored, we filter by pkg
      -v)        shift ;;             # format — ignored
      *:E|*:F)   level_filter="E" ;; # error filter — pass lines=200 for more history
      *)         [[ "$1" =~ ^[a-z] ]] && pkg="$1" ;;
    esac
    shift
  done

  local lines_param="lines=80"
  [[ "$level_filter" == "E" ]] && lines_param="lines=200&level=E"

  if [[ "${one_shot:-0}" == "1" ]]; then
    _agent_curl "/logs/${pkg}?${lines_param}" | jq -r '.[]?' 2>/dev/null
    return
  fi

  # Streaming: poll endpoint, emit only new lines
  local last_line=""
  while true; do
    local batch
    batch=$(_agent_curl "/logs/${pkg}?${lines_param}" | jq -r '.[]?' 2>/dev/null)
    if [[ -n "$batch" ]]; then
      if [[ -z "$last_line" ]]; then
        echo "$batch"
      else
        # Print only lines that appear after the last seen line
        echo "$batch" | awk -v last="$last_line" 'found{print} $0==last{found=1}'
      fi
      last_line=$(echo "$batch" | tail -1)
    fi
    sleep 2
  done
}

# dumpsys meminfo PKG → GET /meminfo/PKG
# dumpsys battery     → GET /battery
# dumpsys activity    → not supported
transport_dumpsys() {
  local subcmd="$1"; shift
  case "$subcmd" in
    meminfo)
      local pkg="${1:-}"
      local resp
      resp=$(_agent_curl "/meminfo/${pkg}" 2>/dev/null)
      # Emit in dumpsys meminfo format so existing grep/awk parsers work
      echo "$resp" | jq -r '
        "App Summary",
        "                       Pss(KB)",
        "                        ------",
        "           Java Heap: " + (.java_heap_kb|tostring),
        "         Native Heap: " + (.native_heap_kb|tostring),
        "                Code: " + (.code_kb|tostring),
        "               Stack: " + (.stack_kb|tostring),
        "            Graphics: " + (.graphics_kb|tostring),
        "       Private Other: " + (.other_kb|tostring),
        "              System: " + (.system_kb|tostring),
        "",
        "            TOTAL: " + (.total_kb|tostring)
      ' 2>/dev/null
      ;;
    battery)
      local resp
      resp=$(_agent_curl "/battery" 2>/dev/null)
      # Emit in dumpsys battery format
      echo "$resp" | jq -r '
        "Current Battery Service state:",
        "  level: " + (.percentage|tostring),
        "  status: " + (.status//"unknown"),
        "  temperature: " + ((.temperature//0)|tostring),
        "  plugged: " + ((.plugged//false|tostring))
      ' 2>/dev/null
      ;;
    activity)
      log_warn "dumpsys activity not supported in agent transport"
      ;;
    *)
      log_warn "transport_agent: unsupported dumpsys: $subcmd"
      ;;
  esac
}

# pidof PKG → GET /pid/PKG → extract pid field
transport_pidof() {
  local pkg="$1"
  _agent_curl "/pid/${pkg}" | jq -r 'if .running then .pid else "" end' 2>/dev/null
}

transport_shell() {
  log_warn "transport_agent: generic shell not supported — use specific transport_* calls"
}

# transport_cmd is used inside pane temp-scripts to build command strings.
# For agent transport these scripts run on the controller, so they use curl.
transport_cmd() {
  local subcmd="$1"; shift
  local base="http://${DEVICE_IP}:${DEVICE_PORT}"
  local auth=""
  [[ -n "${AGENT_TOKEN:-}" ]] && auth="-H '${TOKEN_HEADER}: ${AGENT_TOKEN}'"

  case "$subcmd" in
    am)
      local am_sub="$1"; shift
      case "$am_sub" in
        start)
          local pkg=""
          while [[ $# -gt 0 ]]; do
            [[ "$1" == "-n" ]] && { shift; pkg="${1%%/*}"; }
            shift
          done
          printf "curl -s -m 10 -X POST %s '%s/launch/%s' | jq -r '.launched // .error' 2>/dev/null" \
            "$auth" "$base" "$pkg"
          ;;
        force-stop)
          printf "curl -s -m 10 -X POST %s '%s/kill/%s' | jq -r '.killed // .error' 2>/dev/null" \
            "$auth" "$base" "$1"
          ;;
      esac
      ;;
    dumpsys)
      local ds_sub="$1"; shift
      case "$ds_sub" in
        meminfo)
          printf "curl -s -m 10 %s '%s/meminfo/%s' | jq ." "$auth" "$base" "$1"
          ;;
        battery)
          printf "curl -s -m 10 %s '%s/battery' | jq ." "$auth" "$base"
          ;;
      esac
      ;;
    logcat)
      # Prefer the explicit argument; fall back to env var only if arg is empty.
      local pkg="${1:-${TRANSPORT_LOGCAT_PKG:-}}"
      printf "while true; do curl -s -m 10 %s '%s/logs/%s?lines=80' | jq -r '.[]?' 2>/dev/null; sleep 2; done" \
        "$auth" "$base" "$pkg"
      ;;
    pm)
      case "$1" in
        clear)
          printf "echo 'pm clear not supported in agent transport'"
          ;;
        dump)
          printf "curl -s -m 10 %s '%s/meminfo/%s' | jq ." "$auth" "$base" "$2"
          ;;
      esac
      ;;
    stats)
      printf "curl -s -m 10 %s '%s/stats' | jq ." "$auth" "$base"
      ;;
    files)
      # files list [PATH] — used by files_ls_cmd in android.sh
      local sub="${1:-list}"; shift 2>/dev/null || true
      local path="${1:-/sdcard}"
      local enc_path
      enc_path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
        "$path" 2>/dev/null || printf '%s' "$path")
      printf "curl -s -m 10 %s '%s/files?path=%s' | jq ." "$auth" "$base" "$enc_path"
      ;;
  esac
}

# ── System stats ──────────────────────────────────────────────────────────────
# GET /stats → {mem_total_kb, mem_used_kb, mem_avail_kb, mem_percent,
#               cpu_idle_pct, cpu_used_pct}
transport_stats() {
  _agent_curl "/stats"
}

# ── File operations ───────────────────────────────────────────────────────────

# List directory contents on the remote device.
# Usage: transport_files [PATH]   (default: /sdcard)
# Returns JSON array: [{name, type, size, modified, path}]
transport_files() {
  local path="${1:-/sdcard}"
  local enc_path
  enc_path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
    "$path" 2>/dev/null || printf '%s' "$path")
  _agent_curl "/files?path=${enc_path}"
}

# Download a file from the remote device to a local path.
# Usage: transport_download REMOTE_PATH [LOCAL_PATH]
transport_download() {
  local remote="$1"
  local local_dest="${2:-$HOME/launchapp_downloads/$(basename "$1")}"
  mkdir -p "$(dirname "$local_dest")"

  local enc_path
  enc_path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
    "$remote" 2>/dev/null || printf '%s' "$remote")

  local url="http://${DEVICE_IP}:${DEVICE_PORT}/download?path=${enc_path}"
  local args=(-s -m 120 -o "$local_dest")
  [[ -n "${AGENT_TOKEN:-}" ]] && args+=(-H "${TOKEN_HEADER}: ${AGENT_TOKEN}")

  if curl "${args[@]}" "$url" 2>/dev/null; then
    log_info "Downloaded: $local_dest ($(du -sh "$local_dest" 2>/dev/null | cut -f1))"
  else
    log_error "Download failed: $remote"
    return 1
  fi
}

# Upload a local file to the remote device.
# Usage: transport_upload LOCAL_PATH [REMOTE_DEST_PATH]
transport_upload() {
  local local_src="$1"
  local remote_dest="${2:-/sdcard/$(basename "$1")}"

  [[ -f "$local_src" ]] || { log_error "File not found: $local_src"; return 1; }

  local url="http://${DEVICE_IP}:${DEVICE_PORT}/upload"
  local args=(-s -m 120 -X POST --data-binary "@${local_src}"
    -H "Content-Type: application/octet-stream"
    -H "X-Dest-Path: ${remote_dest}")
  [[ -n "${AGENT_TOKEN:-}" ]] && args+=(-H "${TOKEN_HEADER}: ${AGENT_TOKEN}")

  local result
  result=$(curl "${args[@]}" "$url" 2>/dev/null)
  if echo "$result" | jq -e '.uploaded' &>/dev/null; then
    local uploaded_path size
    uploaded_path=$(echo "$result" | jq -r '.uploaded')
    size=$(echo "$result" | jq -r '.size')
    log_info "Uploaded: ${uploaded_path} (${size} bytes)"
  else
    local err
    err=$(echo "$result" | jq -r '.error // "unknown error"' 2>/dev/null || echo "no response")
    log_error "Upload failed: $err"
    return 1
  fi
}

# Download a screenshot directly as a PNG file.
# Usage: transport_screenshot [LOCAL_PATH]
transport_screenshot() {
  local local_dest="${1:-$HOME/launchapp_screenshots/shot_$(date +%s).png}"
  mkdir -p "$(dirname "$local_dest")"

  local url="http://${DEVICE_IP}:${DEVICE_PORT}/screenshot/download"
  local args=(-s -m 30 -o "$local_dest")
  [[ -n "${AGENT_TOKEN:-}" ]] && args+=(-H "${TOKEN_HEADER}: ${AGENT_TOKEN}")

  if curl "${args[@]}" "$url" 2>/dev/null && [[ -f "$local_dest" ]]; then
    log_info "Screenshot saved: $local_dest"
    echo "$local_dest"
  else
    log_error "Screenshot failed"
    return 1
  fi
}