#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/transport_adb.sh — ADB wireless transport
# Sourced by remote_monitor.sh after a device is selected.
# Expects DEVICE_ADB_ID to be set.
# All transport_* functions route through: adb -s $DEVICE_ADB_ID shell ...
# =============================================================================

TRANSPORT="adb"

# Validate that DEVICE_ADB_ID is set
if [[ -z "${DEVICE_ADB_ID:-}" ]]; then
  echo >&2 "ERROR: DEVICE_ADB_ID not set. Cannot activate ADB transport."
  exit 1
fi

# Verify device is in 'device' state
if ! adb devices 2>/dev/null | grep -q "^${DEVICE_ADB_ID}.*device$"; then
  echo >&2 "ERROR: Device '$DEVICE_ADB_ID' not found or not in 'device' state."
  echo >&2 "        Run 'launchapp -r --adb $DEVICE_ADB_ID' to reconnect."
  exit 1
fi

transport_am()      { adb -s "$DEVICE_ADB_ID" shell am "$@"; }
transport_pm()      { adb -s "$DEVICE_ADB_ID" shell pm "$@"; }
transport_logcat()  { adb -s "$DEVICE_ADB_ID" logcat "$@"; }
transport_dumpsys() { adb -s "$DEVICE_ADB_ID" shell dumpsys "$@"; }
transport_pidof()   {
  adb -s "$DEVICE_ADB_ID" shell pidof "$1" 2>/dev/null \
    || adb -s "$DEVICE_ADB_ID" shell ps -A 2>/dev/null \
         | awk "/$1/{print \$1}" | head -1
}
transport_shell()   { adb -s "$DEVICE_ADB_ID" shell "$@"; }

# Emit a shell command string prefixed with adb shell — used inside tmux pane scripts
transport_cmd() {
  printf 'adb -s %s shell %s' "$DEVICE_ADB_ID" "$*"
}
