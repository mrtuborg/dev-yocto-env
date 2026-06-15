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

# Set container-internal build-cache paths only when the volume mount points
# are present — i.e. we are running inside the docker-yocto-env container.
# On a bare host the volume directories don't exist, so we leave SSTATE_DIR,
# DL_DIR, and TMPDIR to whatever local.conf or the caller has set.
if [ -d /workdir ] && [ -d /sstate-cache ]; then
    export SSTATE_DIR="${SSTATE_DIR:-/sstate-cache}"
    export DL_DIR="${DL_DIR:-/workdir/downloads}"
    export TMPDIR="${TMPDIR:-/workdir/tmp}"
    _CONTAINER_PATHS="SSTATE_DIR DL_DIR TMPDIR"
fi

# Extract passthrough additions from local.conf (skip comment lines)
PASSTHROUGH=$(grep -h "^[[:space:]]*BB_ENV_PASSTHROUGH_ADDITIONS[[:space:]]*+=" "$LOCALCONF" \
    | sed -e 's/.*BB_ENV_PASSTHROUGH_ADDITIONS[[:space:]]*+=//g' \
          -e 's/"//g')

# When running inside the container, always include the cache-path vars so
# BitBake sees them through its environment sanitisation regardless of what
# local.conf declares.
PASSTHROUGH="$PASSTHROUGH ${_CONTAINER_PATHS:-}"
unset _CONTAINER_PATHS

# Deduplicate and apply them to the environment BEFORE setup-environment runs
PASSTHROUGH=$(echo $PASSTHROUGH | tr ' ' '\n' | sort -u | tr '\n' ' ')
export BB_ENV_PASSTHROUGH_ADDITIONS="$PASSTHROUGH"

echo "Build directory detected: $BUILDDIR"
echo "Applied passthrough additions:"
echo "  BB_ENV_PASSTHROUGH_ADDITIONS=\"$BB_ENV_PASSTHROUGH_ADDITIONS\""
