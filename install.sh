#!/usr/bin/env bash
set -euo pipefail

# wifify installer
# Usage: curl -fsSL https://raw.githubusercontent.com/byronsalty/wifify/main/install.sh | bash

REPO="https://github.com/byronsalty/wifify.git"
INSTALL_DIR="${WIFIFY_DIR:-$HOME/wifify}"

# Colors
BOLD='\033[1m'
BLUE='\033[34m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
DIM='\033[2m'
RESET='\033[0m'

info()  { echo -e "${BLUE}==>${RESET} ${BOLD}$1${RESET}"; }
good()  { echo -e "${GREEN}==>${RESET} ${BOLD}$1${RESET}"; }
warn()  { echo -e "${YELLOW}==>${RESET} $1"; }
fail()  { echo -e "${RED}==>${RESET} $1"; exit 1; }

echo ""
echo -e "${BOLD}${BLUE}wifify installer${RESET}"
echo ""

# Check dependencies
command -v git >/dev/null 2>&1 || fail "git is required. Install it with your package manager."
command -v python3 >/dev/null 2>&1 || fail "python3 is required. Install it with your package manager."

# Check Python version (need 3.7+)
PY_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 7 ]; }; then
    fail "Python 3.7+ is required (found $PY_VERSION)."
fi

# Check that python3-venv is available (common missing package on Debian/Ubuntu)
if ! python3 -c "import ensurepip" >/dev/null 2>&1; then
    echo ""
    fail "python3-venv is required but not installed.\n\n  Install it with:\n    sudo apt install python3.${PY_MINOR}-venv\n\n  Then re-run this installer."
fi

# Clone or update
if [ -d "$INSTALL_DIR" ]; then
    if [ -d "$INSTALL_DIR/.git" ]; then
        info "Updating existing installation..."
        git -C "$INSTALL_DIR" pull --quiet
    else
        fail "$INSTALL_DIR already exists and is not a git repo. Remove it or set WIFIFY_DIR to a different path."
    fi
else
    info "Cloning wifify..."
    git clone --quiet "$REPO" "$INSTALL_DIR"
fi

# Set up venv
info "Setting up Python environment..."
if [ ! -f "$INSTALL_DIR/venv/bin/pip" ]; then
    rm -rf "$INSTALL_DIR/venv"
    python3 -m venv "$INSTALL_DIR/venv"
fi
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade rich

# Make scripts executable
chmod +x "$INSTALL_DIR/start.sh" "$INSTALL_DIR/compare.sh"

# Done
echo ""
good "wifify installed to $INSTALL_DIR"
echo ""
echo -e "  ${BOLD}Run a diagnostic session:${RESET}"
echo -e "    cd $INSTALL_DIR && ./start.sh run"
echo ""
echo -e "  ${BOLD}Or add it to your PATH:${RESET}"
echo -e "    export PATH=\"$INSTALL_DIR:\$PATH\""
echo ""
echo -e "  ${DIM}Run ./start.sh with no args for full usage info.${RESET}"
echo ""
