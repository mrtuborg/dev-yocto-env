# File: /docker-yocto-env/core/config.sh

# Configuration settings for the docker-yocto-env environment

# Set the architecture of the environment
# Priorities:
# 1. First argument to the script
# 2. ENV_ARCH environment variable
# 3. uname -m
ENV_ARCH=${1:-${ENV_ARCH:-$(uname -m)}}

# Define Docker registry and image settings
#
# DOCKER_REGISTRY is deployment-specific (it names a private registry that
# hosts the pre-built poky-vde image) and therefore does not belong in this
# public repo. Consumers must export it before sourcing this script (e.g.
# from their own init.sh or a project-level env wrapper, which is the
# natural source of truth for which registry they pull/push from). There is
# no safe public default, so an unset value is a loud error rather than a
# silent fallback to some guessed-at registry.
if [[ -z "${DOCKER_REGISTRY:-}" ]]; then
    echo "ERROR: DOCKER_REGISTRY is not set. Export it before sourcing this script (e.g. from your project's init.sh)." >&2
    return 1 2>/dev/null || exit 1
fi
# YOCTO_RELEASE identifies which Poky/OE release this build targets (e.g.
# "kirkstone", "scarthgap"). Consumers should export it before sourcing this
# script (e.g. from their own init.sh, which is the natural source of truth
# for which manifest/release branch they build against). Defaults to
# "kirkstone" for backward compatibility with existing consumers.
#
# Guard against an explicitly-empty override: "${VAR:-default}" already
# treats unset AND null/empty as "use default" per POSIX parameter expansion,
# but we keep an explicit check here too since this value feeds directly
# into a Docker volume name below — a silently empty segment there would
# produce a malformed or confusingly-named volume instead of a loud error.
YOCTO_RELEASE=${YOCTO_RELEASE:-kirkstone}
[[ -z "$YOCTO_RELEASE" ]] && YOCTO_RELEASE="kirkstone"
VDE_VERSION=22.04
VDE_IMAGE=poky-vde
POKY_IMAGE=${DOCKER_REGISTRY}/${VDE_IMAGE}:${YOCTO_RELEASE}-${VDE_VERSION}

# Define workspace and project settings
PROJECT_TOP=$(git rev-parse --show-toplevel)
PROJECT_NAME=$(basename ${PROJECT_TOP} | tr '.' '-' | tr '[:upper:]' '[:lower:]')
[[ -z "$PROJECT_NAME" ]] && PROJECT_NAME="project"
WORKSPACE_PATH=/workspace
POKY_TMP_DIR=poky_tmp

# Portable short-hash helper (sha256sum is GNU coreutils and absent on macOS
# by default; fall back to shasum, then to cksum as a last resort). This only
# needs to distinguish inputs from each other, not resist attacks.
_hash_string() {
    local input="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$input" | sha256sum | cut -c1-10
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$input" | shasum -a 256 | cut -c1-10
    else
        printf '%s' "$input" | cksum | awk '{print $1}'
    fi
}

# ── Volume naming ──────────────────────────────────────────────────────────
#
# Two identities are computed, because the workdir and sstate-cache volumes
# have different sharing requirements:
#
#   PROJECT_PATH_KEY — unique per checkout LOCATION (basename + hash of the
#   parent directory). Used for the `_workdir` volume (live BitBake TMPDIR +
#   downloads), which must NEVER be shared between two concurrently-active,
#   unrelated builds — two different checkouts (e.g. two CI runner instances,
#   or two directories that happen to share the same basename) must never
#   collide here. It's fine — and expected — for this to differ across
#   checkout locations of even the SAME repo; each location just gets its
#   own independently-warmed workdir cache.
#
#   PROJECT_REPO_KEY — unique per REPOSITORY (basename + hash of the git
#   remote URL), stable regardless of where or how many times it's checked
#   out. Used for the sstate-cache volume, which IS safe (and beneficial) to
#   share across many checkout locations, branches, and hardware targets of
#   the same repo — BitBake's own task-signature hashing already keys sstate
#   objects by everything that actually affects their output (including
#   MACHINE), so sharing one cache across e.g. multiple self-hosted runners
#   building the same repo is both safe and a real speedup. It is
#   deliberately NOT branch-specific by default (sstate is designed to be
#   reused across branches) but IS release-specific (see YOCTO_RELEASE
#   above) since sstate objects from different Poky/OE releases are for all
#   practical purposes never compatible and would just waste disk if mixed.
#
# Branch is folded into the workdir volume only, so switching branches in
# the same local checkout gets a fresh workdir instead of silently reusing
# stale build state from a different branch (a real class of bug — see
# "version going backwards" style staleness issues).
#
# This is a function (not inline top-level code) so it can be called again
# later to RE-derive VOLUME_NAME/SSTATE_VOLUME_NAME. common.sh's
# _load_default_exports() calls this every time it runs — which happens not
# just at initial env setup but on every subsequent plugin invocation (poky,
# volume, cleanup, filebrowser, rpm_host), several of which unset VOLUME_NAME
# via _unload_default_exports when they finish. Without re-deriving it the
# same way here, those later calls would either silently regress to a
# different (stale/incorrect) formula or leave VOLUME_NAME unset entirely.
# Keeping this logic in one function is what makes config.sh authoritative.
_compute_volume_names() {
    PROJECT_PARENT_HASH=$(_hash_string "$(dirname "${PROJECT_TOP}")")
    [[ -z "$PROJECT_PARENT_HASH" ]] && PROJECT_PARENT_HASH="nohash"

    GIT_REMOTE_URL=$(git remote get-url origin 2>/dev/null)
    [[ -z "$GIT_REMOTE_URL" ]] && GIT_REMOTE_URL="local-${PROJECT_NAME}"
    PROJECT_REMOTE_HASH=$(_hash_string "$GIT_REMOTE_URL")
    [[ -z "$PROJECT_REMOTE_HASH" ]] && PROJECT_REMOTE_HASH="nohash"

    PROJECT_PATH_KEY="${PROJECT_NAME}-${PROJECT_PARENT_HASH}"
    PROJECT_REPO_KEY="${PROJECT_NAME}-${PROJECT_REMOTE_HASH}"

    # Branch: prefer CI-provided context (GitHub Actions sets GITHUB_HEAD_REF
    # for PR builds and GITHUB_REF_NAME for push/tag builds automatically —
    # no workflow changes needed to use them; other CI systems' equivalents
    # could be added the same way). This matters because a checked-out PR is
    # normally in detached HEAD state, where plain git commands can't recover
    # the logical branch name. Falls back to real git state for local dev,
    # where HEAD is normally a real branch, not detached.
    GIT_BRANCH="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
    if [[ -z "$GIT_BRANCH" ]]; then
        GIT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
    fi
    if [[ -z "$GIT_BRANCH" ]]; then
        GIT_BRANCH="detached-$(git rev-parse --short HEAD 2>/dev/null)"
    fi
    # Sanitize for use in a Docker volume name: lowercase, replace anything
    # outside [a-z0-9_.-] with '-' (branch names like "feature/foo" contain
    # '/', which Docker volume names don't allow).
    GIT_BRANCH=$(printf '%s' "$GIT_BRANCH" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-')
    [[ -z "$GIT_BRANCH" || "$GIT_BRANCH" == "detached-" ]] && GIT_BRANCH="unknown-branch"

    # Define volume and port settings
    VOLUME_NAME="${PROJECT_PATH_KEY}-${GIT_BRANCH}-${ENV_ARCH}"
    [[ -z "$VOLUME_NAME" ]] && VOLUME_NAME="${PROJECT_NAME}-${ENV_ARCH}"
    # Honour SSTATE_VOLUME_NAME if already set in the environment (e.g. by CI
    # to point multiple checkouts/branches/runners at a single shared sstate
    # volume). Only compute the default when it has not been set by the
    # caller.
    SSTATE_VOLUME_NAME=${SSTATE_VOLUME_NAME:-${PROJECT_REPO_KEY}-${YOCTO_RELEASE}-${ENV_ARCH}_sstate}
    [[ -z "$SSTATE_VOLUME_NAME" ]] && SSTATE_VOLUME_NAME="${PROJECT_REPO_KEY}-${YOCTO_RELEASE}-${ENV_ARCH}_sstate"

    _validate_volume_name "$VOLUME_NAME" "VOLUME_NAME" || return 1
    _validate_volume_name "$SSTATE_VOLUME_NAME" "SSTATE_VOLUME_NAME" || return 1

    export VOLUME_NAME
    export SSTATE_VOLUME_NAME
    return 0
}

# Final sanity check: reject anything that could produce a malformed or
# rejected Docker volume name (an empty component collapsing into a double
# separator, a leading separator, or characters outside Docker's allowed
# set) rather than silently creating a confusing or broken volume.
_validate_volume_name() {
    local name="$1" label="$2"
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "ERROR: computed $label '$name' is not a valid Docker volume name" >&2
        return 1
    fi
    if [[ "$name" == *--* || "$name" == *__* || "$name" == *-_* || "$name" == *_-* ]]; then
        echo "ERROR: computed $label '$name' looks malformed (an empty component likely collapsed into a double separator)" >&2
        return 1
    fi
    return 0
}
_compute_volume_names || return 1 2>/dev/null || exit 1

FILEBROWSER_PORT=9200
DL_PORT=9210
TOASTER_WEBUI=9090

# Set user and group IDs for work directory
WORKDIR_UID=1000
WORKDIR_GID=1000

# Redefine WORKDIR_UID and WORKDIR_GID only if on a Linux machine
if [[ "$(uname -s)" == "Linux" ]]; then
    WORKDIR_UID=$(id -u $USER)
    WORKDIR_GID=$(id -g $USER)
fi

# Determine SSH path based on OS
if [[ "$(uname -s)" == "Linux" ]]; then
    SSH_PATH="/home/$USER/.ssh"
else
    SSH_PATH="/Users/$USER/.ssh"
fi

# Directory exclusion variables for info commands
MACHINES_EXCLUDE_DIRS=${MACHINES_EXCLUDE_DIRS:-"sources"}
IMAGES_EXCLUDE_DIRS=${IMAGES_EXCLUDE_DIRS:-"sources"}

# Export environment variables for use in other scripts
export POKY_IMAGE
export PROJECT_TOP
export PROJECT_NAME
export WORKSPACE_PATH
export WORKDIR_UID
export WORKDIR_GID
export FILEBROWSER_PORT
export ENV_ARCH
export VOLUME_NAME
export SSTATE_VOLUME_NAME
export TOASTER_WEBUI
export DL_PORT
export SSH_PATH
export MACHINES_EXCLUDE_DIRS
export IMAGES_EXCLUDE_DIRS

# Enable Docker BuildKit for modern image building
export DOCKER_BUILDKIT=1