#!/bin/bash
# File: /docker-yocto-env/plugins/poky.sh

# Poky/Yocto build system plugin
# Handles yocto shell, run, and toaster commands

# Plugin initialization
poky_init() {
    register_plugin_command "poky" "poky" "Yocto/Poky build system interface" "poky {shell|run|logs|toaster} [dir] [args] - Yocto build environment"
    
    # Load plugin-specific exports
    _load_poky_exports
}

_load_poky_exports() {
    export POKY_TOOLCHAIN_PATH="sources/poky"
    export TOASTER_ENVIRONMENT="${POKY_TOOLCHAIN_PATH}/oe-init-build-env"
    export POKY_ENVIRONMENT="${WORKSPACE_PATH}/setup-environment"
    export SHELL_HISTFILE="${WORKSPACE_PATH}/${POKY_TMP_DIR}/poky_shell_history"
}

# Guard against concurrent sessions and clean up stale BitBake server files.
# - If a container using POKY_IMAGE is already running → abort with a clear message.
# - If no container is running but lock/socket files exist → they are stale, remove them.
_bb_session_guard() {
    local build_dir="${PROJECT_TOP}/${1}"

    local running_container
    running_container=$(${CONTAINER_CMD} ps --filter "ancestor=${POKY_IMAGE}" --format '{{.Names}}' 2>/dev/null | head -1)

    if [ -n "${running_container}" ]; then
        echo "ERROR: A poky session is already active (container: ${running_container})" >&2
        echo "       Attach with: docker logs -f ${running_container}" >&2
        echo "       Or wait for it to finish before starting a new session." >&2
        return 1
    fi

    # No live container — safe to remove stale lock/socket files
    if [ -S "${build_dir}/bitbake.sock" ] || [ -f "${build_dir}/bitbake.lock" ]; then
        echo "[poky] Removing stale BitBake server files in ${1}..."
        rm -f "${build_dir}/bitbake.lock" "${build_dir}/bitbake.sock"
    fi

    return 0
}

poky() {
    _load_default_exports || return 1
    local COMMAND_TO_RUN="${1}"
    
    shift 1
    local BUILD_DIR=""
    local REMAINING_ARGS=""

    # The first argument could be directory or exec command
    if [ "$#" -gt 0 ] && [ -d "${1}" ]; then
        BUILD_DIR="${1}"
        shift
    fi
    REMAINING_ARGS="$*"

    local SECRETS_ENV_FILE="conf/secrets.env"

    # Reset to the original value so repeated calls don't accumulate.
    POKY_ENVIRONMENT="${WORKSPACE_PATH}/setup-environment"

    if [ -f "${BUILD_DIR}/${SECRETS_ENV_FILE}" ]; then
        echo "Sourcing secrets environment file: ${SECRETS_ENV_FILE}"
        POKY_ENVIRONMENT="${BUILD_DIR}/${SECRETS_ENV_FILE}; \
                            source ${BUILD_DIR}/apply_passthrough.sh; \
                            source ${POKY_ENVIRONMENT}"
    else
        echo "No secrets environment file found at ${SECRETS_ENV_FILE}, skipping sourcing."
    fi

    local SHELL="export HISTFILE=${SHELL_HISTFILE}; ${REMAINING_ARGS}/bin/bash"

    echo POKY_IMAGE=${POKY_IMAGE}
    # Use cached compose file generation
    _generate_compose_file || return 1

    case ${COMMAND_TO_RUN} in
        shell)
            [ -n "${BUILD_DIR}" ] && { _bb_session_guard "${BUILD_DIR}" || return 1; }
            if [ -n "${BUILD_DIR}" ]; then
                cp ${SCRIPT_DIR}/scripts/apply_passthrough.sh ${BUILD_DIR}
                _poky_dock linux/${ENV_ARCH} "source ${POKY_ENVIRONMENT} ${BUILD_DIR}; ${SHELL}"
            else 
                _poky_dock linux/${ENV_ARCH} "${SHELL}"
            fi
            ;;
        logs)
            local container
            container=$(${CONTAINER_CMD} ps \
                --filter "ancestor=${POKY_IMAGE}" \
                --format '{{.Names}}' 2>/dev/null | head -1)
            if [ -z "${container}" ]; then
                echo "[poky] No active build container found (image: ${POKY_IMAGE})"
                return 1
            fi
            echo "[poky] Attaching to container: ${container}  (Ctrl+C to detach)"
            ${CONTAINER_CMD} logs -f "${container}"
            ;;
        run)
            [ -n "${BUILD_DIR}" ] && { _bb_session_guard "${BUILD_DIR}" || return 1; }
            if [ -n "${BUILD_DIR}" ]; then
                cp ${SCRIPT_DIR}/scripts/apply_passthrough.sh ${BUILD_DIR}
                _poky_dock_cmd linux/${ENV_ARCH} "source ${POKY_ENVIRONMENT} ${BUILD_DIR}; ${REMAINING_ARGS}"
                return $?
            else
                _poky_dock_cmd linux/${ENV_ARCH} "${REMAINING_ARGS}"
            fi
            ;;
        toaster)            
            if [ -z "${BUILD_DIR}" ]; then
                echo "Please specify build directory"
                return 1
            fi
            _bb_session_guard "${BUILD_DIR}" || return 1

            local PORT="${REMAINING_ARGS:-${TOASTER_WEBUI}}"
            export TOASTER_WEBUI="${PORT}" # Set the environment variable for toaster port
            # Use cached compose file generation
            _generate_compose_file || return 1

            _poky_dock linux/${ENV_ARCH} \
                    "export HISTFILE=${SHELL_HISTFILE}; \
                    toaster-launch.sh \
                        ${WORKSPACE_PATH} \
                        ${WORKSPACE_PATH}/${POKY_TOOLCHAIN_PATH} \
                        ${BUILD_DIR}"
            ;;
        *)
            echo "Usage: poky {shell|run|logs|toaster} [dir] [args]"
            return 1
            ;;
    esac
    _unload_default_exports
}