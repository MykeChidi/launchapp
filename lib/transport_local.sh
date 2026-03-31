#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/transport_local.sh — Local transport via wireless debugging
#
# Routes all commands through `adb shell` using the device's real network IP
# that was paired via wireless debugging. This gives full pm/dumpsys/am 
# permissions on any Android version/OEM without requiring root.
#
# Setup (done once by _setup_local_adb):
#   adb pair IP:PORT <pairing_code>
#   adb connect IP:PORT
#
# The device IP:port is detected dynamically and stored in LOCAL_DEVICE_ADB_ID
# =============================================================================

TRANSPORT="local"
# Dynamically detect the device IP:port from adb devices
# Falls back to environment variable if set, otherwise errors
DEVICE_ADB_ID="${LOCAL_DEVICE_ADB_ID:-}"

if [[ -z "$DEVICE_ADB_ID" ]]; then
  DEVICE_ADB_ID=$(adb devices 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+.*device$" | awk '{print $1}' | head -1)
  if [[ -z "$DEVICE_ADB_ID" ]]; then
    echo >&2 "ERROR: No wireless ADB device found. Run 'launchapp setup' first."
    exit 1
  fi
fi

transport_am()      { adb -s "$DEVICE_ADB_ID" shell am "$@" 2>/dev/null; }
transport_pm()      { adb -s "$DEVICE_ADB_ID" shell pm "$@" 2>/dev/null; }
transport_logcat()  { adb -s "$DEVICE_ADB_ID" logcat "$@"; }
transport_dumpsys() { adb -s "$DEVICE_ADB_ID" shell dumpsys "$@" 2>/dev/null; }
transport_pidof()   {
  adb -s "$DEVICE_ADB_ID" shell pidof "$1" 2>/dev/null \
    || adb -s "$DEVICE_ADB_ID" shell ps -A 2>/dev/null \
         | awk "/$1/{print \$1}" | head -1
}
transport_shell()   { adb -s "$DEVICE_ADB_ID" shell "$@"; }

# For temp scripts running inside tmux panes — emit the raw command string
# so pane_run can send it to the shell. Local: just the command itself.
transport_cmd() {
  # Usage: transport_cmd am start -n foo/bar
  # Prints a shell command string that pane_run can send
  printf 'adb -s %s shell %s' "$DEVICE_ADB_ID" "$*"
}
