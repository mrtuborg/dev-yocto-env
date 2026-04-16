#!/bin/bash
# File: docker-yocto-env/plugins/devtool.sh
#
# Developer-workflow plugin: find the package/recipe that owns a file on the
# target device, rebuild it, deploy it, and diff against a live
# device — all from one command.
#
# Host-only (instant, no container):
#   devtool who    <target-path>
#   devtool search <pattern>
#   devtool files  <recipe>
#   devtool recipe <target-path>
#
# Requires running container:
#   devtool build  <target-path>   [build_dir]
#   devtool deploy <target-path>   <device-ip>  [build_dir]
#   devtool diff   <target-path>   <device-ip>  [build_dir]
#
# Environment variables (all optional):
#   DEVTOOL_BUILD_DIR    default Yocto build directory  (default: build_roomboard)
#   BUILDHISTORY_DIR     override buildhistory packages path

devtool_init() {
    register_plugin_command \
        "devtool" "devtool" \
        "Find package owner, rebuild, deploy, diff" \
        "devtool {who|search|files|recipe|build|deploy|diff} <target-path> ..."
}

# ---------------------------------------------------------------------------
# Internal: given a target filesystem path, populate module-level variables:
#   _DEVTOOL_RECIPE  _DEVTOOL_PKG  _DEVTOOL_ARCH  _DEVTOOL_LAYER
# Returns 1 (with an error message) if not found.
# Called directly (no subshell), so exit code propagates cleanly.
# ---------------------------------------------------------------------------
_devtool_find_owner() {
    local target_path="$1"
    local bh="${BUILDHISTORY_DIR:-${PROJECT_TOP}/build_roomboard/buildhistory/packages}"

    # Clear module-level output variables so stale values from a previous call
    # are never visible if this call fails early.
    _DEVTOOL_RECIPE=""
    _DEVTOOL_PKG=""
    _DEVTOOL_ARCH=""
    _DEVTOOL_LAYER=""

    if [[ ! -d "$bh" ]]; then
        echo "ERROR: buildhistory not found: $bh" >&2
        echo "       Run a build first to populate buildhistory, or set BUILDHISTORY_DIR." >&2
        return 1
    fi

    # Escape ERE metacharacters in the path (dots, brackets, etc.)
    local escaped
    escaped=$(printf '%s' "$target_path" | sed 's/[].\[^$*]/\\&/g')

    # FILELIST is a single space-separated line; path can be first or non-first token
    local pattern="^FILELIST = ${escaped}( |$)|^FILELIST = .* ${escaped}( |$)"
    local match
    match=$(grep -rEl "$pattern" "$bh" --include='latest' 2>/dev/null | head -1 || true)

    if [[ -z "$match" ]]; then
        echo "ERROR: No package found owning: $target_path" >&2
        echo "       (buildhistory searched: $bh)" >&2
        return 1
    fi

    local pkg_dir recipe_dir
    pkg_dir=$(dirname "$match")
    recipe_dir=$(dirname "$pkg_dir")

    _DEVTOOL_RECIPE=$(basename "$recipe_dir")
    _DEVTOOL_PKG=$(basename "$pkg_dir")
    _DEVTOOL_ARCH=$(basename "$(dirname "$recipe_dir")")
    _DEVTOOL_LAYER="unknown"
    if [[ -f "$recipe_dir/latest" ]]; then
        local layer
        layer=$(grep '^LAYER = ' "$recipe_dir/latest" | sed 's/^LAYER = //' || true)
        [[ -n "$layer" ]] && _DEVTOOL_LAYER="$layer"
    fi
}

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------
devtool() {
    local subcmd="${1:-}"
    if [[ -z "$subcmd" ]]; then
        _devtool_usage
        return 1
    fi
    shift

    case "$subcmd" in
        who)    _devtool_who    "$@" ;;
        search) _devtool_search "$@" ;;
        files)  _devtool_files  "$@" ;;
        recipe) _devtool_recipe "$@" ;;
        build)  _devtool_build  "$@" ;;
        deploy) _devtool_deploy "$@" ;;
        diff)   _devtool_diff   "$@" ;;
        -h|--help|help) _devtool_usage; return 0 ;;
        *)
            echo "ERROR: Unknown sub-command: $subcmd" >&2
            _devtool_usage
            return 1
            ;;
    esac
    return $?
}

_devtool_usage() {
    cat >&2 <<'EOF'
Usage: devtool <sub-command> [args]

HOST-ONLY (no container required):
  who    <target-path>
      Print package name and BitBake recipe that own the file.

  search <pattern>
      Search all packages for files matching an ERE pattern.
      Example: devtool search '\.service$'
               devtool search 'crash-reporter'

  files  <recipe>
      List all files installed by every package of a recipe.

  recipe <target-path>
      Print the path to the .bb file that builds the owning recipe.

REQUIRES CONTAINER (poky must be running or startable):
  build  <target-path>  [build_dir]
      Find the owner and run:  bitbake <recipe>

  deploy <target-path>  <device-ip>  [build_dir]
      Rebuild then deploy the owning recipe to the device with
      devtool deploy-target.

  diff   <target-path>  <device-ip>  [build_dir]
      Diff the file as built (image dir inside container) against
      what is currently on the device. Does NOT rebuild first.

Environment variables:
  BUILDHISTORY_DIR   override buildhistory packages directory
  DEVTOOL_BUILD_DIR  default build directory (overrides hard-coded build_roomboard)

Examples:
  devtool who    /opt/roommate/scripts/crash-reporter.sh
  devtool search 'crash-reporter'
  devtool files  roommate
  devtool recipe /opt/roommate/scripts/crash-reporter.sh
  devtool build  /opt/roommate/scripts/crash-reporter.sh
  devtool deploy /opt/roommate/scripts/crash-reporter.sh  192.168.1.42
  devtool diff   /opt/roommate/scripts/crash-reporter.sh  192.168.1.42
EOF
}

# ---------------------------------------------------------------------------
# devtool who <target-path>
# ---------------------------------------------------------------------------
_devtool_who() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: devtool who <target-path>" >&2
        return 1
    fi
    local target_path="$1"

    _devtool_find_owner "$target_path" || return 1

    echo "File:    $target_path"
    echo "Package: $_DEVTOOL_PKG  (arch: $_DEVTOOL_ARCH)"
    echo "Recipe:  $_DEVTOOL_RECIPE  (layer: $_DEVTOOL_LAYER)"
    echo ""
    echo "To rebuild:  devtool build  $target_path"
    echo "To deploy:   devtool deploy $target_path <device-ip>"
}

# ---------------------------------------------------------------------------
# devtool build <target-path> [build_dir]
# ---------------------------------------------------------------------------
_devtool_build() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: devtool build <target-path> [build_dir]" >&2
        return 1
    fi
    local target_path="$1"
    local build_dir="${2:-${DEVTOOL_BUILD_DIR:-build_roomboard}}"

    if ! declare -F poky > /dev/null 2>&1; then
        echo "ERROR: 'poky' function not found — make sure ./env is sourced" >&2
        return 1
    fi

    _devtool_find_owner "$target_path" || return 1

    echo "File:    $target_path"
    echo "Package: $_DEVTOOL_PKG  (layer: $_DEVTOOL_LAYER)"
    echo "Recipe:  $_DEVTOOL_RECIPE"
    echo ""
    echo "--- running: poky run $build_dir bitbake $_DEVTOOL_RECIPE ---"
    poky run "$build_dir" "bitbake $_DEVTOOL_RECIPE"
}

# ---------------------------------------------------------------------------
# devtool deploy <target-path> <device-ip> [build_dir]
# ---------------------------------------------------------------------------
_devtool_deploy() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: devtool deploy <target-path> <device-ip> [build_dir]" >&2
        return 1
    fi
    local target_path="$1"
    local device_ip="$2"
    local build_dir="${3:-${DEVTOOL_BUILD_DIR:-build_roomboard}}"

    if ! declare -F poky > /dev/null 2>&1; then
        echo "ERROR: 'poky' function not found — make sure ./env is sourced" >&2
        return 1
    fi

    _devtool_find_owner "$target_path" || return 1

    echo "File:    $target_path"
    echo "Package: $_DEVTOOL_PKG  (layer: $_DEVTOOL_LAYER)"
    echo "Recipe:  $_DEVTOOL_RECIPE"
    echo "Target:  root@$device_ip"
    echo ""
    echo "--- step 1/2: bitbake $_DEVTOOL_RECIPE ---"
    if ! poky run "$build_dir" "bitbake $_DEVTOOL_RECIPE"; then
        echo "ERROR: bitbake step failed for recipe '$_DEVTOOL_RECIPE'" >&2
        return 1
    fi

    echo ""
    echo "--- step 2/2: devtool deploy-target $_DEVTOOL_RECIPE root@$device_ip ---"
    if ! poky run "$build_dir" "devtool deploy-target $_DEVTOOL_RECIPE root@$device_ip"; then
        echo "ERROR: deploy step failed for recipe '$_DEVTOOL_RECIPE' to $device_ip" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# devtool search <pattern>   (host-only, ERE)
# ---------------------------------------------------------------------------
_devtool_search() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: devtool search <ERE-pattern>" >&2
        return 1
    fi
    local pattern="$1"
    local bh="${BUILDHISTORY_DIR:-${PROJECT_TOP}/build_roomboard/buildhistory/packages}"

    if [[ ! -d "$bh" ]]; then
        echo "ERROR: buildhistory not found: $bh" >&2
        return 1
    fi

    # Step 1: find package latest files whose FILELIST line contains the pattern (fast)
    # Anchor to ^FILELIST to skip recipe-level latest files (no FILELIST field).
    local candidates
    candidates=$(grep -rEl "^FILELIST.*${pattern}" "$bh" --include='latest' 2>/dev/null || true)

    if [[ -z "$candidates" ]]; then
        echo "No files found matching: $pattern" >&2
        return 1
    fi

    local found=0
    local pkg_latest pkg recipe filelist f
    while IFS= read -r pkg_latest; do
        filelist=$(grep '^FILELIST = ' "$pkg_latest" | sed 's/^FILELIST = //' || true)
        [[ -z "$filelist" ]] && continue

        pkg=$(basename "$(dirname "$pkg_latest")")
        recipe=$(basename "$(dirname "$(dirname "$pkg_latest")")")

        # Check each individual path against the pattern
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            if printf '%s' "$f" | grep -qE "$pattern"; then
                printf "%-55s  pkg:%-30s  recipe:%s\n" "$f" "$pkg" "$recipe"
                (( found++ )) || true
            fi
        done < <(printf '%s' "$filelist" | tr ' ' '\n')
    done <<< "$candidates"

    [[ $found -eq 0 ]] && echo "No files found matching: $pattern" >&2 && return 1
    echo ""
    echo "$found file(s) matched."
}

# ---------------------------------------------------------------------------
# devtool files <recipe>   (host-only)
# ---------------------------------------------------------------------------
_devtool_files() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: devtool files <recipe>" >&2
        return 1
    fi
    local recipe="$1"
    local bh="${BUILDHISTORY_DIR:-${PROJECT_TOP}/build_roomboard/buildhistory/packages}"

    if [[ ! -d "$bh" ]]; then
        echo "ERROR: buildhistory not found: $bh" >&2
        return 1
    fi

    # Find all package-level latest files under the given recipe directory
    local found=0
    local pkg_latest pkg filelist f
    while IFS= read -r pkg_latest; do
        filelist=$(grep '^FILELIST = ' "$pkg_latest" | sed 's/^FILELIST = //' || true)
        [[ -z "$filelist" ]] && continue

        pkg=$(basename "$(dirname "$pkg_latest")")
        echo "--- $pkg ---"
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "  $f"
        done < <(printf '%s' "$filelist" | tr ' ' '\n')
        (( found++ )) || true
    done < <(find "$bh" -mindepth 4 -maxdepth 4 -name latest -path "*/${recipe}/*" 2>/dev/null)

    if [[ $found -eq 0 ]]; then
        echo "ERROR: No packages found for recipe '$recipe' in buildhistory" >&2
        echo "       (buildhistory searched: $bh)" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# devtool recipe <target-path>   (host-only)
# ---------------------------------------------------------------------------
_devtool_recipe() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: devtool recipe <target-path>" >&2
        return 1
    fi

    _devtool_find_owner "$1" || return 1

    local layer_dir="${PROJECT_TOP}/${_DEVTOOL_LAYER}"
    if [[ ! -d "$layer_dir" ]]; then
        echo "ERROR: Layer directory not found: $layer_dir" >&2
        echo "       Set PROJECT_TOP or check that the layer is checked out." >&2
        return 1
    fi

    # .bb files can be named <recipe>.bb or <recipe>_<version>.bb
    local bbfile
    bbfile=$(find "$layer_dir" \( -name "${_DEVTOOL_RECIPE}.bb" -o -name "${_DEVTOOL_RECIPE}_*.bb" \) \
             -not -path "*/node_modules/*" 2>/dev/null | head -1 || true)

    if [[ -z "$bbfile" ]]; then
        echo "ERROR: No .bb file found for recipe '$_DEVTOOL_RECIPE' in $layer_dir" >&2
        return 1
    fi

    echo "Recipe:  $_DEVTOOL_RECIPE  (layer: $_DEVTOOL_LAYER)"
    echo "File:    $bbfile"
}

# ---------------------------------------------------------------------------
# devtool diff <target-path> <device-ip> [build_dir]
# Diffs built image file (inside container) vs file on device.  No rebuild.
# ---------------------------------------------------------------------------
_devtool_diff() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: devtool diff <target-path> <device-ip> [build_dir]" >&2
        return 1
    fi
    local target_path="$1"
    local device_ip="$2"
    local build_dir="${3:-${DEVTOOL_BUILD_DIR:-build_roomboard}}"

    if ! declare -F poky > /dev/null 2>&1; then
        echo "ERROR: 'poky' function not found — make sure ./env is sourced" >&2
        return 1
    fi

    _devtool_find_owner "$target_path" || return 1

    echo "File:    $target_path"
    echo "Recipe:  $_DEVTOOL_RECIPE  (layer: $_DEVTOOL_LAYER)"
    echo "Device:  root@$device_ip"
    echo ""

    local staging_dir="${PROJECT_TOP}/poky_tmp"
    mkdir -p "$staging_dir"
    local built_file="${staging_dir}/.devtool_diff_built"
    local device_file="${staging_dir}/.devtool_diff_device"

    # Step 1: copy built file from container image dir to /workspace/poky_tmp.
    # Capture output and exit code separately so the pipe doesn't swallow the
    # container's exit code.
    local recipe="${_DEVTOOL_RECIPE}"
    local container_cmd
    container_cmd="recipe_dir=\$(find /workdir/tmp/work -mindepth 2 -maxdepth 2 -name '${recipe}' -type d 2>/dev/null | head -1); \
[ -z \"\$recipe_dir\" ] && echo 'ERROR: work dir not found. Has the recipe been built?' >&2 && exit 1; \
img_file=\$(find \"\$recipe_dir\" -path \"*/image${target_path}\" 2>/dev/null | head -1); \
[ -z \"\$img_file\" ] && echo 'ERROR: ${target_path} not found in image dir. Try running: devtool build ${target_path}' >&2 && exit 1; \
cp \"\$img_file\" /workspace/poky_tmp/.devtool_diff_built"

    echo "--- fetching built version from container ---"
    if ! poky run "$build_dir" "$container_cmd"; then
        rm -f "$built_file" "$device_file"
        echo "ERROR: failed to extract built file from container" >&2
        return 1
    fi
    if [[ ! -f "$built_file" ]]; then
        rm -f "$device_file"
        echo "ERROR: container ran but did not produce the expected file" >&2
        return 1
    fi

    # Step 2: fetch file from device via scp
    echo "--- fetching device version from root@${device_ip} ---"
    if ! scp -q "root@${device_ip}:${target_path}" "$device_file" 2>/dev/null; then
        rm -f "$built_file"
        echo "ERROR: scp from root@${device_ip}:${target_path} failed" >&2
        echo "       Check that the device is reachable and SSH is configured." >&2
        return 1
    fi

    # Step 3: diff; clean up temp files regardless of result
    echo "--- diff: built (left) vs device (right) ---"
    local diff_rc=0
    diff --color=auto "$built_file" "$device_file" || diff_rc=$?
    rm -f "$built_file" "$device_file"
    if [[ $diff_rc -eq 0 ]]; then
        echo "(files are identical)"
    fi
    return $diff_rc
}
