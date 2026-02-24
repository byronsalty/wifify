#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"
WIFIFY="$SCRIPT_DIR/wifify.py"

# Colors
BOLD='\033[1m'
BLUE='\033[34m'
GREEN='\033[32m'
DIM='\033[2m'
RESET='\033[0m'

# Ensure venv exists
if [ ! -d "$VENV_DIR" ]; then
    if ! python3 -c "import ensurepip" >/dev/null 2>&1; then
        PY_MINOR=$(python3 -c 'import sys; print(sys.version_info.minor)')
        echo -e "${BOLD}${YELLOW}python3-venv is required but not installed.${RESET}"
        echo -e "  Install it with: sudo apt install python3.${PY_MINOR}-venv"
        exit 1
    fi
    echo -e "${BOLD}Setting up virtual environment...${RESET}"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --quiet rich
    echo -e "${GREEN}Setup complete.${RESET}\n"
fi

PYTHON="$VENV_DIR/bin/python3"

# If not enough args, show usage
if [ $# -lt 2 ]; then
    echo -e "${BOLD}${BLUE}wifify — Compare Runs${RESET}"
    echo ""
    echo -e "${BOLD}Usage:${RESET}"
    echo ""
    echo -e "  ${GREEN}./compare.sh <file1.json> <file2.json>${RESET}"
    echo ""
    echo -e "${BOLD}Examples:${RESET}"
    echo ""
    echo -e "  ${DIM}# Compare a WiFi run against an Ethernet run${RESET}"
    echo -e "  ./compare.sh wifify_wifi_20260223_103000.json wifify_ethernet_20260223_110000.json"
    echo ""
    echo -e "  ${DIM}# Use wildcards to grab the latest of each${RESET}"
    echo -e "  ./compare.sh results/wifify_wifi_*.json results/wifify_ethernet_*.json"
    echo ""
    echo -e "${BOLD}Available result files:${RESET}"
    echo ""
    found=0
    for f in "$SCRIPT_DIR"/results/wifify_*.json "$PWD"/results/wifify_*.json; do
        if [ -f "$f" ]; then
            echo -e "  ${DIM}$(basename "$f")${RESET}"
            found=1
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo -e "  ${DIM}(none found — run ./start.sh run first)${RESET}"
    fi
    echo ""
    exit 0
fi

exec "$PYTHON" "$WIFIFY" compare "$@"
