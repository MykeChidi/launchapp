#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/transport_local.sh — Local transport (runs directly on this device)
# Sourced by launchapp.sh before any mode is invoked.
# All transport_* functions delegate straight to bare Android commands.
# =============================================================================

TRANSPORT="local"

transport_am()      { am "$@"; }
transport_pm()      { pm "$@"; }
transport_logcat()  { logcat "$@"; }
transport_dumpsys() { dumpsys "$@"; }
transport_pidof()   { pidof "$@" 2>/dev/null || ps -A 2>/dev/null | awk "/$1/{print \$1}" | head -1; }
transport_shell()   { bash -c "$*"; }

# For temp scripts running inside tmux panes — emit the raw command string
# so pane_run can send it to the shell. Local: just the command itself.
transport_cmd() {
  # Usage: transport_cmd am start -n foo/bar
  # Prints a shell command string that pane_run can send
  printf '%s' "$*"
}
