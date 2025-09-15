#!/bin/bash
# File: /docker-yocto-env-1/plugins/rpm_host.sh

# RPM host service plugin
# Manages RPM repository hosting service

# Plugin initialization
rpm_host_init() {
    register_plugin_command "rpm_host" "rpm_host" "RPM repository hosting service" "rpm_host {start|stop|status} [port] - Manage RPM host service"
}

rpm_host() {
    local COMMAND="$1"
    local PORT="${2:-${DL_PORT}}" # Use the second argument or default to DL_PORT

    _load_default_exports
    case ${COMMAND} in
        start)
            _start_compose_service "rpm-host" "DL_PORT" "$PORT"
            ;;
        stop)
            _stop_compose_service "rpm-host"
            ;;
        status)
            echo "📊 Checking rpm-host service status..."
            local container_name="${VOLUME_NAME}_rpm-host"
            if ${CONTAINER_CMD} ps -q --filter "name=${container_name}" | grep -q .; then
                echo "✅ rpm-host is running"
                ${CONTAINER_CMD} ps --filter "name=${container_name}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            else
                echo "❌ rpm-host is not running"
            fi
            ;;
        *)
            echo "Usage: rpm_host {start|stop|status} [port]"
            return 1
            ;;
    esac
    _unload_default_exports
}

# Create alias for backward compatibility with hyphenated command
alias rpm-host='rpm_host'