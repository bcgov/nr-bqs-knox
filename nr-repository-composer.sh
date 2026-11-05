#!/usr/bin/env bash
set -euo pipefail

# Modify this to change the image version used
IMAGE="ghcr.io/bcgov/nr-repository-composer:latest"
LOCAL_IMAGE="nr-repository-composer:latest"

# Set to "false" to skip pulling the latest image (uses cached version)
PULL_IMAGE="true"

# Use local image instead of GitHub registry
USE_LOCAL="false"

# NR Repository Composer runner script
# Usage: ./nr-repository-composer.sh [ --local ] [ --all ] <working-directory> [generator] [options...]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_usage() {
    echo "Usage: $0 [ --local ] [ --all ] <working-directory> [generator] [options...]"
    echo ""
    echo "Options:"
    echo "  --local           Use local image ($LOCAL_IMAGE) instead of GitHub registry"
    echo "  --all             Re-run every generator recorded in this repository's"
    echo "                    catalog-info.yaml files. Discovery happens inside"
    echo "                    the container and performs no git or GitHub side"
    echo "                    effects. Interactive by default; pass"
    echo "                    --headless --force through for a scripted run."
    echo ""
    echo "Generator Options:"
    echo "  --help-prompts    Show detailed descriptions of each prompt"
    echo "  --ask-answered    Re-prompt for already configured options"
    echo "  --force           Overwrite existing files without prompting"
    echo "  --headless        Exit with error if any prompt is required (for CI/CD)"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/repo backstage"
    echo "  $0 . gh-maven-build --help"
    echo "  $0 ~/projects/my-app gh-nodejs-build --ask-answered"
    echo "  $0 . --all                             # re-run all generators, interactively"
    echo "  $0 . --all --headless --force          # re-run all generators, non-interactively"
    echo "  $0 . --help"
    echo "  $0 --local . backstage"
    echo ""
    echo "Note: 'nr-repository-composer:' prefix is automatically added to the generator name"
}

# Consume boolean flags (--local, --all). These may appear before or after the
# working directory; everything else becomes the working directory / generator /
# passthrough arguments.
OPT_ALL=""
EXTRA_ARGS=()
ARGV=("$@")
for arg in "${ARGV[@]+"${ARGV[@]}"}"; do
    case "$arg" in
        --help|-h)
            print_usage
            exit 0
            ;;
        --local)
            USE_LOCAL="true"
            PULL_IMAGE="false"
            ;;
        --all)
            OPT_ALL="true"
            ;;
        *)
            # Keep the first non-flag argument as the working directory.
            if [ -z "${WORKING_DIR:-}" ]; then
                WORKING_DIR="$arg"
            else
                EXTRA_ARGS+=("$arg")
            fi
            ;;
    esac
done

# Select image based on --local flag
if [ "$USE_LOCAL" = "true" ]; then
    IMAGE="$LOCAL_IMAGE"
fi

# Check arguments
if [ -z "${WORKING_DIR:-}" ]; then
    print_usage
    exit 1
fi

# Detect container runtime (prefer podman over docker)
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
else
    echo "Error: Neither podman nor docker is installed or in PATH" >&2
    echo "Please install podman or docker to use this tool" >&2
    exit 1
fi

if [[ "$OPT_ALL" = "true" ]]; then
    GENERATOR=""
else
    if [ ${#EXTRA_ARGS[@]} -gt 0 ] && [[ "${EXTRA_ARGS[0]}" != -* ]]; then
        GENERATOR="${EXTRA_ARGS[0]}"
        EXTRA_ARGS=("${EXTRA_ARGS[@]:1}")
    else
        GENERATOR=""
    fi

    # Prepend nr-repository-composer: to generator name if not already present
    if [[ -n "$GENERATOR" && "$GENERATOR" != nr-repository-composer:* ]]; then
        GENERATOR="nr-repository-composer:$GENERATOR"
    fi
fi

# Resolve working directory to absolute path
if [ ! -d "$WORKING_DIR" ]; then
    echo "Error: Directory '$WORKING_DIR' does not exist" >&2
    exit 1
fi

WORKING_DIR="$(cd "$WORKING_DIR" && pwd)"

# Find git repository root by walking up the directory tree
find_git_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.git" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

GIT_ROOT=$(find_git_root "$WORKING_DIR") || true
if [ -z "$GIT_ROOT" ]; then
    echo "Error: No .git directory found in '$WORKING_DIR' or any parent directory" >&2
    echo "The composer must be run within a git repository" >&2
    exit 1
fi

# Build the container argument string for a given working directory (a path
# inside the git repo). $CONTAINER_CMD, $IMAGE, $GIT_ROOT and $PULL_IMAGE must
# already be set.
build_container_args() {
    local workdir="$1"
    local rel="${workdir#"$GIT_ROOT"}"
    rel="${rel#/}"    # Remove leading slash if present
    local args="run --rm -it -v ${GIT_ROOT}:/src"

    if [ -z "$rel" ]; then
        args="$args -w /src"
    else
        args="$args -w /src/$rel"
    fi

    if [ "$CONTAINER_CMD" = "podman" ]; then
        args="$args --userns keep-id"
        if [ "$PULL_IMAGE" = "true" ]; then
            args="$args --pull newer"
        fi
    else
        if [ "$PULL_IMAGE" = "true" ]; then
            args="$args --pull always"
        fi
    fi

    printf '%s' "$args"
}

# Dispatch to --all discovery or a single generator run.
#
# --all is handled inside the container: the image's entrypoint runs the
# backstage-scan generator to discover every generator recorded in the
# repository's catalog-info.yaml files, then re-runs each one. Discovery needs
# no host tooling. It performs no git or GitHub side effects — review the
# resulting changes with your own git workflow.
if [[ "$OPT_ALL" = "true" ]]; then
    # Always start at the repository root so Location targets resolve.
    CONTAINER_ARGS="$(build_container_args "$GIT_ROOT")"
    # shellcheck disable=SC2086
    if [ -z "${EXTRA_ARGS+set}" ]; then
        exec $CONTAINER_CMD $CONTAINER_ARGS $IMAGE --all
    fi
    exec $CONTAINER_CMD $CONTAINER_ARGS $IMAGE --all "${EXTRA_ARGS[@]}"
fi

# Single generator: build the arguments and run, passing through any extra options.
CONTAINER_ARGS="$(build_container_args "$WORKING_DIR")"
if [ -z "${EXTRA_ARGS+set}" ]; then
    # shellcheck disable=SC2086
    exec $CONTAINER_CMD $CONTAINER_ARGS $IMAGE "$GENERATOR"
fi
# shellcheck disable=SC2086
exec $CONTAINER_CMD $CONTAINER_ARGS $IMAGE "$GENERATOR" "${EXTRA_ARGS[@]}"
