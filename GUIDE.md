# launchapp Guide

Complete usage guide. Everything from basic commands to remote debugging workflows to the agent API.

---

## App argument

`<app>` is how you tell launchapp which app to target. It resolves in this order:

1. **Custom alias** — a short name you saved with `launchapp alias add`
2. **Built-in alias** — `chrome`, `spotify`, `youtube`, and 27 others
3. **Full package name** — `com.example.myapp`
4. **APK path** — `/sdcard/myapp.apk` (install mode only)

If the package is not installed, launchapp exits with an error and tells you what it tried.

```bash
launchapp chrome debug              # built-in alias
launchapp myapp debug               # custom alias
launchapp com.example.myapp debug   # full package name
launchapp /sdcard/app-debug.apk install
```

---

## Modes

### debug

```bash
launchapp <app> debug [--save]
```

Opens a tmux session named `dbg_<pkg>` with 6 windows:

| # | Window | Content |
|---|---|---|
| 0 | Logs | Main logcat filtered to the package + AndroidRuntime. Bottom pane: control REPL. |
| 1 | Errors | `*:E *:F` filter — FATAL, ANR, exceptions |
| 2 | Activity | ActivityManager lifecycle events for this package |
| 3 | Crashes | Crash + ANR watcher with push notification on detection |
| 4 | Perf | Memory, GC events, battery — refreshes every 3s |
| 5 | Network | Logcat filtered by HTTP/API/socket keywords |

**Control REPL** (bottom pane of window 0):

```
launch    start the app
kill      force-stop
restart   force-stop then launch
clear     pm clear (wipes app data and cache)
info      pm dump first 40 lines
meminfo   current memory breakdown
exit      close this pane
```

**tmux keys:**

| Keys | Action |
|---|---|
| `Ctrl+b 0`–`5` | Switch window |
| `Ctrl+b ↑/↓` | Switch pane |
| `Ctrl+b d` | Detach (session stays alive) |

`--save` writes all log streams to `~/launchapp_logs/TIMESTAMP_pkg_*.log`.

---

### monitor

```bash
launchapp <app> monitor [--save]
```

Lighter than debug — two panes, no multi-window.

- Top: live logcat with timestamps, filtered to the package
- Bottom: stats bar — memory, battery, temperature — refreshes every 3s

**Keyboard controls in the bottom pane:**

| Key | Action |
|---|---|
| `l` | Launch |
| `k` | Kill |
| `r` | Restart |
| `q` | Quit |

---

### crash

```bash
launchapp <app> crash [--watch] [--save]
```

Foreground mode — stays in your terminal, no tmux.

1. Clears the logcat buffer
2. Launches the app
3. Streams `*:E *:F` logcat watching for `FATAL EXCEPTION` and `ANR in` lines
4. On each crash event:
   - Prints timestamped line to the terminal
   - Appends to `~/launchapp_logs/crash_summary.log`
   - Fires a push notification (if Termux:API is installed and working)
   - Vibrates (if Termux:API is installed and working)

`--watch` — after each crash, automatically force-stops, waits 2 seconds, and relaunches. Crashes are numbered sequentially. Stop with `Ctrl+C`.

`--save` — additionally saves a dated crash log per session.

> If logcat is restricted on your Android version, crash mode will tell you and suggest ADB or agent transport as alternatives.

---

### perf

```bash
launchapp <app> perf
```

Foreground dashboard. Clears screen and refreshes every 3 seconds.

- **Memory** — TOTAL, Native Heap, Dalvik Heap, Graphics from `dumpsys meminfo`. If the format has changed on your Android version it prints the raw output rather than silently showing nothing.
- **CPU** — user+sys ticks from `/proc/PID/stat` (local transport only — restricted on Android 10+)
- **Threads/FDs** — thread count and open file descriptor count (local only)
- **GC events** — last 3 lines from `dalvikvm` tag (pre-Android 14) and `art` tag (Android 14+)
- **Battery** — level, temperature, status, plugged state

---

### network

```bash
launchapp <app> network [--save]
```

Foreground logcat filter watching for network-related keywords in your package's logs. No root required.

Watches for: `https?://` `okhttp` `retrofit` `volley` `request` `response` `.json` `api/` `socket` `dns` `grpc` `websocket` `connect` `url` `endpoint`

---

### info

```bash
launchapp <app> info
```

Prints a formatted summary from `pm dump`:

- Version name and code
- Install and last-update timestamps
- UID
- Main activity (resolved)
- Granted dangerous permissions
- All declared activities (first 10)
- Code path and data directory

---

### top

```bash
launchapp top
```

No app argument needed. Live table of running third-party apps sorted by memory. Refreshes every 3 seconds. Shows top 15 by memory. Stop with `Ctrl+C`.

---

### install

```bash
launchapp /sdcard/Download/myapp.apk install
```

Installs an APK via `pm install -r -t`. Local transport only.

---

### launch

```bash
launchapp <app>
launchapp <app> launch
```

Just launches the app and exits. Default if no mode is specified.

---

## Other commands

### list

```bash
launchapp list [filter]
```

Lists all installed third-party packages. Optional case-insensitive filter.

```bash
launchapp list              # all user apps in columns
launchapp list google       # apps containing "google"
launchapp list shop         # apps containing "shop"
```

---

### attach

```bash
launchapp attach [pattern]
```

Reattaches to a running launchapp tmux session. With a pattern, attaches to the first match. Without, shows a numbered list.

```bash
launchapp attach            # pick from list
launchapp attach chrome     # reattach to Chrome's debug session
```

---

### history

```bash
launchapp history
```

Shows the last 50 entries from `~/launchapp_logs/crash_summary.log`. Each entry has a timestamp, crash type, and the log line.

---

### alias

```bash
launchapp alias add <name> <package[/activity]>
launchapp alias remove <name>
launchapp alias list
```

Custom short names for apps. Stored in `~/.launchapp/aliases`.

```bash
launchapp alias add myapp com.example.myapp
launchapp alias add myapp com.example.myapp/.ui.SplashActivity
launchapp alias list
launchapp alias remove myapp
```

Specifying a full `pkg/activity` string bypasses the activity resolution lookup — useful if the auto-detection guesses wrong.

---

### cache

```bash
launchapp cache clear [package]
```

The activity cache has a 1-hour TTL and auto-invalidates when the app is updated. Clear it manually if you're getting stale launch failures:

```bash
launchapp cache clear                     # all packages
launchapp cache clear com.example.myapp   # one package
```

---

## Remote mode

### Connect via agent

```bash
launchapp -r --connect 192.168.1.42 <app> <mode>
launchapp -r --connect 192.168.1.42:9000 <app> <mode>   # custom port
```

Connects to an agent running on the target phone. After connecting, runs exactly the same mode you'd run locally.

### Connect via ADB wireless

```bash
launchapp -r --adb 192.168.1.42:5555 <app> <mode>
```

Connects via Android's built-in ADB wireless. No agent needed on the target.

### Interactive menus

```bash
launchapp -r                              # scan menu — scan network or pick saved device
launchapp -r --connect 192.168.1.42       # connect then show mode menu
launchapp -r --adb 192.168.1.42:5555      # connect then show mode menu
```

### Network scan

```bash
launchapp -r scan
```

Runs an nmap sweep of your local /24 network. For each device found, probes port 8765 (agent) and port 5555 (ADB) in parallel. Lets you select a device and connection type, then saves it to `~/.launchapp/devices.json` for future use.

### Start the agent on this phone

```bash
launchapp -r --agent
```

Starts the HTTP monitoring agent on this phone so another phone can connect to it.

---

## Agent

The agent (`launchapp-agent` / `agent.py`) is an HTTP server that runs on the target phone and exposes the Android debug APIs over a REST interface. The controller's transport layer translates `transport_*` calls into HTTP requests.

### Starting the agent

```bash
# Standard — token from environment
export LAUNCHAPP_TOKEN='your-token'
launchapp -r --agent

# With explicit token
launchapp-agent --token 'your-token'

# With custom port
launchapp-agent --token 'your-token' --port 9000

# Restrict which IPs can connect
launchapp-agent --token 'your-token' --allow-ip 192.168.1.100
launchapp-agent --token 'your-token' --allow-ip 192.168.1.0/24

# Generate a token and exit (use this output to set up)
launchapp-agent --gen-token

# Explicitly opt out of authentication (private networks only)
launchapp-agent --no-auth
```

### Background agent

```bash
nohup launchapp-agent --token $(cat ~/.launchapp/token) > ~/agent.log 2>&1 &
echo $! > ~/agent.pid

# Monitor
tail -f ~/agent.log

# Stop
kill $(cat ~/agent.pid)
# or:
pkill -f launchapp-agent
```

### Agent REST API

All endpoints require the `X-Launchapp-Token` header when authentication is enabled.

| Method | Endpoint | Description |
|---|---|---|
| GET | `/info` | Device model, Android version, IP, agent version |
| GET | `/packages` | List of all installed packages |
| GET | `/pid/<pkg>` | PID and running state |
| GET | `/meminfo/<pkg>` | Memory breakdown (dumpsys meminfo format) |
| GET | `/battery` | Battery level, temperature, status |
| GET | `/logs/<pkg>` | Recent logcat lines for package (`?lines=N&level=E`) |
| POST | `/launch/<pkg>` | Launch the package |
| POST | `/kill/<pkg>` | Force-stop the package |

Rate limits: control endpoints (launch/kill) 5 req/3s. Log endpoints 20 req/5s. Stats 10 req/5s.

---

## Token setup

The token is a 64-character hex string used to authenticate agent requests. Set it the same way on both phones.

```bash
# Generate once on the target phone
launchapp-agent --gen-token
# → Generated token: a3f8c2d1e4b56789...

# Save to file
echo 'a3f8c2d1e4b56789...' > ~/.launchapp/token
chmod 600 ~/.launchapp/token

# Add to shell (permanent)
echo 'export LAUNCHAPP_TOKEN=$(cat ~/.launchapp/token)' >> ~/.bashrc
source ~/.bashrc
```

Copy the token string to the controller phone and repeat the last two steps.

**The token is never stored in `devices.json`** — it would be exposed in backups and syncs. It's always loaded from the environment or `~/.launchapp/token` at connect time.

---

## Options reference

| Flag | Applies to | Description |
|---|---|---|
| `--save` | debug, monitor, crash, network | Save log streams to `~/launchapp_logs/` |
| `--watch` | crash | Auto-restart app after each FATAL/ANR |
| `--debug` | all | Verbose output to stderr |
| `-r`, `--remote` | all | Enable remote mode |
| `--connect IP[:PORT]` | remote | Connect via agent HTTP |
| `--adb DEVICE_ID` | remote | Connect via ADB wireless |
| `--token TOKEN` | remote | Agent auth token (or set `LAUNCHAPP_TOKEN`) |

`--connect` and `--adb` also accept the `=` form: `--connect=192.168.1.42`.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `LAUNCHAPP_TOKEN` | — | Agent auth token. Must match on both phones. |
| `LAUNCHAPP_CONFIG_DIR` | `~/.launchapp` | Config directory. |
| `LAUNCHAPP_LOG_DIR` | `~/launchapp_logs` | Log output directory. |
| `LAUNCHAPP_DATA_DIR` | auto-detected | Override library file location. |
| `LAUNCHAPP_DEBUG` | `0` | Set to `1` for verbose script output. |

`LAUNCHAPP_DATA_DIR` is for advanced use — set it if you're running launchapp from a non-standard location and it can't find its library files.

---

## Built-in aliases

```
chrome      com.android.chrome
youtube     com.google.android.youtube
yt          com.google.android.youtube
spotify     com.spotify.music
gmail       com.google.android.gm
maps        com.google.android.apps.maps
whatsapp    com.whatsapp
telegram    org.telegram.messenger
instagram   com.instagram.android
twitter     com.twitter.android
netflix     com.netflix.mediaclient
settings    com.android.settings
calculator  com.android.calculator2
camera      com.android.camera2
files       com.android.documentsui
clock       com.android.deskclock
contacts    com.android.contacts
dialer      com.android.dialer
messages    com.google.android.apps.messaging
photos      com.google.android.apps.photos
drive       com.google.android.apps.docs
meet        com.google.android.apps.tachyon
tiktok      com.zhiliaoapp.musically
discord     com.discord
reddit      com.reddit.frontpage
snapchat    com.snapchat.android
linkedin    com.linkedin.android
zoom        us.zoom.videomeetings
vlc         org.videolan.vlc
firefox     org.mozilla.firefox
```

---

## Log file format

When `--save` is used, files are created at:

```
~/launchapp_logs/YYYYMMDD_HHMMSS_<pkg>_<stream>.log
```

Streams: `main`, `errors`, `crashes`, `network`

`crash_summary.log` is a rolling append log across all sessions:

```
2024-01-15 14:23:01 CRASH #1: E/AndroidRuntime: FATAL EXCEPTION: main
2024-01-15 14:23:01 CRASH #1: E/AndroidRuntime: Process: com.example.app, PID: 12345
```

---

## Android version compatibility

| Feature | Android 7-9 | Android 10 | Android 11-14 |
|---|---|---|---|
| Local debug/monitor/crash | ✓ | ✓ | ✓ |
| `/proc` CPU stats | ✓ | Restricted | Restricted |
| ADB wireless (direct) | ✓ | ✓ | ✓ (also supports pairing code) |
| ADB wireless (pairing code) | ✗ | ✗ | ✓ |
| Agent transport | ✓ | ✓ | ✓ |
| Logcat (Termux shell) | ✓ | ✓ | ✓ (may change in future) |

launchapp checks capabilities at startup and tells you when something isn't available on your Android version, rather than silently producing empty output.
