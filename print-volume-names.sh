#!/bin/bash
# File: /docker-yocto-env/print-volume-names.sh
#
# Prints the Docker volume names this environment would use for the current
# checkout, WITHOUT requiring Docker itself or performing any env/container
# setup. Intended for CI (or any script) that needs to build, clean, or
# inspect the same volumes docker-yocto-env uses, without re-implementing
# core/config.sh's naming formula (project/parent-dir/remote-URL hashing,
# branch sanitization, etc.) a second time — that duplication is exactly what
# went stale and silently broke when the naming formula last changed.
#
# Usage:
#   DOCKER_REGISTRY=<registry> ./docker-yocto-env/print-volume-names.sh
#
# Output (KEY=VALUE, one per line, eval-able):
#   VOLUME_NAME=<workdir volume name>
#   SSTATE_VOLUME_NAME=<sstate volume name>
#
# Example (bash):
#   eval "$(DOCKER_REGISTRY=example.com/registry ./docker-yocto-env/print-volume-names.sh)"
#   echo "$VOLUME_NAME"
#
# Must be run (not sourced) from within the consuming project's checkout, or
# with cwd inside it — core/config.sh derives PROJECT_TOP from
# `git rev-parse --show-toplevel` of the current working directory, the same
# as when docker-yocto-env's `env` is sourced normally.
set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")

# shellcheck source=core/config.sh
source "${SCRIPT_DIR}/core/config.sh"

echo "VOLUME_NAME=${VOLUME_NAME}"
echo "SSTATE_VOLUME_NAME=${SSTATE_VOLUME_NAME}"
