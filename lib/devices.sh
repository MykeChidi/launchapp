#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/devices.sh — Device registry persistence (JSON via jq)
# Depends on: lib/constants.sh, lib/log.sh
# =============================================================================

init_devices() {
  mkdir -p "$LAUNCHAPP_CONFIG_DIR"
  [[ -f "$LAUNCHAPP_DEVICES_FILE" ]] || echo "[]" > "$LAUNCHAPP_DEVICES_FILE"
}

devices_count() {
  jq '. | length' "$LAUNCHAPP_DEVICES_FILE" 2>/dev/null || echo "0"
}

# Get a device JSON object by 0-based index
device_get() {
  jq ".[$1]" "$LAUNCHAPP_DEVICES_FILE" 2>/dev/null
}

# Extract a field from a JSON device object (string passed in, not index)
# Usage: device_field JSON_STRING FIELD_NAME
device_field() {
  echo "$1" | jq -r ".$2 // empty"
}

# Append a JSON object to the devices array.
# SECURITY: strip any 'token' field before writing — tokens are never stored in
# devices.json because that file may be backed up or synced to insecure locations.
# Token is loaded at connect time from LAUNCHAPP_TOKEN or ~/.launchapp/token.
device_add() {
  local obj="$1"
  # Remove token field if caller accidentally passed one
  obj=$(echo "$obj" | jq 'del(.token)')
  local tmp
  tmp=$(mktemp)
  jq ". += [$obj]" "$LAUNCHAPP_DEVICES_FILE" > "$tmp" && mv "$tmp" "$LAUNCHAPP_DEVICES_FILE"
}

# Remove a device by 0-based index; optionally disconnect ADB first
# Usage: device_remove INDEX
device_remove() {
  local idx="$1"
  local dev
  dev=$(device_get "$idx")
  local dtype adb_id
  dtype=$(device_field "$dev" type)
  adb_id=$(device_field "$dev" adb_id)

  if [[ "$dtype" == "adb" && -n "$adb_id" ]]; then
    adb disconnect "$adb_id" 2>/dev/null || true
  fi

  local tmp
  tmp=$(mktemp)
  jq "del(.[$idx])" "$LAUNCHAPP_DEVICES_FILE" > "$tmp" && mv "$tmp" "$LAUNCHAPP_DEVICES_FILE"
}

# Print a numbered device list; returns 1 if empty
# Also does a live ping for each device
devices_print_list() {
  local count
  count=$(devices_count)

  if [[ "$count" -eq 0 ]]; then
    echo -e "${YELLOW}No devices saved.${NC}"
    echo "  Use 'Scan Network' or --connect to add one."
    return 1
  fi

  local i=0
  while IFS= read -r dev; do
    local name ip dtype model status
    name=$(device_field "$dev" name)
    ip=$(device_field "$dev" ip)
    dtype=$(device_field "$dev" type)
    model=$(device_field "$dev" model)

    if ping -c 1 -W 1 "$ip" &>/dev/null; then
      status="${GREEN}● online${NC}"
    else
      status="${RED}● offline${NC}"
    fi

    echo -e "${CYAN}[$((i+1))]${NC} ${name}  ${model:+(${model})}"
    echo -e "     IP: ${ip}   Type: ${YELLOW}${dtype}${NC}   ${status}"
    echo
    ((i++))
  done < <(jq -c '.[]' "$LAUNCHAPP_DEVICES_FILE")
  return 0
}
