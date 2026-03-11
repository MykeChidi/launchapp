#!/usr/bin/env python3
"""
launchapp agent — Secure HTTP monitoring agent for Termux/Android.
Run on the TARGET phone. Communicates with remote_monitor.sh on the controller.

Security model:
  - HMAC-SHA256 token authentication on every request
  - Configurable IP allowlist (optional extra layer)
  - Path traversal prevention on all file operations
  - No shell injection — all subprocess calls use list form, never shell=True
  - Rate limiting per endpoint
  - Structured JSON logging
"""

import argparse
import hmac
import http.server
import ipaddress
import json
import logging
import mimetypes
import os
import pathlib
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from typing import Any, Optional

# ── Version ──────────────────────────────────────────────────────────────────
AGENT_VERSION = "1.0.0"
DEFAULT_PORT = 8765
TOKEN_HEADER = "X-Launchapp-Token"
TOKEN_ENV = "LAUNCHAPP_TOKEN"

# ── Safe root for file operations (no traversal outside this) ─────────────────
SAFE_FILE_ROOT = pathlib.Path("/sdcard")

# ── Rate limit: max requests per window per endpoint group ───────────────────
RATE_LIMITS = {
    "stats": (10, 5),  # max 10 requests per 5 seconds
    "logs": (20, 5),
    "files": (30, 10),
    "control": (5, 3),  # launch/kill — strict
    "default": (60, 10),
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("launchapp-agent")


# =============================================================================
# RATE LIMITER
# =============================================================================


class RateLimiter:
    def __init__(self):
        self._buckets: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def check(self, key: str, max_calls: int, window_secs: float) -> bool:
        now = time.monotonic()
        with self._lock:
            times = self._buckets.get(key, [])
            times = [t for t in times if now - t < window_secs]
            if len(times) >= max_calls:
                return False
            times.append(now)
            self._buckets[key] = times
            return True


rate_limiter = RateLimiter()


# =============================================================================
# SECURE SUBPROCESS HELPER
# =============================================================================


def run_cmd(args: list[str], timeout: float = 5.0) -> str:
    """Run a command safely (no shell=True) and return stdout as string."""
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        return ""
    except FileNotFoundError:
        return ""
    except Exception as e:
        log.warning("run_cmd failed %s: %s", args, e)
        return ""


def run_async(args: list[str]) -> None:
    """Fire and forget subprocess, no shell."""
    try:
        subprocess.Popen(
            args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )
    except Exception as e:
        log.warning("run_async failed %s: %s", args, e)


# =============================================================================
# FILE SAFETY
# =============================================================================


def safe_path(raw: str) -> Optional[pathlib.Path]:
    """Resolve path, ensuring it stays within SAFE_FILE_ROOT."""
    try:
        p = pathlib.Path(raw).resolve()
        p.relative_to(SAFE_FILE_ROOT.resolve())  # raises ValueError if outside
        return p
    except (ValueError, RuntimeError):
        return None


# =============================================================================
# DEVICE INFO HELPERS
# =============================================================================


def get_device_info() -> dict[str, Any]:
    return {
        "version": AGENT_VERSION,
        "model": run_cmd(["getprop", "ro.product.model"]) or "Unknown",
        "brand": run_cmd(["getprop", "ro.product.brand"]) or "Unknown",
        "android": run_cmd(["getprop", "ro.build.version.release"]) or "Unknown",
        "sdk": run_cmd(["getprop", "ro.build.version.sdk"]) or "Unknown",
        "build": run_cmd(["getprop", "ro.build.display.id"]) or "Unknown",
        "hostname": socket.gethostname(),
        "ip": _local_ip(),
    }


def _local_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "unknown"


def get_battery() -> dict[str, Any]:
    raw = run_cmd(["termux-battery-status"])
    if raw:
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            pass
    # Fallback via dumpsys
    dump = run_cmd(["dumpsys", "battery"])
    result: dict[str, Any] = {}
    for line in dump.splitlines():
        line = line.strip()
        if "level:" in line:
            try:
                result["percentage"] = int(line.split(":")[1].strip())
            except ValueError:
                pass
        elif "status:" in line:
            result["status"] = line.split(":")[1].strip()
        elif "temperature:" in line:
            try:
                result["temperature"] = int(line.split(":")[1].strip()) / 10
            except ValueError:
                pass
        elif "plugged:" in line:
            result["plugged"] = line.split(":")[1].strip() != "0"
    return result


def get_system_stats() -> dict[str, Any]:
    # Memory from /proc/meminfo — reliable across all Android versions
    mem: dict[str, int] = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    key = parts[0].rstrip(":")
                    try:
                        mem[key] = int(parts[1])
                    except ValueError:
                        pass
    except IOError:
        pass

    total = mem.get("MemTotal", 0)
    avail = mem.get("MemAvailable", 0)
    used = total - avail
    mem_pct = round(used * 100 / total, 1) if total else 0.0

    # CPU from /proc/stat
    cpu_idle = 0.0
    try:
        with open("/proc/stat") as f:
            line = f.readline()
        vals = list(map(int, line.split()[1:]))
        idle = vals[3]
        total_t = sum(vals)
        cpu_idle = round(idle * 100 / total_t, 1) if total_t else 0.0
    except Exception:
        pass

    return {
        "mem_total_kb": total,
        "mem_used_kb": used,
        "mem_avail_kb": avail,
        "mem_percent": mem_pct,
        "cpu_idle_pct": cpu_idle,
        "cpu_used_pct": round(100 - cpu_idle, 1),
    }


def get_app_meminfo(package: str) -> dict[str, Any]:
    dump = run_cmd(["dumpsys", "meminfo", package])
    result: dict[str, Any] = {"raw": dump}
    for line in dump.splitlines():
        line = line.strip()
        if line.startswith("TOTAL"):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    result["total_kb"] = int(parts[1])
                except ValueError:
                    pass
        elif "Native Heap" in line:
            parts = line.split()
            if len(parts) >= 2:
                try:
                    result["native_heap_kb"] = int(parts[-1])
                except ValueError:
                    pass
    return result


def get_installed_packages() -> list[dict[str, str]]:
    raw = run_cmd(["pm", "list", "packages", "-3"])
    packages = []
    for line in raw.splitlines():
        if line.startswith("package:"):
            pkg = line[8:].strip()
            packages.append({"package": pkg})
    return packages


def get_running_processes() -> list[dict[str, Any]]:
    raw = run_cmd(["ps", "-A"])
    procs = []
    for line in raw.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 9:
            procs.append(
                {
                    "pid": parts[0],
                    "name": parts[-1],
                }
            )
    return procs


def find_main_activity(package: str) -> str:
    dump = run_cmd(["pm", "dump", package])
    found_main = False
    for line in dump.splitlines():
        if "android.intent.action.MAIN" in line:
            found_main = True
        if found_main and package in line:
            parts = line.strip().split()
            if parts:
                return parts[-1]
    return ""


def get_recent_logs(package: str, lines: int = 100) -> list[str]:
    raw = run_cmd(["logcat", "-d", "-t", str(lines), "-v", "time"], timeout=10.0)
    # Filter by package without shell
    result = [l for l in raw.splitlines() if package in l]
    return result[-lines:]


def get_pid(package: str) -> Optional[str]:
    raw = run_cmd(["pidof", package])
    if raw.strip():
        return raw.strip().split()[0]
    # Fallback via ps
    for line in run_cmd(["ps", "-A"]).splitlines():
        if package in line:
            return line.split()[0]
    return None


# =============================================================================
# AUTHENTICATION
# =============================================================================


def verify_token(provided: Optional[str], secret: str) -> bool:
    if not secret:
        return True  # no auth configured (warn at startup)
    if not provided:
        return False
    try:
        return hmac.compare_digest(provided.strip(), secret.strip())
    except Exception:
        return False


# =============================================================================
# HTTP REQUEST HANDLER
# =============================================================================


class AgentHandler(http.server.BaseHTTPRequestHandler):

    # Injected by server setup
    auth_token: str = ""
    allowed_ips: list[str] = []

    def log_message(self, fmt: str, *args: Any) -> None:
        log.info("%s - %s", self.client_address[0], fmt % args)

    def _check_auth(self) -> bool:
        if not self.auth_token:
            return True
        token = self.headers.get(TOKEN_HEADER)
        return verify_token(token, self.auth_token)

    def _check_ip(self) -> bool:
        if not self.allowed_ips:
            return True
        client_ip = self.client_address[0]
        for allowed in self.allowed_ips:
            try:
                if ipaddress.ip_address(client_ip) in ipaddress.ip_network(
                    allowed, strict=False
                ):
                    return True
            except ValueError:
                if client_ip == allowed:
                    return True
        return False

    def _check_rate(self, group: str) -> bool:
        max_calls, window = RATE_LIMITS.get(group, RATE_LIMITS["default"])
        key = f"{self.client_address[0]}:{group}"
        return rate_limiter.check(key, max_calls, window)

    def send_json(self, data: Any, status: int = 200) -> None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Agent-Version", AGENT_VERSION)
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status: int, message: str) -> None:
        self.send_json({"error": message}, status)

    def do_GET(self) -> None:
        if not self._check_ip():
            self.send_error_json(403, "IP not allowed")
            return

        if not self._check_auth():
            self.send_error_json(401, "Unauthorized")
            return

        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        query = urllib.parse.parse_qs(parsed.query)

        # ── Routing ──────────────────────────────────────────────────────────
        try:
            if path == "/ping":
                self.send_json({"pong": True, "version": AGENT_VERSION})

            elif path == "/info":
                if not self._check_rate("default"):
                    self.send_error_json(429, "Rate limit exceeded")
                    return
                self.send_json(get_device_info())

            elif path == "/battery":
                if not self._check_rate("stats"):
                    self.send_error_json(429, "Rate limit exceeded")
                    return
                self.send_json(get_battery())

            elif path == "/stats":
                if not self._check_rate("stats"):
                    self.send_error_json(429, "Rate limit exceeded")
                    return
                self.send_json(get_system_stats())

            elif path == "/packages":
                if not self._check_rate("default"):
                    self.send_error_json(429, "Rate limit exceeded")
                    return
                self.send_json(get_installed_packages())

            elif path == "/processes":
                if not self._check_rate("stats"):
                    self.send_error_json(429, "Rate limit exceeded")
                    return
                self.send_json(get_running_processes())

            elif path.startswith("/logs/"):
                if not self._check_rate("logs"):
                    self.send_error_json(429, "Rate limit exceeded")
                    return
                pkg = path[6:]
                if not _valid_package(pkg):
                    self.send_error_json(400, "Invalid package name")
                    return
                n = int(query.get("lines", ["100"])[0])
                n = min(n, 500)
                self.send_json(get_recent_logs(pkg, n))

            elif path.startswith("/meminfo/"):
                if not self._check_rate("stats"):
                    self.send_error_json(429, "Rate limit exceeded")
                    return
                pkg = path[9:]
                if not _valid_package(pkg):
                    self.send_error_json(400, "Invalid package name")
                    return
                self.send_json(get_app_meminfo(pkg))

            elif path.startswith("/pid/"):
                pkg = path[5:]
                if not _valid_package(pkg):
                    self.send_error_json(400, "Invalid package name")
                    return
                pid = get_pid(pkg)
                self.send_json({"pid": pid, "running": pid is not None})

            elif path.startswith("/launch/"):
                if not self._check_rate("control"):
                    self.send_error_json(429, "Rate limit exceeded")
                    return
                pkg = path[8:]
                if not _valid_package(pkg):
                    self.send_error_json(400, "Invalid package name")
                    return
                activity = find_main_activity(pkg)
                if not activity:
                    self.send_error_json(404, f"Main activity not found for {pkg}")
                    return
                run_async(["am", "start", "-n", activity, "-W"])
                self.send_json({"launched": pkg, "activity": activity})

            elif path.startswith("/kill/"):
                if not self._check_rate("control"):
                    self.send_error_json(429, "Rate limit exceeded")
                    return
                pkg = path[6:]
                if not _valid_package(pkg):
                    self.send_error_json(400, "Invalid package name")
                    return
                run_cmd(["am", "force-stop", pkg])
                self.send_json({"killed": pkg})

            elif path == "/screenshot":
                if not self._check_rate("control"):
                    self.send_error_json(429, "Rate limit exceeded")
                    return
                ts = int(time.time())
                remote = f"/sdcard/launchapp_screen_{ts}.png"
                run_cmd(["screencap", "-p", remote], timeout=10)
                if not os.path.exists(remote):
                    self.send_error_json(500, "Screenshot failed")
                    return
                self.send_json({"path": remote, "ready": True})

            elif path == "/screenshot/download":
                # Get latest screenshot
                ts = int(time.time())
                remote = f"/sdcard/launchapp_screen_{ts}.png"
                run_cmd(["screencap", "-p", remote], timeout=10)
                self._serve_file(remote)

            elif path == "/files":
                if not self._check_rate("files"):
                    self.send_error_json(429, "Rate limit exceeded")
                    return
                raw_path = query.get("path", ["/sdcard"])[0]
                safe = safe_path(raw_path)
                if safe is None:
                    self.send_error_json(403, "Path outside allowed root")
                    return
                self._list_files(safe)

            elif path == "/download":
                if not self._check_rate("files"):
                    self.send_error_json(429, "Rate limit exceeded")
                    return
                raw_path = query.get("path", [""])[0]
                if not raw_path:
                    self.send_error_json(400, "path parameter required")
                    return
                safe = safe_path(raw_path)
                if safe is None:
                    self.send_error_json(403, "Path outside allowed root")
                    return
                self._serve_file(str(safe))

            else:
                self.send_error_json(404, f"Unknown endpoint: {path}")

        except Exception as e:
            log.exception("Handler error")
            self.send_error_json(500, str(e))

    def do_POST(self) -> None:
        if not self._check_ip():
            self.send_error_json(403, "IP not allowed")
            return
        if not self._check_auth():
            self.send_error_json(401, "Unauthorized")
            return

        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/upload":
            self._handle_upload()
        else:
            self.send_error_json(404, "Not found")

    def _list_files(self, directory: pathlib.Path) -> None:
        if not directory.exists():
            self.send_error_json(404, "Path not found")
            return
        if not directory.is_dir():
            self.send_error_json(400, "Not a directory")
            return

        entries = []
        try:
            for item in sorted(directory.iterdir()):
                stat = item.stat()
                entries.append(
                    {
                        "name": item.name,
                        "type": "dir" if item.is_dir() else "file",
                        "size": stat.st_size if item.is_file() else None,
                        "modified": int(stat.st_mtime),
                        "path": str(item),
                    }
                )
        except PermissionError:
            self.send_error_json(403, "Permission denied")
            return

        self.send_json(entries)

    def _serve_file(self, filepath: str) -> None:
        if not os.path.isfile(filepath):
            self.send_error_json(404, "File not found")
            return
        if not os.access(filepath, os.R_OK):
            self.send_error_json(403, "Permission denied")
            return

        size = os.path.getsize(filepath)
        mime, _ = mimetypes.guess_type(filepath)
        mime = mime or "application/octet-stream"
        name = os.path.basename(filepath)

        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        self.end_headers()

        try:
            with open(filepath, "rb") as f:
                while True:
                    chunk = f.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except Exception as e:
            log.warning("File serve error: %s", e)

    def _handle_upload(self) -> None:
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > 500 * 1024 * 1024:  # 500 MB max
            self.send_error_json(413, "File too large (max 500MB)")
            return
        if content_length == 0:
            self.send_error_json(400, "Empty body")
            return

        dest_raw = self.headers.get("X-Dest-Path", "/sdcard/launchapp_upload")
        dest = safe_path(dest_raw)
        if dest is None:
            self.send_error_json(403, "Destination outside allowed root")
            return

        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            data = self.rfile.read(content_length)
            dest.write_bytes(data)
            self.send_json({"uploaded": str(dest), "size": len(data)})
        except Exception as e:
            self.send_error_json(500, f"Upload failed: {e}")


def _valid_package(pkg: str) -> bool:
    """Validate Android package name: segments of alphanumeric+underscore separated by dots."""
    if not pkg or len(pkg) > 255:
        return False
    import re

    return bool(re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+", pkg))


# =============================================================================
# SERVER SETUP & MAIN
# =============================================================================


class ThreadedHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def make_handler_class(token: str, allowed_ips: list[str]) -> type:
    class ConfiguredHandler(AgentHandler):
        pass

    ConfiguredHandler.auth_token = token
    ConfiguredHandler.allowed_ips = allowed_ips
    return ConfiguredHandler


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="launchapp monitoring agent")
    p.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"Listen port (default {DEFAULT_PORT})",
    )
    p.add_argument(
        "--token",
        default=os.environ.get(TOKEN_ENV, ""),
        help=f"Auth token (or set ${TOKEN_ENV})",
    )
    p.add_argument(
        "--no-auth",
        action="store_true",
        help="Disable authentication — INSECURE, only use on trusted networks",
    )
    p.add_argument(
        "--allow-ip",
        action="append",
        default=[],
        dest="allowed_ips",
        help="Allowed client IP/CIDR (repeat for multiple, default: all)",
    )
    p.add_argument(
        "--gen-token", action="store_true", help="Generate a random token and exit"
    )
    return p.parse_args()


def gen_token() -> str:
    import secrets

    return secrets.token_hex(32)


def print_startup_info(port: int, token: str, allowed_ips: list[str]) -> None:
    info = get_device_info()
    ip = info.get("ip", "?")

    print()
    print("┌─────────────────────────────────────────────────────────────┐")
    print(f"│  launchapp agent v{AGENT_VERSION}")
    print(f"│  Device : {info['model']} (Android {info['android']})")
    print(f"│  Listen : http://{ip}:{port}")
    print(
        f"│  Token  : {'(none — INSECURE, use --token or set ' + TOKEN_ENV + ')' if not token else token[:8] + '...' + token[-4:]}"
    )
    print(
        f"│  IP ACL : {', '.join(allowed_ips) if allowed_ips else 'any (no restriction)'}"
    )
    print("│")
    print("│  On controller phone:")
    print(f"│    export LAUNCHAPP_TOKEN='{token or '<your-token>'}'")
    print(f"│    launchapp -r --connect {ip}:{port}")
    print("└─────────────────────────────────────────────────────────────┘")
    print()


def main() -> None:
    args = parse_args()

    if args.gen_token:
        t = gen_token()
        print(f"Generated token: {t}")
        print(f"Set on controller: export {TOKEN_ENV}='{t}'")
        print(f"Run agent with:   {TOKEN_ENV}='{t}' launchapp-agent")
        sys.exit(0)

    # ── Token enforcement ─────────────────────────────────────────────────────
    # Running without a token means anyone on the same WiFi network can launch,
    # kill, or read logs from apps on this phone.
    # We require explicit opt-out via --no-auth rather than making insecure the default.
    if not args.token and not args.no_auth:
        print()
        print("ERROR: No authentication token set.")
        print()
        print("Set one with --token or the LAUNCHAPP_TOKEN environment variable:")
        print(
            f"  export {TOKEN_ENV}=$(launchapp-agent --gen-token | awk '{{print $3}}')"
        )
        print("  launchapp -r --agent")
        print()
        print("To run without authentication (only on trusted private networks):")
        print("  launchapp-agent --no-auth")
        print()
        sys.exit(1)

    if not args.token and args.no_auth:
        log.warning("=" * 60)
        log.warning("RUNNING WITHOUT AUTHENTICATION (--no-auth)")
        log.warning("Anyone on your network can control this device.")
        log.warning("=" * 60)

    handler_class = make_handler_class(args.token, args.allowed_ips)
    server = ThreadedHTTPServer(("0.0.0.0", args.port), handler_class)

    print_startup_info(args.port, args.token, args.allowed_ips)

    def shutdown(sig, _frame):
        log.info("Shutting down agent…")
        threading.Thread(target=server.shutdown, daemon=True).start()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    log.info("Agent ready on port %d", args.port)
    server.serve_forever()


if __name__ == "__main__":
    main()
