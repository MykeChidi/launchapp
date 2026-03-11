#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lib/aliases.sh — User alias CRUD (add / remove / list)
# Depends on: lib/constants.sh, lib/log.sh
# =============================================================================

_ensure_alias_file() {
  mkdir -p "$LAUNCHAPP_CONFIG_DIR"
  touch "$LAUNCHAPP_ALIAS_FILE"
}

alias_list() {
  _ensure_alias_file
  echo -e "${CYAN}Custom aliases:${NC}"
  if [[ -s "$LAUNCHAPP_ALIAS_FILE" ]]; then
    awk -F= '{printf "  %-20s → %s\n", $1, $2}' "$LAUNCHAPP_ALIAS_FILE"
  else
    echo "  (none)"
  fi
}

# Usage: alias_add NAME PACKAGE[/ACTIVITY]
alias_add() {
  local name="$1" value="$2"
  [[ -z "$name" || -z "$value" ]] && die "Usage: alias add NAME PACKAGE[/ACTIVITY]"
  _ensure_alias_file
  sed -i "/^${name}=/d" "$LAUNCHAPP_ALIAS_FILE"
  echo "${name}=${value}" >> "$LAUNCHAPP_ALIAS_FILE"
  log_info "Alias added: ${name} → ${value}"
}

# Usage: alias_remove NAME
alias_remove() {
  local name="$1"
  [[ -z "$name" ]] && die "Usage: alias remove NAME"
  _ensure_alias_file
  sed -i "/^${name}=/d" "$LAUNCHAPP_ALIAS_FILE"
  log_info "Alias removed: ${name}"
}

# Dispatcher: alias_cmd list|add|remove [args...]
alias_cmd() {
  local subcmd="${1:-list}"
  shift || true
  case "$subcmd" in
    list)   alias_list ;;
    add)    alias_add "$@" ;;
    remove) alias_remove "$@" ;;
    *)      die "Unknown alias subcommand: $subcmd. Use: list, add, remove" ;;
  esac
}
