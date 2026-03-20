#!/bin/bash
set -e

# Must be sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "This script must be sourced:"
    echo "  source apply_passthrough.sh"
    exit 1
fi

# Determine the directory where this script resides
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILDDIR="$SCRIPT_DIR"

LOCALCONF="$BUILDDIR/conf/local.conf"

if [ ! -f "$LOCALCONF" ]; then
    echo "Error: $LOCALCONF not found."
    echo "Place this script inside your Yocto build directory."
    return 1 2>/dev/null || exit 1
fi

# Extract passthrough additions from local.conf
PASSTHROUGH=$(grep -h "BB_ENV_PASSTHROUGH_ADDITIONS" "$LOCALCONF" \
    | sed -e 's/.*BB_ENV_PASSTHROUGH_ADDITIONS[[:space:]]*+=//g' \
          -e 's/"//g')

# Apply them to the environment BEFORE setup-environment runs
export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS $PASSTHROUGH"

echo "Build directory detected: $BUILDDIR"
echo "Applied passthrough additions:"
echo "  BB_ENV_PASSTHROUGH_ADDITIONS=\"$BB_ENV_PASSTHROUGH_ADDITIONS\""
