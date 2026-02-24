# wifify

A network diagnostics tool that goes beyond simple speed tests. Run it for 15 minutes and get a clear picture of your connection quality — including intermittent issues like packet loss, latency spikes, and bufferbloat that quick speed tests miss.

Designed to help you understand *why* your WiFi feels slow, not just *how fast* it is.

## What it measures

**Baseline snapshot (~60s)**
- WiFi signal strength, noise floor, SNR, channel, and TX rate (macOS)
- Latency and packet loss to your gateway, Google DNS, Cloudflare, and more
- DNS resolution speed across multiple resolvers
- Traceroute to identify network hops and bottlenecks
- Download/upload speed and responsiveness via Apple's `networkQuality` (macOS)
- Bufferbloat detection — how much latency increases under load

**Continuous monitoring (default 15 min)**
- Pings your gateway and the internet every 5 seconds
- Samples WiFi signal strength every 30 seconds (macOS)
- Flags anomalies in real-time: packet loss, latency spikes, signal drops
- Live-updating terminal display

**Summary report**
- Aggregate stats: avg / min / max / P95 / P99 latency
- Total packet loss percentage
- Plain-english diagnosis of issues found
- Results saved to JSON for comparison

## Quick start

```bash
git clone https://github.com/byronsalty/wifify.git
cd wifify
./start.sh run
```

The script auto-creates a Python virtual environment and installs dependencies on first run.

## Usage

```bash
# Run a 15-minute diagnostic session
./start.sh run

# Run for a custom duration
./start.sh run --duration 5

# Label a run (auto-detected as wifi/ethernet by default)
./start.sh run --label wifi

# Compare two runs
./compare.sh results/wifify_wifi_*.json results/wifify_ethernet_*.json
```

## Comparing WiFi vs Ethernet

The real power is running the tool twice — once on WiFi and once on ethernet — to quantify the difference:

```bash
# Step 1: Run on WiFi
./start.sh run --label wifi

# Step 2: Plug in an ethernet cable, then run again
./start.sh run --label ethernet

# Step 3: See the difference
./compare.sh results/wifify_wifi_*.json results/wifify_ethernet_*.json
```

The comparison shows side-by-side metrics with deltas and percentage changes, color-coded to highlight improvements and regressions.

## Example output

```
Phase 1: Baseline Tests
  Connection: wifi via en0 (Wi-Fi)
  Gateway: 192.168.4.1

  WiFi Signal: -58 dBm | Noise: -92 dBm | SNR: 34 dB
  SSID: MyNetwork | Channel: 149 (5GHz, 80MHz) | TX Rate: 866 Mbps

  gateway: 4.7ms | 0.0% loss | 2.1ms jitter
  dns_google: 20.3ms | 0.0% loss | 3.4ms jitter

  DNS: system: avg 12ms | 8.8.8.8: avg 18ms | 1.1.1.1: avg 9ms
  Traceroute: 8 hops to 8.8.8.8
  Speed: 185.4 Mbps down / 37.1 Mbps up
  Responsiveness: 847 RPM
  Bufferbloat: +12ms under load (1.4x idle)

Phase 2: Monitoring (15 min)
  13:01:02  gateway 4.2ms  |  internet 18.3ms  |  signal -58 dBm
  13:01:07  gateway 3.8ms  |  internet 19.1ms  |  signal -58 dBm
  13:01:12  gateway 52.3ms |  internet 89.1ms  |  signal -71 dBm  !! SPIKE
  ...

Phase 3: Summary
  Avg Latency:    4.8 ms (gateway)  |  19.2 ms (internet)
  P95 Latency:   12.3 ms (gateway)
  Packet Loss:   0 / 180 (gateway)

  Diagnosis:
  ! Fair WiFi signal (-66 dBm) — consider moving closer to the router
  ✓ Good gateway latency (4.7ms)
  ✓ Download: 185.4 Mbps
  ✗ Severe bufferbloat — latency increases 25x under load
```

## Understanding the results

| Metric | Good | Okay | Problem |
|--------|------|------|---------|
| WiFi Signal (RSSI) | > -60 dBm | -60 to -70 dBm | < -70 dBm |
| Signal-to-Noise (SNR) | > 30 dB | 20–30 dB | < 20 dB |
| Gateway Latency | < 5 ms | 5–20 ms | > 20 ms |
| Packet Loss | 0% | < 2% | > 2% |
| Jitter | < 3 ms | 3–10 ms | > 10 ms |
| Download Speed | > 100 Mbps | 25–100 Mbps | < 25 Mbps |
| Bufferbloat | < 2x idle | 2–5x idle | > 5x idle |
| Responsiveness (RPM) | > 500 | 200–500 | < 200 |

**Bufferbloat** is when your router's buffers are too large, causing latency to spike under load (downloads, video calls, uploads). If your idle latency is 20ms but jumps to 500ms during a speed test, that's 25x bufferbloat. Fix it by enabling SQM/fq_codel on your router (available on OpenWrt, DD-WRT, Ubiquiti, Mikrotik, and others).

## Platform support

| Feature | macOS | Linux |
|---------|-------|-------|
| Connection detection | `networksetup` | `ip route` + `/sys/class/net/` |
| WiFi signal monitoring | `airport` / `system_profiler` | — |
| Speed + bufferbloat test | `networkQuality` | — |
| Latency monitoring | `ping` | `ping` |
| DNS resolution | `dig` | `dig` |
| Traceroute | `traceroute` | `traceroute` |
| Compare mode | JSON diff | JSON diff |

On Linux, WiFi signal and speed tests are skipped. Latency monitoring, DNS, traceroute, and the comparison engine all work.

## Requirements

- Python 3.7+
- macOS 12+ (Monterey) for speed/bufferbloat tests, or Linux
- No sudo required

Dependencies (`rich`) are installed automatically in a virtual environment on first run.

## How it works

The script uses only built-in OS tools — no custom packet crafting or raw sockets needed:

- **`ping`** — latency, jitter, and packet loss measurement
- **`dig`** — DNS resolution timing
- **`traceroute`** — route analysis
- **`networkQuality`** — Apple's built-in speed and responsiveness test (macOS)
- **`airport`** — WiFi signal metrics (macOS)
- **`ip route`** / **`networksetup`** — connection type detection

## License

[MIT](LICENSE)
