#!/bin/bash
# File: /docker-yocto-env-1/plugins/poky.sh

# Poky/Yocto build system plugin
# Handles yocto shell, run, and toaster commands

# Plugin initialization
poky_init() {
    register_plugin_command "poky" "poky" "Yocto/Poky build system interface" "poky {shell|run|toaster} [dir] [args] - Yocto build environment"
    
    # Load plugin-specific exports
    _load_poky_exports
}

_load_poky_exports() {
    export POKY_TOOLCHAIN_PATH="sources/poky"
    export TOASTER_ENVIRONMENT="${POKY_TOOLCHAIN_PATH}/oe-init-build-env"
    export POKY_ENVIRONMENT="${WORKSPACE_PATH}/setup-environment"
    export SHELL_HISTFILE="${WORKSPACE_PATH}/${POKY_TMP_DIR}/poky_shell_history"
}

poky() {
    _load_default_exports
    local COMMAND_TO_RUN="${1}"
    
    shift 1
    local ARGS=("${@}") # ARGS array, could contain DIR as the 1st element
    local BUILD_DIR=""
    local REMAINING_ARGS=""
    local SHELL="export HISTFILE=${SHELL_HISTFILE}; /bin/bash"

    if [ -n "${ARGS}" ]; then            # All this make sense only if we have arguments
        if [ "${#ARGS[@]}" -lt 2 ]; then # One argument case
            if [ -d "${ARGS}" ]; then    # This one argument could be directory or exec command
                BUILD_DIR="${ARGS}"
            else
                REMAINING_ARGS="${ARGS[*]}"
            fi
        else                             # More than one argument case
            if [ -d "${ARGS[1]}" ]; then # 1st argument is directory
                BUILD_DIR=${ARGS[1]}
                ARGS=("${ARGS[@]:1}")    # Removing the 1st element
            fi
            REMAINING_ARGS="${ARGS[@]}"  # Remaining part is exec command
        fi
    fi

    echo POKY_IMAGE=${POKY_IMAGE}
    # Use cached compose file generation
    _generate_compose_file || return 1

    case ${COMMAND_TO_RUN} in
        shell)
            if [ -n "${BUILD_DIR}" ]; then
                _poky_dock linux/${ENV_ARCH} "source ${POKY_ENVIRONMENT} ${BUILD_DIR}; ${SHELL}"
            else 
                _poky_dock linux/${ENV_ARCH} "${SHELL}"
            fi
            ;;
        run)
            if [ -n "${BUILD_DIR}" ]; then
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
            echo "Usage: poky {shell|run|toaster} [args]"
            return 1
            ;;
    esac
    _unload_default_exports
}