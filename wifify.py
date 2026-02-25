#!/usr/bin/env python3
"""wifify — WiFi/network connectivity diagnostics and monitoring (macOS & Linux)."""

import argparse
import json
import os
import platform
import re
import signal
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from rich.console import Console
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.progress import BarColumn, Progress, TextColumn, TimeElapsedColumn, TimeRemainingColumn
from rich.table import Table
from rich.text import Text

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

IS_MACOS = sys.platform == "darwin"
IS_LINUX = sys.platform.startswith("linux")

AIRPORT_CMD = (
    "/System/Library/PrivateFrameworks/Apple80211.framework"
    "/Versions/Current/Resources/airport"
)

PING_TARGETS = {
    "gateway": None,  # filled dynamically
    "dns_google": "8.8.8.8",
    "dns_cloudflare": "1.1.1.1",
    "google": "google.com",
    "apple": "apple.com",
}

DNS_TEST_DOMAINS = ["google.com", "apple.com", "amazon.com", "github.com", "cloudflare.com"]
DNS_SERVERS: list[Optional[str]] = [None, "8.8.8.8", "1.1.1.1"]

BASELINE_PING_COUNT = 20
TRACEROUTE_MAX_HOPS = 20
MONITOR_INTERVAL = 5  # seconds between monitoring cycles
SIGNAL_SAMPLE_INTERVAL = 30  # seconds between WiFi signal samples

console = Console()

# ---------------------------------------------------------------------------
# Community / Firebase config
# ---------------------------------------------------------------------------

FIREBASE_PROJECT_ID = "YOUR_PROJECT_ID"  # TODO: set after creating Firebase project
FIREBASE_API_KEY = "YOUR_API_KEY"  # TODO: set from Firebase console (public web API key)
FIRESTORE_BASE_URL = f"https://firestore.googleapis.com/v1/projects/{FIREBASE_PROJECT_ID}/databases/(default)/documents"
AUTH_URL = f"https://identitytoolkit.googleapis.com/v1/accounts:signUp?key={FIREBASE_API_KEY}"

VALID_NETWORKS = ["public", "private"]
VALID_CONNECTIONS = ["wifi", "wired"]

LEADERBOARD_METRICS = {
    "download": ("download_mbps", "Download (Mbps)", False),
    "upload": ("upload_mbps", "Upload (Mbps)", False),
    "latency": ("gateway_latency_avg", "Gateway Latency (ms)", True),
    "rpm": ("rpm", "Responsiveness (RPM)", False),
    "bufferbloat": ("bufferbloat_ratio", "Bufferbloat Ratio", True),
}

# ---------------------------------------------------------------------------
# Subprocess helper
# ---------------------------------------------------------------------------


def run_cmd(cmd: list[str], timeout: int = 30) -> tuple[int, str, str]:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", f"Command timed out after {timeout}s"
    except FileNotFoundError:
        return -1, "", f"Command not found: {cmd[0]}"
    except Exception as e:
        return -1, "", str(e)


# ---------------------------------------------------------------------------
# IP / location detection
# ---------------------------------------------------------------------------


def fetch_public_ip_info() -> dict:
    """Fetch public IP and approximate location via ipinfo.io (free, no key required)."""
    try:
        req = urllib.request.Request(
            "https://ipinfo.io/json",
            headers={"Accept": "application/json", "User-Agent": "wifify/1.0"},
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
        loc = data.get("loc", "")  # "lat,lon"
        return {
            "public_ip": data.get("ip"),
            "city": data.get("city"),
            "region": data.get("region"),
            "country": data.get("country"),
            "loc": loc if loc else None,
            "isp": data.get("org"),
        }
    except Exception:
        return {
            "public_ip": None,
            "city": None,
            "region": None,
            "country": None,
            "loc": None,
            "isp": None,
        }


# ---------------------------------------------------------------------------
# Connection detection
# ---------------------------------------------------------------------------


def detect_connection() -> dict:
    interface = None
    gateway = None
    hw_port = "Unknown"
    conn_type = "unknown"

    if IS_MACOS:
        rc, stdout, _ = run_cmd(["route", "-n", "get", "default"])
        if rc == 0:
            for line in stdout.splitlines():
                line = line.strip()
                if line.startswith("interface:"):
                    interface = line.split(":", 1)[1].strip()
                if line.startswith("gateway:"):
                    gateway = line.split(":", 1)[1].strip()

        rc, stdout, _ = run_cmd(["networksetup", "-listallhardwareports"])
        hw_map: dict[str, str] = {}
        current_port = None
        if rc == 0:
            for line in stdout.splitlines():
                if line.startswith("Hardware Port:"):
                    current_port = line.split(":", 1)[1].strip()
                elif line.startswith("Device:"):
                    device = line.split(":", 1)[1].strip()
                    if current_port:
                        hw_map[device] = current_port

        hw_port = hw_map.get(interface, "Unknown") if interface else "Unknown"
        if "Wi-Fi" in hw_port:
            conn_type = "wifi"
        elif any(kw in hw_port.lower() for kw in ["ethernet", "thunderbolt", "usb", "lan"]):
            conn_type = "ethernet"

    elif IS_LINUX:
        # Use `ip route` to find default interface and gateway
        rc, stdout, _ = run_cmd(["ip", "route", "show", "default"])
        if rc == 0:
            # "default via 192.168.1.1 dev eth0 proto ..."
            m = re.search(r"default via ([\d.]+) dev (\S+)", stdout)
            if m:
                gateway = m.group(1)
                interface = m.group(2)

        if interface:
            hw_port = interface
            # Check /sys/class/net/<iface>/type — 1=ethernet, 801=wifi
            type_path = Path(f"/sys/class/net/{interface}/type")
            wireless_path = Path(f"/sys/class/net/{interface}/wireless")
            phy_path = Path(f"/sys/class/net/{interface}/phy80211")
            if wireless_path.exists() or phy_path.exists():
                conn_type = "wifi"
                hw_port = f"{interface} (wireless)"
            elif type_path.exists():
                try:
                    iface_type = type_path.read_text().strip()
                    if iface_type == "1":
                        conn_type = "ethernet"
                        hw_port = f"{interface} (ethernet)"
                except OSError:
                    pass

    return {
        "interface": interface,
        "type": conn_type,
        "hardware_port": hw_port,
        "gateway": gateway,
    }


# ---------------------------------------------------------------------------
# WiFi signal
# ---------------------------------------------------------------------------


def test_wifi_signal() -> dict:
    result: dict[str, Any] = {
        "rssi_dbm": None,
        "noise_dbm": None,
        "snr_db": None,
        "channel": None,
        "channel_band": None,
        "channel_width": None,
        "tx_rate_mbps": None,
        "mcs_index": None,
        "phy_mode": None,
        "ssid": None,
        "bssid": None,
        "security": None,
    }

    rc, stdout, _ = run_cmd([AIRPORT_CMD, "-I"])
    if rc == 0 and stdout.strip():
        mapping: dict[str, tuple[str, type]] = {
            "agrCtlRSSI": ("rssi_dbm", int),
            "agrCtlNoise": ("noise_dbm", int),
            "lastTxRate": ("tx_rate_mbps", float),
            "channel": ("channel", str),
            "SSID": ("ssid", str),
            "BSSID": ("bssid", str),
            "link auth": ("security", str),
            "MCS": ("mcs_index", int),
        }
        for line in stdout.splitlines():
            line = line.strip()
            if ": " not in line:
                continue
            key, val = line.split(": ", 1)
            key = key.strip()
            val = val.strip()
            if key in mapping:
                field, converter = mapping[key]
                try:
                    result[field] = converter(val)
                except ValueError:
                    pass

    if result["rssi_dbm"] is None:
        rc, stdout, _ = run_cmd(["system_profiler", "SPAirPortDataType"], timeout=15)
        if rc == 0:
            m = re.search(r"Signal / Noise:\s*(-?\d+)\s*dBm\s*/\s*(-?\d+)\s*dBm", stdout)
            if m:
                result["rssi_dbm"] = int(m.group(1))
                result["noise_dbm"] = int(m.group(2))
            m = re.search(r"Channel:\s*(\d+)\s*\((\w+),\s*(\w+)\)", stdout)
            if m:
                result["channel"] = m.group(1)
                result["channel_band"] = m.group(2)
                result["channel_width"] = m.group(3)
            m = re.search(r"Transmit Rate:\s*(\d+)", stdout)
            if m:
                result["tx_rate_mbps"] = float(m.group(1))
            m = re.search(r"PHY Mode:\s*([\w./]+)", stdout)
            if m:
                result["phy_mode"] = m.group(1)
            m = re.search(r"MCS Index:\s*(\d+)", stdout)
            if m:
                result["mcs_index"] = int(m.group(1))
            m = re.search(r"Current Network Information:\s*\n\s+(\S+):", stdout)
            if m:
                result["ssid"] = m.group(1)
            m = re.search(r"Security:\s*(.+)", stdout)
            if m:
                result["security"] = m.group(1).strip()

    if result["rssi_dbm"] is not None and result["noise_dbm"] is not None:
        result["snr_db"] = result["rssi_dbm"] - result["noise_dbm"]

    if result["channel"] and result["channel_band"] is None:
        ch = result["channel"]
        if "," in ch:
            ch = ch.split(",")[0]
        try:
            ch_num = int(ch)
            if ch_num <= 14:
                result["channel_band"] = "2.4GHz"
            elif ch_num <= 196:
                result["channel_band"] = "5GHz"
            else:
                result["channel_band"] = "6GHz"
        except ValueError:
            pass

    return result


def quick_signal_sample() -> tuple[Optional[int], Optional[int]]:
    """Fast RSSI/noise sample for monitoring loop."""
    rc, stdout, _ = run_cmd([AIRPORT_CMD, "-I"], timeout=5)
    rssi = None
    noise = None
    if rc == 0:
        for line in stdout.splitlines():
            line = line.strip()
            if line.startswith("agrCtlRSSI:"):
                try:
                    rssi = int(line.split(":", 1)[1].strip())
                except ValueError:
                    pass
            elif line.startswith("agrCtlNoise:"):
                try:
                    noise = int(line.split(":", 1)[1].strip())
                except ValueError:
                    pass
    return rssi, noise


# ---------------------------------------------------------------------------
# Ping
# ---------------------------------------------------------------------------


def test_ping(target: str, label: str, count: int = 20) -> dict:
    result: dict[str, Any] = {
        "target": target,
        "label": label,
        "count": count,
        "transmitted": 0,
        "received": 0,
        "packet_loss_pct": 100.0,
        "min_ms": None,
        "avg_ms": None,
        "max_ms": None,
        "stddev_ms": None,
        "jitter_ms": None,
        "rtts_ms": [],
        "error": None,
    }

    rc, stdout, stderr = run_cmd(["ping", "-c", str(count), target], timeout=count * 2 + 10)
    if rc == -1:
        result["error"] = stderr
        return result

    rtts = []
    for line in stdout.splitlines():
        m = re.search(r"time=(\d+\.?\d*)\s*ms", line)
        if m:
            rtts.append(float(m.group(1)))
    result["rtts_ms"] = rtts

    # macOS: "5 packets transmitted, 5 packets received, 0.0% packet loss"
    # Linux: "5 packets transmitted, 5 received, 0% packet loss"
    m = re.search(
        r"(\d+) packets transmitted, (\d+)(?: packets)? received, ([\d.]+)% packet loss",
        stdout,
    )
    if m:
        result["transmitted"] = int(m.group(1))
        result["received"] = int(m.group(2))
        result["packet_loss_pct"] = float(m.group(3))

    # macOS: "min/avg/max/stddev = ..."  Linux: "min/avg/max/mdev = ..."
    m = re.search(
        r"min/avg/max/(?:std|m)dev\s*=\s*([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)\s*ms",
        stdout,
    )
    if m:
        result["min_ms"] = float(m.group(1))
        result["avg_ms"] = float(m.group(2))
        result["max_ms"] = float(m.group(3))
        result["stddev_ms"] = float(m.group(4))

    if len(rtts) >= 2:
        diffs = [abs(rtts[i + 1] - rtts[i]) for i in range(len(rtts) - 1)]
        result["jitter_ms"] = round(statistics.mean(diffs), 3)

    return result


def single_ping(target: str, timeout: int = 5) -> Optional[float]:
    """Single ping, returns RTT in ms or None if lost."""
    # macOS: -W takes milliseconds; Linux: -W takes seconds
    wait_val = str(timeout * 1000) if IS_MACOS else str(timeout)
    rc, stdout, _ = run_cmd(["ping", "-c", "1", "-W", wait_val, target], timeout=timeout + 2)
    if rc == 0:
        m = re.search(r"time=(\d+\.?\d*)\s*ms", stdout)
        if m:
            return float(m.group(1))
    return None


# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------


def test_dns_resolution() -> dict:
    queries = []
    for domain in DNS_TEST_DOMAINS:
        for server in DNS_SERVERS:
            cmd = ["dig", domain, "+noall", "+stats", "+answer", "+time=5", "+tries=1"]
            if server:
                cmd.append(f"@{server}")

            server_label = server or "system"
            rc, stdout, _ = run_cmd(cmd, timeout=10)
            query_time = None
            answer = None
            status = "fail"

            if rc == 0:
                m = re.search(r"Query time:\s*(\d+)\s*msec", stdout)
                if m:
                    query_time = int(m.group(1))
                    status = "ok"
                for line in stdout.splitlines():
                    if "\tIN\tA\t" in line:
                        answer = line.split()[-1]
                        break

            queries.append({
                "domain": domain,
                "server": server_label,
                "time_ms": query_time,
                "status": status,
                "answer": answer,
            })

    ok_times = [q["time_ms"] for q in queries if q["time_ms"] is not None]
    return {
        "queries": queries,
        "avg_time_ms": round(statistics.mean(ok_times), 1) if ok_times else None,
        "max_time_ms": max(ok_times) if ok_times else None,
        "failures": sum(1 for q in queries if q["status"] == "fail"),
    }


# ---------------------------------------------------------------------------
# Network quality (speed + bufferbloat)
# ---------------------------------------------------------------------------


def test_network_quality() -> dict:
    result: dict[str, Any] = {
        "dl_throughput_mbps": None,
        "ul_throughput_mbps": None,
        "responsiveness_rpm": None,
        "base_rtt_ms": None,
        "idle_latency_ms": None,
        "loaded_latency_ms": None,
        "bufferbloat_ms": None,
        "bufferbloat_ratio": None,
        "interface_name": None,
        "error": None,
    }

    rc, stdout, stderr = run_cmd(["networkQuality", "-c"], timeout=120)
    if rc != 0:
        result["error"] = stderr or "networkQuality failed"
        return result

    try:
        data = json.loads(stdout)
    except json.JSONDecodeError as e:
        result["error"] = f"JSON parse error: {e}"
        return result

    result["dl_throughput_mbps"] = round(data.get("dl_throughput", 0) / 1_000_000, 2)
    result["ul_throughput_mbps"] = round(data.get("ul_throughput", 0) / 1_000_000, 2)
    raw_rpm = data.get("responsiveness")
    result["responsiveness_rpm"] = round(raw_rpm) if raw_rpm is not None else None
    result["base_rtt_ms"] = data.get("base_rtt")
    result["interface_name"] = data.get("interface_name")

    # Idle latency from flows
    idle_samples = data.get("il_h2_req_resp", [])
    if idle_samples:
        result["idle_latency_ms"] = round(statistics.median(idle_samples), 1)

    # Loaded latency from flows
    loaded_samples = data.get("lud_foreign_h2_req_resp", [])
    if not loaded_samples:
        loaded_samples = data.get("dl_h2_req_resp", [])
    if loaded_samples:
        result["loaded_latency_ms"] = round(statistics.median(loaded_samples), 1)

    if result["idle_latency_ms"] and result["loaded_latency_ms"]:
        result["bufferbloat_ms"] = round(
            result["loaded_latency_ms"] - result["idle_latency_ms"], 1
        )
        if result["idle_latency_ms"] > 0:
            result["bufferbloat_ratio"] = round(
                result["loaded_latency_ms"] / result["idle_latency_ms"], 1
            )

    return result


# ---------------------------------------------------------------------------
# Traceroute
# ---------------------------------------------------------------------------


def test_traceroute(target: str = "8.8.8.8") -> dict:
    rc, stdout, stderr = run_cmd(
        ["traceroute", "-m", str(TRACEROUTE_MAX_HOPS), "-w", "2", target],
        timeout=TRACEROUTE_MAX_HOPS * 3 + 10,
    )
    hops = []
    if stdout:
        for line in stdout.splitlines()[1:]:
            line = line.strip()
            if not line:
                continue
            m = re.match(r"\s*(\d+)\s+(.*)", line)
            if not m:
                continue
            hop_num = int(m.group(1))
            rest = m.group(2)

            if rest.strip() == "* * *":
                hops.append({"hop": hop_num, "host": "*", "ip": None, "rtts_ms": []})
                continue

            host_match = re.search(r"([\w.\-]+)\s+\(([\d.]+)\)", rest)
            host = host_match.group(1) if host_match else None
            ip = host_match.group(2) if host_match else None
            rtts = [float(x) for x in re.findall(r"([\d.]+)\s+ms", rest)]
            hops.append({"hop": hop_num, "host": host, "ip": ip, "rtts_ms": rtts})

    return {
        "target": target,
        "hops": hops,
        "total_hops": len(hops),
        "error": stderr if rc == -1 else None,
    }


# ---------------------------------------------------------------------------
# Verdict helpers
# ---------------------------------------------------------------------------


def severity_style(severity: str) -> str:
    return {"good": "green", "warning": "yellow", "bad": "red", "info": "cyan"}.get(
        severity, "white"
    )


def severity_icon(severity: str) -> str:
    return {"good": "✓", "warning": "!", "bad": "✗", "info": "•"}.get(severity, "•")


def generate_verdicts(results: dict) -> list[dict]:
    verdicts = []

    # WiFi signal
    if results["connection"]["type"] == "wifi" and results.get("wifi_signal"):
        ws = results["wifi_signal"]
        rssi = ws.get("rssi_dbm")
        if rssi is not None:
            if rssi >= -50:
                verdicts.append({"category": "wifi_signal", "severity": "good",
                    "message": f"Excellent WiFi signal ({rssi} dBm)"})
            elif rssi >= -60:
                verdicts.append({"category": "wifi_signal", "severity": "good",
                    "message": f"Good WiFi signal ({rssi} dBm)"})
            elif rssi >= -70:
                verdicts.append({"category": "wifi_signal", "severity": "warning",
                    "message": f"Fair WiFi signal ({rssi} dBm) — consider moving closer to the router"})
            else:
                verdicts.append({"category": "wifi_signal", "severity": "bad",
                    "message": f"Weak WiFi signal ({rssi} dBm) — likely degrading your connection"})

        snr = ws.get("snr_db")
        if snr is not None and snr < 20:
            verdicts.append({"category": "wifi_noise", "severity": "bad",
                "message": f"Poor signal-to-noise ratio ({snr} dB) — high interference, try changing WiFi channel"})
        elif snr is not None and snr < 30:
            verdicts.append({"category": "wifi_noise", "severity": "warning",
                "message": f"Moderate signal-to-noise ratio ({snr} dB)"})

        band = ws.get("channel_band")
        if band and "2.4" in band:
            verdicts.append({"category": "wifi_band", "severity": "warning",
                "message": "Connected on 2.4GHz — 5GHz or 6GHz offers faster speeds if in range"})

    # Packet loss from baseline pings
    for label, ping_data in results.get("baseline_latency", {}).items():
        loss = ping_data.get("packet_loss_pct", 0)
        if loss > 5:
            verdicts.append({"category": "packet_loss", "severity": "bad",
                "message": f"Significant packet loss to {label} ({loss}%)"})
        elif loss > 1:
            verdicts.append({"category": "packet_loss", "severity": "warning",
                "message": f"Some packet loss to {label} ({loss}%)"})

    # Gateway latency
    gw = results.get("baseline_latency", {}).get("gateway", {})
    gw_avg = gw.get("avg_ms")
    if gw_avg is not None:
        if gw_avg > 20:
            verdicts.append({"category": "gateway_latency", "severity": "bad",
                "message": f"High latency to gateway ({gw_avg:.1f}ms) — local network congestion or WiFi issue"})
        elif gw_avg > 10:
            verdicts.append({"category": "gateway_latency", "severity": "warning",
                "message": f"Elevated gateway latency ({gw_avg:.1f}ms)"})
        else:
            verdicts.append({"category": "gateway_latency", "severity": "good",
                "message": f"Good gateway latency ({gw_avg:.1f}ms)"})

    # Jitter
    for label, ping_data in results.get("baseline_latency", {}).items():
        jitter = ping_data.get("jitter_ms")
        if jitter is not None and jitter > 10:
            verdicts.append({"category": "jitter", "severity": "warning",
                "message": f"High jitter to {label} ({jitter:.1f}ms) — affects video calls and gaming"})

    # DNS
    dns = results.get("dns", {})
    if dns.get("failures", 0) > 0:
        verdicts.append({"category": "dns", "severity": "bad",
            "message": f"{dns['failures']} DNS queries failed"})
    if dns.get("avg_time_ms") and dns["avg_time_ms"] > 100:
        verdicts.append({"category": "dns_speed", "severity": "warning",
            "message": f"Slow DNS resolution (avg {dns['avg_time_ms']}ms) — consider switching to 1.1.1.1 or 8.8.8.8"})

    # Speed
    speed = results.get("speed", {})
    dl = speed.get("dl_throughput_mbps")
    if dl is not None:
        if dl < 10:
            verdicts.append({"category": "speed", "severity": "bad",
                "message": f"Very slow download ({dl:.1f} Mbps)"})
        elif dl < 50:
            verdicts.append({"category": "speed", "severity": "warning",
                "message": f"Moderate download speed ({dl:.1f} Mbps)"})
        else:
            verdicts.append({"category": "speed", "severity": "good",
                "message": f"Download: {dl:.1f} Mbps"})

    ul = speed.get("ul_throughput_mbps")
    if ul is not None:
        if ul < 5:
            verdicts.append({"category": "speed_up", "severity": "bad",
                "message": f"Very slow upload ({ul:.1f} Mbps)"})
        elif ul < 20:
            verdicts.append({"category": "speed_up", "severity": "warning",
                "message": f"Moderate upload speed ({ul:.1f} Mbps)"})
        else:
            verdicts.append({"category": "speed_up", "severity": "good",
                "message": f"Upload: {ul:.1f} Mbps"})

    # Bufferbloat
    bb_ratio = speed.get("bufferbloat_ratio")
    rpm = speed.get("responsiveness_rpm")
    if bb_ratio is not None:
        if bb_ratio > 5 or (rpm is not None and rpm < 200):
            verdicts.append({"category": "bufferbloat", "severity": "bad",
                "message": (
                    f"Severe bufferbloat — latency increases {bb_ratio:.0f}x under load "
                    f"({speed.get('loaded_latency_ms', '?')}ms vs {speed.get('idle_latency_ms', '?')}ms idle). "
                    f"Consider enabling SQM/fq_codel on your router"
                )})
        elif bb_ratio > 3:
            verdicts.append({"category": "bufferbloat", "severity": "warning",
                "message": f"Moderate bufferbloat — latency increases {bb_ratio:.0f}x under load"})
        else:
            verdicts.append({"category": "bufferbloat", "severity": "good",
                "message": f"Low bufferbloat — latency stable under load (RPM: {rpm})"})

    # Monitoring summary verdicts
    mon = results.get("monitoring_summary")
    if mon:
        total_pings = mon.get("gateway_total", 0)
        gw_loss = mon.get("gateway_loss_count", 0)
        inet_loss = mon.get("internet_loss_count", 0)
        anomalies = mon.get("anomaly_count", 0)

        if total_pings > 0:
            gw_loss_pct = round(gw_loss / total_pings * 100, 1)
            inet_loss_pct = round(inet_loss / total_pings * 100, 1)

            if gw_loss_pct > 2:
                verdicts.append({"category": "monitoring_loss", "severity": "bad",
                    "message": f"Gateway packet loss during monitoring: {gw_loss_pct}% ({gw_loss}/{total_pings} pings dropped)"})
            elif gw_loss_pct > 0:
                verdicts.append({"category": "monitoring_loss", "severity": "warning",
                    "message": f"Intermittent gateway packet loss: {gw_loss_pct}% ({gw_loss}/{total_pings})"})

            if inet_loss_pct > 2:
                verdicts.append({"category": "monitoring_inet_loss", "severity": "bad",
                    "message": f"Internet packet loss during monitoring: {inet_loss_pct}% ({inet_loss}/{total_pings})"})
            elif inet_loss_pct > 0:
                verdicts.append({"category": "monitoring_inet_loss", "severity": "warning",
                    "message": f"Intermittent internet packet loss: {inet_loss_pct}% ({inet_loss}/{total_pings})"})

        if anomalies > 0:
            verdicts.append({"category": "anomalies", "severity": "warning",
                "message": f"{anomalies} anomalies detected during {mon.get('duration_min', '?')}-minute monitoring"})

        gw_p95 = mon.get("gateway_p95_ms")
        gw_avg = mon.get("gateway_avg_ms")
        if gw_p95 is not None and gw_avg is not None and gw_p95 > gw_avg * 3:
            verdicts.append({"category": "latency_spikes", "severity": "warning",
                "message": f"Latency spikes detected — P95 ({gw_p95:.0f}ms) is {gw_p95/gw_avg:.0f}x the average ({gw_avg:.1f}ms)"})

    if not verdicts:
        verdicts.append({"category": "overall", "severity": "good",
            "message": "Network connection looks healthy — no significant issues detected"})

    return verdicts


# ---------------------------------------------------------------------------
# Percentile helper
# ---------------------------------------------------------------------------


def percentile(data: list[float], pct: float) -> float:
    if not data:
        return 0.0
    sorted_data = sorted(data)
    k = (len(sorted_data) - 1) * (pct / 100)
    f = int(k)
    c = f + 1
    if c >= len(sorted_data):
        return sorted_data[-1]
    return sorted_data[f] + (k - f) * (sorted_data[c] - sorted_data[f])


# ---------------------------------------------------------------------------
# Phase 1: Baseline
# ---------------------------------------------------------------------------


def run_baseline(connection: dict) -> dict:
    results: dict[str, Any] = {}

    # WiFi signal
    if connection["type"] == "wifi":
        console.print("\n  Scanning WiFi signal...", style="dim")
        ws = test_wifi_signal()
        results["wifi_signal"] = ws

        rssi = ws.get("rssi_dbm")
        rssi_style = "green" if rssi and rssi >= -60 else "yellow" if rssi and rssi >= -70 else "red"
        snr = ws.get("snr_db")

        items = []
        if rssi is not None:
            items.append(f"[{rssi_style}]{rssi} dBm[/]")
        if ws.get("noise_dbm") is not None:
            items.append(f"Noise: {ws['noise_dbm']} dBm")
        if snr is not None:
            items.append(f"SNR: {snr} dB")
        console.print(f"  WiFi Signal: {' | '.join(items)}")

        items2 = []
        if ws.get("ssid"):
            items2.append(f"SSID: {ws['ssid']}")
        if ws.get("channel"):
            ch = ws["channel"]
            if ws.get("channel_band"):
                ch += f" ({ws['channel_band']}"
                if ws.get("channel_width"):
                    ch += f", {ws['channel_width']}"
                ch += ")"
            items2.append(f"Channel: {ch}")
        if ws.get("tx_rate_mbps"):
            items2.append(f"TX Rate: {ws['tx_rate_mbps']} Mbps")
        if items2:
            console.print(f"  {' | '.join(items2)}")
    else:
        results["wifi_signal"] = None

    # Baseline latency pings
    console.print("\n  Running baseline latency tests...", style="dim")
    targets = dict(PING_TARGETS)
    targets["gateway"] = connection["gateway"]
    results["baseline_latency"] = {}

    for label, target in targets.items():
        if target is None:
            continue
        console.print(f"    Pinging {label} ({target})...", style="dim", end="")
        ping_result = test_ping(target, label, count=BASELINE_PING_COUNT)
        results["baseline_latency"][label] = ping_result
        avg = ping_result.get("avg_ms")
        loss = ping_result.get("packet_loss_pct", 0)
        jitter = ping_result.get("jitter_ms")

        loss_style = "green" if loss == 0 else "yellow" if loss < 2 else "red"
        avg_style = "green" if avg and avg < 20 else "yellow" if avg and avg < 50 else "red"

        parts = []
        if avg is not None:
            parts.append(f"[{avg_style}]{avg:.1f}ms[/]")
        if loss is not None:
            parts.append(f"[{loss_style}]{loss}% loss[/]")
        if jitter is not None:
            parts.append(f"{jitter:.1f}ms jitter")
        console.print(f"\r    {label}: {' | '.join(parts)}          ")

    # DNS
    console.print("\n  Testing DNS resolution...", style="dim")
    dns_result = test_dns_resolution()
    results["dns"] = dns_result

    # Group by server
    by_server: dict[str, list[int]] = {}
    for q in dns_result["queries"]:
        if q["time_ms"] is not None:
            by_server.setdefault(q["server"], []).append(q["time_ms"])
    parts = []
    for srv, times in by_server.items():
        avg = statistics.mean(times)
        parts.append(f"{srv}: avg {avg:.0f}ms")
    console.print(f"  DNS: {' | '.join(parts)}")
    if dns_result["failures"] > 0:
        console.print(f"  [red]{dns_result['failures']} DNS queries failed[/]")

    # Traceroute
    console.print("\n  Running traceroute...", style="dim")
    tr = test_traceroute("8.8.8.8")
    results["traceroute"] = tr
    console.print(f"  Traceroute: {tr['total_hops']} hops to 8.8.8.8")

    # Speed test (macOS only — uses networkQuality)
    if IS_MACOS:
        console.print("\n  Running speed test (this takes ~15 seconds)...", style="dim")
        speed = test_network_quality()
        results["speed"] = speed

        if speed.get("error"):
            console.print(f"  [red]Speed test error: {speed['error']}[/]")
        else:
            dl = speed.get("dl_throughput_mbps", 0)
            ul = speed.get("ul_throughput_mbps", 0)
            rpm = speed.get("responsiveness_rpm")
            console.print(f"  Speed: [bold]{dl:.1f} Mbps[/] down / [bold]{ul:.1f} Mbps[/] up")
            if rpm is not None:
                rpm_val = round(rpm)
                rpm_style = "green" if rpm_val > 500 else "yellow" if rpm_val > 200 else "red"
                console.print(f"  Responsiveness: [{rpm_style}]{rpm_val} RPM[/]")
            bb = speed.get("bufferbloat_ratio")
            bb_ms = speed.get("bufferbloat_ms")
            if bb is not None and bb_ms is not None:
                bb_style = "green" if bb < 2 else "yellow" if bb < 5 else "red"
                console.print(f"  Bufferbloat: [{bb_style}]+{bb_ms:.0f}ms under load ({bb:.1f}x idle)[/]")
    else:
        console.print("\n  [dim]Speed test skipped (networkQuality is macOS-only)[/]")
        results["speed"] = {}

    return results


# ---------------------------------------------------------------------------
# Phase 2: Monitoring
# ---------------------------------------------------------------------------


def run_monitoring(
    connection: dict,
    duration_min: float,
    baseline_gw_avg: Optional[float],
) -> tuple[list[dict], dict]:
    """Returns (samples, summary)."""
    gateway = connection["gateway"]
    is_wifi = connection["type"] == "wifi"
    duration_sec = duration_min * 60
    start_time = time.time()
    samples: list[dict] = []
    anomalies: list[dict] = []
    last_signal_time = 0.0

    # Running averages for anomaly detection
    gw_rtts: list[float] = []
    inet_rtts: list[float] = []
    baseline_gw = baseline_gw_avg or 10.0

    # Build the live display
    progress = Progress(
        TextColumn("[bold blue]Monitoring"),
        BarColumn(bar_width=40),
        TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
        TimeElapsedColumn(),
        TextColumn("/"),
        TimeRemainingColumn(),
    )
    task_id = progress.add_task("monitor", total=duration_sec)

    MAX_TABLE_ROWS = 20
    recent_rows: list[list[Any]] = []

    def build_sample_table() -> Table:
        """Build a fresh table from recent rows."""
        tbl = Table(show_header=True, header_style="bold", expand=True, show_edge=False)
        tbl.add_column("Time", style="dim", width=10)
        tbl.add_column("Gateway", width=14)
        tbl.add_column("Internet", width=14)
        if is_wifi:
            tbl.add_column("Signal", width=12)
        tbl.add_column("Status", width=20)
        for row in recent_rows:
            tbl.add_row(*row)
        return tbl

    def build_layout() -> Table:
        """Rebuild the display layout."""
        outer = Table.grid(expand=True)
        outer.add_row(progress)
        outer.add_row(build_sample_table())
        return outer

    def add_sample_row(sample: dict) -> None:
        """Add a row to recent_rows, trimming old ones."""
        ts = datetime.fromtimestamp(sample["timestamp"]).strftime("%H:%M:%S")

        gw_ms = sample.get("gateway_ms")
        if gw_ms is not None:
            gw_style = "green" if gw_ms < 10 else "yellow" if gw_ms < 30 else "red"
            gw_text = Text(f"{gw_ms:.1f}ms", style=gw_style)
        else:
            gw_text = Text("LOST", style="bold red")

        inet_ms = sample.get("internet_ms")
        if inet_ms is not None:
            inet_style = "green" if inet_ms < 30 else "yellow" if inet_ms < 80 else "red"
            inet_text = Text(f"{inet_ms:.1f}ms", style=inet_style)
        else:
            inet_text = Text("LOST", style="bold red")

        status = ""
        if sample.get("anomaly"):
            status = f"[bold red]!! {sample['anomaly_reason']}[/]"

        row: list[Any] = [ts, gw_text, inet_text]
        if is_wifi:
            sig = sample.get("signal_dbm")
            if sig is not None:
                sig_style = "green" if sig >= -60 else "yellow" if sig >= -70 else "red"
                row.append(Text(f"{sig} dBm", style=sig_style))
            else:
                row.append("—")
        row.append(status)

        recent_rows.append(row)
        while len(recent_rows) > MAX_TABLE_ROWS:
            recent_rows.pop(0)

    next_cycle = start_time

    with Live(build_layout(), console=console, refresh_per_second=2) as live:
        while True:
            now = time.time()
            elapsed = now - start_time
            if elapsed >= duration_sec:
                break

            # Wait until next cycle time
            if now < next_cycle:
                time.sleep(min(next_cycle - now, 0.5))
                continue

            next_cycle += MONITOR_INTERVAL
            progress.update(task_id, completed=min(elapsed, duration_sec))

            sample: dict[str, Any] = {"timestamp": time.time(), "anomaly": False, "anomaly_reason": ""}

            # Ping gateway
            if gateway:
                gw_rtt = single_ping(gateway)
                sample["gateway_ms"] = gw_rtt
                if gw_rtt is not None:
                    gw_rtts.append(gw_rtt)
            else:
                sample["gateway_ms"] = None

            # Ping internet
            inet_rtt = single_ping("8.8.8.8")
            sample["internet_ms"] = inet_rtt
            if inet_rtt is not None:
                inet_rtts.append(inet_rtt)

            # WiFi signal (every 30s)
            sample["signal_dbm"] = None
            sample["noise_dbm"] = None
            if is_wifi and (time.time() - last_signal_time) >= SIGNAL_SAMPLE_INTERVAL:
                rssi, noise = quick_signal_sample()
                sample["signal_dbm"] = rssi
                sample["noise_dbm"] = noise
                last_signal_time = time.time()

            # Anomaly detection
            reasons = []
            if sample["gateway_ms"] is None:
                reasons.append("PACKET LOSS (gateway)")
            elif len(gw_rtts) > 5:
                running_avg = statistics.mean(gw_rtts[-20:])
                threshold = max(running_avg * 3, baseline_gw * 2, 30)
                if sample["gateway_ms"] > threshold:
                    reasons.append(f"SPIKE ({sample['gateway_ms']:.0f}ms)")

            if sample["internet_ms"] is None:
                reasons.append("PACKET LOSS (internet)")

            if is_wifi and sample["signal_dbm"] is not None and sample["signal_dbm"] < -75:
                reasons.append(f"WEAK SIGNAL ({sample['signal_dbm']} dBm)")

            if reasons:
                sample["anomaly"] = True
                sample["anomaly_reason"] = " | ".join(reasons)
                anomalies.append(sample)

            samples.append(sample)
            add_sample_row(sample)
            live.update(build_layout())

        progress.update(task_id, completed=duration_sec)

    # Build summary
    gw_all = [s["gateway_ms"] for s in samples if s["gateway_ms"] is not None]
    inet_all = [s["internet_ms"] for s in samples if s["internet_ms"] is not None]
    signal_all = [s["signal_dbm"] for s in samples if s.get("signal_dbm") is not None]

    gw_loss_count = sum(1 for s in samples if s["gateway_ms"] is None)
    inet_loss_count = sum(1 for s in samples if s["internet_ms"] is None)

    def stat_block(data: list[float]) -> dict:
        if not data:
            return {"avg": None, "min": None, "max": None, "p95": None, "p99": None, "stddev": None}
        return {
            "avg": round(statistics.mean(data), 2),
            "min": round(min(data), 2),
            "max": round(max(data), 2),
            "p95": round(percentile(data, 95), 2),
            "p99": round(percentile(data, 99), 2),
            "stddev": round(statistics.stdev(data), 2) if len(data) > 1 else 0.0,
        }

    # Jitter for monitoring
    gw_jitter = None
    if len(gw_all) >= 2:
        diffs = [abs(gw_all[i + 1] - gw_all[i]) for i in range(len(gw_all) - 1)]
        gw_jitter = round(statistics.mean(diffs), 2)

    summary = {
        "duration_min": round((time.time() - start_time) / 60, 1),
        "total_samples": len(samples),
        "gateway_total": len(samples),
        "gateway_stats": stat_block(gw_all),
        "gateway_loss_count": gw_loss_count,
        "gateway_avg_ms": round(statistics.mean(gw_all), 2) if gw_all else None,
        "gateway_p95_ms": round(percentile(gw_all, 95), 2) if gw_all else None,
        "gateway_jitter_ms": gw_jitter,
        "internet_stats": stat_block(inet_all),
        "internet_loss_count": inet_loss_count,
        "anomaly_count": len(anomalies),
        "anomaly_timestamps": [
            datetime.fromtimestamp(a["timestamp"]).strftime("%H:%M:%S") for a in anomalies
        ],
    }

    if signal_all:
        summary["signal_stats"] = {
            "avg": round(statistics.mean(signal_all), 1),
            "min": min(signal_all),
            "max": max(signal_all),
        }

    return samples, summary


# ---------------------------------------------------------------------------
# Phase 3: Summary
# ---------------------------------------------------------------------------


def print_summary(results: dict) -> None:
    console.print()

    # Monitoring summary
    mon = results.get("monitoring_summary")
    if mon:
        table = Table(title="Monitoring Summary", show_edge=False, expand=True)
        table.add_column("Metric", style="bold")
        table.add_column("Gateway", justify="right")
        table.add_column("Internet", justify="right")

        gs = mon.get("gateway_stats", {})
        ins = mon.get("internet_stats", {})

        def fmt(v: Any, unit: str = "ms") -> str:
            if v is None:
                return "—"
            return f"{v:.1f} {unit}" if isinstance(v, float) else f"{v} {unit}"

        table.add_row("Avg Latency", fmt(gs.get("avg")), fmt(ins.get("avg")))
        table.add_row("Min Latency", fmt(gs.get("min")), fmt(ins.get("min")))
        table.add_row("Max Latency", fmt(gs.get("max")), fmt(ins.get("max")))
        table.add_row("P95 Latency", fmt(gs.get("p95")), fmt(ins.get("p95")))
        table.add_row("P99 Latency", fmt(gs.get("p99")), fmt(ins.get("p99")))
        table.add_row("Std Dev", fmt(gs.get("stddev")), fmt(ins.get("stddev")))
        table.add_row(
            "Packet Loss",
            f"{mon.get('gateway_loss_count', 0)} / {mon.get('gateway_total', 0)}",
            f"{mon.get('internet_loss_count', 0)} / {mon.get('gateway_total', 0)}",
        )
        if mon.get("gateway_jitter_ms") is not None:
            table.add_row("Jitter", fmt(mon["gateway_jitter_ms"]), "—")
        table.add_row("Anomalies", str(mon.get("anomaly_count", 0)), "")
        table.add_row("Duration", f"{mon.get('duration_min', 0):.1f} min", "")

        console.print(table)

        if mon.get("signal_stats"):
            ss = mon["signal_stats"]
            console.print(
                f"\n  WiFi Signal: avg [bold]{ss['avg']} dBm[/] | "
                f"min {ss['min']} dBm | max {ss['max']} dBm"
            )

        if mon.get("anomaly_timestamps"):
            console.print(f"\n  Anomaly times: {', '.join(mon['anomaly_timestamps'])}")

    # Verdicts
    verdicts = results.get("verdicts", [])
    if verdicts:
        console.print()
        verdict_panel_items = []
        for v in verdicts:
            icon = severity_icon(v["severity"])
            style = severity_style(v["severity"])
            verdict_panel_items.append(f"  [{style}]{icon} {v['message']}[/]")

        console.print(Panel(
            "\n".join(verdict_panel_items),
            title="[bold]Diagnosis[/]",
            border_style="blue",
        ))


# ---------------------------------------------------------------------------
# Compare mode
# ---------------------------------------------------------------------------


def compare_results(file1: str, file2: str) -> None:
    with open(file1) as f:
        a = json.load(f)
    with open(file2) as f:
        b = json.load(f)

    label_a = a["meta"]["label"]
    label_b = b["meta"]["label"]
    plat_a = a["meta"].get("platform", "")
    plat_b = b["meta"].get("platform", "")
    loc_a = a["meta"].get("location") or {}
    loc_b = b["meta"].get("location") or {}

    def _header_detail(plat: str, loc: dict) -> str:
        parts = []
        if plat:
            parts.append(plat)
        city = loc.get("city")
        if city:
            parts.append(city)
        return f" [dim]({', '.join(parts)})[/]" if parts else ""

    console.print(Panel(
        f"[bold]{label_a.upper()}[/]{_header_detail(plat_a, loc_a)} vs [bold]{label_b.upper()}[/]{_header_detail(plat_b, loc_b)}",
        title="[bold blue]wifify — Comparison[/]",
        border_style="blue",
    ))

    def get_nested(d: dict, keys: tuple) -> Any:
        for k in keys:
            if isinstance(d, dict):
                d = d.get(k)  # type: ignore
            else:
                return None
        return d

    # Metric definitions: (name, key_path, unit, lower_is_better)
    metrics: list[tuple[str, tuple, str, bool]] = [
        ("Download Speed", ("speed", "dl_throughput_mbps"), "Mbps", False),
        ("Upload Speed", ("speed", "ul_throughput_mbps"), "Mbps", False),
        ("Responsiveness (RPM)", ("speed", "responsiveness_rpm"), "RPM", False),
        ("Base RTT", ("speed", "base_rtt_ms"), "ms", True),
        ("Idle Latency", ("speed", "idle_latency_ms"), "ms", True),
        ("Loaded Latency", ("speed", "loaded_latency_ms"), "ms", True),
        ("Bufferbloat Delta", ("speed", "bufferbloat_ms"), "ms", True),
    ]

    # Add baseline latency metrics
    for target_label in ["gateway", "dns_google", "dns_cloudflare"]:
        nice_name = target_label.replace("_", " ").title()
        metrics.append((f"{nice_name} Latency", ("baseline_latency", target_label, "avg_ms"), "ms", True))
        metrics.append((f"{nice_name} Loss", ("baseline_latency", target_label, "packet_loss_pct"), "%", True))
        metrics.append((f"{nice_name} Jitter", ("baseline_latency", target_label, "jitter_ms"), "ms", True))

    # Add monitoring metrics
    metrics.append(("Mon. Avg Gateway", ("monitoring_summary", "gateway_avg_ms"), "ms", True))
    metrics.append(("Mon. P95 Gateway", ("monitoring_summary", "gateway_p95_ms"), "ms", True))
    metrics.append(("Mon. Gateway Loss", ("monitoring_summary", "gateway_loss_count"), "", True))
    metrics.append(("Mon. Anomalies", ("monitoring_summary", "anomaly_count"), "", True))

    # DNS
    metrics.append(("DNS Avg Time", ("dns", "avg_time_ms"), "ms", True))

    table = Table(title="Performance Comparison", expand=True, show_edge=False)
    table.add_column("Metric", style="bold", width=24)
    table.add_column(label_a.upper(), justify="right", width=14)
    table.add_column(label_b.upper(), justify="right", width=14)
    table.add_column("Delta", justify="right", width=14)
    table.add_column("Change", justify="right", width=10)

    for name, path, unit, lower_is_better in metrics:
        val_a = get_nested(a, path)
        val_b = get_nested(b, path)

        if val_a is None and val_b is None:
            continue

        str_a = f"{val_a:.1f}" if isinstance(val_a, (int, float)) else "N/A"
        str_b = f"{val_b:.1f}" if isinstance(val_b, (int, float)) else "N/A"

        if isinstance(val_a, (int, float)) and isinstance(val_b, (int, float)) and val_a != 0:
            delta = val_b - val_a
            pct = ((val_b - val_a) / abs(val_a)) * 100
            is_better = (delta < 0) if lower_is_better else (delta > 0)
            style = "green" if is_better else "red" if abs(pct) > 10 else "yellow"
            delta_str = f"[{style}]{delta:+.1f} {unit}[/]"
            pct_str = f"[{style}]{pct:+.1f}%[/]"
        else:
            delta_str = "—"
            pct_str = "—"

        table.add_row(name, str_a, str_b, delta_str, pct_str)

    console.print(table)

    # WiFi signal comparison (if both have it)
    ws_a = a.get("wifi_signal")
    ws_b = b.get("wifi_signal")
    if ws_a and ws_b and ws_a.get("rssi_dbm") is not None:
        console.print()
        sig_table = Table(title="WiFi Signal Comparison", expand=True, show_edge=False)
        sig_table.add_column("Metric", style="bold", width=20)
        sig_table.add_column(label_a.upper(), justify="right", width=14)
        sig_table.add_column(label_b.upper(), justify="right", width=14)

        for name, key in [("RSSI", "rssi_dbm"), ("Noise", "noise_dbm"), ("SNR", "snr_db"), ("TX Rate", "tx_rate_mbps")]:
            va = ws_a.get(key)
            vb = ws_b.get(key)
            sig_table.add_row(
                name,
                str(va) if va is not None else "—",
                str(vb) if vb is not None else "—",
            )
        console.print(sig_table)

    # Verdicts from both runs
    console.print()
    for label, data in [(label_a, a), (label_b, b)]:
        verdicts = data.get("verdicts", [])
        if verdicts:
            items = []
            for v in verdicts:
                icon = severity_icon(v["severity"])
                style = severity_style(v["severity"])
                items.append(f"  [{style}]{icon} {v['message']}[/]")
            console.print(Panel("\n".join(items), title=f"[bold]{label.upper()} Verdicts[/]", border_style="dim"))


# ---------------------------------------------------------------------------
# Community: Firebase helpers
# ---------------------------------------------------------------------------


def _firebase_configured() -> bool:
    return FIREBASE_PROJECT_ID != "YOUR_PROJECT_ID" and FIREBASE_API_KEY != "YOUR_API_KEY"


def firebase_anon_auth() -> str:
    """Authenticate anonymously with Firebase, return an ID token."""
    data = json.dumps({"returnSecureToken": True}).encode()
    req = urllib.request.Request(AUTH_URL, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read().decode())
            return result["idToken"]
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        raise RuntimeError(f"Firebase auth failed ({e.code}): {body}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"Network error during auth: {e.reason}") from e


def to_firestore_value(value: Any) -> dict:
    """Convert a Python value to Firestore REST API value format."""
    if value is None:
        return {"nullValue": None}
    if isinstance(value, bool):
        return {"booleanValue": value}
    if isinstance(value, int):
        return {"integerValue": str(value)}
    if isinstance(value, float):
        return {"doubleValue": value}
    if isinstance(value, str):
        return {"stringValue": value}
    return {"stringValue": str(value)}


def from_firestore_value(fv: dict) -> Any:
    """Convert a Firestore REST API value dict to a Python value."""
    if "nullValue" in fv:
        return None
    if "booleanValue" in fv:
        return fv["booleanValue"]
    if "integerValue" in fv:
        return int(fv["integerValue"])
    if "doubleValue" in fv:
        return fv["doubleValue"]
    if "stringValue" in fv:
        return fv["stringValue"]
    if "timestampValue" in fv:
        return fv["timestampValue"]
    return None


def extract_upload_payload(results: dict) -> dict:
    """Extract curated fields from a full results JSON for upload."""
    meta = results.get("meta", {})
    conn = results.get("connection", {})
    speed = results.get("speed", {})
    ws = results.get("wifi_signal") or {}
    dns = results.get("dns", {})
    gw_ping = results.get("baseline_latency", {}).get("gateway", {})
    mon = results.get("monitoring_summary", {})
    inet_stats = mon.get("internet_stats", {})

    inet_loss_pct = 0.0
    total = mon.get("gateway_total", 0)
    if total > 0:
        inet_loss_pct = round(mon.get("internet_loss_count", 0) / total * 100, 2)

    # Map connection type to wifi/wired
    conn_type = conn.get("type", "unknown")
    connection = "wifi" if conn_type == "wifi" else "wired"

    loc = meta.get("location") or {}

    return {
        "client_timestamp": meta.get("timestamp"),
        "platform": meta.get("platform", "unknown"),
        "connection": connection,
        "os": meta.get("os_version", "unknown"),
        "public_ip": meta.get("public_ip"),
        "city": loc.get("city"),
        "region": loc.get("region"),
        "country": loc.get("country"),
        "download_mbps": speed.get("dl_throughput_mbps"),
        "upload_mbps": speed.get("ul_throughput_mbps"),
        "rpm": speed.get("responsiveness_rpm"),
        "bufferbloat_ratio": speed.get("bufferbloat_ratio"),
        "gateway_latency_avg": gw_ping.get("avg_ms"),
        "gateway_latency_p95": mon.get("gateway_p95_ms"),
        "gateway_packet_loss_pct": gw_ping.get("packet_loss_pct", 0.0),
        "internet_latency_avg": inet_stats.get("avg"),
        "internet_packet_loss_pct": inet_loss_pct,
        "dns_avg_ms": dns.get("avg_time_ms"),
        "monitoring_duration_min": mon.get("duration_min", 0),
        "anomaly_count": mon.get("anomaly_count", 0),
        "rssi": ws.get("rssi_dbm"),
        "snr": ws.get("snr_db"),
        "channel_band": ws.get("channel_band"),
    }


def upload_result(results_file: str, handle: str, network: str, isp: Optional[str]) -> None:
    """Upload results to the community Firestore."""
    if not _firebase_configured():
        console.print("[red]Firebase is not configured. Set FIREBASE_PROJECT_ID and FIREBASE_API_KEY in wifify.py.[/]")
        return

    with open(results_file) as f:
        results = json.load(f)

    payload = extract_upload_payload(results)
    payload["handle"] = handle
    payload["network"] = network
    payload["isp"] = isp

    # Convert to Firestore document format
    fields = {k: to_firestore_value(v) for k, v in payload.items()}

    console.print("  Authenticating...", style="dim")
    try:
        token = firebase_anon_auth()
    except RuntimeError as e:
        console.print(f"[red]Auth error: {e}[/]")
        return

    console.print("  Uploading...", style="dim")
    doc_body = json.dumps({"fields": fields}).encode()
    url = f"{FIRESTORE_BASE_URL}/results"
    req = urllib.request.Request(url, data=doc_body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {token}")

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read().decode())
            doc_name = result.get("name", "")
            doc_id = doc_name.split("/")[-1] if doc_name else "unknown"
            console.print(f"\n  [bold green]Uploaded![/] Document ID: {doc_id}")
            console.print(f"  Category: [bold]{network} {payload['connection']}[/]")
            console.print(f"  View leaderboard: [dim]./start.sh leaderboard --network {network} --connection {payload['connection']}[/]")
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        console.print(f"[red]Upload failed ({e.code}): {body}[/]")
    except urllib.error.URLError as e:
        console.print(f"[red]Network error: {e.reason}[/]")


def prompt_upload_after_run(filepath: str) -> None:
    """Interactively prompt the user to upload results after a run."""
    if not _firebase_configured():
        return
    if not sys.stdin.isatty():
        return

    console.print()
    answer = input("  Upload to community leaderboard? (y/n): ").strip().lower()
    if answer not in ("y", "yes"):
        return

    handle = input("  Your display name (handle): ").strip()
    if not handle:
        console.print("  [yellow]Skipped — handle is required.[/]")
        return
    if len(handle) > 30:
        console.print("  [yellow]Skipped — handle must be 30 characters or less.[/]")
        return

    console.print("\n  Is this a public or private network?")
    console.print("    1. private (your home, office, etc.)")
    console.print("    2. public (hotel, coffee shop, hotspot, etc.)")
    choice = input("  Select (1/2): ").strip()
    if choice == "1":
        network = "private"
    elif choice == "2":
        network = "public"
    else:
        console.print("  [yellow]Skipped — invalid selection.[/]")
        return

    isp = input("  ISP name (optional, press Enter to skip): ").strip() or None

    upload_result(filepath, handle, network, isp)


# ---------------------------------------------------------------------------
# Community: Leaderboard
# ---------------------------------------------------------------------------


def fetch_leaderboard(network: str, connection: str, metric_field: str, limit: int) -> list[dict]:
    """Fetch top results from Firestore for a given network/connection combo."""
    # Determine sort direction
    lower_is_better = False
    for _, (field, _, lib) in LEADERBOARD_METRICS.items():
        if field == metric_field:
            lower_is_better = lib
            break
    direction = "ASCENDING" if lower_is_better else "DESCENDING"

    query = {
        "structuredQuery": {
            "from": [{"collectionId": "results"}],
            "where": {
                "compositeFilter": {
                    "op": "AND",
                    "filters": [
                        {
                            "fieldFilter": {
                                "field": {"fieldPath": "network"},
                                "op": "EQUAL",
                                "value": {"stringValue": network},
                            }
                        },
                        {
                            "fieldFilter": {
                                "field": {"fieldPath": "connection"},
                                "op": "EQUAL",
                                "value": {"stringValue": connection},
                            }
                        },
                    ],
                }
            },
            "orderBy": [{"field": {"fieldPath": metric_field}, "direction": direction}],
            "limit": limit,
        }
    }

    url = f"{FIRESTORE_BASE_URL}:runQuery"
    data = json.dumps(query).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        console.print(f"[red]Leaderboard query failed ({e.code}): {body}[/]")
        return []
    except urllib.error.URLError as e:
        console.print(f"[red]Network error: {e.reason}[/]")
        return []

    entries = []
    for item in raw:
        doc = item.get("document")
        if not doc:
            continue
        fields = doc.get("fields", {})
        entries.append({k: from_firestore_value(v) for k, v in fields.items()})

    return entries


def compute_percentile_rank(
    network: str, connection: str, field: str, value: float, lower_is_better: bool
) -> Optional[float]:
    """Compute what percentile the given value falls at."""
    all_entries = fetch_leaderboard(network, connection, field, limit=1000)
    if not all_entries:
        return None

    values = [e.get(field) for e in all_entries if e.get(field) is not None]
    if not values:
        return None

    if lower_is_better:
        worse_count = sum(1 for v in values if v > value)
    else:
        worse_count = sum(1 for v in values if v < value)

    return round((worse_count / len(values)) * 100, 1)


def display_leaderboard(
    entries: list[dict],
    metric_key: str,
    metric_label: str,
    lower_is_better: bool,
    network: str,
    connection: str,
    user_value: Optional[float] = None,
    user_percentile: Optional[float] = None,
) -> None:
    """Render leaderboard as a rich table."""
    title = f"Leaderboard: {metric_label} ({network} {connection})"
    table = Table(title=title, expand=True, show_edge=False)
    table.add_column("#", style="dim", width=4)
    table.add_column("Handle", style="bold", width=18)
    table.add_column(metric_label, justify="right", width=16)
    table.add_column("ISP", width=16)
    table.add_column("Date", style="dim", width=12)

    for i, entry in enumerate(entries, 1):
        val = entry.get(metric_key)
        val_str = f"{val:.1f}" if isinstance(val, (int, float)) else "—"
        handle = entry.get("handle", "?")
        isp = entry.get("isp") or "—"
        ts = entry.get("client_timestamp", "")
        date_str = ts[:10] if len(ts) >= 10 else "—"
        table.add_row(str(i), handle, val_str, isp, date_str)

    console.print(table)

    if user_value is not None:
        console.print()
        val_str = f"{user_value:.1f}"
        console.print(f"  Your result: [bold]{val_str}[/]")
        if user_percentile is not None:
            console.print(f"  Better than [bold green]{user_percentile}%[/] of {network} {connection} uploads")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wifify",
        description="macOS WiFi/network connectivity diagnostics and monitoring",
    )
    subparsers = parser.add_subparsers(dest="command")

    run_parser = subparsers.add_parser("run", help="Run diagnostic tests and monitor")
    run_parser.add_argument("--label", type=str, default=None, help="Label for this run (default: auto-detected)")
    run_parser.add_argument("--duration", type=float, default=15, help="Monitoring duration in minutes (default: 15)")
    run_parser.add_argument("--output", type=str, default=None, help="Output directory for results JSON (default: results/)")

    cmp_parser = subparsers.add_parser("compare", help="Compare two result files")
    cmp_parser.add_argument("file1", type=str, help="First results JSON file")
    cmp_parser.add_argument("file2", type=str, help="Second results JSON file")

    upload_parser = subparsers.add_parser("upload", help="Upload results to community")
    upload_parser.add_argument("file", type=str, help="Results JSON file")
    upload_parser.add_argument("--handle", type=str, help="Display name")
    upload_parser.add_argument("--network", type=str, choices=VALID_NETWORKS, help="public or private network")
    upload_parser.add_argument("--isp", type=str, default=None, help="ISP name (optional)")

    lb_parser = subparsers.add_parser("leaderboard", help="View community leaderboards")
    lb_parser.add_argument("--network", type=str, default="private", choices=VALID_NETWORKS)
    lb_parser.add_argument("--connection", type=str, default="wifi", choices=VALID_CONNECTIONS)
    lb_parser.add_argument("--metric", type=str, default="download", choices=LEADERBOARD_METRICS.keys())
    lb_parser.add_argument("--limit", type=int, default=20)
    lb_parser.add_argument("--compare", metavar="FILE", type=str, help="Show your percentile rank")

    return parser


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def run_diagnostics(label: Optional[str], duration: float, output_dir: Optional[str]) -> None:
    # Default output dir to results/ next to this script
    if output_dir is None:
        output_dir = str(Path(__file__).resolve().parent / "results")
    # Check macOS version for networkQuality
    mac_ver = platform.mac_ver()[0] if IS_MACOS else ""
    if mac_ver:
        try:
            major = int(mac_ver.split(".")[0])
            if major < 12:
                console.print(
                    "[yellow]Warning: networkQuality requires macOS 12+. Speed tests will be skipped.[/]"
                )
        except ValueError:
            pass

    now = datetime.now()
    console.print(Panel(
        f"[bold]wifify — Network Diagnostics[/]\n"
        f"{now.strftime('%Y-%m-%d %H:%M:%S')}",
        border_style="blue",
    ))

    # Phase 1: Connection detection
    console.print("\n[bold blue]Phase 1: Baseline Tests[/]")
    connection = detect_connection()
    auto_label = label or connection["type"]

    console.print(f"  Connection: [bold]{connection['type']}[/] via {connection['interface']} ({connection['hardware_port']})")
    console.print(f"  Gateway: {connection['gateway']}")
    console.print(f"  Label: [bold]{auto_label}[/]")

    # Detect public IP and location
    ip_info = fetch_public_ip_info()
    plat = "macos" if IS_MACOS else ("linux" if IS_LINUX else "unknown")

    if ip_info.get("public_ip"):
        location_parts = [p for p in [ip_info.get("city"), ip_info.get("region"), ip_info.get("country")] if p]
        location_str = ", ".join(location_parts) if location_parts else None
        console.print(f"  Public IP: {ip_info['public_ip']}")
        if location_str:
            console.print(f"  Location: {location_str}")

    results: dict[str, Any] = {
        "meta": {
            "version": "1.0.0",
            "timestamp": now.isoformat(),
            "timestamp_epoch": time.time(),
            "label": auto_label,
            "hostname": os.uname().nodename,
            "platform": plat,
            "os_version": f"macOS {mac_ver}" if mac_ver else (platform.platform() if IS_LINUX else "unknown"),
            "duration_min": duration,
            "public_ip": ip_info.get("public_ip"),
            "location": {
                "city": ip_info.get("city"),
                "region": ip_info.get("region"),
                "country": ip_info.get("country"),
            } if ip_info.get("public_ip") else None,
        },
        "connection": connection,
    }

    # Run baseline
    baseline = run_baseline(connection)
    results.update(baseline)

    # Phase 2: Monitoring
    console.print(f"\n[bold blue]Phase 2: Monitoring ({duration:.0f} min)[/]")

    # Get baseline gateway avg for anomaly detection
    gw_baseline = results.get("baseline_latency", {}).get("gateway", {})
    baseline_gw_avg = gw_baseline.get("avg_ms")

    samples, summary = run_monitoring(connection, duration, baseline_gw_avg)
    results["monitoring"] = samples
    results["monitoring_summary"] = summary

    # Phase 3: Summary
    console.print(f"\n[bold blue]Phase 3: Summary[/]")
    results["verdicts"] = generate_verdicts(results)
    print_summary(results)

    # Save results (strip rtts_ms from monitoring samples for file size)
    save_results = json.loads(json.dumps(results, default=str))
    for sample in save_results.get("monitoring", []):
        sample.pop("anomaly_reason", None)

    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    filename = f"wifify_{auto_label}_{now.strftime('%Y%m%d_%H%M%S')}.json"
    filepath = output_path / filename
    with open(filepath, "w") as f:
        json.dump(save_results, f, indent=2, default=str)

    console.print(f"\n  Results saved to: [bold green]{filepath}[/]")
    console.print(f"  Compare with:  [dim]./compare.sh {filepath} <other_file.json>[/]")

    # Offer to upload to community
    try:
        prompt_upload_after_run(str(filepath))
    except (KeyboardInterrupt, EOFError):
        pass


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    if args.command == "run":
        # Handle Ctrl+C gracefully — save partial results
        interrupted = False

        def handle_sigint(signum: int, frame: Any) -> None:
            nonlocal interrupted
            if not interrupted:
                interrupted = True
                console.print("\n[yellow]Interrupted — wrapping up and saving results...[/]")
                raise KeyboardInterrupt
            else:
                sys.exit(1)

        signal.signal(signal.SIGINT, handle_sigint)

        try:
            run_diagnostics(args.label, args.duration, args.output)
        except KeyboardInterrupt:
            console.print("[yellow]Partial results may have been saved.[/]")

    elif args.command == "compare":
        if not os.path.isfile(args.file1):
            console.print(f"[red]Error: File not found: {args.file1}[/]")
            sys.exit(1)
        if not os.path.isfile(args.file2):
            console.print(f"[red]Error: File not found: {args.file2}[/]")
            sys.exit(1)
        compare_results(args.file1, args.file2)

    elif args.command == "upload":
        if not os.path.isfile(args.file):
            console.print(f"[red]Error: File not found: {args.file}[/]")
            sys.exit(1)
        handle = args.handle
        if not handle:
            handle = input("Enter your display name (handle): ").strip()
            if not handle:
                console.print("[red]Handle is required.[/]")
                sys.exit(1)
        network = args.network
        if not network:
            network = input("Network type — public or private? ").strip().lower()
            if network not in VALID_NETWORKS:
                console.print(f"[red]Invalid network type. Choose from: {', '.join(VALID_NETWORKS)}[/]")
                sys.exit(1)
        upload_result(args.file, handle, network, args.isp)

    elif args.command == "leaderboard":
        metric_field, metric_label, lower_is_better = LEADERBOARD_METRICS[args.metric]
        entries = fetch_leaderboard(args.network, args.connection, metric_field, args.limit)

        user_value = None
        user_percentile = None
        if args.compare:
            if not os.path.isfile(args.compare):
                console.print(f"[red]Error: File not found: {args.compare}[/]")
                sys.exit(1)
            with open(args.compare) as f:
                user_results = json.load(f)
            payload = extract_upload_payload(user_results)
            user_value = payload.get(metric_field)
            if user_value is not None:
                user_percentile = compute_percentile_rank(
                    args.network, args.connection, metric_field, user_value, lower_is_better
                )

        display_leaderboard(
            entries, args.metric, metric_label, lower_is_better,
            args.network, args.connection, user_value, user_percentile,
        )


if __name__ == "__main__":
    main()
