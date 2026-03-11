#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# remote_monitor — Compatibility wrapper for launchapp -r
#
# This script exists so that any existing usage of remote_monitor still works.
#
# launchapp -r --connect 192.168.1.42 chrome debug
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
exec "$SCRIPT_DIR/launchapp.sh" -r "$@"
