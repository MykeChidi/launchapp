# `launchapp` - Termux-native Android debug tookit

Termux-native Android debug toolkit — local and remote app monitoring, crash detection, performance profiling, and network inspection from your phone.


```bash
launchapp chrome debug
launchapp spotify crash --watch
launchapp -r --connect 192.168.1.42 com.example.myapp perf  # remote
```

---

## What it does

launchapp wraps Android's `am`, `pm`, `logcat`, and `dumpsys` commands into structured tmux sessions and live monitors. It runs entirely on Android via Termux — no desktop required.

**Three connection modes:**

| Mode | How it works | Setup |
|------|-------------|-------|
| **Local** | Runs directly on the device you're holding | Zero setup |
| **ADB wireless** | Connects to another phone over WiFi via `adb` | One-time pairing |
| **Agent** | Lightweight Python HTTP server on the target phone | Run `launchapp -r --agent` once |

**Debug modes:**

| Mode | What you get |
|------|-------------|
| `debug` | 6-window tmux session — logs, errors, activity lifecycle, crashes, performance, network |
| `monitor` | Split-pane live monitor with interactive controls |
| `crash` | Foreground crash + ANR watcher with optional auto-restart (`--watch`) |
| `perf` | Live performance dashboard — heap, GC, battery |
| `network` | Logcat-based network call monitor (HTTP/OkHttp/Retrofit) |
| `info` | App version, permissions, activities, install paths |
| `top` | Live running process list with memory usage |
| `install` | Install an APK with progress output |

---

## Requirements

**On the controlling phone (Termux):**

- `tmux` — session management
- `jq` — JSON parsing
- `curl` — agent transport
- `python` — agent server + token generation

**Optional:**

- `android-tools` (ADB) — for ADB wireless mode
- `termux-api` + Termux:API app — crash notifications and vibration
- `nmap` — network scan (`launchapp -r scan`)
- `tcpdump` + root — raw network traffic mode

Install everything at once:

```bash
pkg install tmux jq curl python android-tools nmap
```

---

## Quick install

```bash
git clone https://github.com/MykeChidi/launchapp
cd launchapp
bash install.sh
source ~/.bashrc
launchapp setup  # one-time ADB loopback setup
```

`install.sh` handles package checks, shell aliases, config directories, and optional token generation. See [SETUP.md](SETUP.md) for the full walkthrough.

---

## Usage at a glance

```bash
# Local — debug on this phone
launchapp chrome debug
launchapp spotify monitor
launchapp com.example.myapp crash --watch --save
launchapp youtube perf
launchapp top

# Remote — control another phone via agent
launchapp -r --connect 192.168.1.42 chrome debug
launchapp -r --connect 192.168.1.42:8765 spotify crash --watch

# Remote — control another phone via ADB wireless
launchapp -r --adb 192.168.1.42:5555 com.example.myapp monitor

# Scan your network for devices
launchapp -r scan

# Start agent on this phone so another phone can connect to it
launchapp -r --agent

# App aliases
launchapp alias add myapp com.example.myapp
launchapp alias list
launchapp alias remove myapp

# Utilities
launchapp list [filter]       # list installed packages
launchapp attach [session]    # reattach to a running tmux session
launchapp history             # show crash history
launchapp cache clear [pkg]   # clear cached activity resolution
```

Full reference: [USAGE.md](USAGE.md)

---

## Built-in app aliases

Common apps work by short name without needing the full package:

`chrome` · `youtube` · `spotify` · `gmail` · `maps` · `whatsapp` · `telegram` · `instagram` · `netflix` · `firefox` · `discord` · `reddit` · `snapchat` · `zoom`· and more.

---

## Project structure

```
launchapp/
├── launchapp.sh          # Entry point
├── remote_monitor.sh     # Backwards-compat wrapper for -r flag
├── agent.py              # HTTP monitoring agent (runs on target phone)
├── install.sh            # Setup script
├── lib/
│   ├── constants.sh      # Global constants and capability detection
│   ├── log.sh            # Logging helpers
│   ├── deps.sh           # Dependency checks
│   ├── tmux.sh           # Session and pane management
│   ├── android.sh        # Package resolution, app lifecycle
│   ├── aliases.sh        # User alias CRUD
│   ├── devices.sh        # Saved device registry (JSON)
│   ├── agent_client.sh   # HTTP client wrappers for agent API
│   ├── adb_client.sh     # ADB wireless helpers
│   ├── transport_local.sh
│   ├── transport_adb.sh
│   └── transport_agent.sh
├── modes/
│   ├── debug.sh
│   ├── monitor.sh
│   ├── crash.sh
│   ├── perf.sh
│   ├── network.sh
│   └── files.sh
└── remote/
    ├── scan.sh           # Network scan and device onboarding
    └── network_traffic.sh # tcpdump-based traffic monitor
```

---

## Security

The agent server (`agent.py`) is designed for use on trusted local networks. Key properties:

- **Authentication required by default** — token must be set via `--token` or `LAUNCHAPP_TOKEN`; running without auth requires explicit `--no-auth`
- **No shell injection** — all subprocess calls use list form, never `shell=True`
- **Path traversal prevention** — all file operations are confined to `/sdcard`
- **Per-endpoint rate limiting** — protects against accidental request storms
- **IP allowlist** — optional extra layer via `--allow-ip`
- **Tokens never stored on disk** — stripped from `devices.json` on save

Do not expose the agent port to the internet or untrusted networks.

---

## License

MIT