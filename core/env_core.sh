#!/bin/bash
# File: /docker-yocto-env/core/env_core.sh

# Core environment initialization

# Get script directory - handle the case where BASH_SOURCE[0] might be empty
if [ -n "${BASH_SOURCE[0]}" ]; then
    CORE_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
else
    # Fallback for zsh or if BASH_SOURCE is not available
    CORE_DIR=$(dirname "$(realpath "${(%):-%x}")")
fi

# Load common functions and configuration
if ! source "${CORE_DIR}/common.sh"; then
    echo "ERROR: Failed to load common.sh" >&2
    return 1
fi

if ! source "${CORE_DIR}/config.sh"; then
    echo "ERROR: Failed to load config.sh" >&2
    return 1
fi

# Load shared utilities
if ! source "${CORE_DIR}/../lib/docker_utils.sh"; then
    echo "ERROR: Failed to load docker_utils.sh" >&2
    return 1
fi

# Load plugin loader
if ! source "${CORE_DIR}/plugin_loader.sh"; then
    echo "ERROR: Failed to load plugin_loader.sh" >&2
    return 1
fi

# Function to initialize the environment
_initialize_environment() {
    echo "Initializing Yocto environment..."
    
    # Load default exports first
    _load_default_exports || return 1
    
    # Check if we need to build the image
    if [[ "${PULL_VDE}" != "true" ]]; then
        # Only build if the image doesn't already exist
        if ! ${CONTAINER_CMD} image inspect "${POKY_IMAGE}" >/dev/null 2>&1; then
            echo "Building image..."
            ${CONTAINER_CMD} build -t ${POKY_IMAGE} \
                --build-arg POKY_REPO=https://github.com/yoctoproject/poky.git \
                --build-arg POKY_COMMIT_ID=6505459809380ddcf152a09343e4dc55038de332 \
                -f ${SCRIPT_DIR}/Dockerfile_22.04 \
                ${SCRIPT_DIR}/ || return 1
        else
            echo "Image ${POKY_IMAGE} already exists, skipping build"
        fi
    fi
    
    echo POKY_IMAGE=${POKY_IMAGE}
    
    # Generate initial compose file and create volume
    _generate_compose_file || return 1
    _ensure_docker_volume || return 1
    
    # Initialize workdir if needed
    _initialize_workdir || return 1
    _initialize_shared_volume "${SSTATE_VOLUME_NAME:-${VOLUME_NAME}_sstate}" sstate || return 1
    _initialize_shared_volume "${DL_VOLUME_NAME:-${VOLUME_NAME}_downloads}" downloads || return 1
    
    # Load plugins after environment is ready
    load_plugins
    
    echo "Environment initialization complete."
}

# Function to initialize workdir (moved from main env file)
_initialize_workdir() {
    # Check if workdir is already initialized to avoid slow container startup
    local volume_name="${VOLUME_NAME}_workdir"
    
    # Docker doesn't need special volume flags
    local init_volume_flags=""
    
    # Check if workdir is already initialized by checking for marker or content
    echo "Checking workdir initialization status..."
    local check_result=$(${CONTAINER_CMD} run --rm \
        -v "${volume_name}:/workdir${init_volume_flags}" \
        alpine:latest sh -c 'test -f /workdir/.initialized && echo "initialized" || (test -d /workdir/tmp && echo "has_content" || echo "empty")' 2>/dev/null || echo "empty")
    
    if [[ "$check_result" == "initialized" ]]; then
        echo "Workdir already initialized (marker found), skipping setup"
    elif [[ "$check_result" == "has_content" ]]; then
        echo "Workdir has existing content, verifying permissions..."
        # Check if we can write as the build user, if not fix permissions
        ${CONTAINER_CMD} run --rm -u ${WORKDIR_UID}:${WORKDIR_GID} \
            -v "${volume_name}:/workdir${init_volume_flags}" \
            alpine:latest sh -c "
                if touch /workdir/.initialized 2>/dev/null; then
                    echo 'Workdir verified - permissions OK'
                else
                    echo 'Cannot write to workdir - permissions need fixing'
                    exit 1
                fi
            " || {
                echo "Fixing workdir permissions..."
                ${CONTAINER_CMD} run --rm -u root \
                    -v "${volume_name}:/workdir${init_volume_flags}" \
                    alpine:latest sh -c "
                        chown -R ${WORKDIR_UID}:${WORKDIR_GID} /workdir
                        chmod -R u+rwX,g+rwX /workdir
                        echo 'Permissions fixed - ownership set to ${WORKDIR_UID}:${WORKDIR_GID}'
                    "
            }
    else
        echo "Initializing workdir for first time..."
        # Run initialization as root to set up permissions, then chown to build user
        ${CONTAINER_CMD} run --rm -u root \
            -v "${volume_name}:/workdir${init_volume_flags}" \
            alpine:latest sh -c "
                echo 'Setting up workdir structure and permissions...'
                mkdir -p /workdir/tmp
                chown -R ${WORKDIR_UID}:${WORKDIR_GID} /workdir
                chmod -R u+rwX,g+rwX /workdir
                touch /workdir/.initialized
                echo 'Workdir initialization complete - ownership set to ${WORKDIR_UID}:${WORKDIR_GID}'
            "
    fi
}

# Create (if absent) and make writable a shared, persistent cache volume.
#
# Used for BOTH the sstate cache and DL_DIR. Unlike the per-checkout
# workdir/TMPDIR volume, these are content-addressed (sstate: BitBake task
# signatures) or URL-addressed and checksum-verified (downloads), so they are
# safe to share across checkout locations, branches and CI runners — see the
# "Volume naming" comment in core/config.sh.
#
# Each volume root IS the cache directory (objects are written directly to the
# root, so the rpm-host can serve them at /sstate-cache/PATH with no subpath
# mount, which Docker named volumes don't support).
#
# Only the volume ROOT needs chowning: BitBake owns everything it creates
# below it. That makes this O(1) regardless of cache size, so it runs
# unconditionally on every env load — no ".initialized" marker, no probe
# container. That is deliberate and strictly safer than a marker: if a
# volume's root ownership is ever clobbered, this self-heals it, whereas a
# marker would report "already initialized" and leave the build broken.
_initialize_shared_volume() {
    local vol="$1" label="$2"

    ${CONTAINER_CMD} volume inspect "$vol" >/dev/null 2>&1 \
        || ${CONTAINER_CMD} volume create "$vol" >/dev/null 2>&1 \
        || { echo "ERROR: Failed to create ${label} volume: $vol" >&2; return 1; }

    ${CONTAINER_CMD} run --rm -u root -v "${vol}:/v" alpine:latest \
        chown "${WORKDIR_UID}:${WORKDIR_GID}" /v >/dev/null 2>&1 \
        || { echo "ERROR: Failed to prepare ${label} volume: $vol" >&2; return 1; }
}
