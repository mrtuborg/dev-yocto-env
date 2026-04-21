#!/bin/bash
# File: /docker-yocto-env/plugins/filebrowser.sh

# Filebrowser service plugin
# Manages filebrowser web interface

# Plugin initialization
filebrowser_init() {
    register_plugin_command "filebrowser" "filebrowser" "File browser web interface" "filebrowser {start|stop|status} [port] - Manage filebrowser service"
}

filebrowser() {
    local COMMAND="$1"
    local PORT="${2:-${FILEBROWSER_PORT}}" # Use the second argument or default to FILEBROWSER_PORT
    _load_default_exports || return 1

    case ${COMMAND} in
        start)
            _start_compose_service "filebrowser" "FILEBROWSER_PORT" "$PORT"
            ;;
        stop)
            _stop_compose_service "filebrowser"
            ;;
        status)
            _status_compose_service "filebrowser"
            ;;
        *)
            echo "Usage: filebrowser {start|stop|status} [port]"
            return 1
            ;;
    esac

    _unload_default_exports
}