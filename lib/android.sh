#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/android.sh — Android package resolution and device helpers
# Depends on: lib/constants.sh, lib/log.sh, lib/transport_*.sh (one must be
#             sourced before any function here is called)
#
# All Android command calls go through transport_* functions so this file
# works identically whether the transport is local, ADB, or agent.
# =============================================================================

# ── Built-in package aliases ──────────────────────────────────────────────────
declare -gA BUILTIN_PACKAGES=(
  [chrome]="com.android.chrome"
  [youtube]="com.google.android.youtube"
  [yt]="com.google.android.youtube"
  [spotify]="com.spotify.music"
  [gmail]="com.google.android.gm"
  [maps]="com.google.android.apps.maps"
  [whatsapp]="com.whatsapp"
  [telegram]="org.telegram.messenger"
  [instagram]="com.instagram.android"
  [twitter]="com.twitter.android"
  [netflix]="com.netflix.mediaclient"
  [settings]="com.android.settings"
  [calculator]="com.android.calculator2"
  [camera]="com.android.camera2"
  [files]="com.android.documentsui"
  [clock]="com.android.deskclock"
  [contacts]="com.android.contacts"
  [dialer]="com.android.dialer"
  [messages]="com.google.android.apps.messaging"
  [photos]="com.google.android.apps.photos"
  [drive]="com.google.android.apps.docs"
  [meet]="com.google.android.apps.tachyon"
  [tiktok]="com.zhiliaoapp.musically"
  [discord]="com.discord"
  [reddit]="com.reddit.frontpage"
  [snapchat]="com.snapchat.android"
  [linkedin]="com.linkedin.android"
  [zoom]="us.zoom.videomeetings"
  [vlc]="org.videolan.vlc"
  [firefox]="org.mozilla.firefox"
)

# ── String helpers ────────────────────────────────────────────────────────────

escape_grep() {
  printf '%s' "$1" | sed 's/[.[\*^$()+?{|]/\\&/g'
}

is_valid_package() {
  [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$ ]]
}

package_from_string() {
  echo "${1%%/*}"
}

# ── Package / activity resolution ────────────────────────────────────────────

resolve_app() {
  local input="$1"

  if [[ -f "$LAUNCHAPP_ALIAS_FILE" ]]; then
    local match
    match=$(grep -i "^${input}=" "$LAUNCHAPP_ALIAS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    if [[ -n "$match" ]]; then
      log_debug "Resolved '$input' via user alias → $match"
      echo "$match"; return 0
    fi
  fi

  if [[ -n "${BUILTIN_PACKAGES[$input]+_}" ]]; then
    local pkg="${BUILTIN_PACKAGES[$input]}"
    if find_main_activity "$pkg"; then return 0; fi
    log_warn "Package '${pkg}' not installed on device"
    return 1
  fi

  if is_valid_package "$input"; then
    if find_main_activity "$input"; then return 0; fi
    log_warn "Package '$input' not installed on device"
    return 1
  fi

  return 1
}

# Query pm for the MAIN launcher activity; print "pkg/activity"
# Cache key includes transport type so local and remote caches don't collide.
# Cache is also keyed by app version so installs/updates invalidate automatically.
#
# Resilience: tries three parsing strategies before falling back to a guess.
# dumpsys pm output format changes between Android versions without notice.
find_main_activity() {
  local pkg="$1"

  # ── Version-keyed cache ───────────────────────────────────────────────────
  # Include the installed app version in the cache key so updates auto-invalidate.
  local app_version
  app_version=$(transport_pm list packages 2>/dev/null \
    | grep -F "package:$pkg=" | cut -d= -f2 | head -1)
  # Fallback: use mtime-only key if version not parseable (older Android/pm format)
  local cache_key="${TRANSPORT:-local}_${pkg}_${app_version:-v0}"
  local cached="$LAUNCHAPP_CACHE_DIR/${cache_key}.activity"

  if [[ -f "$cached" ]] && \
     (( $(date +%s) - $(stat -c %Y "$cached" 2>/dev/null || echo 0) < 3600 )); then
    cat "$cached"
    return 0
  fi

  if ! transport_pm list packages 2>/dev/null | grep -qF "package:$pkg"; then
    return 1
  fi

  local dump activity
  dump=$(transport_pm dump "$pkg" 2>/dev/null)

  # Strategy 1 (original): MAIN action block followed by pkg name on next line
  activity=$(echo "$dump" \
    | awk '/android\.intent\.action\.MAIN/{f=1} f && /'"$(escape_grep "$pkg")"'/{print $2; exit}')

  # Strategy 2: look for "android.intent.action.MAIN" and grab first activity on
  # ANY following line that contains a slash (handles reordered output in Android 13+)
  if [[ -z "$activity" ]]; then
    activity=$(echo "$dump" \
      | awk '/android\.intent\.action\.MAIN/{f=1} f && /\//{match($0,/[^ \t]+\/[^ \t]+/); if(RSTART) {print substr($0,RSTART,RLENGTH); exit}}')
  fi

  # Strategy 3: look for "launchMode" section and extract the first activity line
  # containing the package name (Android 14+ pm dump format)
  if [[ -z "$activity" ]]; then
    activity=$(echo "$dump" \
      | grep -A1 "launchMode=" | grep -oP "${pkg//./\\.}/?\\.?[A-Za-z0-9_.]+" | head -1)
  fi

  if [[ -z "$activity" ]]; then
    activity="${pkg}/.MainActivity"
    log_warn "Main activity unknown for ${pkg} (tried 3 strategies); guessing ${activity}"
    log_warn "If launch fails, run: launchapp alias add <name> ${pkg}/YourActivity"
  fi

  mkdir -p "$LAUNCHAPP_CACHE_DIR"
  # Invalidate any stale cache entries for this pkg before writing new one
  rm -f "$LAUNCHAPP_CACHE_DIR/${TRANSPORT:-local}_${pkg}_"*.activity 2>/dev/null || true
  echo "$activity" | tee "$cached"
  return 0
}

validate_installed() {
  local pkg
  pkg=$(package_from_string "$1")
  transport_pm list packages 2>/dev/null | grep -qF "package:$pkg" \
    || die "Package '$pkg' is not installed on the target device"
}

list_user_packages() {
  transport_pm list packages -3 2>/dev/null | sed 's/^package://' | sort
}

# ── Process helpers ───────────────────────────────────────────────────────────

get_pid() {
  local pkg="$1"
  transport_pidof "$pkg" 2>/dev/null | awk '{print $1}'
}

# ── App lifecycle ─────────────────────────────────────────────────────────────

do_launch() {
  local app_string="$1"
  local result
  result=$(transport_am start -n "$app_string" -W 2>&1) || true
  if echo "$result" | grep -qi "error\|exception\|not found\|unable"; then
    log_error "Launch failed: $result"
    return 1
  fi
  log_info "Launched: $app_string"
  return 0
}

do_install() {
  local apk="$1"
  [[ -f "$apk" ]] || die "APK not found: $apk"
  log_info "Installing: $apk"
  transport_pm install -r -t "$apk" 2>&1 | tee /dev/stderr | grep -qi "success" \
    && log_info "Install successful" \
    || die "Install failed"
}

# ── Cache management ──────────────────────────────────────────────────────────

invalidate_cache() {
  local pkg="${1:-}"
  if [[ -n "$pkg" ]]; then
    rm -f "$LAUNCHAPP_CACHE_DIR"/*_"${pkg}".activity 2>/dev/null || true
    log_info "Cache cleared for $pkg"
  else
    rm -f "$LAUNCHAPP_CACHE_DIR"/*.activity 2>/dev/null || true
    log_info "All activity cache cleared"
  fi
}

# ── Pane command string builders ──────────────────────────────────────────────
# Modes call these to get the right command string for the active transport.
# The string is passed to pane_run / write_temp_script and runs in a tmux pane.

logcat_stream_cmd() {
  # Usage: logcat_stream_cmd PKG [extra flags]
  export TRANSPORT_LOGCAT_PKG="$1"
  transport_cmd logcat "${2:-}" "$1"
}

am_start_cmd()  { transport_cmd am start -n "$1" -W; }
am_stop_cmd()   { transport_cmd am force-stop "$1"; }
meminfo_cmd()   { transport_cmd dumpsys meminfo "$1"; }
battery_cmd()   { transport_cmd dumpsys battery; }
pm_clear_cmd()  { transport_cmd pm clear "$1"; }
pm_dump_cmd()   { transport_cmd pm dump "$1"; }
