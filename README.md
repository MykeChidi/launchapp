# launchapp

Android debug toolkit for Termux. Full logcat sessions, crash watching, performance dashboards, and network monitoring — on your phone or a remote one — with identical commands either way.

```bash
launchapp chrome debug                            # debug Chrome on this phone
launchapp -r --connect 192.168.1.42 chrome debug  # debug Chrome on that phone
```

Same 6-window tmux session. Same control REPL. Same output. The modes are transport-agnostic — they have no idea whether they're running locally or remotely.

---

## Install

Install from source:

```bash
git clone https://github.com/MykeChidi/launchapp
cd launchapp && bash install.sh
```

For remote debugging, also install:

```bash
pkg install curl jq nmap android-tools termux-api
```

> **Termux must come from F-Droid**, not the Play Store. The Play Store version is abandoned and has broken packages.

---

## Quick start

```bash
launchapp list                        # see all installed apps
launchapp chrome debug                # 6-window debug session
launchapp myapp crash --watch         # crash watcher, auto-restart on FATAL/ANR
launchapp youtube perf                # live performance dashboard
launchapp com.example.myapp info      # version, permissions, activities
```

---

## Modes

Every mode works identically across all three transports.

| Mode | What opens |
|---|---|
| `debug` | 6-window tmux: Logs, Errors, Activity, Crashes, Perf, Network |
| `monitor` | 2-pane live monitor with keyboard controls |
| `crash` | Foreground watcher — push notification + vibrate on FATAL/ANR |
| `perf` | Memory, GC events, battery — refreshes every 3s |
| `network` | Logcat network sniffer — no root required |
| `info` | Version, permissions, and activities from `pm dump` |
| `top` | Live running app list with memory usage |
| `launch` | Just launch the app |

---

## Transports

| Transport | How | Logcat |
|---|---|---|
| `local` | Direct `am`/`pm`/`logcat` on this phone | Live stream |
| `adb` | ADB wireless — `adb -s DEVICE shell …` | Live stream |
| `agent` | HTTP — `curl http://DEVICE:PORT/…` | 2s poll |

> ADB and local have 100% feature parity. Agent transport is ~95% — the only gap is logcat polled every 2 seconds instead of streamed.

---

## Remote debugging

### Agent transport

Run this on the **target phone** (the one you want to debug):

```bash
launchapp-agent --gen-token          # generate a token
export LAUNCHAPP_TOKEN='your-token'
launchapp -r --agent                 # start the agent
# prints: Listen: http://192.168.1.42:8765
```

Then on the **controller phone**:

```bash
export LAUNCHAPP_TOKEN='your-token'  # same token
launchapp -r --connect 192.168.1.42 chrome debug
```

### ADB wireless transport

On the **target phone**: Settings → Developer Options → Wireless Debugging → Enable → Pair device with pairing code.

On the **controller phone**:

```bash
launchapp -r scan       # interactive scan + pairing
# or connect directly:
launchapp -r --adb 192.168.1.42:5555 chrome debug
```

---

## App argument

`<app>` resolves in this order: custom alias → built-in alias → full package name.

```bash
launchapp chrome debug                  # built-in alias
launchapp myapp debug                   # your custom alias
launchapp com.example.myapp debug       # full package name
```

Built-in aliases: `chrome` `youtube` `spotify` `gmail` `maps` `whatsapp` `telegram` `instagram` `twitter` `netflix` `settings` `camera` `files` `clock` `contacts` `dialer` `messages` `photos` `drive` `meet` `tiktok` `discord` `reddit` `snapchat` `linkedin` `zoom` `vlc` `firefox`

Add your own:

```bash
launchapp alias add myapp com.example.myapp
launchapp alias add myapp com.example.myapp/.ui.MainActivity   # specific activity
launchapp alias list
launchapp alias remove myapp
```

---

## All commands

```
launchapp <app> [mode] [options]
launchapp list [filter]
launchapp top
launchapp attach [session]
launchapp history
launchapp alias add|remove|list [name] [pkg]
launchapp cache clear [package]

launchapp -r --connect IP[:PORT] [app] [mode] [options]
launchapp -r --adb DEVICE_ID [app] [mode] [options]
launchapp -r --connect IP[:PORT]          interactive menu
launchapp -r                              scan / pick saved device
launchapp -r --agent                      start agent on this phone
launchapp -r scan                         nmap scan + onboarding
```

**Options:**

| Flag | Description |
|---|---|
| `--save` | Save logs to `~/launchapp_logs/` |
| `--watch` | Auto-restart app after crash (crash mode) |
| `--token TOKEN` | Agent auth token |
| `-v` | Verbose output |

---

## Authentication

The agent requires a token. Without one it refuses to start.

```bash
launchapp-agent --gen-token
# → Generated token: a3f8c2d1e4b56789…

export LAUNCHAPP_TOKEN='a3f8c2d1e4b56789…'
```

Set the same token on both phones. Add it to `~/.bashrc` to make it permanent:

```bash
echo "export LAUNCHAPP_TOKEN=\$(cat ~/.launchapp/token)" >> ~/.bashrc
```

To run without authentication on a private network only:

```bash
launchapp-agent --no-auth
```

---

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `LAUNCHAPP_TOKEN` | — | Agent auth token |
| `LAUNCHAPP_CONFIG_DIR` | `~/.launchapp` | Config, aliases, device registry, cache |
| `LAUNCHAPP_LOG_DIR` | `~/launchapp_logs` | Log file output |
| `LAUNCHAPP_DATA_DIR` | auto | Override library file location |
| `LAUNCHAPP_DEBUG` | `0` | Set to `1` for verbose output |

---

## Requirements

| Package | Needed for | Install |
|---|---|---|
| `tmux` | All debug/monitor modes | auto with `pkg install launchapp` |
| `python` | Agent | auto with `pkg install launchapp` |
| `curl` | Agent transport | `pkg install curl` |
| `jq` | Remote device management | `pkg install jq` |
| `nmap` | Network scan | `pkg install nmap` |
| `android-tools` | ADB transport | `pkg install android-tools` |
| `termux-api` | Push notifications on crash | F-Droid + `pkg install termux-api` |

---

## Android version notes

| Android | Status |
|---|---|
| 11+ | Full support including ADB wireless pairing |
| 10 | Full support — ADB connects directly without pairing code |
| 7–9 | Core features work; some OEM restrictions possible |

launchapp detects restricted capabilities at startup and degrades gracefully with a clear message rather than silently producing empty output.

---

## License

MIT — see [LICENSE](LICENSE).
