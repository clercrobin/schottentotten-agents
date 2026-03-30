#!/bin/bash
# ============================================================
# AI Agent Factory — Layered Configuration Loader
#
# Resolves project context and loads config in layers:
#   1. Base defaults (config.sh)
#   2. Project overrides (projects/<name>/config.sh)
#   3. Project-specific STATE_DIR, LOG_DIR
#
# Project resolution order:
#   --project <name> flag > $AI_AGENT_PROJECT env > .current-project file
#
# Usage (by entry-point scripts):
#   source "$SCRIPT_DIR/config-loader.sh"           # auto-detect project
#   source "$SCRIPT_DIR/config-loader.sh" myproject  # explicit project
# ============================================================

export BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ────────────────────────────────────────────
# 1. Load base defaults
# ────────────────────────────────────────────
source "$BASE_DIR/config.sh"

# ────────────────────────────────────────────
# 2. Resolve project name
# ────────────────────────────────────────────
_resolve_project() {
    # Priority 1: explicit argument passed to this script
    if [ -n "${1:-}" ]; then
        echo "$1"
        return
    fi

    # Priority 2: --project flag already parsed by caller (PROJECT_NAME var)
    if [ -n "${PROJECT_NAME:-}" ]; then
        echo "$PROJECT_NAME"
        return
    fi

    # Priority 3: environment variable
    if [ -n "${AI_AGENT_PROJECT:-}" ]; then
        echo "$AI_AGENT_PROJECT"
        return
    fi

    # Priority 4: .current-project file
    if [ -f "$BASE_DIR/.current-project" ]; then
        cat "$BASE_DIR/.current-project"
        return
    fi

    # No project context — use base config only
    echo ""
}

export PROJECT_NAME
PROJECT_NAME=$(_resolve_project "${1:-}")

# ────────────────────────────────────────────
# 3. Load project overrides if project is set
# ────────────────────────────────────────────
export PROJECT_DIR=""

if [ -n "$PROJECT_NAME" ]; then
    PROJECT_DIR="$BASE_DIR/projects/$PROJECT_NAME"

    if [ -f "$PROJECT_DIR/config.sh" ]; then
        source "$PROJECT_DIR/config.sh"
    elif [ -d "$PROJECT_DIR" ]; then
        # Project dir exists but no config — that's OK, use base defaults
        :
    else
        echo "[config-loader] WARNING: project '$PROJECT_NAME' not found at $PROJECT_DIR" >&2
    fi
fi

# ────────────────────────────────────────────
# 4. Set project-specific paths (after overrides loaded)
# ────────────────────────────────────────────
if [ -n "$PROJECT_NAME" ] && [ -d "$PROJECT_DIR" ]; then
    export STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state}"
    export LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
else
    export STATE_DIR="${STATE_DIR:-$BASE_DIR/state}"
    export LOG_DIR="${LOG_DIR:-$BASE_DIR/logs}"
fi

mkdir -p "$STATE_DIR" "$LOG_DIR"

# Re-derive GITHUB_REPO_FULL in case GITHUB_OWNER or GITHUB_REPO were overridden
export GITHUB_REPO_FULL="${GITHUB_OWNER}/${GITHUB_REPO}"

# ────────────────────────────────────────────
# Helper: parse --project flag from script args
# Strips --project <name> from the argument list
# Usage: eval "$(parse_project_flag "$@")"
#   This sets PROJECT_NAME and updates the positional params
# ────────────────────────────────────────────
parse_project_flag() {
    local new_args=()
    local project=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --project)
                if [ -n "${2:-}" ]; then
                    project="$2"
                    shift 2
                else
                    echo "echo 'ERROR: --project requires a name' >&2; exit 1"
                    return
                fi
                ;;
            --project=*)
                project="${1#--project=}"
                shift
                ;;
            *)
                new_args+=("$1")
                shift
                ;;
        esac
    done

    if [ -n "$project" ]; then
        echo "PROJECT_NAME='$project'; set -- ${new_args[*]:+"${new_args[*]}"}; source \"\$BASE_DIR/config-loader.sh\" \"\$PROJECT_NAME\""
    else
        echo "set -- ${new_args[*]:+"${new_args[*]}"}"
    fi
}
