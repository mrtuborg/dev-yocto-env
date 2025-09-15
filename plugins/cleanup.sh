#!/bin/bash
# File: /docker-yocto-env-1/plugins/cleanup.sh

# Cleanup plugin
# Provides workdir analysis and cleanup functionality

# Plugin initialization
cleanup_init() {
    register_plugin_command "cleanup" "cleanup" "Workdir cleanup and analysis" "cleanup [analysis] - Analyze and manage build artifacts"
}

cleanup() {
    local COMMAND="$1"
    local WORKDIR_MOUNT="/workdir"
    
    _load_default_exports
    
    case ${COMMAND} in
        analysis|"")
            echo "=== Workdir Cleanup Analysis ==="
            
            # Get list of machines that exist in the project configuration
            echo "🔍 Getting project machines..."
            local project_machines=$(info machines | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
            if [ -z "$project_machines" ]; then
                echo "❌ No machines found in project configuration"
                _unload_default_exports
                return 0
            fi
            
            echo "📋 Project machines: $(echo "$project_machines" | tr '\n' ',' | sed 's/,$//')"
            echo
            
            # Convert to space-separated format for easier passing to Docker
            local project_machines_list=$(echo "$project_machines" | tr '\n' ' ')
            
            local volumes=$(${CONTAINER_CMD} volume ls --format "{{.Name}}" | grep -E "^${PROJECT_NAME}-.*_workdir$" | sort)
            
            if [ -z "$volumes" ]; then
                echo "No workdir volumes found for project: ${PROJECT_NAME}"
                _unload_default_exports
                return 0
            fi
            
            local total_size=0
            local temp_file=$(mktemp)
            local built_machines_file=$(mktemp)
            
            echo "$volumes" | while IFS= read -r volume; do
                [ -z "$volume" ] && continue
                local arch=$(echo "$volume" | sed "s/^${PROJECT_NAME}-\(.*\)_workdir$/\1/")
                echo "📊 Analyzing: $volume (Architecture: $arch)"
                
                echo "  🔍 Starting Docker container analysis..."
                
                # First, let's check what's actually in the volume quickly
                echo "  📂 Quick volume inspection..."
                
                # Check if volume has content before doing expensive operations
                local has_content=$(${CONTAINER_CMD} run --rm -v "$volume:$WORKDIR_MOUNT" alpine:latest sh -c "
                    cd $WORKDIR_MOUNT 2>/dev/null || exit 1
                    ls -A . 2>/dev/null | wc -l
                " 2>/dev/null || echo "0")
                
                if [ "$has_content" -eq 0 ]; then
                    echo "  📁 Volume is empty"
                    local volume_info="TOTAL:0"
                else
                    echo "  📁 Volume has $has_content items - starting detailed analysis..."
                    
                    # Calculate total cleanable tmp size in one Docker call
                    local tmp_size=$(${CONTAINER_CMD} run --rm -v "$volume:$WORKDIR_MOUNT" -e "PROJECT_MACHINES=$project_machines_list" alpine:latest sh -c "
                        # Use a temp file to accumulate sizes since shell variables don't persist across subshells
                        temp_total=/tmp/total_size
                        echo '0' > \$temp_total
                        
                        # Process work directory - both machine-specific and machine-influenced directories
                        if [ -d $WORKDIR_MOUNT/tmp/work ]; then
                            find $WORKDIR_MOUNT/tmp/work -maxdepth 1 -type d 2>/dev/null | while read arch_dir; do
                                [ \"\$arch_dir\" = '$WORKDIR_MOUNT/tmp/work' ] && continue
                                arch_part=\$(basename \"\$arch_dir\")
                                
                                # Check if this is a machine-specific directory (contains machine name)
                                machine=\$(echo \"\$arch_part\" | sed 's/.*-\\([^-]*-[^-]*\\)-poky-linux/\\1/' | sed 's/.*-\\([^-]*-[^-]*\\)-fslc-linux/\\1/')
                                [ \"\$machine\" = \"\$arch_part\" ] && {
                                    machine=\$(echo \"\$arch_part\" | sed 's/.*-\\([^-]*\\)-poky-linux/\\1/' | sed 's/.*-\\([^-]*\\)-fslc-linux/\\1/')
                                }
                                [ \"\$machine\" = \"\$arch_part\" ] && {
                                    machine=\$(echo \"\$arch_part\" | grep -o 'imx[0-9][a-z]*[^-]*' || echo \"\$arch_part\" | grep -o 'roommate[^-]*' || echo 'unknown')
                                }
                                
                                # If we found a machine name, check if it's in project
                                if [ \"\$machine\" != 'unknown' ] && [ \"\$machine\" != '' ]; then
                                    machine_normalized=\$(echo \"\$machine\" | sed 's/_/-/g')
                                    if echo \"\$PROJECT_MACHINES\" | grep -q \"\$machine_normalized\"; then
                                        size=\$(du -sb \"\$arch_dir\" 2>/dev/null | cut -f1 || echo '0')
                                        current_total=\$(cat \$temp_total)
                                        echo \$((current_total + size)) > \$temp_total
                                    fi
                                fi
                            done
                        fi
                        
                        # Process deploy directory
                        if [ -d $WORKDIR_MOUNT/tmp/deploy/images ]; then
                            for machine_dir in $WORKDIR_MOUNT/tmp/deploy/images/*; do
                                [ -d \"\$machine_dir\" ] || continue
                                machine=\$(basename \"\$machine_dir\")
                                machine_normalized=\$(echo \"\$machine\" | sed 's/_/-/g')
                                if echo \"\$PROJECT_MACHINES\" | grep -q \"\$machine_normalized\"; then
                                    size=\$(du -sb \"\$machine_dir\" 2>/dev/null | cut -f1 || echo '0')
                                    current_total=\$(cat \$temp_total)
                                    echo \$((current_total + size)) > \$temp_total
                                fi
                            done
                        fi
                        
                        cat \$temp_total
                    " 2>/dev/null || echo "0")
                    
                    echo "      Tmp total: $((tmp_size / 1024 / 1024 / 1024))GB"
                    
                    local vol_total_size=$tmp_size
                fi
                
                # Convert bytes to gigabytes format
                local total_gb=$((vol_total_size / 1024 / 1024 / 1024))
                echo "  💾 tmp: ${total_gb}GB"
                
                # Store size for total calculation
                echo "$vol_total_size" >> "$temp_file"
                echo
            done
            
            # Calculate total from temp file
            if [ -f "$temp_file" ]; then
                total_size=$(awk '{sum += $1} END {print sum}' "$temp_file" 2>/dev/null || echo "0")
                rm -f "$temp_file"
            fi
            
            # Convert total to gigabytes format
            local total_gb=$((total_size / 1024 / 1024 / 1024))
            echo "💾 Total tmp directory size: ${total_gb}GB"
            echo
            ;;
            
        *)
            echo "Usage: cleanup [analysis]"
            echo "  analysis  - Show workdir analysis with machine footprint (default)"
            ;;
    esac
    
    _unload_default_exports
}