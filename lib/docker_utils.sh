#!/bin/bash
# File: /docker-yocto-env-1/lib/docker_utils.sh

# Common docker execution utilities shared across plugins

# Docker volume creation helper
_ensure_docker_volume() {
    local volume_name="${VOLUME_NAME}_workdir"
    if ! ${CONTAINER_CMD} volume inspect "$volume_name" >/dev/null 2>&1; then
        echo "Creating volume: $volume_name"
        ${CONTAINER_CMD} volume create "$volume_name" > /dev/null 2>&1 || {
            echo "ERROR: Failed to create volume: $volume_name" >&2
            return 1
        }
    fi
    return 0
}

# Docker compose file generation helper
_generate_compose_file() {
    local compose_file="docker-compose.${ENV_ARCH}.yml"
    local template_file="${SCRIPT_DIR}/docker-compose.template.yml"
    
    # Check if SCRIPT_DIR is set
    if [ -z "$SCRIPT_DIR" ]; then
        echo "ERROR: SCRIPT_DIR not set - cannot locate docker-compose template" >&2
        return 1
    fi
    
    # Check if template exists
    if [[ ! -f "$template_file" ]]; then
        echo "ERROR: Docker compose template not found: $template_file" >&2
        return 1
    fi
    
    # Only regenerate if template is newer or compose file doesn't exist
    if [[ ! -f "$compose_file" ]] || [[ "$template_file" -nt "$compose_file" ]] || [[ "$_COMPOSE_FILE_GENERATED" != "$compose_file" ]]; then
        echo "Generating docker-compose configuration..."
        # Fix the context path to be absolute instead of relative
        envsubst < "$template_file" | sed "s|context: ./docker-yocto-env|context: ${SCRIPT_DIR}|g" > "$compose_file" || {
            echo "ERROR: Failed to generate docker-compose file" >&2
            return 1
        }
        _COMPOSE_FILE_GENERATED="$compose_file"
    fi
    return 0
}

# Common docker execution function
_run_docker() {
    local interactive="$1"
    local buildplatform="$2"
    local command_to_run="$3"
    
    # Validate inputs
    if [[ -z "$command_to_run" ]]; then
        echo "ERROR: No command specified for docker execution" >&2
        return 1
    fi
    
    # Check required variables
    if [ -z "$PROJECT_TOP" ] || [ -z "$WORKSPACE_PATH" ] || [ -z "$VOLUME_NAME" ]; then
        echo "ERROR: Required environment variables not set (PROJECT_TOP, WORKSPACE_PATH, VOLUME_NAME)" >&2
        return 1
    fi
    
    # Display mode
    if [[ "$interactive" == "true" ]]; then
        echo "Poky dock in interactive mode"
    else
        echo "Poky dock in non-interactive mode"
    fi

    # Docker handles volume permissions automatically - no special flags needed
    local VOLUME_FLAGS=""
    local WORKDIR_FLAGS=""
    local EXTRA_DOCKER_ARGS=()
    
    echo "Using Docker - fast volume handling"

    # Determine SSH path based on OS
    local SSH_PATH
    if [[ "$(uname -s)" == "Linux" ]]; then
        SSH_PATH="/home/$USER/.ssh"
    else
        SSH_PATH="/Users/$USER/.ssh"
    fi

    # Prepare docker arguments
    local docker_args=(
        -u vari
        --rm
        -v "${PROJECT_TOP}:${WORKSPACE_PATH}${VOLUME_FLAGS}"
        -v "${VOLUME_NAME}_workdir:/workdir${WORKDIR_FLAGS}"
        -v "${SSH_PATH}:/home/vari/.ssh${VOLUME_FLAGS}"
        -w "${WORKSPACE_PATH}"
    )
    
    # Add extra docker args (e.g., --privileged on macOS)
    if [[ ${#EXTRA_DOCKER_ARGS[@]} -gt 0 ]]; then
        docker_args+=("${EXTRA_DOCKER_ARGS[@]}")
    fi
    
    # Add interactive flag if needed
    if [[ "$interactive" == "true" ]]; then
        docker_args+=(-it)
    fi
    
    # Add image and command
    docker_args+=("${POKY_IMAGE}" /bin/bash -c "${command_to_run}")

    # Create temp directory
    mkdir -p "${PROJECT_TOP}/${POKY_TMP_DIR}" || {
        echo "ERROR: Failed to create temp directory" >&2
        return 1
    }

    # Show debug info for interactive mode
    if [[ "$interactive" == "true" ]]; then
        echo "Running with UID:GID ${WORKDIR_UID}:${WORKDIR_GID}"
        echo "Volume flags: ${VOLUME_FLAGS}"
    fi
    
    # Execute container run directly (works better with volume flags than compose)
    ${CONTAINER_CMD} run "${docker_args[@]}"
    return $?
}

# Simplified wrapper functions
_poky_dock() {
    _run_docker true "$1" "$2"
}

_poky_dock_cmd() {
    _run_docker false "$1" "$2"
}

# Docker compose service management helpers
_start_compose_service() {
    local service_name="$1"
    local port_var="$2"
    local port_value="$3"
    
    # Export the port environment variable if provided
    if [ -n "$port_var" ] && [ -n "$port_value" ]; then
        export "$port_var"="$port_value"
    fi
    
    # Generate compose file
    _generate_compose_file || return 1

    echo "🚀 Starting $service_name service on port ${port_value:-default}..."
    ${CONTAINER_CMD} compose -f "${PROJECT_TOP}/docker-compose.${ENV_ARCH}.yml" \
        -p "${VOLUME_NAME}" \
        up -d "$service_name"
}

_stop_compose_service() {
    local service_name="$1"
    
    echo "🛑 Stopping $service_name service..."
    ${CONTAINER_CMD} compose -f "${PROJECT_TOP}/docker-compose.${ENV_ARCH}.yml" \
        -p "${VOLUME_NAME}" \
        stop "$service_name"
}

_status_compose_service() {
    local service_name="$1"
    
    echo "📊 Checking $service_name service status..."
    ${CONTAINER_CMD} compose -f "${PROJECT_TOP}/docker-compose.${ENV_ARCH}.yml" \
        -p "${VOLUME_NAME}" \
        ps "$service_name"
}