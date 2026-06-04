#!/bin/bash
# volume-rename.sh — Copy a Docker volume to a new name and optionally remove the old one.
#
# Use this before moving the project directory to a new path. The volume name is
# derived from the project directory name (see core/config.sh: PROJECT_NAME), so
# a renamed/moved directory will look for a different volume on next startup.
#
# Usage:
#   ./docker-yocto-env/scripts/volume-rename.sh <old-volume> <new-volume> [--remove-old]
#
# Example:
#   ./docker-yocto-env/scripts/volume-rename.sh \
#       roomboard-linux-github-x86_64_workdir \
#       roomboard-linux-x86_64_workdir \
#       --remove-old
#
# To find the current volume name:
#   docker volume ls | grep workdir

set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <old-volume> <new-volume> [--remove-old]"
    echo ""
    echo "  <old-volume>   Source volume name (current)"
    echo "  <new-volume>   Target volume name (new directory name)"
    echo "  --remove-old   Delete the source volume after copying (optional)"
    exit 1
}

_volume_in_use() {
    docker ps -a --filter "volume=$1" --format '{{.Names}}' 2>/dev/null | grep -q .
}

[[ $# -lt 2 ]] && usage

OLD_VOLUME="$1"
NEW_VOLUME="$2"
REMOVE_OLD=false
[[ "${3:-}" == "--remove-old" ]] && REMOVE_OLD=true

# Verify source volume exists
if ! docker volume inspect "$OLD_VOLUME" &>/dev/null; then
    echo "ERROR: Source volume '$OLD_VOLUME' not found."
    echo "Available volumes:"
    docker volume ls --format '  {{.Name}}' | grep workdir || true
    exit 1
fi

# Warn if a container is using the source volume
if _volume_in_use "$OLD_VOLUME"; then
    echo "WARNING: The following containers reference '$OLD_VOLUME':"
    docker ps -a --filter "volume=$OLD_VOLUME" --format '  {{.Names}} ({{.Status}})'
    echo "Stop them before copying to avoid an inconsistent snapshot."
    read -rp "Continue anyway? [y/N] " yn || { echo "Aborted."; exit 1; }
    [[ "$yn" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# Refuse to overwrite an existing target
if docker volume inspect "$NEW_VOLUME" &>/dev/null; then
    echo "ERROR: Target volume '$NEW_VOLUME' already exists. Remove it first:"
    echo "  docker volume rm $NEW_VOLUME"
    exit 1
fi

# Estimate size
SIZE=$(docker run --rm -v "${OLD_VOLUME}:/vol" alpine du -sh /vol 2>/dev/null | awk '{print $1}' || echo "unknown")
echo "Source volume: $OLD_VOLUME (${SIZE})"
echo "Target volume: $NEW_VOLUME"
echo ""

read -rp "Proceed with copy? [y/N] " confirm || { echo "Aborted."; exit 1; }
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo "Creating target volume..."
docker volume create "$NEW_VOLUME"

# Remove target on any failure so re-runs don't hit the "already exists" guard
trap 'echo "ERROR: Copy failed. Cleaning up partial target volume..."; docker volume rm '"$NEW_VOLUME"' 2>/dev/null || true' ERR

echo "Copying data (this may take several minutes for a large sstate-cache)..."
docker run --rm \
    -v "${OLD_VOLUME}:/from" \
    -v "${NEW_VOLUME}:/to" \
    alpine ash -c "cp -a /from/. /to/ && echo 'Copy complete.'"

# Disable the error trap now that copy succeeded
trap - ERR

COPIED=$(docker run --rm -v "${NEW_VOLUME}:/vol" alpine du -sh /vol 2>/dev/null | awk '{print $1}' || echo "unknown")
echo "Target volume size: ${COPIED}"

if $REMOVE_OLD; then
    echo "Removing source volume '$OLD_VOLUME'..."
    docker volume rm "$OLD_VOLUME"
    echo "Done. Old volume removed."
else
    echo "Done. Source volume '$OLD_VOLUME' retained."
    echo "Remove it later with: docker volume rm $OLD_VOLUME"
fi
