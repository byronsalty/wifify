#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"
WIFIFY="$SCRIPT_DIR/wifify.py"

# Colors
BOLD='\033[1m'
BLUE='\033[34m'
GREEN='\033[32m'
YELLOW='\033[33m'
DIM='\033[2m'
RESET='\033[0m'

# Ensure venv exists
if [ ! -f "$VENV_DIR/bin/pip" ]; then
    if ! python3 -c "import ensurepip" >/dev/null 2>&1; then
        PY_MINOR=$(python3 -c 'import sys; print(sys.version_info.minor)')
        echo -e "${BOLD}${YELLOW}python3-venv is required but not installed.${RESET}"
        echo -e "  Install it with: sudo apt install python3.${PY_MINOR}-venv"
        exit 1
    fi
    rm -rf "$VENV_DIR"
    echo -e "${YELLOW}Setting up virtual environment...${RESET}"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --quiet rich
    echo -e "${GREEN}Setup complete.${RESET}\n"
fi

PYTHON="$VENV_DIR/bin/python3"

# If no args, show usage
if [ $# -eq 0 ]; then
    echo -e "${BOLD}${BLUE}wifify — WiFi/Network Diagnostics${RESET}"
    echo ""
    echo -e "${BOLD}Usage:${RESET}"
    echo ""
    echo -e "  ${GREEN}./start.sh run${RESET}                       Run a 15-minute diagnostic session"
    echo -e "  ${GREEN}./start.sh run --duration 5${RESET}          Run for 5 minutes instead"
    echo -e "  ${GREEN}./start.sh run --label wifi${RESET}          Tag this run as 'wifi' (auto-detected by default)"
    echo -e "  ${GREEN}./start.sh run --label ethernet${RESET}      Tag this run as 'ethernet'"
    echo -e "  ${GREEN}./start.sh compare FILE1 FILE2${RESET}       Compare two saved result files"
    echo ""
    echo -e "${BOLD}Typical workflow:${RESET}"
    echo ""
    echo -e "  ${DIM}# Step 1: Run on WiFi${RESET}"
    echo -e "  ./start.sh run --label wifi"
    echo ""
    echo -e "  ${DIM}# Step 2: Plug in ethernet cable, then run again${RESET}"
    echo -e "  ./start.sh run --label ethernet"
    echo ""
    echo -e "  ${DIM}# Step 3: Compare the two runs${RESET}"
    echo -e "  ./compare.sh results/wifify_wifi_*.json results/wifify_ethernet_*.json"
    echo ""
    echo -e "${BOLD}What it tests:${RESET}"
    echo ""
    echo -e "  ${BLUE}Phase 1 — Baseline (~60s)${RESET}"
    echo -e "    • WiFi signal strength, noise, SNR, channel (if on WiFi)"
    echo -e "    • Latency & packet loss to gateway, Google DNS, Cloudflare, etc."
    echo -e "    • DNS resolution speed across multiple resolvers"
    echo -e "    • Traceroute to identify network hops"
    echo -e "    • Speed test + bufferbloat detection via networkQuality (macOS only)"
    echo ""
    echo -e "  ${BLUE}Phase 2 — Continuous Monitoring (default 15 min)${RESET}"
    echo -e "    • Pings gateway + internet every 5 seconds"
    echo -e "    • Samples WiFi signal every 30 seconds (macOS WiFi only)"
    echo -e "    • Flags anomalies: packet loss, latency spikes, signal drops"
    echo -e "    • Live updating display in your terminal"
    echo ""
    echo -e "  ${BLUE}Phase 3 — Summary${RESET}"
    echo -e "    • Aggregate stats: avg/min/max/P95/P99 latency, total packet loss"
    echo -e "    • Plain-english diagnosis of any issues found"
    echo -e "    • Results saved to JSON for comparison"
    echo ""
    echo -e "${BOLD}Options:${RESET}"
    echo ""
    echo -e "  --label NAME       Label for this run (default: auto-detected wifi/ethernet)"
    echo -e "  --duration MINS    Monitoring duration in minutes (default: 15)"
    echo -e "  --output DIR       Directory to save results (default: current directory)"
    echo ""
    echo -e "${DIM}Press Ctrl+C at any time to stop monitoring early and save partial results.${RESET}"
    exit 0
fi

exec "$PYTHON" "$WIFIFY" "$@"
