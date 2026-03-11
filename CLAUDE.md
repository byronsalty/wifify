# wifify

Network diagnostics tool — measures WiFi/network quality over time (latency, packet loss, signal strength, bufferbloat, speed).

## Stack

- Python 3.7+ (single file: `wifify.py`)
- Shell scripts: `start.sh` (entry point), `compare.sh`, `install.sh`
- Dependency: `rich` (installed in venv automatically)
- iOS client in `ios/Wifify/` (Swift)

## Project structure

- `wifify.py` — all Python logic (diagnostics, monitoring, comparison, community upload/leaderboard)
- `start.sh` — entry point, sets up venv, delegates to wifify.py
- `compare.sh` — shortcut for compare mode
- `install.sh` — curl-pipe installer for users
- `results/` — saved JSON diagnostic results (gitignored)
- `ios/` — iOS Swift client (in progress)

## Task runner

Use `just` for common tasks. Run `just --list` to see available recipes.

## Key conventions

- This is an open source project (MIT license, public GitHub repo)
- No secrets or API keys in the repo
- Single-file Python architecture — keep `wifify.py` as the sole Python source
- Platform-aware: macOS gets full features, Linux gets a subset (no WiFi signal, no speed test)
- The tool uses only built-in OS commands (ping, dig, traceroute, networkQuality, airport)
