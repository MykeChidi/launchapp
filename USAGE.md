# Usage Guide

Complete command reference for launchapp.

---

## Table of contents

- [Syntax](#syntax)
- [App argument](#app-argument)
- [Modes](#modes)
  - [launch](#launch)
  - [debug](#debug)
  - [monitor](#monitor)
  - [crash](#crash)
  - [perf](#perf)
  - [network](#network)
  - [info](#info)
  - [install](#install)
  - [top](#top)
- [Remote mode (`-r`)](#remote-mode--r)
  - [Agent connection](#agent-connection)
  - [ADB connection](#adb-connection)
  - [Network scan](#network-scan)
  - [Interactive menus](#interactive-menus)
- [Global options](#global-options)
- [Subcommands](#subcommands)
  - [alias](#alias)
  - [list](#list)
  - [attach](#attach)
  - [history](#history)
  - [cache](#cache)
- [Log saving](#log-saving)
- [Examples](#examples)

---

## Syntax

```
launchapp [options] <app> [mode] [mode-options]
launchapp [options] <subcommand> [args]
launchapp -r [connection] [<app>] [mode] [mode-options]
```

---

## App argument

The `<app>` argument accepts three forms:

**Short alias** — built-in names for common apps:

```bash
launchapp chrome debug
launchapp spotify monitor
launchapp youtube perf
```

Built-in aliases: `chrome`, `youtube`, `spotify`, `gmail`, `maps`, `whatsapp`, `telegram`, `instagram`, `netflix`, `settings`, `calculator`, `camera`, `files`, `clock`, `contacts`, `dialer`, `messages`, `photos`, `drive`, `meet`, `tiktok`, `discord`, `reddit`, `snapchat`, `linkedin`, `zoom`, `firefox`

**Full package name:**

```bash
launchapp com.example.myapp debug
launchapp com.android.chrome monitor
```

**User alias** — names you define yourself:

```bash
launchapp alias add myapp com.example.myapp
launchapp myapp debug
```

If the app is not found, launchapp prints the resolved package and suggests running `launchapp list` to search.

---

## Modes

### launch

Default mode. Launches the app and exits.

```bash
launchapp chrome
launchapp com.example.myapp launch   # explicit
```

### debug

Opens a 6-window tmux session with all debug views running in parallel.

```bash
launchapp chrome debug
launchapp com.example.myapp debug --save
```

**Windows:**

| # | Name | Content |
|---|------|---------|
| 0 | Logs | Full logcat stream filtered to the app + control REPL in lower pane |
| 1 | Errors | `*:E *:F` errors and fatal exceptions |
| 2 | Activity | Activity lifecycle events (`ActivityManager`, `ActivityTaskManager`) |
| 3 | Crashes | Crash + ANR monitor with notifications |
| 4 | Performance | Memory, battery, GC — refreshes every 3 seconds |
| 5 | Network | HTTP/OkHttp/Retrofit/Volley call activity from logcat |
| 6 | Stats | System CPU/RAM/battery (agent transport only) |

**Control REPL (window 0, lower pane):**

```
Commands: launch  kill  restart  clear  info  meminfo  exit
> restart
> meminfo
> clear
```

**tmux key bindings:**

| Keys | Action |
|------|--------|
| `Ctrl+b 0–9` | Switch windows |
| `Ctrl+b ↑↓` | Switch panes |
| `Ctrl+b d` | Detach (session stays alive) |
| `Ctrl+b &` | Kill current window |

Reattach later with `launchapp attach`.

### monitor

Split-pane live monitor with an interactive control menu.

```bash
launchapp spotify monitor
launchapp com.example.myapp monitor --save
```

Combines logcat, crash detection, memory, and battery into a single tmux session with an interactive app control panel.

### crash

Foreground crash and ANR watcher. Streams logcat and highlights `FATAL EXCEPTION` and `ANR in` events.

```bash
launchapp com.example.myapp crash
launchapp com.example.myapp crash --watch
launchapp com.example.myapp crash --watch --save
```

**`--watch`** — automatically force-stops and relaunches the app after each detected crash. Useful for soak testing.

Each detected crash:
- Prints the timestamp and crash line
- Sends a Termux notification (if Termux:API is available)
- Triggers vibration
- Appends to `~/launchapp_logs/crash_summary.log`

### perf

Live performance dashboard. Refreshes every 3 seconds.

```bash
launchapp chrome perf
launchapp com.example.myapp perf
```

Displays:
- Heap summary (Total PSS, Native Heap, Dalvik Heap, Java Heap)
- Battery level, status, temperature
- Recent GC events from dalvikvm logcat

### network

Logcat-based network call monitor. Filters for HTTP, OkHttp, Retrofit, Volley, and socket-related log lines.

```bash
launchapp chrome network
launchapp com.example.myapp network --save
```

This works without root and without a proxy — it reads whatever the app logs to logcat. Apps that suppress network logging will not appear here. For raw packet inspection, use `launchapp -r scan` and select **Network traffic** mode (requires root + tcpdump).

### info

Prints app identity, main activity, granted permissions, declared activities, and install paths.

```bash
launchapp chrome info
launchapp com.example.myapp info
```

Output sections: Identity (version, install/update time, UID), Main activity, Permissions (granted only), Activities, Size (codePath, dataDir).

### install

Installs an APK file. Local transport only.

```bash
launchapp myapp.apk install
launchapp /sdcard/Downloads/myapp-release.apk install
```

Equivalent to `adb install -r -t`. Prints success or failure and exits.

### top

Live running process list with PID and memory, sorted by memory usage. Refreshes every 3 seconds.

```bash
launchapp top
```

Shows up to 15 processes. Press `Ctrl+C` to exit.

---

## Remote mode (`-r`)

Add `-r` or `--remote` to run any mode against another phone instead of the current one. The transport (agent or ADB) is selected by the connection flag.

```bash
launchapp -r --connect IP[:PORT] <app> [mode]
launchapp -r --adb DEVICE_ID    <app> [mode]
```

### Agent connection

Requires the agent to be running on the target phone. See [SETUP.md](SETUP.md) for agent setup.

```bash
# Basic connection (default port 8765)
launchapp -r --connect 192.168.1.42 chrome debug

# Custom port
launchapp -r --connect 192.168.1.42:9000 spotify monitor

# Pass token inline instead of via env var
launchapp -r --connect 192.168.1.42 --token your_token chrome crash
```

**Token resolution order:**

1. `--token TOKEN` flag
2. `LAUNCHAPP_TOKEN` environment variable
3. `~/.launchapp/token` file (read at agent startup, not automatically by controller)

### ADB connection

```bash
# Connect to a device already paired and listed in adb devices
launchapp -r --adb 192.168.1.42:5555 chrome debug

# Works with any ADB device ID format
launchapp -r --adb emulator-5554 com.example.myapp crash
```

If the device is not already connected, launchapp will attempt `adb connect` automatically.

### Network scan

Scans the local WiFi subnet for devices, probes each one for agent and ADB availability, and presents an interactive onboarding menu.

```bash
launchapp -r scan
```

The scan uses `nmap` (`pkg install nmap`) and checks each discovered IP for:
- Agent HTTP server on port 8765
- ADB port 5555

After selecting a device and connection mode, it is saved to `~/.launchapp/devices.json` for future use.

### Interactive menus

If `-r` is used without specifying an app or mode, launchapp shows an interactive menu:

```bash
launchapp -r --connect 192.168.1.42    # remote menu for this device
launchapp -r                           # scan/select menu
```

**Remote menu options:**

```
1. debug      6-window tmux session
2. monitor    split-pane live monitor
3. crash      crash + ANR watcher
4. perf       performance dashboard
5. network    network call monitor
6. launch     launch an app
7. info       app info
8. top        live process list
9. network traffic (tcpdump — root required)
0. Exit
```

**Scan menu options:**

```
1. Scan network for devices
2. Select saved device
3. List saved devices
4. Remove device
5. Run agent on this phone
0. Exit
```

---

## Global options

| Option | Description |
|--------|-------------|
| `-r`, `--remote` | Enable remote mode |
| `--connect IP[:PORT]` | Connect via agent HTTP |
| `--adb DEVICE_ID` | Connect via ADB wireless |
| `--token TOKEN` | Agent auth token (overrides `LAUNCHAPP_TOKEN`) |
| `--save` | Save logs to `~/launchapp_logs/` |
| `--watch` | Auto-restart app on crash (crash mode only) |
| `-v` | Verbose output (`LAUNCHAPP_DEBUG=1`) |
| `--version` | Print version and exit |
| `-h`, `--help` | Print usage and exit |

---

## Subcommands

### alias

Manage short names for packages. Aliases take precedence over built-in names.

```bash
launchapp alias list
launchapp alias add myapp com.example.myapp
launchapp alias add myapp com.example.myapp/.MainActivity   # with explicit activity
launchapp alias remove myapp
```

Aliases are stored in `~/.launchapp/aliases` (plain `name=value` format, one per line).

### list

List installed user packages. Optionally filter by name or package substring.

```bash
launchapp list
launchapp list google
launchapp list example
```

### attach

Reattach to a running launchapp tmux session.

```bash
launchapp attach           # shows a numbered list if multiple sessions exist
launchapp attach chrome    # attaches to the first session matching "chrome"
launchapp attach dbg_com.android.chrome
```

Session name prefixes: `dbg_` (debug), `mon_` (monitor), `adg_` (agent debug), `amon_` (agent monitor), `adbg_` (ADB debug), `net_` (network traffic).

### history

Show the cumulative crash and ANR history log.

```bash
launchapp history
```

Crashes are appended to `~/launchapp_logs/crash_summary.log` by crash mode and the crash window in debug mode. The history command just cats that file with a header.

### cache

Manage the activity resolution cache. The cache stores resolved `package/activity` strings so launchapp does not have to call `pm dump` on every invocation.

```bash
launchapp cache clear            # clear all cached entries
launchapp cache clear chrome     # clear cache for one package
```

The cache is version-keyed — if you update an app, its cache entry is automatically invalidated on next resolution. Manual clearing is only needed if an app's activity changes without a version bump (rare, but possible with debug builds).

---

## Log saving

Add `--save` to any mode that supports it (debug, monitor, crash, network) to write log output to timestamped files in `~/launchapp_logs/`.

```bash
launchapp com.example.myapp crash --save
launchapp com.example.myapp debug --save
```

Files created per session:

| File | Contents |
|------|---------|
| `DDMMYYYY_HHMMSS_pkg_main.log` | Main logcat stream |
| `DDMMYYYY_HHMMSS_pkg_errors.log` | Error/fatal stream |
| `DDMMYYYY_HHMMSS_pkg_crashes.log` | Crash/ANR events only |
| `DDMMYYYY_HHMMSS_pkg_network.log` | Network log lines |
| `crash_summary.log` | Cumulative crash history (all sessions) |

The log directory can be changed with `LAUNCHAPP_LOG_DIR`:

```bash
export LAUNCHAPP_LOG_DIR=/sdcard/mylogs
```

---

## Examples

```bash
# Launch and immediately open a 6-window debug session
launchapp com.example.myapp debug

# Watch for crashes and auto-restart, saving everything
launchapp com.example.myapp crash --watch --save

# Check what version is installed and what permissions it has
launchapp com.example.myapp info

# See all running apps and their memory usage
launchapp top

# Find packages matching a name
launchapp list example

# Save an alias so you don't have to type the package name
launchapp alias add myapp com.example.myapp
launchapp myapp debug

# Install a new build and immediately start monitoring
launchapp /sdcard/Downloads/myapp-debug.apk install
launchapp myapp crash --watch

# Remote: debug an app on another phone via agent
export LAUNCHAPP_TOKEN=$(cat ~/.launchapp/token)
launchapp -r --connect 192.168.1.42 com.example.myapp debug --save

# Remote: connect via ADB and watch for crashes
launchapp -r --adb 192.168.1.42:5555 com.example.myapp crash

# Remote: scan network and pick a device interactively
launchapp -r scan

# Reattach to a debug session you detached from
launchapp attach myapp

# Clear a stale activity cache entry after modifying a debug build
launchapp cache clear com.example.myapp
```