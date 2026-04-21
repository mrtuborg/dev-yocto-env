#!/bin/bash
# File: /docker-yocto-env/plugins/info.sh

# System information plugin
# Provides commands to query available machines, images, and distros

# Plugin initialization
info_init() {
    register_plugin_command "info" "info" "System information commands" "info {machines|images|distro} [filter] - List configuration information"
}

info() {
    local print_filter="${2:-}"

    case $1 in
        machines)
            # Build find exclusion arguments for machines
            local find_args=()
            if [ -n "$MACHINES_EXCLUDE_DIRS" ]; then
                # Use a more compatible approach for splitting the string
                local exclude_dirs_list="$MACHINES_EXCLUDE_DIRS"
                while [ -n "$exclude_dirs_list" ]; do
                    # Extract first directory
                    local exclude_dir="${exclude_dirs_list%% *}"
                    find_args+=(-path "./$exclude_dir" -prune -o)
                    # Remove processed directory from list
                    if [ "$exclude_dir" = "$exclude_dirs_list" ]; then
                        # Only one directory left
                        break
                    else
                        exclude_dirs_list="${exclude_dirs_list#* }"
                    fi
                done
            fi
            find_args+=(-type f -path '*/machine/*.conf' -print)
            
            find . "${find_args[@]}" | sed 's|.*/||; s|\.conf$||' | \
                { [ -n "${print_filter}" ] && grep "${print_filter}" || cat; } | sort | \
                xargs -I {} echo -n "{}, " | sed 's/, $/\n/'
            ;;
        images)
            # Build find exclusion arguments for images
            local find_args=()
            if [ -n "$IMAGES_EXCLUDE_DIRS" ]; then
                # Use a more compatible approach for splitting the string
                local exclude_dirs_list="$IMAGES_EXCLUDE_DIRS"
                while [ -n "$exclude_dirs_list" ]; do
                    # Extract first directory
                    local exclude_dir="${exclude_dirs_list%% *}"
                    find_args+=(-path "./$exclude_dir" -prune -o)
                    # Remove processed directory from list
                    if [ "$exclude_dir" = "$exclude_dirs_list" ]; then
                        # Only one directory left
                        break
                    else
                        exclude_dirs_list="${exclude_dirs_list#* }"
                    fi
                done
            fi
            find_args+=(-type f -path '*/images/*.bb' -print)
            
            find . "${find_args[@]}" | sed 's|.*/||; s|\.bb$||' | \
                { [ -n "${print_filter}" ] && grep "${print_filter}" || cat; } | sort | \
                xargs -I {} echo -n "{}, " | sed 's/, $/\n/'
            ;;
        distro)
            find . -type f -name '*.conf' -exec grep -H 'DISTRO =' {} \; | \
            { [ -n "${print_filter}" ] && grep "${print_filter}" || cat; }  | cut -d '=' -f 2 | tr -d ' \"' | \
            sort | uniq
            ;;
        *)
            echo "Usage: info {machines|images|distro} [filter]"
            echo "  machines [filter] - List available machine configurations"
            echo "  images [filter]   - List available image recipes"
            echo "  distro [filter]   - List available distro configurations"
            return 1
            ;;
    esac
}
