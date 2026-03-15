# Setup Guide

Complete installation and configuration reference for launchapp.

---

## Table of contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Shell configuration](#shell-configuration)
- [Agent token setup](#agent-token-setup)
- [Connecting to a second phone](#connecting-to-a-second-phone)
  - [Agent mode](#agent-mode-recommended)
  - [ADB wireless mode](#adb-wireless-mode)
- [Environment variables](#environment-variables)
- [Directory layout](#directory-layout)
- [Upgrading](#upgrading)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)

---

## Requirements

### Required packages

| Package | Purpose | Install |
|---------|---------|---------|
| `tmux` | Session and pane management | `pkg install tmux` |
| `jq` | JSON parsing for device registry and agent responses | `pkg install jq` |
| `curl` | Agent HTTP transport | `pkg install curl` |
| `python` | Agent server + token generation | `pkg install python` |

### Optional packages

| Package | Purpose | Install |
|---------|---------|---------|
| `android-tools` | ADB wireless mode | `pkg install android-tools` |
| `termux-api` | Crash notifications and vibration | `pkg install termux-api` |
| `nmap` | Network scanning (`launchapp -r scan`) | `pkg install nmap` |
| `tcpdump` | Raw network traffic mode (requires root) | `pkg install root-repo && pkg install tcpdump` |

### Termux:API app

If you want crash notifications and vibration alerts, you need both:

1. The `termux-api` Termux package (`pkg install termux-api`)
2. The **Termux:API** companion app installed from F-Droid or Google Play

Both must be installed and at compatible versions. launchapp checks this at startup and degrades silently if either is missing.

---

## Installation

### Recommended: install script

```bash
git clone https://github.com/MykeChidi/launchapp
cd launchapp
bash install.sh
source ~/.bashrc
```

The install script does the following:

1. Checks for required and optional packages, and offers to install missing ones
2. Makes entry-point scripts executable
3. Adds `launchapp` and `remote_monitor` aliases to your shell rc file
4. Optionally symlinks `launchapp` into `$PREFIX/bin` so it works without an alias
5. Creates config and log directories
6. Generates an agent token and saves it to `~/.launchapp/token`
7. Optionally exports `LAUNCHAPP_TOKEN` in your rc file
8. Runs a syntax check on all shell and Python files

### First-time setup (required once)

launchapp uses ADB over loopback to get full shell permissions on any Android version. Run this once after installing:

```bash
launchapp setup
```

This requires **Wireless Debugging** to be enabled in Developer Options. On Android 11+, you may need to pair first — the setup command will walk you through it.

You only need to do this once. After that `launchapp <app> debug` just works.

### Verify the installation

```bash
launchapp --version
launchapp list
```

If `launchapp: command not found`, either reload your shell (`source ~/.bashrc`) or the symlink step was skipped. In that case run directly:

```bash
bash ~/launchapp/launchapp.sh --version
```

---

## Shell configuration

The install script adds two aliases to your rc file:

```bash
alias launchapp='bash /path/to/launchapp.sh'
alias remote='bash /path/to/remote_monitor.sh'
```

If you chose the symlink option, `launchapp` will be available system-wide and the alias is not needed.

### Locating library files

launchapp finds its own library files using three strategies in order:

1. `$LAUNCHAPP_DATA_DIR` — explicit override
2. `$PREFIX/share/launchapp/` — standard `pkg install` layout
3. Same directory as `launchapp.sh` — git clone / development layout

If you move the scripts, set `LAUNCHAPP_DATA_DIR`:

```bash
export LAUNCHAPP_DATA_DIR=/path/to/launchapp
```

---

## Agent token setup

The agent server requires a token by default. Without one, anyone on the same WiFi network can launch, kill, and read logs from apps on your phone.

### Generate a token

```bash
# Generates a cryptographically random 64-character hex token
python3 -c "import secrets; print(secrets.token_hex(32))" > ~/.launchapp/token
chmod 600 ~/.launchapp/token
```

Or use the built-in helper:

```bash
launchapp-agent --gen-token
```

### Make the token available to launchapp

Add to `~/.bashrc`:

```bash
export LAUNCHAPP_TOKEN=$(cat ~/.launchapp/token 2>/dev/null)
```

Or pass it inline:

```bash
LAUNCHAPP_TOKEN=your_token launchapp -r --connect 192.168.1.42 chrome debug
```

### Using a token with the agent

When starting the agent on the target phone, pass the same token:

```bash
# Option 1: environment variable
export LAUNCHAPP_TOKEN=$(cat ~/.launchapp/token)
launchapp -r --agent

# Option 2: explicit flag
launchapp-agent --token your_token_here
```

The token shown in the agent startup banner is truncated for security (`abc12345...ef90`). The full token is in `~/.launchapp/token`.

---

## Connecting to a second phone

launchapp supports two remote modes. Choose based on your situation:

| | Agent mode | ADB wireless |
|---|---|---|
| **Root required** | No | No |
| **Setup** | Run agent once on target | Pair once via Developer Options |
| **Latency** | HTTP polling (2s for logcat) | Direct ADB shell |
| **File transfer** | Yes (upload/download) | Via `adb pull/push` |
| **Best for** | Ongoing monitoring without a PC | Quick one-off debugging |

### Agent mode (recommended)

**On the TARGET phone (the phone you want to debug):**

```bash
# Install launchapp on the target phone too
git clone https://github.com/yourusername/launchapp
cd launchapp
bash install.sh

# Start the agent
export LAUNCHAPP_TOKEN=$(cat ~/.launchapp/token)
launchapp -r --agent
```

The agent prints its IP, port, and the export command to run on the controller:

```
┌─────────────────────────────────────────────────────────────┐
│  launchapp agent v1.0.0
│  Device : Pixel 7 (Android 14)
│  Listen : http://192.168.1.42:8765
│  Token  : abc12345...ef90
│
│  On controller phone:
│    export LAUNCHAPP_TOKEN='your_full_token_here'
│    launchapp -r --connect 192.168.1.42:8765
└─────────────────────────────────────────────────────────────┘
```

**On the CONTROLLER phone (the phone you're holding):**

```bash
export LAUNCHAPP_TOKEN='your_full_token_here'
launchapp -r --connect 192.168.1.42 chrome debug
```

Both phones must be on the same WiFi network. The default agent port is `8765`. To use a custom port:

```bash
# On target
launchapp-agent --port 9000 --token your_token

# On controller
launchapp -r --connect 192.168.1.42:9000 chrome debug
```

#### Keeping the agent alive

Android may kill the agent when the screen turns off due to battery optimisation. To prevent this:

1. Open Android **Settings → Apps → Termux**
2. **Battery → Unrestricted**
3. Disable battery optimisation for Termux

Alternatively run the agent inside a tmux session so it survives Termux backgrounding:

```bash
tmux new-session -d -s agent "launchapp -r --agent"
```

### ADB wireless mode

**On the TARGET phone:**

1. **Settings → About phone** — tap **Build number** 7 times to enable Developer Options
2. **Settings → Developer Options → Wireless Debugging** — enable it

**Android 11+ (API 30+) — pairing required:**

3. Tap **Pair device with pairing code**
4. Note the pairing code and `IP:PORT` shown on screen

**On the CONTROLLER phone:**

```bash
# Scan first to find the target, then select ADB mode
launchapp -r scan

# Or connect directly if you know the device ID
launchapp -r --adb 192.168.1.42:5555 chrome debug
```

If using `launchapp -r scan`, the tool will prompt you for the pairing code and connection port interactively.

**Android 10 and below — no pairing step:**

After enabling Wireless Debugging, just connect directly:

```bash
launchapp -r --adb 192.168.1.42:5555 chrome debug
```

### Saving devices

After first connecting via scan or `--connect`, the device is saved to `~/.launchapp/devices.json` (without the token). On subsequent runs, use the interactive menu to select it:

```bash
launchapp -r          # shows scan/select menu if no --connect or --adb given
```

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LAUNCHAPP_TOKEN` | *(none)* | Agent auth token. Read from `~/.launchapp/token` if not set |
| `LAUNCHAPP_DATA_DIR` | *(auto-detected)* | Override library file location |
| `LAUNCHAPP_CONFIG_DIR` | `~/.launchapp` | Config and device registry directory |
| `LAUNCHAPP_LOG_DIR` | `~/launchapp_logs` | Log output directory (used with `--save`) |
| `LAUNCHAPP_DEBUG` | `0` | Set to `1` for verbose debug output including curl errors |

---

## Directory layout

```
~/.launchapp/
├── aliases          # User-defined app aliases (name=package format)
├── devices.json     # Saved remote devices
├── token            # Agent auth token (chmod 600)
└── cache/           # Activity resolution cache (auto-invalidates on app update)

~/launchapp_logs/
├── crash_summary.log          # Cumulative crash/ANR history
├── DDMMYYYY_HHMMSS_pkg_*.log  # Per-session log files (--save)

~/launchapp_screenshots/       # Screenshots captured via info or agent
~/launchapp_downloads/         # Files downloaded from remote device via agent
```

---

## Upgrading

```bash
cd launchapp
git pull
bash install.sh   # re-runs package checks and permission fixes
source ~/.bashrc
```

The cache in `~/.launchapp/cache/` is version-keyed and will auto-invalidate. Your aliases, saved devices, and token are preserved.

---

## Uninstalling

```bash
# Using uninstall script
bash launchapp/uninstall.sh

# Then Remove the cloned directory
rm -rf ~/launchapp
```

---

## Troubleshooting

### `launchapp: command not found`

The alias was not loaded. Run `source ~/.bashrc` or open a new Termux session. If the problem persists, check that the alias block was added to the correct rc file for your shell (`echo $SHELL`).

### `ERROR: launchapp library files not found`

The script cannot locate its `lib/` directory. Either:

- You moved `launchapp.sh` without moving the rest of the project, or
- You are running the script from a different working directory

Fix: `export LAUNCHAPP_DATA_DIR=/path/to/launchapp` or re-run from the project directory.

### `Cannot reach agent at IP:PORT`

- Both phones must be on the same WiFi network
- Confirm the agent is running on the target: `tmux list-sessions`
- Confirm the port is correct (default `8765`)
- Check Android is not blocking the port: try `nc -zv IP 8765` from the controller

### `Authentication failed (HTTP 401)`

The `LAUNCHAPP_TOKEN` on the controller does not match the token the agent was started with. Copy the full token from `~/.launchapp/token` on the target phone and export it on the controller.

### `ADB connect failed`

- Wireless Debugging must be enabled in Developer Options on the target
- For Android 11+, you must complete the pairing step first (Settings → Developer Options → Wireless Debugging → Pair device with pairing code)
- Both phones must be on the same WiFi network
- Try `adb devices` to confirm the target appears

### Agent is killed when screen turns off

Battery optimisation is killing Termux. Set Termux to **Unrestricted** battery in Android Settings, or run the agent inside a tmux session.

### `logcat is not accessible on this Android version`

Future Android versions may restrict logcat for non-system processes. Use ADB or agent transport instead:

```bash
launchapp -r --adb 192.168.1.42:5555 com.example.myapp crash
```

### Crash notifications are not working

Both `termux-api` (the Termux package) and the **Termux:API** app (from F-Droid or Play Store) must be installed and at compatible versions. Run `termux-info` to check. If it hangs, the Termux:API app is either not installed or is version-mismatched — reinstall it.