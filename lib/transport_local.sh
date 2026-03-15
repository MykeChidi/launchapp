#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/transport_local.sh — Local transport via ADB loopback
#
# Routes all commands through `adb shell` against localhost:5555.
# This gives full pm/dumpsys/am permissions on any Android version/OEM
# without requiring root, avoiding the shell permission restrictions that
# affect direct Termux commands on Android 12+.
#
# Setup (done once by activate_local_transport):
#   adb connect localhost:5555
# =============================================================================

TRANSPORT="local"
DEVICE_ADB_ID="localhost:5555"

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
