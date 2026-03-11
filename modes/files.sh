#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# modes/files.sh — Interactive file manager for the remote device
#
# Agent transport only — reads and writes files on the target phone via the
# agent's /files, /download, /upload, and /screenshot/download endpoints.
# Local and ADB transports do not support file operations and exit with a
# clear error.
#
# Depends on: lib/constants.sh lib/log.sh lib/android.sh lib/transport_agent.sh
# =============================================================================

mode_files() {
  local _pkg="${1:-}"   # optional — not used but kept for consistent call signature

  # ── Transport gate ────────────────────────────────────────────────────────
  if [[ "${TRANSPORT:-local}" != "agent" ]]; then
    echo
    echo -e "${RED}File manager requires agent transport.${NC}"
    echo
    echo "Connect with:  launchapp -r --connect IP files"
    echo
    return 1
  fi

  need_curl; need_jq

  local base="http://${DEVICE_IP}:${DEVICE_PORT}"
  local auth_header="${AGENT_TOKEN:+-H ${TOKEN_HEADER}: ${AGENT_TOKEN}}"
  local dl_dir="$HOME/launchapp_downloads"
  mkdir -p "$dl_dir"

  # ── Curl helper (inline — we're not inside a tempscript here) ─────────────
  _fm_curl() {
    local endpoint="$1"; shift
    local url="${base}${endpoint}"
    local args=(-s -m 15)
    [[ -n "${AGENT_TOKEN:-}" ]] && args+=(-H "${TOKEN_HEADER}: ${AGENT_TOKEN}")
    curl "${args[@]}" "$@" "$url" 2>/dev/null
  }

  # ── URL-encode a path ─────────────────────────────────────────────────────
  _fm_encode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
      "$1" 2>/dev/null || printf '%s' "$1"
  }

  # ── List directory — pretty print ─────────────────────────────────────────
  _fm_ls() {
    local path="$1"
    local enc; enc=$(_fm_encode "$path")
    local result
    result=$(_fm_curl "/files?path=${enc}")

    if [[ -z "$result" ]] || echo "$result" | jq -e '.error' &>/dev/null; then
      local err; err=$(echo "$result" | jq -r '.error // "no response"' 2>/dev/null)
      echo -e "  ${RED}Error: ${err}${NC}"
      return 1
    fi

    local count; count=$(echo "$result" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 ]]; then
      echo "  (empty)"
      return 0
    fi

    # Print dirs first, then files, with sizes for files
    echo "$result" | jq -r '
      sort_by(.type, .name) |
      .[] |
      if .type == "dir" then
        "  \u001b[36mDIR \u001b[0m  " + .name + "/"
      else
        "  \u001b[0mFILE\u001b[0m  " + .name +
        (if .size != null then
          "  (" + (if .size > 1048576 then (.size/1048576 | floor | tostring) + "MB"
                   elif .size > 1024 then (.size/1024 | floor | tostring) + "KB"
                   else (.size | tostring) + "B" end) + ")"
         else "" end)
      end
    ' 2>/dev/null || echo "  (parse error)"
  }

  # ── Interactive session ───────────────────────────────────────────────────
  local cwd="/sdcard"
  local device_label="${DEVICE_NAME:-${DEVICE_IP}}"

  echo
  echo -e "${GREEN}┌─────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${GREEN}│${NC}  File Manager — ${YELLOW}${device_label}${NC}"
  echo -e "${GREEN}│${NC}"
  echo -e "${GREEN}│${NC}  Commands:"
  echo -e "${GREEN}│${NC}    ${YELLOW}ls [path]${NC}              list directory (default: current)"
  echo -e "${GREEN}│${NC}    ${YELLOW}cd <path>${NC}              change directory"
  echo -e "${GREEN}│${NC}    ${YELLOW}up${NC}                     go up one level"
  echo -e "${GREEN}│${NC}    ${YELLOW}download <name>${NC}        download file from current dir"
  echo -e "${GREEN}│${NC}    ${YELLOW}download <full-path>${NC}   download file by absolute path"
  echo -e "${GREEN}│${NC}    ${YELLOW}upload <local-path>${NC}    upload to current remote dir"
  echo -e "${GREEN}│${NC}    ${YELLOW}upload <local> <remote>${NC}  upload to specific remote path"
  echo -e "${GREEN}│${NC}    ${YELLOW}screenshot${NC}             capture + download screenshot"
  echo -e "${GREEN}│${NC}    ${YELLOW}pwd${NC}                    show current path"
  echo -e "${GREEN}│${NC}    ${YELLOW}exit / q${NC}               quit"
  echo -e "${GREEN}└─────────────────────────────────────────────────────────────┘${NC}"
  echo
  echo "Downloads saved to: ${dl_dir}"
  echo

  # Show initial listing
  echo -e "${CYAN}${cwd}${NC}"
  _fm_ls "$cwd"
  echo

  while true; do
    printf "${CYAN}[%s]${NC} > " "$cwd"
    read -r cmd a1 a2 || break

    case "$cmd" in

      ls)
        local ls_path="${a1:-$cwd}"
        # Relative path: prepend cwd
        [[ "$ls_path" != /* ]] && ls_path="${cwd}/${ls_path}"
        echo -e "${CYAN}${ls_path}${NC}"
        _fm_ls "$ls_path"
        echo
        ;;

      cd)
        if [[ -z "$a1" ]]; then
          echo "  Usage: cd <path>"
          continue
        fi
        local new_dir="$a1"
        [[ "$new_dir" != /* ]] && new_dir="${cwd}/${new_dir}"
        # Verify it exists and is a directory before accepting
        local enc; enc=$(_fm_encode "$new_dir")
        local check; check=$(_fm_curl "/files?path=${enc}")
        if echo "$check" | jq -e '.error' &>/dev/null; then
          local err; err=$(echo "$check" | jq -r '.error' 2>/dev/null)
          echo -e "  ${RED}${err}${NC}"
        else
          cwd="$new_dir"
          echo -e "${CYAN}${cwd}${NC}"
          _fm_ls "$cwd"
          echo
        fi
        ;;

      up)
        local parent; parent=$(dirname "$cwd")
        [[ "$parent" == "$cwd" ]] && { echo "  Already at root"; continue; }
        cwd="$parent"
        echo -e "${CYAN}${cwd}${NC}"
        _fm_ls "$cwd"
        echo
        ;;

      pwd)
        echo "  $cwd"
        echo
        ;;

      download)
        if [[ -z "$a1" ]]; then
          echo "  Usage: download <filename-or-path>"
          continue
        fi
        local remote_path="$a1"
        # Relative path: prepend cwd
        [[ "$remote_path" != /* ]] && remote_path="${cwd}/${a1}"
        local fname; fname=$(basename "$remote_path")
        local local_out="${dl_dir}/${fname}"
        echo "  Downloading ${remote_path} → ${local_out}…"
        transport_download "$remote_path" "$local_out" && echo || echo -e "  ${RED}Failed${NC}"
        ;;

      upload)
        if [[ -z "$a1" ]]; then
          echo "  Usage: upload <local-path> [remote-dest]"
          continue
        fi
        local local_src="$a1"
        local remote_dest="${a2:-${cwd}/$(basename "$a1")}"
        if [[ ! -f "$local_src" ]]; then
          echo -e "  ${RED}File not found: ${local_src}${NC}"
          continue
        fi
        echo "  Uploading ${local_src} → ${remote_dest}…"
        transport_upload "$local_src" "$remote_dest" && echo || echo -e "  ${RED}Failed${NC}"
        ;;

      screenshot)
        local ts; ts=$(date +%s)
        local out="${dl_dir}/screenshot_${ts}.png"
        echo "  Capturing screenshot…"
        transport_screenshot "$out" && echo || echo -e "  ${RED}Failed${NC}"
        ;;

      exit|quit|q)
        echo
        break
        ;;

      '')
        # blank line — re-print current listing
        echo -e "${CYAN}${cwd}${NC}"
        _fm_ls "$cwd"
        echo
        ;;

      *)
        echo -e "  ${RED}Unknown command: ${cmd}${NC}  (try ls, cd, download, upload, screenshot, exit)"
        ;;

    esac
  done
}
