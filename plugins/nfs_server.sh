#!/bin/bash
# File: /docker-yocto-env/plugins/nfs_server.sh

# NFS server plugin
# Manages NFS server for netboot functionality

# Plugin initialization
nfs_server_init() {
    register_plugin_command "nfs_server" "nfs_server" "NFS server management" "nfs_server {start|stop|status} - Manage NFS server for netboot"
}

nfs_server() {
    local COMMAND="$1"

    case ${COMMAND} in
        start)
            sudo ${SCRIPT_DIR}/scripts/start_socat.sh >> socat_nfs.log 2>&1
            ;;
        stop)
            sudo ${SCRIPT_DIR}/scripts/stop_socat.sh >> socat_nfs.log 2>&1
            ;;
        status)
            local count
            count=$(sudo sh -c "ps -ax | grep socat | grep -v grep | wc -l" | xargs)
            if [ "$count" -ne 0 ]; then
                echo "NFS server is running"
            else
                echo "NFS server is not running"
            fi
            ;;
        *)
            echo "Usage: nfs_server {start|stop|status}"
            return 1
            ;;
    esac
}

# Create alias for backward compatibility with hyphenated command
alias nfs-server='nfs_server'