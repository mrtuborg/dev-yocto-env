#!/bin/bash
# volume-backup.sh — Archive a Docker volume to a compressed tar file, or restore from one.
#
# Useful before major changes (workspace moves, Docker upgrades, machine migrations).
# The archive preserves full file permissions and ownership.
#
# Usage:
#   Backup:   ./docker-yocto-env/scripts/volume-backup.sh backup  <volume> [output-dir]
#   Restore:  ./docker-yocto-env/scripts/volume-backup.sh restore <volume> <archive.tar.gz>
#
# Examples:
#   # Backup current workdir volume to ~/ws/volume-backups/
#   ./docker-yocto-env/scripts/volume-backup.sh backup roomboard-linux-x86_64_workdir ~/ws/volume-backups
#
#   # Restore into an existing (or new) volume
#   ./docker-yocto-env/scripts/volume-backup.sh restore roomboard-linux-x86_64_workdir \
#       ~/ws/volume-backups/roomboard-linux-x86_64_workdir-2026-06-04.tar.gz
#
# To find the current volume name:
#   docker volume ls | grep workdir

set -euo pipefail

usage() {
    echo "Usage:"
    echo "  $(basename "$0") backup  <volume> [output-dir]"
    echo "  $(basename "$0") restore <volume> <archive.tar.gz>"
    exit 1
}

_volume_in_use() {
    docker ps -a --filter "volume=$1" --format '{{.Names}}' 2>/dev/null | grep -q .
}

[[ $# -lt 2 ]] && usage

COMMAND="$1"
VOLUME="$2"

case "$COMMAND" in
backup)
    OUTPUT_DIR=$(realpath "${3:-$HOME/ws/volume-backups}")
    mkdir -p "$OUTPUT_DIR"
    TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
    ARCHIVE="${OUTPUT_DIR}/${VOLUME}-${TIMESTAMP}.tar.gz"

    if ! docker volume inspect "$VOLUME" &>/dev/null; then
        echo "ERROR: Volume '$VOLUME' not found."
        exit 1
    fi

    if _volume_in_use "$VOLUME"; then
        echo "WARNING: The following containers reference '$VOLUME':"
        docker ps -a --filter "volume=$VOLUME" --format '  {{.Names}} ({{.Status}})'
        echo "Stop them before backing up to avoid an inconsistent snapshot."
        read -rp "Continue anyway? [y/N] " yn || { echo "Aborted."; exit 1; }
        [[ "$yn" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi

    SIZE=$(docker run --rm -v "${VOLUME}:/vol" alpine du -sh /vol 2>/dev/null | awk '{print $1}' || echo "unknown")
    echo "Volume:  $VOLUME (${SIZE})"
    echo "Archive: $ARCHIVE"
    echo ""
    read -rp "Proceed with backup? [y/N] " confirm || { echo "Aborted."; exit 1; }
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

    echo "Archiving (this may take several minutes)..."
    docker run --rm \
        -v "${VOLUME}:/vol:ro" \
        --mount "type=bind,src=${OUTPUT_DIR},dst=/backup" \
        alpine tar czf "/backup/$(basename "$ARCHIVE")" -C /vol .

    ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | awk '{print $1}')
    echo "Backup complete: $ARCHIVE (${ARCHIVE_SIZE})"
    ;;

restore)
    ARCHIVE="${3:-}"
    [[ -z "$ARCHIVE" ]] && { echo "ERROR: archive path required for restore."; usage; }
    [[ ! -f "$ARCHIVE" ]] && { echo "ERROR: Archive '$ARCHIVE' not found."; exit 1; }

    ARCHIVE_ABS=$(realpath "$ARCHIVE")
    ARCHIVE_DIR=$(dirname "$ARCHIVE_ABS")
    ARCHIVE_FILE=$(basename "$ARCHIVE_ABS")

    # Refuse to restore into a non-empty volume to guarantee a clean state
    if docker volume inspect "$VOLUME" &>/dev/null; then
        VOL_ITEMS=$(docker run --rm -v "${VOLUME}:/vol" alpine sh -c "ls -A /vol | wc -l" 2>/dev/null || echo "0")
        if [[ "$VOL_ITEMS" -gt 0 ]]; then
            echo "ERROR: Volume '$VOLUME' already exists and is non-empty (${VOL_ITEMS} items)."
            echo "Restore requires an empty volume to guarantee a clean result."
            echo "Remove it first:  docker volume rm $VOLUME"
            echo "Then re-run this command to create a fresh volume and restore into it."
            exit 1
        fi
    else
        echo "Creating volume '$VOLUME'..."
        docker volume create "$VOLUME"
    fi

    ARCHIVE_SIZE=$(du -sh "$ARCHIVE_ABS" | awk '{print $1}')
    echo "Archive: $ARCHIVE_ABS (${ARCHIVE_SIZE})"
    echo "Target:  $VOLUME"
    echo ""
    read -rp "Proceed with restore? [y/N] " confirm || { echo "Aborted."; exit 1; }
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

    echo "Restoring (this may take several minutes)..."
    docker run --rm \
        -v "${VOLUME}:/vol" \
        --mount "type=bind,src=${ARCHIVE_DIR},dst=/backup,readonly" \
        alpine tar xzf "/backup/${ARCHIVE_FILE}" -C /vol

    SIZE=$(docker run --rm -v "${VOLUME}:/vol" alpine du -sh /vol 2>/dev/null | awk '{print $1}' || echo "unknown")
    echo "Restore complete. Volume '$VOLUME' is ${SIZE}."
    ;;

*)
    echo "ERROR: Unknown command '$COMMAND'."
    usage
    ;;
esac
