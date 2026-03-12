# wifify task runner

# Run a diagnostic session (default 15 min)
[group('run')]
run *ARGS:
    ./start.sh run {{ARGS}}

# Compare two result files
[group('run')]
compare FILE1 FILE2:
    ./compare.sh {{FILE1}} {{FILE2}}

# Upload results to community leaderboard
[group('run')]
upload *ARGS:
    ./start.sh upload {{ARGS}}

# View community leaderboard
[group('run')]
leaderboard *ARGS:
    ./start.sh leaderboard {{ARGS}}

# Update metadata on a saved result file
[group('run')]
update *ARGS:
    ./start.sh update {{ARGS}}

# Set up Python venv and install dependencies
[group('dev')]
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f venv/bin/pip ]; then
        python3 -m venv venv
    fi
    venv/bin/pip install --quiet --upgrade rich

# Print current version
[group('dev')]
version:
    @cat VERSION

# Run the test suite
[group('dev')]
test:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "No tests configured yet."

# Tag a release (e.g. just release 0.2.0)
[group('dev')]
release VERSION:
    bin/release {{VERSION}}

# Commit staged changes with an AI-generated message
[group('git')]
commit:
    #!/usr/bin/env bash
    set -euo pipefail
    if git diff --cached --quiet; then
        echo "No staged changes to commit."
        exit 1
    fi
    echo "Generating commit message with Claude..."
    DIFF=$(git diff --cached)
    MSG=$(echo "$DIFF" | claude -p "Write a concise git commit message for this diff. Output ONLY the commit message, nothing else. Use conventional style: a short summary line (max 72 chars), lowercase, imperative mood, no period at the end.")
    echo ""
    echo "Commit message: $MSG"
    echo ""
    git commit -m "$MSG"
