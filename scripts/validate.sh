#!/usr/bin/env bash
# Run shellcheck on all project shell scripts
#
# Usage: ./scripts/validate.sh
# Exit code: 0 if all scripts pass, 1 if any issues found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v shellcheck &>/dev/null; then
    echo "ERROR: shellcheck is not installed" >&2
    echo "Install with: brew install shellcheck (macOS) or apt-get install shellcheck (Ubuntu)" >&2
    exit 1
fi

scripts=(
    "$SCRIPT_DIR/launch.sh"
    "$SCRIPT_DIR/inject-secrets.sh"
    "$SCRIPT_DIR/validate.sh"
)

errors=0
for script in "${scripts[@]}"; do
    if [[ ! -f "$script" ]]; then
        echo "WARN: $script not found, skipping" >&2
        continue
    fi
    echo "Checking $(basename "$script")..."
    if ! shellcheck -x "$script"; then
        ((errors++))
    fi
done

if [[ "$errors" -gt 0 ]]; then
    echo "FAIL: $errors script(s) had issues" >&2
    exit 1
fi

echo "PASS: all scripts clean"
