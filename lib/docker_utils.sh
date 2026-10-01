#!/bin/bash
# File: /docker-yocto-env/lib/docker_utils.sh

# Common docker execution utilities shared across plugins

# Docker volume creation helper
_ensure_docker_volume() {
  local volume_name="${VOLUME_NAME}_workdir"
  if ! ${CONTAINER_CMD} volume inspect "$volume_name" >/dev/null 2>&1; then
    echo "Creating volume: $volume_name"
    ${CONTAINER_CMD} volume create "$volume_name" >/dev/null 2>&1 || {
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
    envsubst <"$template_file" | sed "s|context: ./docker-yocto-env|context: ${SCRIPT_DIR}|g" >"$compose_file" || {
      echo "ERROR: Failed to generate docker-compose file" >&2
      return 1
    }
    _COMPOSE_FILE_GENERATED="$compose_file"
  fi
  return 0
}

# Build /etc/passwd and /etc/group overrides so the container's numeric
# UID:GID always resolves to a real account.
#
# _run_docker() runs the container as the host's UID:GID so bind-mounted writes
# work on Linux, where mount permission checks are UID-based. The image, though,
# bakes 'vari' at whatever USER_ID/USER_GID it was built with (1000 by default),
# so any other UID has no /etc/passwd entry. glibc's getpwuid() then fails and
# OpenSSH aborts with "No user exists for uid <N>", breaking every git-over-SSH
# fetch BitBake performs while resolving SRCREV/AUTOREV. Exporting HOME does not
# help: ssh calls getpwuid() directly, independently of $HOME.
#
# Applied on every platform, not just Linux: the UID the container runs as and
# the UID baked into the image are set independently, so they can disagree
# anywhere. Where they already agree this is a no-op.
#
# The override is derived from the image's own /etc/passwd so the system
# accounts the Yocto build relies on (root, nobody, ...) are preserved — a
# hand-written minimal file would drop them and break pseudo/do_rootfs.
_prepare_container_identity() {
  _CONTAINER_PASSWD_FILE=""
  _CONTAINER_GROUP_FILE=""

  # uid 0 always resolves: every image ships a root entry.
  if [[ "${WORKDIR_UID}" == "0" ]]; then
    return 0
  fi

  # Must live under PROJECT_TOP: it is the path shared into the container
  # runtime's VM on macOS (colima/Lima/Docker Desktop). A host-only path such
  # as /tmp does not exist inside that VM, and the bind mount fails outright.
  local cache_dir="${PROJECT_TOP}/${POKY_TMP_DIR}"
  mkdir -p "${cache_dir}" || return 1

  local image_passwd="${cache_dir}/.image-passwd"
  local image_group="${cache_dir}/.image-group"
  local image_stamp="${cache_dir}/.image-id"

  local image_id
  image_id=$(${CONTAINER_CMD} image inspect -f '{{.Id}}' "${POKY_IMAGE}" 2>/dev/null)

  # Re-extract only when the image changed, so repeated bitbake invocations
  # don't each pay for an extra container start.
  if [[ -z "${image_id}" ]] || [[ ! -s "${image_passwd}" ]] || [[ ! -s "${image_group}" ]] ||
    [[ "$(cat "${image_stamp}" 2>/dev/null)" != "${image_id}" ]]; then
    ${CONTAINER_CMD} run --rm --entrypoint cat "${POKY_IMAGE}" /etc/passwd >"${image_passwd}" 2>/dev/null
    ${CONTAINER_CMD} run --rm --entrypoint cat "${POKY_IMAGE}" /etc/group >"${image_group}" 2>/dev/null

    if [[ ! -s "${image_passwd}" ]] || [[ ! -s "${image_group}" ]]; then
      echo "WARNING: could not read /etc/passwd from ${POKY_IMAGE}; using a minimal fallback" >&2
      printf 'root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' >"${image_passwd}"
      printf 'root:x:0:\nnobody:x:65534:\n' >"${image_group}"
    fi

    ${CONTAINER_CMD} image inspect -f '{{.Id}}' "${POKY_IMAGE}" >"${image_stamp}" 2>/dev/null || : >"${image_stamp}"
  fi

  local out_passwd="${cache_dir}/.container-passwd"
  local out_group="${cache_dir}/.container-group"

  # Drop the image's own 'vari' entry plus anything already occupying the
  # target UID/GID (getpwuid returns the first match, so a duplicate would
  # win and hand back the wrong home), then re-add 'vari' at the UID:GID the
  # container actually runs as. Keeping the name and the /home/vari home path
  # preserves the HOME export and the ~/.ssh, .gitconfig and .git-credentials
  # mounts set up below.
  awk -F: -v uid="${WORKDIR_UID}" '$1 != "vari" && $3 != uid' "${image_passwd}" >"${out_passwd}" || return 1
  printf 'vari:x:%s:%s:vari:/home/vari:/bin/bash\n' "${WORKDIR_UID}" "${WORKDIR_GID}" >>"${out_passwd}"

  awk -F: -v gid="${WORKDIR_GID}" '$1 != "vari" && $3 != gid' "${image_group}" >"${out_group}" || return 1
  printf 'vari:x:%s:\n' "${WORKDIR_GID}" >>"${out_group}"

  _CONTAINER_PASSWD_FILE="${out_passwd}"
  _CONTAINER_GROUP_FILE="${out_group}"
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

  # On Linux use host networking so BitBake inside the container can reach
  # the shared prserv daemon on the host at localhost:8585.
  # On macOS Docker Desktop uses a VM; host networking is not supported there,
  # and developers use per-workspace prserv (localhost:0) anyway.
  if [[ "$(uname -s)" == "Linux" ]]; then
    EXTRA_DOCKER_ARGS+=(--network host)
  fi

  # Resolve the invoking user's home from the passwd database rather than
  # $USER, which is often unset under non-interactive invocations (e.g. a
  # systemd-managed CI runner). "/home/$USER/.ssh" would then collapse to
  # "/home/.ssh", which Docker creates as an empty directory and mounts over
  # the container's ~/.ssh, breaking SSH-authenticated git fetches.
  local HOST_HOME
  HOST_HOME="$(_host_home_dir)"
  local SSH_PATH="${HOST_HOME}/.ssh"

  # git-credentials is created by CI for HTTPS auth
  local GIT_CREDENTIALS_PATH="${HOST_HOME}/.git-credentials"

  # Prepare docker arguments
  #
  # /home/vari in the image is owned by whatever USER_ID/USER_GID it was
  # built with (1000 by default) — not necessarily WORKDIR_UID:WORKDIR_GID
  # (the host's real UID:GID, used for -u above). BitBake and other tools
  # need to write into $HOME (e.g. sanity-checker's .netrc probe), so bind
  # a host-side scratch directory over /home/vari: it's created below via
  # a plain host `mkdir -p`, inheriting the invoking (host) user's
  # ownership, which always matches WORKDIR_UID:WORKDIR_GID.
  local HOME_DIR="${PROJECT_TOP}/${POKY_TMP_DIR}/home"
  mkdir -p "$HOME_DIR"

  _prepare_container_identity || return 1

  local docker_args=(
    -u "${WORKDIR_UID}:${WORKDIR_GID}"
    # Running as a numeric UID:GID (to match the host, for bind-mount
    # write access) means the container has no matching /etc/passwd
    # entry, so Docker can't auto-derive HOME from it. Force HOME back
    # to /home/vari explicitly so the git-credentials/.gitconfig mounts
    # below (and BitBake's HOME expectations) keep working.
    -e HOME=/home/vari
    --rm
    -v "${PROJECT_TOP}:${WORKSPACE_PATH}${VOLUME_FLAGS}"
    -v "${VOLUME_NAME}_workdir:/workdir${WORKDIR_FLAGS}"
    -v "${SSTATE_VOLUME_NAME:-${VOLUME_NAME}_sstate}:/sstate-cache${WORKDIR_FLAGS}"
    -v "${HOME_DIR}:/home/vari${VOLUME_FLAGS}"
    -v "${SSH_PATH}:/home/vari/.ssh${VOLUME_FLAGS}"
    -w "${WORKSPACE_PATH}"
  )

  # Give the container's numeric UID:GID a real passwd/group entry so
  # getpwuid() — and therefore ssh — works (see _prepare_container_identity).
  if [[ -n "${_CONTAINER_PASSWD_FILE}" ]] && [[ -n "${_CONTAINER_GROUP_FILE}" ]]; then
    docker_args+=(-v "${_CONTAINER_PASSWD_FILE}:/etc/passwd:ro${VOLUME_FLAGS}")
    docker_args+=(-v "${_CONTAINER_GROUP_FILE}:/etc/group:ro${VOLUME_FLAGS}")
  fi

  # A symlinked ~/.ssh/config (dotfiles managers like stow, chezmoi or a plain
  # ln -s) points to an absolute host path that does not exist in the
  # container. ssh treats a missing user config as no config, so per-host
  # IdentityFile entries are ignored and auth falls back to a password prompt.
  # Mount the real file at its host path so the symlink works in the container.
  if [[ -L "${SSH_PATH}/config" ]]; then
    local _ssh_cfg_target
    _ssh_cfg_target="$(realpath "${SSH_PATH}/config" 2>/dev/null)"
    if [[ -f "${_ssh_cfg_target}" ]]; then
      docker_args+=(-v "${_ssh_cfg_target}:${_ssh_cfg_target}:ro${VOLUME_FLAGS}")
    fi
  fi

  # SSTATE_DIR, DL_DIR, and TMPDIR are all set and passed through by
  # apply_passthrough.sh inside the container. Do not inject them via -e here
  # — a host TMPDIR (e.g. /var/folders/... on macOS) would override the
  # correct container default (/workdir/tmp).

  # Forward the host SSH agent socket so the container can use already-loaded keys
  if [[ -n "$SSH_AUTH_SOCK" ]] && [[ -S "$SSH_AUTH_SOCK" ]]; then
    docker_args+=(-e SSH_AUTH_SOCK=/run/ssh-agent.sock)
    docker_args+=(-v "${SSH_AUTH_SOCK}:/run/ssh-agent.sock")
  fi

  # Mount git-credentials if available (for HTTPS fetches with GHE_TOKEN).
  # BitBake sanitises the environment, so GIT_CONFIG_* env vars won't reach
  # the fetcher's git process.  Instead, mount a .gitconfig that enables the
  # credential store — git reads $HOME/.gitconfig natively and BitBake
  # preserves HOME="/home/vari".
  if [[ -f "$GIT_CREDENTIALS_PATH" ]]; then
    mkdir -p "${PROJECT_TOP}/${POKY_TMP_DIR}"
    local _gitcfg="${PROJECT_TOP}/${POKY_TMP_DIR}/.gitconfig-docker"
    # credential.helper — use stored .git-credentials for HTTPS auth
    # url.insteadOf    — rewrite SSH git@ URLs to HTTPS so private repos
    #                    accessible via token don't require SSH key/agent
    printf '[credential]\n\thelper = store\n[url "https://git.va-dev.no/"]\n\tinsteadOf = git@git.va-dev.no:\n' >"$_gitcfg"
    docker_args+=(-v "${GIT_CREDENTIALS_PATH}:/home/vari/.git-credentials:ro${VOLUME_FLAGS}")
    docker_args+=(-v "${_gitcfg}:/home/vari/.gitconfig:ro${VOLUME_FLAGS}")
  fi

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
    # Port has changed — invalidate cached compose file so envsubst picks up new value
    unset _COMPOSE_FILE_GENERATED
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
