#!/bin/bash

#==============================================================================
# Podman Machine Setup Script for Yocto Development
#==============================================================================
# This script creates and configures a Podman machine optimized for Yocto
# builds with proper file sharing, permissions, and resource allocation.
#
# Features:
# - Rootful mode for better file permissions
# - Enhanced volume mounts for workspace access
# - Timezone configuration for build compatibility
# - Resource allocation suitable for Yocto builds
# - Error handling and validation
#
# Usage: ./setup-podman-machine.sh [machine-name]
# Example: ./setup-podman-machine.sh yocto-dev
#==============================================================================

set -e  # Exit on any error

# Configuration variables
MACHINE_NAME="${1:-yocto-dev}"
CPUS=6
MEMORY=16384  # 16GB in MiB
DISK_SIZE=200  # 200GB
TIMEZONE="Europe/Oslo"
WORKSPACE_PATH="/Users/$(whoami)/ws"
SSH_PATH="/Users/$(whoami)/.ssh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#==============================================================================
# Helper Functions
#==============================================================================

print_header() {
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}==============================================================================${NC}"
}

print_step() {
    echo -e "${GREEN}[STEP]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Confirm user action
confirm() {
    local prompt="$1"
    local response
    
    while true; do
        read -p "${prompt} (y/n): " response
        case $response in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}

#==============================================================================
# Validation Functions
#==============================================================================

validate_podman() {
    print_step "Validating Podman installation..."
    
    if ! command_exists podman; then
        print_error "Podman is not installed. Please install Podman Desktop or Podman CLI first."
        echo "Visit: https://podman.io/getting-started/installation"
        exit 1
    fi
    
    local podman_version=$(podman --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    print_info "Found Podman version: $podman_version"
    
    # Check if version is 4.0.0 or higher (required for machine command)
    if [[ $(echo "$podman_version 4.0.0" | tr " " "\n" | sort -V | head -n 1) != "4.0.0" ]]; then
        print_error "Podman version 4.0.0 or higher is required for machine support."
        exit 1
    fi
}

validate_resources() {
    print_step "Validating system resources..."
    
    # Check available memory (macOS specific)
    if command_exists sysctl; then
        local total_memory_bytes=$(sysctl -n hw.memsize)
        local total_memory_gb=$((total_memory_bytes / 1024 / 1024 / 1024))
        
        print_info "Total system memory: ${total_memory_gb}GB"
        
        if [ $total_memory_gb -lt 12 ]; then
            print_warning "System has less than 12GB RAM. Consider reducing machine memory allocation."
            if [ $total_memory_gb -lt 8 ]; then
                print_error "System has less than 8GB RAM. This may not be sufficient for Yocto builds."
                if ! confirm "Continue anyway?"; then
                    exit 1
                fi
            fi
        fi
    fi
    
    # Check available disk space
    local available_space=$(df -BG "$(dirname "$WORKSPACE_PATH")" | awk 'NR==2 {gsub(/G/, "", $4); print $4}')
    print_info "Available disk space: ${available_space}GB"
    
    if [ "$available_space" -lt 150 ]; then
        print_warning "Less than 150GB available. Yocto builds require significant disk space."
        if ! confirm "Continue anyway?"; then
            exit 1
        fi
    fi
}

validate_workspace() {
    print_step "Validating workspace and SSH paths..."
    
    if [ ! -d "$WORKSPACE_PATH" ]; then
        print_error "Workspace path does not exist: $WORKSPACE_PATH"
        if confirm "Create workspace directory?"; then
            mkdir -p "$WORKSPACE_PATH"
            print_info "Created workspace directory: $WORKSPACE_PATH"
        else
            exit 1
        fi
    fi
    
    # Check SSH directory
    if [ ! -d "$SSH_PATH" ]; then
        print_warning "SSH directory does not exist: $SSH_PATH"
        if confirm "Create SSH directory?"; then
            mkdir -p "$SSH_PATH"
            chmod 700 "$SSH_PATH"
            print_info "Created SSH directory: $SSH_PATH"
        else
            print_warning "SSH directory will not be mounted in containers"
            SSH_PATH=""
        fi
    fi
    
    # Test write permissions
    local test_file="$WORKSPACE_PATH/.podman-setup-test"
    if touch "$test_file" 2>/dev/null; then
        rm -f "$test_file"
        print_info "Workspace has write permissions: $WORKSPACE_PATH"
    else
        print_error "Cannot write to workspace directory: $WORKSPACE_PATH"
        exit 1
    fi
}

#==============================================================================
# Machine Management Functions
#==============================================================================

check_existing_machine() {
    print_step "Checking for existing Podman machines..."
    
    local existing_machines=$(podman machine list --format "{{.Name}}" 2>/dev/null || true)
    
    if [ -n "$existing_machines" ]; then
        print_info "Found existing machines:"
        echo "$existing_machines" | sed 's/^/  - /'
        
        if echo "$existing_machines" | grep -q "^$MACHINE_NAME$"; then
            print_warning "Machine '$MACHINE_NAME' already exists."
            
            if confirm "Remove existing machine '$MACHINE_NAME' and create new one?"; then
                stop_and_remove_machine "$MACHINE_NAME"
            else
                print_info "Exiting without changes."
                exit 0
            fi
        fi
    else
        print_info "No existing machines found."
    fi
}

stop_and_remove_machine() {
    local machine_name="$1"
    
    print_step "Stopping and removing machine: $machine_name"
    
    # Stop machine if running
    if podman machine list --format "{{.Name}} {{.LastUp}}" | grep "$machine_name" | grep -q "Currently running"; then
        print_info "Stopping machine: $machine_name"
        podman machine stop "$machine_name" || true
    fi
    
    # Remove machine
    print_info "Removing machine: $machine_name"
    podman machine rm "$machine_name" --force || true
}

create_machine() {
    print_step "Creating new Podman machine: $MACHINE_NAME"
    
    print_info "Machine configuration:"
    echo "  - Name: $MACHINE_NAME"
    echo "  - CPUs: $CPUS"
    echo "  - Memory: ${MEMORY} MiB ($(($MEMORY / 1024))GB)"
    echo "  - Disk: ${DISK_SIZE}GB"
    echo "  - Timezone: $TIMEZONE"
    echo "  - Mode: Rootful (better file permissions)"
    echo "  - Workspace mount: $WORKSPACE_PATH"
    echo "  - SSH mount: $SSH_PATH (read-write for SSH operations)"
    echo "  - Timezone mount: /usr/share/zoneinfo (read-only)"
    
    if ! confirm "Create machine with these settings?"; then
        print_info "Machine creation cancelled."
        exit 0
    fi
    
    # Create the machine with enhanced configuration
    print_info "Initializing machine (this may take a few minutes)..."
    
    # Build volume mount arguments
    local volume_args=(
        --volume "$WORKSPACE_PATH:$WORKSPACE_PATH"
        --volume "/usr/share/zoneinfo:/usr/share/zoneinfo:ro"
    )
    
    # Add SSH mount if SSH directory exists
    if [ -n "$SSH_PATH" ] && [ -d "$SSH_PATH" ]; then
        volume_args+=(--volume "$SSH_PATH:$SSH_PATH")
    fi
    
    podman machine init \
        --cpus "$CPUS" \
        --memory "$MEMORY" \
        --disk-size "$DISK_SIZE" \
        --rootful \
        "${volume_args[@]}" \
        --timezone "$TIMEZONE" \
        "$MACHINE_NAME"
    
    print_info "Machine '$MACHINE_NAME' created successfully!"
}

start_machine() {
    print_step "Starting Podman machine: $MACHINE_NAME"
    
    podman machine start "$MACHINE_NAME"
    
    print_info "Machine '$MACHINE_NAME' started successfully!"
    
    # Wait a moment for the machine to be fully ready
    sleep 3
}

#==============================================================================
# Testing Functions
#==============================================================================

test_machine_configuration() {
    print_step "Testing machine configuration..."
    
    # Test basic connectivity
    print_info "Testing Podman connectivity..."
    if ! podman version >/dev/null 2>&1; then
        print_error "Cannot connect to Podman. Machine may not be running properly."
        return 1
    fi
    
    # Test volume mounting
    print_info "Testing volume mounting..."
    local test_container="alpine:latest"
    
    # Pull test image if not present
    podman pull "$test_container" >/dev/null 2>&1 || {
        print_error "Failed to pull test image: $test_container"
        return 1
    }
    
    # Test workspace mount and permissions
    local test_file="$WORKSPACE_PATH/.podman-test-$(date +%s)"
    local container_test_result
    
    container_test_result=$(podman run --rm \
        -v "$WORKSPACE_PATH:/workspace" \
        "$test_container" \
        sh -c "touch /workspace/.podman-test-\$(date +%s) && echo 'SUCCESS' || echo 'FAILED'")
    
    if [ "$container_test_result" = "SUCCESS" ]; then
        print_info "✓ Volume mounting and write permissions work correctly"
        # Clean up test files
        rm -f "$WORKSPACE_PATH"/.podman-test-*
    else
        print_error "✗ Volume mounting or write permissions failed"
        return 1
    fi
    
    # Test timezone configuration
    print_info "Testing timezone configuration..."
    local container_timezone
    container_timezone=$(podman run --rm "$test_container" date +%Z)
    
    if [ -n "$container_timezone" ]; then
        print_info "✓ Timezone configuration working (container timezone: $container_timezone)"
    else
        print_warning "⚠ Could not verify timezone configuration"
    fi
    
    # Test user ID mapping (with rootful mode)
    print_info "Testing user ID mapping..."
    local container_user_info
    container_user_info=$(podman run --rm -v "$WORKSPACE_PATH:/workspace" "$test_container" \
        sh -c "ls -la /workspace | head -n 5")
    
    print_info "✓ Container can access workspace files:"
    echo "$container_user_info" | sed 's/^/    /'
    
    return 0
}

test_yocto_environment() {
    print_step "Testing Yocto environment compatibility..."
    
    # Check if env file exists
    local env_file="$WORKSPACE_PATH/roomboard-linux.kirkstone/docker-yocto-env/env"
    
    if [ -f "$env_file" ]; then
        print_info "Found Yocto environment file: $env_file"
        print_info "You can now test the Yocto environment with:"
        echo "  cd $WORKSPACE_PATH/roomboard-linux.kirkstone"
        echo "  . ./env"
    else
        print_info "Yocto environment file not found at expected location."
        print_info "Make sure your Yocto project is in: $WORKSPACE_PATH"
    fi
}

#==============================================================================
# Main Execution
#==============================================================================

main() {
    print_header "Podman Machine Setup for Yocto Development"
    
    echo "This script will create a Podman machine optimized for Yocto builds."
    echo "The machine will be configured with:"
    echo "  - Enhanced file sharing and permissions"
    echo "  - Sufficient resources for Yocto builds"
    echo "  - Proper timezone configuration"
    echo "  - Rootful mode for better compatibility"
    echo
    
    # Validation phase
    validate_podman
    validate_resources
    validate_workspace
    
    # Machine management phase
    check_existing_machine
    create_machine
    start_machine
    
    # Testing phase
    if test_machine_configuration; then
        print_step "All tests passed! ✓"
        
        print_header "Setup Complete!"
        echo -e "${GREEN}Podman machine '$MACHINE_NAME' is ready for Yocto development.${NC}"
        echo
        echo "Machine details:"
        podman machine list
        echo
        echo "Next steps:"
        echo "  1. Navigate to your Yocto project directory"
        echo "  2. Source the environment: . ./env"
        echo "  3. Start building!"
        echo
        echo "To manage this machine:"
        echo "  - Start: podman machine start $MACHINE_NAME"
        echo "  - Stop:  podman machine stop $MACHINE_NAME"
        echo "  - Info:  podman machine list"
        
        test_yocto_environment
        
    else
        print_error "Machine configuration tests failed!"
        print_info "You may need to troubleshoot the setup or try different configuration options."
        exit 1
    fi
}

# Script entry point
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
