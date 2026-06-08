#!/bin/bash
# File: /docker-yocto-env/plugins/volume.sh

# Volume management plugin
# Backup, restore, rename, and inspect the workdir Docker volume for the current project.

volume_init() {
    register_plugin_command "volume" "volume" "Workdir volume management" \
        "volume {info|backup|restore|rename} - Manage the project workdir Docker volume"
}

volume() {
    local COMMAND="${1:-info}"
    local WORKDIR_VOLUME="${VOLUME_NAME}_workdir"
    local SSTATE_VOLUME="${SSTATE_VOLUME_NAME:-${VOLUME_NAME}-sstate}"

    _load_default_exports || return 1

    # Check whether a container is currently using a volume (by name).
    _vol_in_use() {
        ${CONTAINER_CMD} ps -a --filter "volume=$1" --format '{{.Names}}' 2>/dev/null | grep -q .
    }

    # Print a warning + interactive confirmation when the volume is live.
    _warn_if_in_use() {
        local vol="$1"
        if _vol_in_use "$vol"; then
            echo "⚠️  The following containers reference '$vol':"
            ${CONTAINER_CMD} ps -a --filter "volume=$vol" --format '  {{.Names}} ({{.Status}})'
            echo "   Stop them first to avoid an inconsistent snapshot."
            read -rp "   Continue anyway? [y/N] " yn || { echo "Aborted."; return 1; }
            [[ "$yn" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }
        fi
        return 0
    }

    case "$COMMAND" in
    info)
        echo "🗄️  Project: ${PROJECT_NAME}"
        echo "📦 Workdir volume: ${WORKDIR_VOLUME}"
        echo "📦 Sstate volume:  ${SSTATE_VOLUME}"
        echo ""
        echo "All volumes for this project:"
        ${CONTAINER_CMD} volume ls --format "{{.Name}}" 2>/dev/null \
            | grep "^${PROJECT_NAME}-" \
            | while read -r vol; do
                SIZE=$(${CONTAINER_CMD} run --rm -v "${vol}:/vol" alpine du -sh /vol 2>/dev/null \
                    | awk '{print $1}' || echo "?")
                IN_USE=""
                if _vol_in_use "$vol"; then IN_USE=" [in use]"; fi
                echo "  ${vol} (${SIZE})${IN_USE}"
            done
        ;;

    backup)
        local OUTPUT_DIR
        OUTPUT_DIR=$(realpath "${2:-$HOME/ws/volume-backups}")
        mkdir -p "$OUTPUT_DIR"

        local TIMESTAMP
        TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
        local ARCHIVE="${OUTPUT_DIR}/${WORKDIR_VOLUME}-${TIMESTAMP}.tar.gz"

        if ! ${CONTAINER_CMD} volume inspect "$WORKDIR_VOLUME" &>/dev/null; then
            echo "❌ Volume '$WORKDIR_VOLUME' does not exist."
            _unload_default_exports; return 1
        fi

        _warn_if_in_use "$WORKDIR_VOLUME" || { _unload_default_exports; return 1; }

        local SIZE
        SIZE=$(${CONTAINER_CMD} run --rm -v "${WORKDIR_VOLUME}:/vol" alpine \
            du -sh /vol 2>/dev/null | awk '{print $1}' || echo "unknown")

        echo "📦 Volume:  $WORKDIR_VOLUME (${SIZE})"
        echo "💾 Archive: $ARCHIVE"
        echo ""
        read -rp "Proceed with backup? [y/N] " confirm || { echo "Aborted."; _unload_default_exports; return 1; }
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; _unload_default_exports; return 0; }

        echo "Archiving (this may take several minutes)..."
        ${CONTAINER_CMD} run --rm \
            -v "${WORKDIR_VOLUME}:/vol:ro" \
            --mount "type=bind,src=${OUTPUT_DIR},dst=/backup" \
            alpine tar czf "/backup/$(basename "$ARCHIVE")" -C /vol .

        local ARCHIVE_SIZE
        ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | awk '{print $1}')
        echo "✅ Backup complete: $ARCHIVE (${ARCHIVE_SIZE})"
        ;;

    restore)
        local ARCHIVE="${2:-}"
        if [[ -z "$ARCHIVE" ]]; then
            echo "Usage: volume restore <archive.tar.gz>"
            _unload_default_exports; return 1
        fi
        if [[ ! -f "$ARCHIVE" ]]; then
            echo "❌ Archive not found: $ARCHIVE"
            _unload_default_exports; return 1
        fi

        local ARCHIVE_ABS
        ARCHIVE_ABS=$(realpath "$ARCHIVE")
        local ARCHIVE_DIR
        ARCHIVE_DIR=$(dirname "$ARCHIVE_ABS")
        local ARCHIVE_FILE
        ARCHIVE_FILE=$(basename "$ARCHIVE_ABS")

        # Refuse to restore into a non-empty volume to guarantee a clean result
        if ${CONTAINER_CMD} volume inspect "$WORKDIR_VOLUME" &>/dev/null; then
            local VOL_ITEMS
            VOL_ITEMS=$(${CONTAINER_CMD} run --rm -v "${WORKDIR_VOLUME}:/vol" alpine \
                sh -c "ls -A /vol | wc -l" 2>/dev/null || echo "0")
            if [[ "$VOL_ITEMS" -gt 0 ]]; then
                echo "❌ Volume '$WORKDIR_VOLUME' already exists and is non-empty (${VOL_ITEMS} items)."
                echo "   Restore requires an empty volume to guarantee a clean result."
                echo "   Remove it first:  ${CONTAINER_CMD} volume rm $WORKDIR_VOLUME"
                _unload_default_exports; return 1
            fi
        else
            echo "Creating volume '$WORKDIR_VOLUME'..."
            ${CONTAINER_CMD} volume create "$WORKDIR_VOLUME"
        fi

        local ARCHIVE_SIZE
        ARCHIVE_SIZE=$(du -sh "$ARCHIVE_ABS" | awk '{print $1}')
        echo "💾 Archive: $ARCHIVE_ABS (${ARCHIVE_SIZE})"
        echo "📦 Target:  $WORKDIR_VOLUME"
        echo ""
        read -rp "Proceed with restore? [y/N] " confirm || { echo "Aborted."; _unload_default_exports; return 1; }
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; _unload_default_exports; return 0; }

        echo "Restoring (this may take several minutes)..."
        ${CONTAINER_CMD} run --rm \
            -v "${WORKDIR_VOLUME}:/vol" \
            --mount "type=bind,src=${ARCHIVE_DIR},dst=/backup,readonly" \
            alpine tar xzf "/backup/${ARCHIVE_FILE}" -C /vol

        local SIZE
        SIZE=$(${CONTAINER_CMD} run --rm -v "${WORKDIR_VOLUME}:/vol" alpine \
            du -sh /vol 2>/dev/null | awk '{print $1}' || echo "unknown")
        echo "✅ Restore complete. Volume '$WORKDIR_VOLUME' is ${SIZE}."
        ;;

    rename)
        local NEW_NAME="${2:-}"
        local REMOVE_OLD=false
        [[ "${3:-}" == "--remove-old" ]] && REMOVE_OLD=true

        if [[ -z "$NEW_NAME" ]]; then
            echo "Usage: volume rename <new-volume-name> [--remove-old]"
            echo ""
            echo "Renames the current workdir volume by copying it to a new name."
            echo "Use this after moving the project directory so the build env finds the right volume."
            echo ""
            echo "Current volume: ${WORKDIR_VOLUME}"
            _unload_default_exports; return 1
        fi

        if ! ${CONTAINER_CMD} volume inspect "$WORKDIR_VOLUME" &>/dev/null; then
            echo "❌ Volume '$WORKDIR_VOLUME' does not exist."
            _unload_default_exports; return 1
        fi

        if ${CONTAINER_CMD} volume inspect "$NEW_NAME" &>/dev/null; then
            echo "❌ Target volume '$NEW_NAME' already exists. Remove it first:"
            echo "   ${CONTAINER_CMD} volume rm $NEW_NAME"
            _unload_default_exports; return 1
        fi

        _warn_if_in_use "$WORKDIR_VOLUME" || { _unload_default_exports; return 1; }

        local SIZE
        SIZE=$(${CONTAINER_CMD} run --rm -v "${WORKDIR_VOLUME}:/vol" alpine \
            du -sh /vol 2>/dev/null | awk '{print $1}' || echo "unknown")

        echo "📦 Source: $WORKDIR_VOLUME (${SIZE})"
        echo "📦 Target: $NEW_NAME"
        echo ""
        read -rp "Proceed with copy? [y/N] " confirm || { echo "Aborted."; _unload_default_exports; return 1; }
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; _unload_default_exports; return 0; }

        echo "Creating target volume..."
        ${CONTAINER_CMD} volume create "$NEW_NAME"

        # Remove target on any failure so re-runs don't hit the "already exists" guard
        _cleanup_on_err() {
            echo "❌ Copy failed. Cleaning up partial target volume..."
            ${CONTAINER_CMD} volume rm "$NEW_NAME" 2>/dev/null || true
        }
        trap _cleanup_on_err ERR

        echo "Copying data (this may take several minutes for a large sstate-cache)..."
        ${CONTAINER_CMD} run --rm \
            -v "${WORKDIR_VOLUME}:/from:ro" \
            -v "${NEW_NAME}:/to" \
            alpine ash -c "cp -a /from/. /to/ && echo 'Copy complete.'"

        trap - ERR

        local COPIED
        COPIED=$(${CONTAINER_CMD} run --rm -v "${NEW_NAME}:/vol" alpine \
            du -sh /vol 2>/dev/null | awk '{print $1}' || echo "unknown")
        echo "Target volume size: ${COPIED}"

        if $REMOVE_OLD; then
            echo "Removing source volume '$WORKDIR_VOLUME'..."
            ${CONTAINER_CMD} volume rm "$WORKDIR_VOLUME"
            echo "✅ Done. Old volume removed."
        else
            echo "✅ Done. Source volume '$WORKDIR_VOLUME' retained."
            echo "   Remove it later with: ${CONTAINER_CMD} volume rm $WORKDIR_VOLUME"
        fi
        ;;

    *)
        echo "Usage: volume {info|backup|restore|rename}"
        echo ""
        echo "  info               Show current project volumes and sizes"
        echo "  backup [dir]       Archive workdir volume to tar.gz (default: ~/ws/volume-backups)"
        echo "  restore <archive>  Restore workdir volume from archive (requires empty target)"
        echo "  rename <name> [--remove-old]  Copy workdir volume to a new name"
        _unload_default_exports; return 1
        ;;
    esac

    _unload_default_exports
}
