#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/agent_client.sh — HTTP client wrapper for launchapp agent API
# Depends on: lib/constants.sh, lib/log.sh
#
# Expects these globals to be set by the caller before any agent_* call:
#   DEVICE_IP, DEVICE_PORT, AGENT_TOKEN
# =============================================================================

# Core curl wrapper — all agent calls route through here
# Usage: _agent_curl ENDPOINT [extra curl flags...]
_agent_curl() {
  local endpoint="$1"; shift
  local url="http://${DEVICE_IP}:${DEVICE_PORT}${endpoint}"
  local args=(-s -m 10)
  [[ -n "${AGENT_TOKEN:-}" ]] && args+=(-H "${TOKEN_HEADER}: ${AGENT_TOKEN}")
  curl "${args[@]}" "$@" "$url" 2>/dev/null
}

# GET request; returns raw response body
agent_get() { _agent_curl "$1"; }

# POST request with JSON body
agent_post() {
  local endpoint="$1" body="${2:-{}}"
  _agent_curl "$endpoint" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$body"
}

# Ping the agent; returns 0 if reachable and authenticated
# Usage: agent_ping [IP] [PORT] [TOKEN]
agent_ping() {
  local ip="${1:-$DEVICE_IP}"
  local port="${2:-$DEVICE_PORT}"
  local token="${3:-${AGENT_TOKEN:-}}"
  local args=(-s -m 3)
  [[ -n "$token" ]] && args+=(-H "${TOKEN_HEADER}: $token")
  curl "${args[@]}" "http://${ip}:${port}/ping" 2>/dev/null | grep -q "pong"
}

# Upload a local file to the agent
# Usage: agent_upload LOCAL_PATH DEST_PATH_ON_DEVICE
agent_upload() {
  local local_path="$1" dest_path="$2"
  [[ -f "$local_path" ]] || { log_error "File not found: $local_path"; return 1; }
  local url="http://${DEVICE_IP}:${DEVICE_PORT}/upload"
  local args=(-s -m 120 -X POST
    --data-binary "@${local_path}"
    -H "Content-Type: application/octet-stream"
    -H "X-Dest-Path: ${dest_path}")
  [[ -n "${AGENT_TOKEN:-}" ]] && args+=(-H "${TOKEN_HEADER}: ${AGENT_TOKEN}")
  curl "${args[@]}" "$url" 2>/dev/null
}

# Download a file from the agent to a local path
# Usage: agent_download REMOTE_PATH LOCAL_PATH
agent_download() {
  local remote_path="$1" local_path="$2"
  local enc_path
  enc_path=$(python3 -c \
    "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
    "$remote_path" 2>/dev/null || printf '%s' "$remote_path")
  mkdir -p "$(dirname "$local_path")"
  local args=(-s -m 120 -o "$local_path")
  [[ -n "${AGENT_TOKEN:-}" ]] && args+=(-H "${TOKEN_HEADER}: ${AGENT_TOKEN}")
  curl "${args[@]}" \
    "http://${DEVICE_IP}:${DEVICE_PORT}/download?path=${enc_path}" 2>/dev/null
  [[ -f "$local_path" ]]
}

# ── Convenience wrappers ──────────────────────────────────────────────────────
agent_info()        { agent_get "/info"; }
agent_battery()     { agent_get "/battery"; }
agent_stats()       { agent_get "/stats"; }
agent_packages()    { agent_get "/packages"; }
agent_processes()   { agent_get "/processes"; }
agent_logs()        { agent_get "/logs/${1}${2:+?lines=$2}"; }
agent_meminfo()     { agent_get "/meminfo/${1}"; }
agent_pid()         { agent_get "/pid/${1}"; }
agent_launch_pkg()  { agent_get "/launch/${1}"; }
agent_kill_pkg()    { agent_get "/kill/${1}"; }
agent_screenshot()  { agent_get "/screenshot"; }
agent_files()       { agent_get "/files?path=${1:-/sdcard}"; }
