# File: /docker-yocto-env/core/config.sh

# Configuration settings for the docker-yocto-env environment

# Set the architecture of the environment
# Priorities:
# 1. First argument to the script
# 2. ENV_ARCH environment variable
# 3. uname -m
ENV_ARCH=${1:-${ENV_ARCH:-$(uname -m)}}

# Define Docker registry and image settings
DOCKER_REGISTRY=roommatedev01.azurecr.io
YOCTO_RELEASE=kirkstone
VDE_VERSION=22.04
VDE_IMAGE=poky-vde
POKY_IMAGE=${DOCKER_REGISTRY}/${VDE_IMAGE}:${YOCTO_RELEASE}-${VDE_VERSION}

# Define workspace and project settings
PROJECT_TOP=$(git rev-parse --show-toplevel)
PROJECT_NAME=$(basename ${PROJECT_TOP} | tr '.' '-')
WORKSPACE_PATH=/workspace
POKY_TMP_DIR=poky_tmp

# Define volume and port settings
VOLUME_NAME=${PROJECT_NAME}-${ENV_ARCH}
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
export TOASTER_WEBUI
export DL_PORT
export MACHINES_EXCLUDE_DIRS
export IMAGES_EXCLUDE_DIRS

# Enable Docker BuildKit for modern image building
export DOCKER_BUILDKIT=1