#!/bin/bash
# File: /docker-yocto-env/core/plugin_loader.sh

# This script dynamically loads plugin scripts from the plugins directory
# and provides a command registration system for organizing functionality.

# Directory containing the plugins
# Use SCRIPT_DIR if available, otherwise calculate from current file
if [ -n "${SCRIPT_DIR}" ]; then
    PLUGINS_DIR="${SCRIPT_DIR}/plugins"
else
    PLUGINS_DIR="$(dirname "$(realpath "$0")")/../plugins"
fi

# Simple command tracking using regular variables
PLUGIN_COMMAND_LIST=""
PLUGIN_HELP_LIST=""

# Function to register a plugin command
register_plugin_command() {
    local plugin_name="$1"
    local command="$2"
    local help_text="$3"
    local description="${4:-$help_text}"
    
    # Validate inputs
    if [ -z "$plugin_name" ] || [ -z "$command" ] || [ -z "$help_text" ]; then
        echo "ERROR: Invalid plugin command registration - missing required parameters" >&2
        return 1
    fi
    
    # Add to our simple lists (format: command:plugin:description)
    PLUGIN_COMMAND_LIST="${PLUGIN_COMMAND_LIST}${command}:${plugin_name}:${description}
"
}

# Function to show all available commands
show_plugin_commands() {
    echo "Available plugin commands:"
    echo "============================================"
    
    if [ -z "$PLUGIN_COMMAND_LIST" ]; then
        echo "No plugin commands registered."
        return 0
    fi
    
    # Parse and display the commands (avoid subshell issue)
    local current_plugin=""
    local temp_file=$(mktemp)
    echo "$PLUGIN_COMMAND_LIST" | sort > "$temp_file"
    
    while IFS=':' read -r command plugin description; do
        if [ -n "$command" ]; then
            if [ "$plugin" != "$current_plugin" ]; then
                if [ -n "$current_plugin" ]; then
                    echo ""
                fi
                ### echo "[$plugin plugin]"
                current_plugin="$plugin"
            fi
            printf " * %-25s - %s\n" "$command" "$description"
        fi
    done < "$temp_file"
    
    rm -f "$temp_file"
}

# Function to load plugins
load_plugins() {
    if [ -d "$PLUGINS_DIR" ]; then
        echo "Loading plugins from: $PLUGINS_DIR"
        
        for plugin in "$PLUGINS_DIR"/*.sh; do
            if [ -f "$plugin" ]; then
                local plugin_name=$(basename "$plugin" .sh)
                echo "  Loading plugin: $plugin_name"
                
                # Source the plugin file
                if source "$plugin"; then
                    # Call plugin initialization if it exists
                    if declare -F "${plugin_name}_init" >/dev/null; then
                        "${plugin_name}_init"
                    fi
                else
                    echo "  ERROR: Failed to load plugin $plugin_name"
                fi
            fi
        done
        echo "Plugin loading complete."
    else
        echo "Plugins directory not found: $PLUGINS_DIR"
        return 1
    fi
}

# Function to check if a command is handled by a plugin
is_plugin_command() {
    local command="$1"
    echo "$PLUGIN_COMMAND_LIST" | grep -q "^${command}:"
}
