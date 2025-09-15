#!/bin/bash
# File: /docker-yocto-env-1/core/common.sh

# Common utility functions for docker-yocto-env

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to print error messages
print_error() {
    echo "ERROR: $1" >&2
}

# Function to print info messages
print_info() {
    echo "INFO: $1"
}

# Function to ensure a directory exists
ensure_directory() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
        print_info "Created directory: $1"
    fi
}

# Cache for expensive operations
_COMPOSE_FILE_GENERATED=""
_PROJECT_TOP_CACHED=""

# Load default exports function (moved from main env file)
_load_default_exports() {
    # Detect container runtime (docker only)
    if command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
    else
        echo "ERROR: docker not found in PATH" >&2
        echo "Please install Docker Desktop or Colima:" >&2
        echo "  Docker Desktop: https://www.docker.com/products/docker-desktop" >&2
        echo "  Colima: brew install colima docker && colima start" >&2
        return 1
    fi
    
    YOCTO_RELEASE=kirkstone
    VDE_VERSION=22.04
    VDE_IMAGE=poky-vde
    DOCKER_REGISTRY=roommatedev01.azurecr.io

    POKY_IMAGE=${DOCKER_REGISTRY}/${VDE_IMAGE}:${YOCTO_RELEASE}-${VDE_VERSION}
    NETBOOT_SERVER_IMAGE=roommatedev01.azurecr.io/netboot-server:latest

    PROJECT_TOP=$(git rev-parse --show-toplevel)
    PROJECT_NAME=$(basename ${PROJECT_TOP} | tr '.' '-')
    POKY_TMP_DIR=poky_tmp
    WORKSPACE_PATH=/workspace

    VOLUME_NAME=${PROJECT_NAME}-${ENV_ARCH}
    FILEBROWSER_PORT=9200
    DL_PORT=9210

    TOASTER_WEBUI=9090
    WORKDIR_UID=1000
    WORKDIR_GID=1000
    # Redefine WORKDIR_UID and WORKDIR_GID only if on a Linux machine
    if [[ "$(uname -s)" == "Linux" ]]; then
        WORKDIR_UID=$(id -u $USER)
        WORKDIR_GID=$(id -g $USER)
    fi

    # Directory exclusion variables for info commands
    # Set default exclusions - can be overridden by user
    MACHINES_EXCLUDE_DIRS=${MACHINES_EXCLUDE_DIRS:-"sources"}
    IMAGES_EXCLUDE_DIRS=${IMAGES_EXCLUDE_DIRS:-"sources"}

    echo "Environment: ${ENV_ARCH}"
    echo "Container runtime: Docker"

    # Export environment variables for docker-compose
    export POKY_IMAGE
    export NETBOOT_SERVER_IMAGE
    export PROJECT_TOP
    export PROJECT_NAME
    export WORKSPACE_PATH
    export WORKDIR_UID
    export WORKDIR_GID
    export FILEBROWSER_PORT
    export ENV_ARCH
    export VOLUME_NAME
    export TOASTER_WEBUI
    export DL_PORT
    export MACHINES_EXCLUDE_DIRS
    export IMAGES_EXCLUDE_DIRS
    
    # Enable Docker BuildKit for modern image building
    export DOCKER_BUILDKIT=1
}

# Unload default exports function
_unload_default_exports() {
    # Unexport environment variables for docker-compose
    unset POKY_IMAGE
    unset PROJECT_NAME
    unset WORKSPACE_PATH
    unset FILEBROWSER_PORT
    unset VOLUME_NAME
    unset DOCKER_BUILDKIT
}