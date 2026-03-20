#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# remote/scan.sh — Network scanning and device onboarding
# Depends on: lib/constants.sh lib/log.sh lib/deps.sh
#             lib/devices.sh lib/agent_client.sh lib/adb_client.sh
# =============================================================================

# ── Exported globals (set on successful scan/select) ─────────────────────────
# DEVICE_IP, DEVICE_NAME, DEVICE_TYPE, DEVICE_PORT, DEVICE_ADB_ID, AGENT_TOKEN

scan_network() {
  need_nmap
  echo
  echo -e "${GREEN}Scanning network for devices…${NC}"
  echo

  # Detect local WiFi IP
  local local_ip
  local_ip=$(ip -4 addr show wlan0 2>/dev/null \
    | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
  [[ -z "$local_ip" ]] && \
    local_ip=$(ip -4 addr show 2>/dev/null \
      | grep -oP '(?<=inet\s)\d+(\.\d+){3}' \
      | grep -v '^127\.' | head -1)
  [[ -z "$local_ip" ]] && die "Not connected to any network"

  # Read the actual prefix length from the interface
  local network prefix_len cidr
  cidr=$(ip -4 addr show wlan0 2>/dev/null \
    | grep -oP "(?<=inet\s)${local_ip}/[0-9]+" | head -1)
  if [[ -z "$cidr" ]]; then
    cidr=$(ip -4 addr show 2>/dev/null \
      | grep -oP "(?<=inet\s)${local_ip}/[0-9]+" | head -1)
  fi
  prefix_len="${cidr##*/}"
  prefix_len="${prefix_len:-24}"
  network="${local_ip}/${prefix_len}"
  
  echo -e "${CYAN}Network: $network${NC}"
  echo -e "${YELLOW}This may take ~30s…${NC}"
  echo

  # Single nmap pass: discover hosts + hostnames together
  declare -A ip_to_host
  while IFS= read -r line; do
    if [[ "$line" =~ "Nmap scan report for" ]]; then
      if [[ "$line" =~ \(([0-9.]+)\) ]]; then
        ip="${BASH_REMATCH[1]}"
        host=$(echo "$line" | awk '{print $5}')
      else
        ip=$(echo "$line" | awk '{print $NF}')
        host="$ip"
      fi
      ip_to_host[$ip]="$host"
    fi
  done < <(nmap -sn --resolve-all "$network" 2>/dev/null)

  declare -A menu
  local count=0

  for ip in "${!ip_to_host[@]}"; do
    [[ "$ip" == "$local_ip" ]] && continue
    ((count++)) || true
    local host="${ip_to_host[$ip]}"

    # Probe for agent and ADB in parallel
    local agent_str="No" adb_str="No"
    if curl -s -m 2 "http://${ip}:${AGENT_DEFAULT_PORT}/ping" 2>/dev/null | grep -q "pong"; then
      agent_str="${GREEN}Yes (:${AGENT_DEFAULT_PORT})${NC}"
    fi
    nc -z -w 1 "$ip" 5555 2>/dev/null && adb_str="${GREEN}Yes${NC}"

    menu[$count]="${ip}|${host}|${agent_str}|${adb_str}"
    echo -e "${CYAN}[$count]${NC} $ip  (${host})"
    echo -e "      Agent: $agent_str   ADB: $adb_str"
    echo
  done

  [[ $count -eq 0 ]] && { log_warn "No other devices found"; return 1; }

  echo -e "${GREEN}Select device (0 to cancel):${NC}"
  local choice
  read -rp "> " choice
  [[ "$choice" == "0" || -z "$choice" ]] && return 1
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ -z "${menu[$choice]+_}" ]]; then
    log_error "Invalid selection"; sleep 2; return 1
  fi

  IFS='|' read -r sel_ip sel_host _ _ <<< "${menu[$choice]}"

  read -rp "Device name [$sel_host]: " device_name
  device_name="${device_name:-$sel_host}"

  echo
  echo "Connection mode:"
  local modes=()
  local i=0
  ((i++)) || true; echo "  $i. Agent (authenticated HTTP — recommended)"; modes+=(agent)
  if nc -z -w 1 "$sel_ip" 5555 2>/dev/null; then
    ((i++)) || true; echo "  $i. ADB wireless"; modes+=(adb)
  fi
  ((i++)) || true; echo "  $i. Network traffic only (tcpdump — root required)"; modes+=(network)
  echo
  local mc
  read -rp "Choice [1]: " mc
  mc="${mc:-1}"
  if ! [[ "$mc" =~ ^[0-9]+$ ]] || [[ "$mc" -lt 1 ]] || [[ "$mc" -gt "${#modes[@]}" ]]; then
    log_error "Invalid choice"; return 1
  fi

  local selected_mode="${modes[$((mc-1))]}"
  case "$selected_mode" in
    agent)   _onboard_agent   "$device_name" "$sel_ip" ;;
    adb)     _onboard_adb     "$device_name" "$sel_ip" ;;
    network) _onboard_network "$device_name" "$sel_ip" ;;
  esac
}

# ── Device onboarding ─────────────────────────────────────────────────────────

_onboard_agent() {
  local name="$1" ip="$2"
  need_curl

  echo
  echo "Agent auth token (leave blank if agent has no auth configured):"
  read -rsp "> " token_input; echo
  token_input="${token_input:-${AGENT_TOKEN:-}}"

  local curl_args=(-s -m 5)
  [[ -n "$token_input" ]] && curl_args+=(-H "${TOKEN_HEADER}: $token_input")
  local info
  info=$(curl "${curl_args[@]}" "http://${ip}:${AGENT_DEFAULT_PORT}/info" 2>/dev/null)

  if [[ -z "$info" ]] || ! echo "$info" | jq -e . &>/dev/null; then
    log_error "Cannot reach agent at $ip:${AGENT_DEFAULT_PORT}"
    log_warn "Make sure agent.py is running on the target device"
    sleep 2; return 1
  fi

  local model android agent_ver
  model=$(echo "$info" | jq -r '.model // "Unknown"')
  android=$(echo "$info" | jq -r '.android // "Unknown"')
  agent_ver=$(echo "$info" | jq -r '.version // "?"')
  log_info "Connected: $model (Android $android, agent v$agent_ver)"

  local json_obj
  json_obj=$(jq -n \
    --arg name  "$name" \
    --arg ip    "$ip" \
    --arg type  "agent" \
    --arg port  "$AGENT_DEFAULT_PORT" \
    --arg model "$model" \
    --arg token "$token_input" \
    '{"name":$name,"ip":$ip,"type":$type,"port":$port,"model":$model,"token":$token}')
  device_add "$json_obj"

  DEVICE_IP="$ip"; DEVICE_NAME="$name"; DEVICE_TYPE="agent"
  DEVICE_PORT="$AGENT_DEFAULT_PORT"; AGENT_TOKEN="$token_input"
  log_info "Saved: $name (agent)"; sleep 1
  return 0
}

_onboard_adb() {
  local name="$1" ip="$2"
  adb_setup_device "$name" "$ip" || return 1

  local model android
  model=$(adb -s "$DEVICE_ADB_ID" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
  android=$(adb -s "$DEVICE_ADB_ID" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')

  local json_obj
  json_obj=$(jq -n \
    --arg name    "$name" \
    --arg ip      "$ip" \
    --arg type    "adb" \
    --arg adb_id  "$DEVICE_ADB_ID" \
    --arg model   "${model:-Unknown}" \
    --arg android "${android:-Unknown}" \
    '{"name":$name,"ip":$ip,"type":$type,"adb_id":$adb_id,"model":$model,"android":$android}')
  device_add "$json_obj"

  DEVICE_IP="$ip"; DEVICE_NAME="$name"; DEVICE_TYPE="adb"
  log_info "Saved: $name (adb)"; sleep 1
  return 0
}

_onboard_network() {
  local name="$1" ip="$2"
  local json_obj
  json_obj=$(jq -n \
    --arg name "$name" \
    --arg ip   "$ip" \
    --arg type "network" \
    '{"name":$name,"ip":$ip,"type":$type}')
  device_add "$json_obj"
  DEVICE_IP="$ip"; DEVICE_NAME="$name"; DEVICE_TYPE="network"
  log_info "Saved: $name (network-only)"; sleep 1
  return 0
}

# ── Select a saved device ─────────────────────────────────────────────────────

select_device() {
  need_jq

  echo -e "${GREEN}Saved Devices${NC}"
  echo "──────────────────────────────────────────"
  echo
  devices_print_list || return 1

  local count; count=$(devices_count)
  local choice
  read -rp "Select device: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || \
     [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$count" ]]; then
    log_error "Invalid selection"; sleep 2; return 1
  fi

  local idx=$((choice-1))
  local dev; dev=$(device_get "$idx")

  DEVICE_IP=$(device_field "$dev" ip)
  DEVICE_NAME=$(device_field "$dev" name)
  DEVICE_TYPE=$(device_field "$dev" type)

  case "$DEVICE_TYPE" in
    agent)
      DEVICE_PORT=$(device_field "$dev" port)
      DEVICE_PORT="${DEVICE_PORT:-$AGENT_DEFAULT_PORT}"
      # Token must come from LAUNCHAPP_TOKEN env var or ~/.launchapp/token.
      if [[ -z "${AGENT_TOKEN:-}" && -f "$LAUNCHAPP_CONFIG_DIR/token" ]]; then
        AGENT_TOKEN=$(cat "$LAUNCHAPP_CONFIG_DIR/token")
      fi

      if ! agent_ping "$DEVICE_IP" "$DEVICE_PORT" "${AGENT_TOKEN:-}"; then
        log_error "Agent not reachable at $DEVICE_IP:$DEVICE_PORT"
        log_warn "Ensure agent is running on the target device"
        sleep 2; return 1
      fi
      log_info "Agent connected: $DEVICE_NAME"
      ;;
    adb)
      DEVICE_ADB_ID=$(device_field "$dev" adb_id)
      if ! adb_ping "$DEVICE_ADB_ID"; then
        log_info "Reconnecting ADB…"
        adb connect "$DEVICE_ADB_ID" 2>/dev/null
        sleep 1
        if ! adb_ping "$DEVICE_ADB_ID"; then
          log_error "ADB not connected: $DEVICE_ADB_ID"; sleep 2; return 1
        fi
      fi
      log_info "ADB connected: $DEVICE_NAME"
      ;;
    network)
      ping -c 1 -W 2 "$DEVICE_IP" &>/dev/null || log_warn "Device may be offline"
      ;;
  esac

  log_info "Selected: $DEVICE_NAME ($DEVICE_TYPE @ $DEVICE_IP)"
  sleep 1
  return 0
}

remove_device() {
  need_jq
  echo -e "${GREEN}Saved Devices${NC}"
  echo
  devices_print_list || return

  local count; count=$(devices_count)
  echo -e "${YELLOW}Device to remove (0 to cancel):${NC}"
  local choice
  read -rp "> " choice
  [[ "$choice" == "0" || -z "$choice" ]] && return
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || \
     [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$count" ]]; then
    log_error "Invalid"; sleep 2; return
  fi

  local idx=$((choice-1))
  local name; name=$(jq -r ".[$idx].name" "$LAUNCHAPP_DEVICES_FILE")
  read -rp "Remove '$name'? (y/n): " confirm
  [[ "$confirm" != "y" ]] && return
  device_remove "$idx"
  log_info "Removed: $name"
  sleep 2
}
