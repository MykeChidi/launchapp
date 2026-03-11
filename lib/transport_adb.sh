#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/transport_adb.sh — ADB wireless transport
# Sourced by remote_monitor.sh after a device is selected.
# Expects DEVICE_ADB_ID to be set.
# All transport_* functions route through: adb -s $DEVICE_ADB_ID shell ...
# =============================================================================

TRANSPORT="adb"

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
