#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/adb_client.sh — ADB over WiFi helpers
# Depends on: lib/log.sh, lib/deps.sh
#
# Expects DEVICE_ADB_ID to be set by the caller.
# =============================================================================

# Run an adb command targeting DEVICE_ADB_ID
adb_run() { adb -s "$DEVICE_ADB_ID" "$@"; }

# Run a shell command on the device
adb_shell() { adb -s "$DEVICE_ADB_ID" shell "$@"; }

# Check if a device ID is in 'device' state
adb_ping() {
  adb devices 2>/dev/null | grep -q "^${1}.*device$"
}

# Attempt to reconnect a stored ADB device
adb_reconnect() {
  log_info "Reconnecting ADB: ${DEVICE_ADB_ID}…"
  adb connect "$DEVICE_ADB_ID" 2>/dev/null
  sleep 1
  adb_ping "$DEVICE_ADB_ID"
}

# Resolve the main launcher activity for a package over ADB
# Prints "pkg/activity" or returns 1
adb_find_activity() {
  local pkg="$1"
  local activity
  local esc_pkg="${pkg//./\\.}"
  activity=$(adb_shell pm dump "$pkg" 2>/dev/null \
    | awk '/android\.intent\.action\.MAIN/{f=1} f && /'"${esc_pkg}"'\// {
        for(i=1;i<=NF;i++) if($i ~ /'"${esc_pkg}"'\//) {print $i; exit}
    }')
  [[ -n "$activity" ]] && echo "$activity" || return 1
}

# Launch a package over ADB
# Usage: adb_launch PKG
adb_launch() {
  local pkg="$1"
  local act
  act=$(adb_find_activity "$pkg") || { log_error "Main activity not found for $pkg"; return 1; }
  adb_shell am start -n "$act" -W 2>/dev/null && log_info "Launched: $pkg" || return 1
}

# Take a screenshot via ADB; saves to local path
# Usage: adb_screenshot [OUTPUT_PATH]
adb_screenshot() {
  local ts; ts=$(date +%s)
  local remote="/sdcard/la_shot_${ts}.png"
  local out="${1:-$HOME/launchapp_screenshots/shot_${ts}.png}"
  mkdir -p "$(dirname "$out")"
  adb_shell screencap -p "$remote"
  adb_run pull "$remote" "$out" 2>/dev/null
  adb_shell rm "$remote" 2>/dev/null || true
  [[ -f "$out" ]] && { log_info "Screenshot: $out"; echo "$out"; } || { log_error "Screenshot failed"; return 1; }
}

# Pair and connect a new ADB wireless device interactively
# Usage: adb_setup_device NAME IP → sets DEVICE_ADB_ID on success
#
# Android 11+ (API 30+): uses `adb pair` with a pairing code shown on the device
# Android 10 and below:  no pairing step — just `adb connect IP:5555` after
#                        enabling Wireless Debugging in Developer Options
adb_setup_device() {
  local name="$1" ip="$2"
  need_adb

  # DEVICE_ADB_ANDROID_INT is set by _connect_adb or by the scan flow
  local android_int="${DEVICE_ADB_ANDROID_INT:-0}"

  echo -e "${YELLOW}ADB Wireless Setup — ${name} (${ip})${NC}"
  echo

  if (( android_int >= 30 )); then
    # ── Android 11+ pairing flow ──────────────────────────────────────────
    echo "  On the target phone:"
    echo "  Settings → About → tap Build Number 7×"
    echo "  Developer Options → Wireless Debugging → Pair device with code"
    echo
    read -rp "  Pairing code (6 digits shown on phone): " pair_code
    read -rp "  Pairing IP:PORT (shown on phone, e.g. 192.168.1.42:37000): " pair_addr

    if ! adb pair "$pair_addr" "$pair_code"; then
      log_error "Pairing failed — check the code and IP:PORT and try again"
      return 1
    fi
    log_info "Paired successfully."
    echo
    read -rp "  Connection port (shown under 'Wireless Debugging', e.g. 5555): " conn_port
    local conn_addr="${ip}:${conn_port}"

  else
    # ── Android 10 and below flow — no pairing step ───────────────────────
    echo "  Android 10 or below detected — no pairing code needed."
    echo "  On the target phone:"
    echo "  Settings → About → tap Build Number 7×"
    echo "  Developer Options → Wireless Debugging → Enable"
    echo
    echo "  Connecting directly to $ip:5555…"
    local conn_addr="${ip}:5555"
  fi

  if ! adb connect "$conn_addr"; then
    log_error "adb connect failed for $conn_addr"
    return 1
  fi

  sleep 1
  if ! adb_ping "$conn_addr"; then
    log_error "Device '$conn_addr' not in 'device' state — enable Wireless Debugging and authorize on the device"
    return 1
  fi

  DEVICE_ADB_ID="$conn_addr"
  log_info "ADB connected: $conn_addr"
  return 0
}
